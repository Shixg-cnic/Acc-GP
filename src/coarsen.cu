#include "check.hpp"
#include "coarsen.hpp"
#include "detail/sclp_record.hpp"
#include "detail/sclp_admission.hpp"
#include "detail/scratch_buffer.hpp"
#include "detail/scratch_pool.hpp"
#include "coarsen_rows.cuh"
#include "coarsen_matching.cuh"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <map>
#include <numeric>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <utility>
#include <vector>

#include <thrust/binary_search.h>
#include <thrust/count.h>
#include <thrust/copy.h>
#include <thrust/execution_policy.h>
#include <thrust/functional.h>
#include <thrust/gather.h>
#include <thrust/iterator/counting_iterator.h>
#include <thrust/iterator/discard_iterator.h>
#include <thrust/iterator/transform_iterator.h>
#include <thrust/reduce.h>
#include <thrust/scan.h>
#include <thrust/sequence.h>
#include <thrust/sort.h>
#include <thrust/transform_reduce.h>

#include <cub/device/device_radix_sort.cuh>
#include <cub/device/device_select.cuh>
#include <cuda/std/tuple>

namespace gpart {
namespace {
using detail::SclpRecordLayout;

// Carry original incident-weight sums through the same contraction map.
// They bound every descendant row because contraction only removes edges.
// Saturation disables packing instead of letting a validation sum wrap.
template <typename OffsetT, typename WeightT, int Width = 32>
__global__ void record_bound_kernel(
    std::int64_t n, const OffsetT* offsets, const WeightT* edge_weights,
    const std::int32_t* neighbors,
    unsigned long long* row_bounds, unsigned long long* maximum) {
    __shared__ unsigned long long block_degree[256 / Width];
    __shared__ unsigned long long block_raw_degree[256 / Width];
    __shared__ unsigned int block_flags[256 / Width];
    const auto v = (static_cast<std::int64_t>(blockIdx.x) * blockDim.x + threadIdx.x) / Width;
    const bool valid=v<n;
    const int lane = threadIdx.x & (Width - 1);
    const unsigned mask = Width == 32 ? 0xffffffffU : 0xffU << (threadIdx.x & 24);
    unsigned long long degree = 0;
    bool unsorted = false, zero = false, nonunit = false;
    const std::int64_t begin=valid ? offsets[v] : 0,end=valid ? offsets[v+1] : 0;
    for (std::int64_t e = begin+lane;e<end;e+=Width) {
        const auto w = static_cast<unsigned long long>(detail::edge_weight(edge_weights,e));
        degree = ~0ULL - degree < w ? ~0ULL : degree + w;
        unsorted = unsorted || (e > begin && neighbors[e] <= neighbors[e-1]);
        zero = zero || !w;
        nonunit = nonunit || w != 1;
    }
    for (int s = Width / 2; s; s >>= 1) {
        const auto other = __shfl_down_sync(mask, degree, s, Width);
        degree = ~0ULL - degree < other ? ~0ULL : degree + other;
    }
    const auto unsorted_lanes = __ballot_sync(0xffffffffU, unsorted) & mask;
    const auto zero_lanes = __ballot_sync(0xffffffffU, zero) & mask;
    const auto nonunit_lanes = __ballot_sync(0xffffffffU, nonunit) & mask;
    if (lane == 0) {
        if (valid) row_bounds[v]=degree;
        block_degree[threadIdx.x / Width]=degree;
        block_raw_degree[threadIdx.x / Width]=end - begin;
        block_flags[threadIdx.x / Width]=(unsorted_lanes ? 1U : 0U) |
            (zero_lanes ? 2U : 0U) | (nonunit_lanes ? 4U : 0U);
    }
    __syncthreads();
    if (!threadIdx.x) {
        unsigned long long largest=0, largest_raw=0;unsigned int flags=0;
        for (int i=0;i<256 / Width;++i) {
            largest=max(largest,block_degree[i]); largest_raw=max(largest_raw,block_raw_degree[i]);
            flags|=block_flags[i];
        }
        atomicMax(maximum,largest);
        atomicMax(maximum+3,largest_raw);
        if (flags & 1U) atomicExch(maximum+1,1ULL);
        if (flags & 6U) atomicOr(maximum+2, static_cast<unsigned long long>((flags >> 1) & 3U));
    }
}

template <typename OffsetT>
__global__ void contract_record_bounds(std::int64_t n, const std::int32_t* map,
    const unsigned long long* fine_bounds, unsigned long long* coarse_bounds,
    const OffsetT* offsets, OffsetT* raw_counts) {
    const auto v = static_cast<std::int64_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (v >= n) return;
    if (raw_counts) row_atomic_add(raw_counts + map[v], offsets[v + 1] - offsets[v]);
    auto* target = coarse_bounds + map[v];
    const auto amount = fine_bounds[v];
    auto previous = atomicCAS(target, 0ULL, 0ULL);
    while (true) {
        const auto sum = ~0ULL - previous < amount ? ~0ULL : previous + amount;
        const auto observed = atomicCAS(target, previous, sum);
        if (observed == previous) break;
        previous = observed;
    }
}

struct RowLimits { unsigned long long weight, records; };
template <typename OffsetT> struct RowLimitsAt {
    const unsigned long long* weights;
    const OffsetT* records;
    __host__ __device__ RowLimits operator()(std::int64_t i) const {
        return {weights[i], static_cast<unsigned long long>(records[i])};
    }
};
struct RowLimitsMaximum {
    __host__ __device__ RowLimits operator()(RowLimits a, RowLimits b) const {
        return {a.weight > b.weight ? a.weight : b.weight,
                a.records > b.records ? a.records : b.records};
    }
};
thread_local bool gpu_component_timings=true;
class GpuTimingScope {
    bool previous_=gpu_component_timings;
public:
    explicit GpuTimingScope(bool enabled) { gpu_component_timings=enabled; }
    ~GpuTimingScope() { gpu_component_timings=previous_; }
};
class GpuEventTimer {
public:
    GpuEventTimer() {
        if (!enabled_) return;
        CUDA_CHECK(cudaEventCreate(&start_));
        CUDA_CHECK(cudaEventCreate(&stop_));
        CUDA_CHECK(cudaEventRecord(start_));
    }

    ~GpuEventTimer() {
        if (!enabled_) return;
        cudaEventDestroy(stop_);
        cudaEventDestroy(start_);
    }

    double seconds() {
        if (!enabled_) return 0.0;
        CUDA_CHECK(cudaEventRecord(stop_));
        CUDA_CHECK(cudaEventSynchronize(stop_));
        float milliseconds = 0.0F;
        CUDA_CHECK(cudaEventElapsedTime(&milliseconds, start_, stop_));
        return static_cast<double>(milliseconds) * 1.0e-3;
    }

private:
    bool enabled_=gpu_component_timings;
    cudaEvent_t start_{};
    cudaEvent_t stop_{};
};

__device__ __forceinline__ std::uint32_t mix32(std::uint32_t x) {
    x ^= x >> 16;
    x *= 0x7feb352dU;
    x ^= x >> 15;
    x *= 0x846ca68bU;
    return x ^ (x >> 16);
}

template <typename OffsetT, typename WeightT>
__global__ void weighted_cut_kernel(
    std::int64_t n, const OffsetT* offsets,
    const std::int32_t* neighbors, const WeightT* edge_weights,
    const std::int32_t* labels, unsigned long long* cut) {
    const auto v = static_cast<std::int64_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (v >= n) return;
    unsigned long long local = 0;
    const int p = labels[v];
    for (auto e = offsets[v]; e < offsets[v + 1]; ++e) {
        if (labels[neighbors[e]] != p) local += detail::edge_weight(edge_weights,e);
    }
    if (local) atomicAdd(cut, local);
}

constexpr int WARPS_PER_BLOCK = 8;
constexpr int WARP_SIZE = 32;
constexpr std::uint64_t INVALID_KEY = std::numeric_limits<std::uint64_t>::max();

template <typename WeightT>
__device__ __forceinline__ void atomic_add_graph_weight(
    WeightT* address, WeightT value) {
    if constexpr (sizeof(WeightT) == sizeof(std::uint32_t)) {
        atomicAdd(reinterpret_cast<unsigned int*>(address),
                  static_cast<unsigned int>(value));
    } else {
        atomicAdd(reinterpret_cast<unsigned long long*>(address),
                  static_cast<unsigned long long>(value));
    }
}

template <typename WeightT>
__global__ void coarse_vertex_weights_kernel(
    std::int64_t n, const WeightT* vertex_weights,
    const std::int32_t* map, WeightT* coarse_weights) {
    const auto v = static_cast<std::int64_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (v >= n) return;
    atomic_add_graph_weight(coarse_weights + map[v], vertex_weights[v]);
}

template <typename OffsetT, typename WeightT, typename ValueT>
__global__ void encode_contraction_edges_kernel(
    std::int64_t n, const OffsetT* offsets,
    const std::int32_t* neighbors, const WeightT* edge_weights,
    const std::int32_t* map, std::uint64_t* keys, ValueT* values,
    SclpRecordLayout layout,bool combine_duplicates=false) {
    const int lane = threadIdx.x & (WARP_SIZE - 1);
    const auto warp = static_cast<std::int64_t>(blockIdx.x) *
                      WARPS_PER_BLOCK + (threadIdx.x / WARP_SIZE);
    if (warp >= n) return;
    const auto source = static_cast<std::uint32_t>(map[warp]);
    const std::int64_t begin = offsets[warp];
    const std::int64_t end = offsets[warp + 1];
    if (!combine_duplicates) {
        for (auto e=begin+lane;e<end;e+=WARP_SIZE) {
            const auto target=static_cast<std::uint32_t>(map[neighbors[e]]);
            keys[e]=source!=target ? layout.encode(source,target,detail::edge_weight(edge_weights,e)) : UINT64_MAX;
            if (!layout.packed()) values[e]=detail::edge_weight(edge_weights,e);
        }
        return;
    }
    for (auto base=begin;base<end;base+=WARP_SIZE) {
        const auto e=base+lane;
        const bool valid=e<end;
        const auto target=valid ? static_cast<std::uint32_t>(map[neighbors[e]]) : source;
        const auto active=__ballot_sync(0xffffffffU,valid && source!=target);
        ValueT weight=valid ? static_cast<ValueT>(detail::edge_weight(edge_weights,e)) : 0;
        bool leader=valid && source!=target;
        if (combine_duplicates && leader) {
            const auto peers=__match_any_sync(active,target);
            leader=lane==__ffs(peers)-1;
            if constexpr (sizeof(ValueT)==4) weight=__reduce_add_sync(peers,weight);
            else {
                ValueT sum=0;
                for(auto remaining=peers;remaining;remaining&=remaining-1)
                    sum+=__shfl_sync(peers,weight,__ffs(remaining)-1);
                weight=sum;
            }
        }
        // Both layouts reserve UINT64_MAX outside the valid structural keys.
        // A packed chunk may combine equal targets before global sorting;
        // exact reduction still merges records across all fine rows/chunks.
        if(valid) {
            keys[e] = leader ? layout.encode(source,target,weight) : UINT64_MAX;
            if (!layout.packed()) values[e] = detail::edge_weight(edge_weights,e);
        }
    }
}

struct ExternalContractionRecord {
    __host__ __device__ bool operator()(std::uint64_t record) const { return record!=UINT64_MAX; }
};

template <typename OffsetT, typename WeightT, typename ValueT>
__global__ void write_coarse_csr_kernel(
    std::int64_t count, const std::uint64_t* keys,
    const ValueT* values, std::int32_t* neighbors,
    WeightT* edge_weights, OffsetT* offsets, SclpRecordLayout layout) {
    const auto i = static_cast<std::int64_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (i >= count) return;
    const auto source = layout.source(keys[i]);
    neighbors[i] = static_cast<std::int32_t>(layout.target(keys[i]));
    edge_weights[i] = static_cast<WeightT>(layout.packed() ? keys[i] & layout.weight_mask : values[i]);
    if (i == 0 || source != layout.source(keys[i - 1])) {
        offsets[source] = static_cast<OffsetT>(i);
    }
}
constexpr int SCLP_LOW_DEGREE = 8;
constexpr int SCLP_MEDIUM_DEGREE = 256;
constexpr int SCLP_AFFINITY_WARPS_PER_BLOCK = 4;
constexpr int SCLP_MEDIUM_HASH_SIZE = 512;
constexpr std::int32_t SCLP_INVALID = 0x7fffffff;


#include "coarsen_residual.cuh"
#include "coarsen_sclp.cuh"
}  // namespace

struct SclpWorkspace::Impl {
    using VertexT = gpart::GraphTypes::VertexT;
    using WeightT = gpart::GraphTypes::WeightT;

    bool record_bound_known = false;
    bool positive_edge_weights = false;
    bool unit_edge_weights = false;
    bool row_local_contraction = false;
    bool track_weight_invariants = false;
    bool weight_invariants_known = false;
    std::uint64_t total_vertex_weight = 0;
    std::uint64_t maximum_vertex_weight = 0;
    bool sorted_unique_rows = false;
    std::int64_t original_vertices = 0;
    std::uint64_t maximum_row_weight = 0;
    detail::ScratchBuffer<unsigned long long> row_weight_bounds;
    detail::ScratchBuffer<unsigned long long> next_row_weight_bounds;
    detail::ScratchBuffer<gpart::GraphTypes::OffsetT> raw_row_offsets;
    detail::ScratchBuffer<gpart::GraphTypes::OffsetT> raw_row_cursors;
    detail::ScratchBuffer<VertexT> raw_neighbors;
    detail::ScratchBuffer<WeightT> raw_weights;
    SclpRecordLayout record_layout(std::int64_t n, std::uint64_t maximum) const {
        return record_bound_known ? SclpRecordLayout::checked(n, maximum, 1)
                                  : SclpRecordLayout{};
    }

    detail::ScratchBuffer<VertexT> clusters;
    detail::ScratchBuffer<std::uint8_t> residual_roles;
    detail::ScratchBuffer<unsigned long long> second_affinity;
    detail::ScratchBuffer<unsigned long long> degree_class_counts;
    detail::ScratchBuffer<VertexT> low_vertices;
    detail::ScratchBuffer<VertexT> medium_vertices;
    detail::ScratchBuffer<VertexT> high_vertices;
    detail::ScratchBuffer<VertexT> proposals;
    detail::ScratchBuffer<VertexT> order;
    detail::ScratchBuffer<VertexT> ordered_targets;
    detail::ScratchBuffer<VertexT> favorites;
    detail::ScratchBuffer<std::int32_t> pair_flags;
    detail::ScratchBuffer<std::int32_t> pair_positions;
    detail::ScratchBuffer<std::int32_t> nonempty_flags;
    detail::ScratchBuffer<std::int32_t> compact_ids;

    detail::ScratchBuffer<std::int64_t> high_edge_counts;
    detail::ScratchBuffer<std::int64_t> high_edge_offsets;

    detail::ScratchBuffer<std::uint32_t> proposal_ties;
    detail::ScratchBuffer<std::uint8_t> radix_temp;
    detail::ScratchBuffer<SclpAdmissionKey<std::uint64_t>> compact_admission_keys;
    detail::ScratchBuffer<SclpAdmissionKey<std::uint64_t>> sorted_admission_keys;
    detail::ScratchBuffer<SclpAdmissionKey<std::uint32_t>> compact_admission_keys32;
    detail::ScratchBuffer<SclpAdmissionKey<std::uint32_t>> sorted_admission_keys32;
    template <typename GainT> auto& admission_compact() {
        if constexpr(sizeof(GainT)==4) return compact_admission_keys32;
        else return compact_admission_keys;
    }
    template <typename GainT> auto& admission_sorted() {
        if constexpr(sizeof(GainT)==4) return sorted_admission_keys32;
        else return sorted_admission_keys;
    }

    detail::ScratchBuffer<unsigned long long> cluster_weights;
    detail::ScratchBuffer<std::uint64_t> affinity_keys;
    detail::ScratchBuffer<std::uint64_t> affinity_values;
    detail::ScratchBuffer<std::uint64_t> unique_keys;
    detail::ScratchBuffer<std::uint64_t> unique_values;
    // Narrow only after proving that the entire directed edge-weight sum fits.
    // Every affinity/reduced edge is a nonnegative subset of that sum, and
    // contraction cannot increase it. Keys and decision/admission arithmetic
    // retain their original types.
    bool packed_weights = false;
    detail::ScratchBuffer<std::uint32_t> packed_affinity_values;
    detail::ScratchBuffer<std::uint32_t> packed_unique_values;
    template <typename ValueT> auto& values() {
        if constexpr (sizeof(ValueT) == 4) return packed_affinity_values;
        else return affinity_values;
    }
    template <typename ValueT> auto& reduced_values() {
        if constexpr (sizeof(ValueT) == 4) return packed_unique_values;
        else return unique_values;
    }
    detail::ScratchBuffer<unsigned long long> best_affinity;
    detail::ScratchBuffer<unsigned long long> unrestricted_best_affinity;
    detail::ScratchBuffer<unsigned long long> current_affinity;
    detail::ScratchBuffer<unsigned long long> best_ties;
    detail::ScratchBuffer<unsigned long long> gains;
    detail::ScratchBuffer<std::uint64_t> ordered_weights;
    detail::ScratchBuffer<std::uint64_t> prefix_weights;
    detail::ScratchBuffer<unsigned long long> base_cluster_weights;
    detail::ScratchBuffer<std::uint64_t> pair_ones;
    detail::ScratchBuffer<std::uint64_t> pair_ranks;
    detail::ScratchBuffer<unsigned long long> counters;
    detail::ScratchBuffer<unsigned long long> role_diagnostics;
    detail::ScratchBuffer<unsigned long long> cut_counter;
    detail::ScratchBuffer<unsigned long long> cross_counter;
    detail::ScratchBuffer<std::uint64_t> diagnostic_member_counts;
    detail::ScratchBuffer<std::uint64_t> diagnostic_unit_weights;
    detail::ScratchBuffer<WeightT> diagnostic_sorted_cluster_weights;
};

SclpWorkspace::SclpWorkspace() : impl(std::make_unique<Impl>()) {}
SclpWorkspace::~SclpWorkspace() = default;
SclpWorkspace::SclpWorkspace(SclpWorkspace&&) noexcept = default;
SclpWorkspace& SclpWorkspace::operator=(SclpWorkspace&&) noexcept = default;

void SclpWorkspace::reserve_contract_buffers(std::int64_t max_edges) {
    if (max_edges < 0) {
        throw std::invalid_argument("negative contraction buffer size");
    }
    auto& ws = *impl;
    const auto capacity = static_cast<std::size_t>(max_edges);
    ws.affinity_keys.reserve(capacity);
    ws.unique_keys.reserve(capacity);
    ws.affinity_keys.resize(capacity);
    ws.unique_keys.resize(capacity);
    // When records fit, neither edge-sized value buffer is allocated. The
    // fallback grows them lazily if a later level exceeds its checked layout.
    if (ws.record_layout(ws.original_vertices, ws.maximum_row_weight).packed())
        return;
    const auto reserve_values = [&](auto& values, auto& unique_values) {
        using ValueT = typename std::decay_t<decltype(values)>::value_type;
        values.resize(capacity);
        unique_values.resize(capacity);
        std::size_t radix_bytes = 0;
        cub::DoubleBuffer<std::uint64_t> sort_keys(
            thrust::raw_pointer_cast(ws.affinity_keys.data()),
            thrust::raw_pointer_cast(ws.unique_keys.data()));
        cub::DoubleBuffer<ValueT> sort_values(
            thrust::raw_pointer_cast(values.data()),
            thrust::raw_pointer_cast(unique_values.data()));
        CUDA_CHECK(cub::DeviceRadixSort::SortPairs(
            nullptr, radix_bytes, sort_keys, sort_values,
            static_cast<gpart::GraphTypes::OffsetT>(max_edges)));
        ws.radix_temp.resize(radix_bytes);
    };
    if (ws.packed_weights) reserve_values(ws.packed_affinity_values, ws.packed_unique_values);
    else reserve_values(ws.affinity_values, ws.unique_values);
}

namespace {
template <typename CountT>
void sort_packed_records(detail::ScratchBuffer<std::uint64_t>& records,
    detail::ScratchBuffer<std::uint64_t>& sorted,
    detail::ScratchBuffer<std::uint8_t>& temporary, CountT count,
    SclpRecordLayout layout) {
    cub::DoubleBuffer<std::uint64_t> buffers(
        thrust::raw_pointer_cast(records.data()), thrust::raw_pointer_cast(sorted.data()));
    std::size_t bytes = 0;
    CUDA_CHECK(cub::DeviceRadixSort::SortKeys(
        nullptr, bytes, buffers, count, layout.weight_bits, 64));
    if (temporary.size() < bytes) temporary.resize(bytes);
    CUDA_CHECK(cub::DeviceRadixSort::SortKeys(
        thrust::raw_pointer_cast(temporary.data()), bytes, buffers,
        count, layout.weight_bits, 64));
    if (buffers.Current() == thrust::raw_pointer_cast(records.data())) records.swap(sorted);
}

std::int64_t reduce_packed_records(detail::ScratchBuffer<std::uint64_t>& records,
    const detail::ScratchBuffer<std::uint64_t>& sorted, std::int64_t count,
    SclpRecordLayout layout) {
    const auto keys = thrust::make_transform_iterator(sorted.begin(),
        detail::SclpRecordKey{layout.weight_bits});
    const auto reduced = thrust::reduce_by_key(detail::scratch_policy(), keys, keys + count,
        sorted.begin(), thrust::make_discard_iterator(), records.begin(),
        thrust::equal_to<std::uint64_t>(), detail::SclpRecordSum{layout.weight_mask});
    return static_cast<std::int64_t>(reduced.second - records.begin());
}
} // namespace

template <typename ValueT>
DeviceAggregateResult aggregate_typed(
    const DeviceWeightedGraph& graph, SclpWorkspace& workspace,
    int parts, std::uint32_t seed,
    int level, SclpStats& stats, bool diagnostics, int cluster_size_factor,
    bool pack_isolated, bool seed_matching, bool capacity_safe_fast_path) {
    auto& ws = *workspace.impl;
    GpuEventTimer aggregate_timer;
    const auto n = graph.vertices();
    const auto m = graph.edges();
    if (n <= 0 || n > std::numeric_limits<std::int32_t>::max()) {
        throw std::runtime_error("SCLP coarsening received an unsupported graph size");
    }
    constexpr int maximum_rounds = 4;
    constexpr bool two_hop_enabled = true;
    constexpr double two_hop_threshold = 0.60;
    const auto total_weight = ws.weight_invariants_known ? ws.total_vertex_weight : thrust::reduce(
        detail::scratch_policy(), graph.vertex_weights.begin(), graph.vertex_weights.end(),
        std::uint64_t{0}, thrust::plus<std::uint64_t>());
    const auto maximum_vertex = ws.weight_invariants_known ? ws.maximum_vertex_weight : thrust::reduce(
        detail::scratch_policy(), graph.vertex_weights.begin(), graph.vertex_weights.end(),
        std::uint64_t{0}, thrust::maximum<std::uint64_t>());
    if (ws.track_weight_invariants) {
        ws.total_vertex_weight = total_weight;
        ws.maximum_vertex_weight = maximum_vertex;
        ws.weight_invariants_known = true;
    }
    const auto denominator = static_cast<std::uint64_t>(cluster_size_factor) *
                             static_cast<std::uint64_t>(parts);
    const auto average_cap = total_weight / denominator +
                             (total_weight % denominator != 0 ? 1 : 0);
    stats.capacity = std::max(maximum_vertex, average_cap);

    const int vertex_blocks = static_cast<int>((n + 255) / 256);
    auto& clusters = ws.clusters;
    clusters.resize(static_cast<std::size_t>(n));
    auto& cluster_weights = ws.cluster_weights;
    std::int64_t initial_cluster_count = n;
    if (seed_matching) {
        // One useful seed pass, not a complete HEM trial. Keep roots and
        // weights directly; compact/build CSR only after residual aggregation.
        ws.proposals.resize(n);
        ws.nonempty_flags.resize(n);
        auto* roots = thrust::raw_pointer_cast(clusters.data());
        auto* choices = thrust::raw_pointer_cast(ws.proposals.data());
        CUDA_CHECK(cudaMemsetAsync(roots, 0xff, n * sizeof(std::int32_t)));
        const auto choose = [&](auto width) {
            constexpr int Width = decltype(width)::value;
            matching_choose<Width><<<static_cast<int>((n * Width + 255) / 256), 256>>>(
                n, thrust::raw_pointer_cast(graph.offsets.data()),
                thrust::raw_pointer_cast(graph.neighbors.data()),
                thrust::raw_pointer_cast(graph.edge_weights.data()),
                thrust::raw_pointer_cast(graph.vertex_weights.data()), roots, choices,
                stats.capacity, seed ^ (level * 0x9e3779b9U), nullptr);
        };
        if (m / n < 8) choose(std::integral_constant<int, 1>{});
        else choose(std::integral_constant<int, 32>{});
        matching_commit<<<vertex_blocks, 256>>>(n, choices, roots);
        matching_roots<<<vertex_blocks, 256>>>(n, roots,
            thrust::raw_pointer_cast(ws.nonempty_flags.data()));
        cluster_weights.assign(n, 0ULL);
        residual_seed_weights<<<vertex_blocks, 256>>>(n, roots,
            thrust::raw_pointer_cast(graph.vertex_weights.data()),
            thrust::raw_pointer_cast(cluster_weights.data()));
        CUDA_CHECK(cudaGetLastError());
        initial_cluster_count = thrust::reduce(detail::scratch_policy(),
            ws.nonempty_flags.begin(), ws.nonempty_flags.end(), std::int64_t{0});
        std::cout << "ml_residual_seed level=" << level << " rounds=1 pairs="
                  << n - initial_cluster_count << " clusters=" << initial_cluster_count << '\n';
    } else {
        thrust::sequence(detail::scratch_policy(),clusters.begin(), clusters.end());
        cluster_weights.assign(graph.vertex_weights.begin(), graph.vertex_weights.end());
    }
    ws.residual_roles.resize(n);
    ws.second_affinity.resize(n);
    SclpResidualPolicy residual_policy;

    // Degree classes are fixed for this graph level and built once. Low and
    // medium vertices are currently warp-per-vertex; only high vertices use
    // the global sort/reduce fallback.
    auto& low_vertices=ws.low_vertices;
    auto& medium_vertices=ws.medium_vertices;
    auto& high_vertices=ws.high_vertices;
    const bool implicit_low = graph.maximum_degree <= SCLP_LOW_DEGREE;
    unsigned long long counts[5] = {};
    if (implicit_low) {
        // The existing input metadata proves all rows belong to the low bin.
        // Use their IDs directly, avoiding three N-sized queue allocations.
        counts[0] = n;
        counts[4] = graph.maximum_degree;
    } else {
        low_vertices.resize(static_cast<std::size_t>(n));
        medium_vertices.resize(static_cast<std::size_t>(n));
        high_vertices.resize(graph.maximum_degree <= SCLP_MEDIUM_DEGREE ? 0 : static_cast<std::size_t>(n));
        ws.degree_class_counts.resize(5);
        auto* class_counts=thrust::raw_pointer_cast(ws.degree_class_counts.data());
        CUDA_CHECK(cudaMemsetAsync(class_counts,0,5*sizeof(unsigned long long)));
        if (n >= (1 << 20))
            sclp_compact_degree_classes_block<<<vertex_blocks,256>>>(n,
                thrust::raw_pointer_cast(graph.offsets.data()),thrust::raw_pointer_cast(low_vertices.data()),
                thrust::raw_pointer_cast(medium_vertices.data()),thrust::raw_pointer_cast(high_vertices.data()),class_counts);
        else
            sclp_compact_degree_classes<<<vertex_blocks,256>>>(n,
                thrust::raw_pointer_cast(graph.offsets.data()),thrust::raw_pointer_cast(low_vertices.data()),
                thrust::raw_pointer_cast(medium_vertices.data()),thrust::raw_pointer_cast(high_vertices.data()),class_counts);
        CUDA_CHECK(cudaGetLastError());
        CUDA_CHECK(cudaMemcpy(counts,class_counts,sizeof(counts),cudaMemcpyDeviceToHost));
    }
    const auto low_count=static_cast<std::int64_t>(counts[0]);
    const auto medium_count=static_cast<std::int64_t>(counts[1]);
    const auto high_count=static_cast<std::int64_t>(counts[2]);
    stats.has_heavy_rows=counts[3]!=0;
    stats.maximum_degree=counts[4];

    auto& high_edge_counts = ws.high_edge_counts;
    auto& high_edge_offsets = ws.high_edge_offsets;
    high_edge_counts.resize(static_cast<std::size_t>(high_count));
    high_edge_offsets.resize(static_cast<std::size_t>(high_count));
    const auto prepare_high_edges = [&](bool filter_sources, std::uint32_t role_salt,
                                        std::uint32_t mover_threshold) -> std::int64_t {
        if (high_count == 0) return 0;
        const int blocks = static_cast<int>((high_count + 255) / 256);
        sclp_high_edge_counts_kernel<<<blocks, 256>>>(
            high_count, thrust::raw_pointer_cast(high_vertices.data()),
            thrust::raw_pointer_cast(graph.offsets.data()),
            thrust::raw_pointer_cast(clusters.data()),
            role_salt, mover_threshold, filter_sources,
            thrust::raw_pointer_cast(high_edge_counts.data()), residual_policy);
        CUDA_CHECK(cudaGetLastError());
        thrust::exclusive_scan(detail::scratch_policy(), high_edge_counts.begin(), high_edge_counts.end(), high_edge_offsets.begin());
        return thrust::reduce(detail::scratch_policy(), high_edge_counts.begin(), high_edge_counts.end(), std::int64_t{0});
    };
    const auto high_edge_count = prepare_high_edges(false,0,0);
    std::int64_t singleton_heavy_count=0;
    if (stats.has_heavy_rows && ws.sorted_unique_rows) {
        // Favorites are not needed until two-hop, after singleton scanning.
        ws.favorites.resize(static_cast<std::size_t>(high_count));
        const auto end=thrust::copy_if(detail::scratch_policy(),high_vertices.begin(),
            high_vertices.begin()+high_count,ws.favorites.begin(),
            SclpHeavySingletonRow<gpart::GraphTypes::OffsetT>{thrust::raw_pointer_cast(graph.offsets.data())});
        singleton_heavy_count=end-ws.favorites.begin();
    }
    auto& affinity_keys = ws.affinity_keys;
    auto& affinity_values = ws.template values<ValueT>();
    auto& unique_keys = ws.unique_keys;
    auto& unique_values = ws.template reduced_values<ValueT>();
    const auto record_layout = ws.record_layout(n, ws.maximum_row_weight);
    if (affinity_keys.size() < static_cast<std::size_t>(high_edge_count)) {
        affinity_keys.resize(static_cast<std::size_t>(high_edge_count));
    }
    if (unique_keys.size() < static_cast<std::size_t>(high_edge_count)) {
        unique_keys.resize(static_cast<std::size_t>(high_edge_count));
    }
    if (!record_layout.packed()) {
        if (affinity_values.size() < static_cast<std::size_t>(high_edge_count))
            affinity_values.resize(static_cast<std::size_t>(high_edge_count));
        if (unique_values.size() < static_cast<std::size_t>(high_edge_count))
            unique_values.resize(static_cast<std::size_t>(high_edge_count));
    }
    auto& best_affinity = ws.best_affinity;
    auto& unrestricted_best_affinity = ws.unrestricted_best_affinity;
    auto& current_affinity = ws.current_affinity;
    auto& best_ties = ws.best_ties;
    auto& gains = ws.gains;
    auto& proposal_ties = ws.proposal_ties;
    auto& proposals = ws.proposals;
    auto& order = ws.order;
    auto& ordered_targets = ws.ordered_targets;
    auto& ordered_weights = ws.ordered_weights;
    auto& compact_admission_keys = ws.template admission_compact<ValueT>();
    auto& sorted_admission_keys = ws.template admission_sorted<ValueT>();
    best_affinity.resize(static_cast<std::size_t>(n));
    unrestricted_best_affinity.resize(static_cast<std::size_t>(n));
    current_affinity.resize(static_cast<std::size_t>(n));
    best_ties.resize(static_cast<std::size_t>(n));
    gains.resize(static_cast<std::size_t>(n));
    proposal_ties.resize(static_cast<std::size_t>(n));
    proposals.resize(static_cast<std::size_t>(n));
    order.resize(static_cast<std::size_t>(n));
    // Valid targets are below n. Compacting preserves ascending vertex IDs;
    // stable radix sort therefore supplies the old final vertex tie-break
    // without sorting that field. ValueT already has a proven global bound.
    int target_bits=0;
    for(auto value=static_cast<std::uint64_t>(n-1);value;value>>=1) ++target_bits;
    int row_gain_bits = 8 * sizeof(ValueT);
    if (ws.record_bound_known) {
        int bits = 0;
        for (auto bound=ws.maximum_row_weight;bound;bound>>=1) ++bits;
        row_gain_bits = std::max(1,std::min(row_gain_bits,bits));
    }
    auto& radix_temp = ws.radix_temp;
    auto& prefix_weights = ws.prefix_weights;
    auto& base_cluster_weights = ws.base_cluster_weights;
    auto& counters = ws.counters;
    auto& role_diagnostics = ws.role_diagnostics;
    auto& cut_counter = ws.cut_counter;
    counters.resize(diagnostics ? 3 : 0);
    role_diagnostics.resize(diagnostics ? 3 : 0);
    cut_counter.resize(diagnostics ? 1 : 0);
    const auto build_admission_order = [n, vertex_blocks, &graph, &order,
                                        &ordered_targets, &ordered_weights,
                                        &compact_admission_keys,
                                        &sorted_admission_keys, &radix_temp,
                                        target_bits](
        const detail::ScratchBuffer<std::int32_t>& source_targets,
        const detail::ScratchBuffer<unsigned long long>& source_gains,
        const detail::ScratchBuffer<std::uint32_t>& source_ties, int gain_bits) {
        // Select 32-bit IDs using only the proposal stencil. Reuse the order
        // buffer until radix decoding overwrites it after reading all IDs.
        const auto input = thrust::make_counting_iterator<std::int32_t>(0);
        const auto end = thrust::copy_if(detail::scratch_policy(), input, input + n,
            source_targets.begin(), order.begin(), SclpValidProposal{});
        const auto count = static_cast<std::int64_t>(end - order.begin());
        if (count == 0) return count;
        ordered_targets.resize(static_cast<std::size_t>(count));
        ordered_weights.resize(static_cast<std::size_t>(count));
        compact_admission_keys.resize(static_cast<std::size_t>(count));
        sorted_admission_keys.resize(static_cast<std::size_t>(count));
        const int admission_end_bit = 32 + gain_bits + target_bits;
        const SclpAdmissionRecord<ValueT> record{
            thrust::raw_pointer_cast(source_targets.data()),
            thrust::raw_pointer_cast(source_gains.data()),
            thrust::raw_pointer_cast(source_ties.data()), gain_bits};
        sclp_selected_admission_keys<<<static_cast<int>((count + 255) / 256), 256>>>(
            count, thrust::raw_pointer_cast(order.data()), record,
            thrust::raw_pointer_cast(compact_admission_keys.data()));
        CUDA_CHECK(cudaGetLastError());
        std::size_t radix_temp_bytes = 0;
        CUDA_CHECK(cub::DeviceRadixSort::SortKeys(nullptr, radix_temp_bytes,
            thrust::raw_pointer_cast(compact_admission_keys.data()),
            thrust::raw_pointer_cast(sorted_admission_keys.data()),
            static_cast<int>(count), SclpAdmissionKeyDecomposer<ValueT>{}, 0, admission_end_bit));
        if (radix_temp.size() < radix_temp_bytes) radix_temp.resize(radix_temp_bytes);
        auto call_temp_bytes = radix_temp_bytes;
        CUDA_CHECK(cub::DeviceRadixSort::SortKeys(
            thrust::raw_pointer_cast(radix_temp.data()), call_temp_bytes,
            thrust::raw_pointer_cast(compact_admission_keys.data()),
            thrust::raw_pointer_cast(sorted_admission_keys.data()),
            static_cast<int>(count), SclpAdmissionKeyDecomposer<ValueT>{},0,admission_end_bit));
        const int blocks = static_cast<int>((count + 255) / 256);
        sclp_decode_admission_keys_kernel<<<blocks, 256>>>(
            count, thrust::raw_pointer_cast(sorted_admission_keys.data()),
            thrust::raw_pointer_cast(graph.vertex_weights.data()),
            thrust::raw_pointer_cast(order.data()),
            thrust::raw_pointer_cast(ordered_targets.data()),
            thrust::raw_pointer_cast(ordered_weights.data()), gain_bits);
        CUDA_CHECK(cudaGetLastError());
        if (count>=16384 && gain_bits<8*sizeof(ValueT))
            std::cout << "ml_gpu_admission count=" << count << " gain_bits=" << gain_bits
                      << " key_bits=" << admission_end_bit << '\n';
        return count;
    };
    const auto device_cluster_cut = [&]() {
        CUDA_CHECK(cudaMemset(thrust::raw_pointer_cast(cut_counter.data()), 0,
                              sizeof(unsigned long long)));
        weighted_cut_kernel<<<vertex_blocks, 256>>>(
            n, thrust::raw_pointer_cast(graph.offsets.data()),
            thrust::raw_pointer_cast(graph.neighbors.data()),
            thrust::raw_pointer_cast(graph.edge_weights.data()),
            thrust::raw_pointer_cast(clusters.data()),
            thrust::raw_pointer_cast(cut_counter.data()));
        CUDA_CHECK(cudaGetLastError());
        unsigned long long directed = 0;
        CUDA_CHECK(cudaMemcpy(&directed,
            thrust::raw_pointer_cast(cut_counter.data()), sizeof(directed),
            cudaMemcpyDeviceToHost));
        if (directed & 1ULL) {
            throw std::runtime_error("SCLP cluster cut is not symmetric");
        }
        return static_cast<std::uint64_t>(directed / 2);
    };

    auto form_exact_proposals = [&, level, seed](
        int round, bool filter_roles, std::uint32_t mover_threshold,
        bool measure_affinity, bool need_regret = true) {
        GpuEventTimer affinity_timer;
        const auto role_salt = seed ^
            (static_cast<std::uint32_t>(level) * 0x9e3779b9U) ^
            (static_cast<std::uint32_t>(round) * 0x85ebca6bU) ^ 0x27d4eb2dU;
        const auto tie_salt = seed ^
            (static_cast<std::uint32_t>(level) * 0xc2b2ae35U) ^
            (static_cast<std::uint32_t>(round) * 0x165667b1U) ^ 0xd3a2646cU;
        residual_policy = {};
        {
            residual_freeze_roles<<<vertex_blocks, 256>>>(n,
                thrust::raw_pointer_cast(clusters.data()),
                thrust::raw_pointer_cast(graph.vertex_weights.data()),
                thrust::raw_pointer_cast(cluster_weights.data()), role_salt, mover_threshold, !filter_roles,
                thrust::raw_pointer_cast(ws.residual_roles.data()));
            CUDA_CHECK(cudaGetLastError());
            residual_policy = {thrust::raw_pointer_cast(ws.residual_roles.data()),
                thrust::raw_pointer_cast(cluster_weights.data()), stats.capacity,
                filter_roles && need_regret ? thrust::raw_pointer_cast(ws.second_affinity.data()) : nullptr};
        }
        // Before the first move each vertex has its own cluster. Certified
        // duplicate-free rows need only a weighted neighbor maximum, not a
        // hash table or global sort/reduce. Preserve exactly the same ties.
        const bool singleton_fast = round == 0 && !seed_matching && ws.sorted_unique_rows;
        // Low/medium and singleton kernels assign all four fields directly.
        // Only the general hub path uses atomic reductions into these arrays.
        if (!singleton_fast && high_count) {
            sclp_clear_high_affinity<<<static_cast<int>((high_count + 255) / 256), 256>>>(high_count,
                thrust::raw_pointer_cast(high_vertices.data()),
                thrust::raw_pointer_cast(current_affinity.data()), thrust::raw_pointer_cast(best_affinity.data()),
                thrust::raw_pointer_cast(best_ties.data()), thrust::raw_pointer_cast(unrestricted_best_affinity.data()), residual_policy.second);
            CUDA_CHECK(cudaGetLastError());
        }
        // Residual two-hop needs favorites only for remaining singletons.
        // Diagnostic paths retain complete scans.
        const bool filter_sources = !diagnostics;
        if (singleton_fast) {
            const auto singleton=[&](auto width,std::int64_t count,const auto& rows,bool identity=false,bool split_heavy=false) {
                if (!count) return;
                constexpr int Width=decltype(width)::value;
                sclp_singleton_affinity_kernel<gpart::GraphTypes::OffsetT,gpart::GraphTypes::WeightT,Width><<<static_cast<int>((count+256/Width-1)/(256/Width)),256>>>(
                    count,thrust::raw_pointer_cast(graph.offsets.data()),
                    thrust::raw_pointer_cast(graph.neighbors.data()),thrust::raw_pointer_cast(graph.edge_weights.data()),
                    role_salt,mover_threshold,tie_salt,filter_roles,filter_sources,
                    thrust::raw_pointer_cast(current_affinity.data()),thrust::raw_pointer_cast(best_affinity.data()),
                    thrust::raw_pointer_cast(best_ties.data()),thrust::raw_pointer_cast(unrestricted_best_affinity.data()),
                    identity ? nullptr : thrust::raw_pointer_cast(rows.data()),split_heavy, residual_policy);
            };
            singleton(std::integral_constant<int,8>{},low_count,low_vertices,implicit_low);
            singleton(std::integral_constant<int,32>{},medium_count,medium_vertices);
            singleton(std::integral_constant<int,32>{},high_count,high_vertices,false,singleton_heavy_count!=0);
            if (singleton_heavy_count) {
                sclp_singleton_heavy_affinity_kernel<<<static_cast<int>(singleton_heavy_count),256>>>(
                    thrust::raw_pointer_cast(ws.favorites.data()),thrust::raw_pointer_cast(graph.offsets.data()),
                    thrust::raw_pointer_cast(graph.neighbors.data()),thrust::raw_pointer_cast(graph.edge_weights.data()),
                    role_salt,mover_threshold,tie_salt,filter_roles,filter_sources,
                    thrust::raw_pointer_cast(current_affinity.data()),thrust::raw_pointer_cast(best_affinity.data()),
                    thrust::raw_pointer_cast(best_ties.data()),thrust::raw_pointer_cast(unrestricted_best_affinity.data()), residual_policy);
                std::cout << "ml_gpu_singleton_heavy_rows=" << singleton_heavy_count << " threads_per_row=256\n";
            }
            CUDA_CHECK(cudaGetLastError());
        }
        if (!singleton_fast && low_count > 0) {
            const int blocks = static_cast<int>(
                (low_count + WARPS_PER_BLOCK * 4 - 1) /
                (WARPS_PER_BLOCK * 4));
            sclp_affinity_low_match_kernel<<<blocks, 256>>>(
                low_count, implicit_low ? nullptr : thrust::raw_pointer_cast(low_vertices.data()),
                thrust::raw_pointer_cast(graph.offsets.data()),
                thrust::raw_pointer_cast(graph.neighbors.data()),
                thrust::raw_pointer_cast(graph.edge_weights.data()),
                thrust::raw_pointer_cast(clusters.data()),
                role_salt, mover_threshold, tie_salt, filter_roles, filter_sources,
                thrust::raw_pointer_cast(current_affinity.data()),
                thrust::raw_pointer_cast(best_affinity.data()),
                thrust::raw_pointer_cast(best_ties.data()),
                thrust::raw_pointer_cast(unrestricted_best_affinity.data()), residual_policy);
            CUDA_CHECK(cudaGetLastError());
        }
        if (!singleton_fast && medium_count > 0) {
            const int threads = SCLP_AFFINITY_WARPS_PER_BLOCK * WARP_SIZE;
            const int blocks = static_cast<int>(
                (medium_count + SCLP_AFFINITY_WARPS_PER_BLOCK - 1) /
                SCLP_AFFINITY_WARPS_PER_BLOCK);
            constexpr std::size_t shared_bytes =
                SCLP_AFFINITY_WARPS_PER_BLOCK * SCLP_MEDIUM_HASH_SIZE *
                (sizeof(std::int32_t) + sizeof(unsigned long long));
            sclp_affinity_medium_hash_kernel<<<blocks, threads, shared_bytes>>>(
                medium_count, thrust::raw_pointer_cast(medium_vertices.data()),
                thrust::raw_pointer_cast(graph.offsets.data()),
                thrust::raw_pointer_cast(graph.neighbors.data()),
                thrust::raw_pointer_cast(graph.edge_weights.data()),
                thrust::raw_pointer_cast(clusters.data()),
                role_salt, mover_threshold, tie_salt, filter_roles, filter_sources,
                thrust::raw_pointer_cast(current_affinity.data()),
                thrust::raw_pointer_cast(best_affinity.data()),
                thrust::raw_pointer_cast(best_ties.data()),
                thrust::raw_pointer_cast(unrestricted_best_affinity.data()), residual_policy);
            CUDA_CHECK(cudaGetLastError());
        }
        std::int64_t unique_count = 0;
        if (!singleton_fast && high_edge_count > 0) {
            const auto active_edges = prepare_high_edges(filter_sources,role_salt,mover_threshold);
            if (active_edges > 0) {
                sclp_fill_affinity_high_kernel<<<static_cast<int>(high_count), 256>>>(
                    high_count, thrust::raw_pointer_cast(high_vertices.data()),
                    thrust::raw_pointer_cast(high_edge_offsets.data()),
                    thrust::raw_pointer_cast(graph.offsets.data()),
                    thrust::raw_pointer_cast(graph.neighbors.data()),
                    thrust::raw_pointer_cast(graph.edge_weights.data()),
                    thrust::raw_pointer_cast(clusters.data()),
                    role_salt, mover_threshold, filter_sources,
                    thrust::raw_pointer_cast(affinity_keys.data()),
                    thrust::raw_pointer_cast(affinity_values.data()), record_layout, residual_policy);
                CUDA_CHECK(cudaGetLastError());
                if (record_layout.packed()) {
                    sort_packed_records(affinity_keys, unique_keys, radix_temp,
                        static_cast<gpart::GraphTypes::OffsetT>(active_edges), record_layout);
                    // Every valid encoded key is below the reserved sentinel,
                    // including when n is a power of two.
                    const auto valid_end = thrust::lower_bound(detail::scratch_policy(),
                        unique_keys.begin(), unique_keys.begin() + active_edges, INVALID_KEY);
                    unique_count = reduce_packed_records(affinity_keys, unique_keys,
                        valid_end - unique_keys.begin(), record_layout);
                } else {
                    std::size_t affinity_radix_bytes = 0;
                    cub::DoubleBuffer<std::uint64_t> sort_keys(
                        thrust::raw_pointer_cast(affinity_keys.data()),
                        thrust::raw_pointer_cast(unique_keys.data()));
                    cub::DoubleBuffer<ValueT> sort_values(
                        thrust::raw_pointer_cast(affinity_values.data()),
                        thrust::raw_pointer_cast(unique_values.data()));
                    CUDA_CHECK(cub::DeviceRadixSort::SortPairs(
                        nullptr, affinity_radix_bytes, sort_keys, sort_values,
                        static_cast<gpart::GraphTypes::OffsetT>(active_edges), 0, 2 * record_layout.vertex_bits));
                    radix_temp.resize(std::max(radix_temp.size(), affinity_radix_bytes));
                    auto affinity_radix_call_bytes = affinity_radix_bytes;
                    CUDA_CHECK(cub::DeviceRadixSort::SortPairs(
                        thrust::raw_pointer_cast(radix_temp.data()),
                        affinity_radix_call_bytes, sort_keys, sort_values,
                        static_cast<gpart::GraphTypes::OffsetT>(active_edges), 0, 2 * record_layout.vertex_bits));
                    // Keep the existing reduce input/output roles regardless of the
                    // number of radix passes. Only ownership changes, never edge order.
                    if (sort_keys.Current() == thrust::raw_pointer_cast(affinity_keys.data())) {
                        affinity_keys.swap(unique_keys);
                        affinity_values.swap(unique_values);
                    }
                    const auto valid_end = thrust::lower_bound(
                        detail::scratch_policy(), unique_keys.begin(),
                        unique_keys.begin() + active_edges,
                        INVALID_KEY);
                    const auto reduced = thrust::reduce_by_key(
                        detail::scratch_policy(), unique_keys.begin(), valid_end,
                        unique_values.begin(), affinity_keys.begin(), affinity_values.begin());
                    unique_count = static_cast<std::int64_t>(
                        reduced.first - affinity_keys.begin());
                }
            }
        }
        if (unique_count > 0) {
            const int blocks = static_cast<int>((unique_count + 255) / 256);
            sclp_affinity_baseline_kernel<<<blocks, 256>>>(
                unique_count, thrust::raw_pointer_cast(affinity_keys.data()),
                thrust::raw_pointer_cast(affinity_values.data()),
                thrust::raw_pointer_cast(clusters.data()),
                role_salt, mover_threshold, filter_roles,
                thrust::raw_pointer_cast(current_affinity.data()),
                thrust::raw_pointer_cast(best_affinity.data()),
                thrust::raw_pointer_cast(unrestricted_best_affinity.data()), record_layout, residual_policy);
            CUDA_CHECK(cudaGetLastError());
            sclp_best_tie_kernel<<<blocks, 256>>>(
                unique_count, thrust::raw_pointer_cast(affinity_keys.data()),
                thrust::raw_pointer_cast(affinity_values.data()),
                thrust::raw_pointer_cast(clusters.data()),
                thrust::raw_pointer_cast(best_affinity.data()),
                tie_salt, role_salt, mover_threshold, filter_roles,
                thrust::raw_pointer_cast(best_ties.data()), record_layout, residual_policy);
            CUDA_CHECK(cudaGetLastError());
        }
        if (diagnostics && filter_roles && need_regret) {
            // Independent CPU oracle, debug-only: sum original CSR edges by
            // target root, then sort feasible connections. This checks every
            // GPU affinity path, not just the final coarse graph's validity.
            const auto host = copy_device_weighted(graph);
            std::vector<std::int32_t> roots(n), targets(n);
            std::vector<std::uint8_t> roles(n);
            std::vector<unsigned long long> loads(n), first(n), second(n);
            thrust::copy(clusters.begin(), clusters.end(), roots.begin());
            thrust::copy(ws.residual_roles.begin(), ws.residual_roles.end(), roles.begin());
            thrust::copy(cluster_weights.begin(), cluster_weights.end(), loads.begin());
            thrust::copy(best_affinity.begin(), best_affinity.end(), first.begin());
            thrust::copy(ws.second_affinity.begin(), ws.second_affinity.end(), second.begin());
            for (std::int64_t v=0; v<n; ++v) {
                if (!roles[roots[v]]) continue;
                std::map<std::int32_t, unsigned long long> connections;
                for (auto e=host.offsets[v]; e<host.offsets[v+1]; ++e)
                    if (host.neighbors[e] != v)
                        connections[roots[host.neighbors[e]]] += host.edge_weights[e];
                std::vector<unsigned long long> eligible;
                for (const auto& entry : connections) {
                    const auto c=entry.first;
                    if (c != roots[v] && !roles[c] && loads[c] && loads[c]<=stats.capacity &&
                        loads[roots[v]]<=stats.capacity-loads[c]) eligible.push_back(entry.second);
                }
                std::sort(eligible.rbegin(),eligible.rend());
                if (first[v] != (eligible.empty()?0:eligible[0]) ||
                    second[v] != (eligible.size()<2?0:eligible[1]))
                    throw std::runtime_error("regret top-two affinity differs from CPU oracle at vertex " + std::to_string(v));
            }
        }
        if (diagnostics) {
            CUDA_CHECK(cudaMemset(
                thrust::raw_pointer_cast(role_diagnostics.data()), 0,
                3 * sizeof(unsigned long long)));
        }
        sclp_decode_gain_kernel<<<vertex_blocks, 256>>>(
            n, thrust::raw_pointer_cast(clusters.data()),
            thrust::raw_pointer_cast(current_affinity.data()),
            thrust::raw_pointer_cast(best_affinity.data()),
            thrust::raw_pointer_cast(best_ties.data()),
            thrust::raw_pointer_cast(unrestricted_best_affinity.data()),
            role_salt, mover_threshold, filter_roles,
            thrust::raw_pointer_cast(proposals.data()),
            thrust::raw_pointer_cast(gains.data()),
            thrust::raw_pointer_cast(proposal_ties.data()),
            diagnostics ? thrust::raw_pointer_cast(role_diagnostics.data()) : nullptr, residual_policy);
        CUDA_CHECK(cudaGetLastError());
        const auto affinity_seconds = affinity_timer.seconds();
        if (measure_affinity) stats.affinity_seconds += affinity_seconds;
    };

    std::int64_t cluster_count = initial_cluster_count;
    const std::int64_t desired_clusters = (n + 1) / 2;
    // Positive integer weights imply at most W vertices in a cluster of
    // weight W. Each has <= D neighbors; each singleton donor weighs <= M.
    // Therefore a receiver and ALL possible incoming requests weigh at most
    // W + W*D*M. Track a conservative upper bound across committed rounds.
    // A proof of fit makes the priority order irrelevant: all requests pass.
    std::uint64_t cluster_weight_bound = seed_matching
        ? (maximum_vertex > stats.capacity / 2 ? stats.capacity : 2 * maximum_vertex)
        : maximum_vertex;
    for (int round = 0; round < maximum_rounds; ++round) {
        if (static_cast<double>(cluster_count) <= 0.60 * n) break;
        const auto removable_clusters = std::max<std::int64_t>(
            0, cluster_count - desired_clusters);
        const double mover_fraction = std::min(
            0.50, static_cast<double>(removable_clusters) /
                  static_cast<double>(cluster_count));
        const auto mover_threshold = static_cast<std::uint32_t>(
            mover_fraction * 4294967296.0);
        const auto room = stats.capacity - cluster_weight_bound;
        const auto degree = stats.maximum_degree;
        const bool all_requests_fit = capacity_safe_fast_path &&
            (degree == 0 || cluster_weight_bound <= room / maximum_vertex / degree);
        const auto next_weight_bound = all_requests_fit
            ? cluster_weight_bound + cluster_weight_bound * degree * maximum_vertex
            : stats.capacity;
        form_exact_proposals(round, true, mover_threshold, true, !all_requests_fit);
        if (diagnostics) {
            unsigned long long host_role_diagnostics[3] = {};
            CUDA_CHECK(cudaMemcpy(
                host_role_diagnostics,
                thrust::raw_pointer_cast(role_diagnostics.data()),
                sizeof(host_role_diagnostics), cudaMemcpyDeviceToHost));
            stats.positive_gain_vertices = host_role_diagnostics[0];
            stats.role_blocked_vertices = host_role_diagnostics[1];
            stats.role_blocked_gain = host_role_diagnostics[2];
        }
        GpuEventTimer admission_timer;
        const auto cut_before = diagnostics ? device_cluster_cut() : 0;
        std::int64_t valid_count = 0;
        unsigned long long accepted = 0;
        unsigned long long rejected = 0;
        unsigned long long predicted_gain = 0;
        if (all_requests_fit) {
            auto* admission_counters = diagnostics ? thrust::raw_pointer_cast(counters.data()) : nullptr;
            if (diagnostics) CUDA_CHECK(cudaMemset(admission_counters, 0, 3 * sizeof(unsigned long long)));
            residual_commit_all<<<vertex_blocks, 256>>>(n,
                thrust::raw_pointer_cast(proposals.data()),
                thrust::raw_pointer_cast(graph.vertex_weights.data()),
                thrust::raw_pointer_cast(gains.data()),
                thrust::raw_pointer_cast(clusters.data()),
                thrust::raw_pointer_cast(cluster_weights.data()), admission_counters);
            CUDA_CHECK(cudaGetLastError());
            if (diagnostics) {
                unsigned long long host_counters[3] = {};
                CUDA_CHECK(cudaMemcpy(host_counters, admission_counters, sizeof(host_counters), cudaMemcpyDeviceToHost));
                accepted = host_counters[0]; predicted_gain = host_counters[2];
            }
        } else {
            valid_count = build_admission_order(
                proposals, ws.second_affinity, proposal_ties,
                round==0 && !seed_matching && ws.sorted_unique_rows && ws.unit_edge_weights && n==ws.original_vertices
                    ? 1 : row_gain_bits);
        }
        if (!all_requests_fit && valid_count > 0) {
            const int blocks = static_cast<int>((valid_count + 255) / 256);
            prefix_weights.resize(static_cast<std::size_t>(valid_count));
            base_cluster_weights.resize(static_cast<std::size_t>(valid_count));
            thrust::inclusive_scan_by_key(
                detail::scratch_policy(), ordered_targets.begin(),
                ordered_targets.begin() + valid_count, ordered_weights.begin(),
                prefix_weights.begin());
            // Snapshot the same pre-batch receiver loads only for proposals.
            thrust::gather(detail::scratch_policy(), ordered_targets.begin(),
                ordered_targets.begin() + valid_count, cluster_weights.begin(), base_cluster_weights.begin());
            if (diagnostics) {
                CUDA_CHECK(cudaMemset(thrust::raw_pointer_cast(counters.data()), 0,
                                      3 * sizeof(unsigned long long)));
            }
            auto* admission_counters = diagnostics
                ? thrust::raw_pointer_cast(counters.data()) : nullptr;
            sclp_commit_kernel<<<blocks, 256>>>(
                valid_count, thrust::raw_pointer_cast(order.data()),
                thrust::raw_pointer_cast(ordered_targets.data()),
                thrust::raw_pointer_cast(ordered_weights.data()),
                thrust::raw_pointer_cast(prefix_weights.data()),
                thrust::raw_pointer_cast(base_cluster_weights.data()),
                stats.capacity, thrust::raw_pointer_cast(gains.data()),
                thrust::raw_pointer_cast(clusters.data()),
                thrust::raw_pointer_cast(cluster_weights.data()),
                admission_counters,
                diagnostics ? admission_counters + 1 : nullptr,
                diagnostics ? admission_counters + 2 : nullptr);
            CUDA_CHECK(cudaGetLastError());
            if (diagnostics) {
                unsigned long long host_counters[3] = {};
                CUDA_CHECK(cudaMemcpy(
                    host_counters, admission_counters, sizeof(host_counters),
                    cudaMemcpyDeviceToHost));
                accepted = host_counters[0];
                rejected = host_counters[1];
                predicted_gain = host_counters[2];
            }
        }

        const auto previous_cluster_count = cluster_count;
        cluster_count = static_cast<std::int64_t>(thrust::count_if(
            detail::scratch_policy(), cluster_weights.begin(), cluster_weights.end(), SclpNonzeroWeight{}));
        {
            const auto removed = previous_cluster_count - cluster_count;
            if (all_requests_fit) valid_count = removed;
            if (removed < 0 || removed > valid_count ||
                (diagnostics && accepted != static_cast<unsigned long long>(removed)))
                throw std::runtime_error("residual singleton merge accounting failed");
            accepted = static_cast<unsigned long long>(removed);
            rejected = static_cast<unsigned long long>(valid_count) - accepted;
            std::cout << "ml_residual_round level=" << level << " round=" << round
                      << " proposals=" << valid_count << " accepted=" << accepted
                      << " capacity_rejected=" << rejected
                      << " regret_elided=" << all_requests_fit << " clusters=" << cluster_count << '\n';
        }
        cluster_weight_bound = next_weight_bound;
        stats.lp_accepted += accepted;
        stats.capacity_rejected += rejected;
        stats.proposal_count += static_cast<std::uint64_t>(valid_count);
        ++stats.rounds;
        stats.admission_seconds += admission_timer.seconds();
        const auto cut_after = diagnostics ? device_cluster_cut() : 0;
        if (diagnostics && cut_after > cut_before) {
            throw std::runtime_error("SCLP synchronous batch increased cluster cut");
        }
        std::cout << "ml_gpu_sclp_round level=" << level
                  << " round=" << round
                  << " proposals=" << valid_count;
        if (diagnostics) {
            std::cout << " accepted=" << accepted
                      << " capacity_rejected=" << rejected
                      << " predicted_gain=" << predicted_gain
                      << " capacity_rejection_ratio="
                      << (valid_count == 0 ? 0.0 :
                          static_cast<double>(rejected) /
                          static_cast<double>(valid_count))
                      << " cut_before=" << cut_before
                      << " cut_after=" << cut_after
                      << " actual_gain=" << (cut_before - cut_after)
                      << " positive_gain_vertices="
                      << stats.positive_gain_vertices
                      << " role_blocked=" << stats.role_blocked_vertices
                      << " role_blocked_gain=" << stats.role_blocked_gain;
        }
        std::cout << " mover_fraction=" << mover_fraction
                  << " clusters=" << cluster_count
                  << " contraction_ratio="
                  << static_cast<double>(cluster_count) / static_cast<double>(n)
                  << '\n';
        if (static_cast<double>(cluster_count) <= 0.60 * n) break;
    }

    if (pack_isolated) {
        const auto all = thrust::make_counting_iterator<std::int32_t>(0);
        const ZeroDegreeVertex<gpart::GraphTypes::OffsetT> zero_degree{
            thrust::raw_pointer_cast(graph.offsets.data())};
        const auto count = thrust::count_if(detail::scratch_policy(), all, all+n, zero_degree);
        if (count > 1) {
            detail::ScratchBuffer<std::int32_t> isolated(count);
            detail::ScratchBuffer<std::uint64_t> prefix(count);
            thrust::copy_if(detail::scratch_policy(), all, all+n, isolated.begin(), zero_degree);
            thrust::gather(detail::scratch_policy(),isolated.begin(), isolated.end(), graph.vertex_weights.begin(), prefix.begin());
            thrust::inclusive_scan(detail::scratch_policy(), prefix.begin(), prefix.end(), prefix.begin());
            const std::uint64_t total = prefix[count-1];
            detail::ScratchBuffer<std::int32_t> representatives(
                total/stats.capacity+(total%stats.capacity!=0), std::numeric_limits<std::int32_t>::max());
            const auto blocks = static_cast<int>((count+255)/256);
            isolated_representative_kernel<<<blocks,256>>>(count,
                thrust::raw_pointer_cast(isolated.data()), thrust::raw_pointer_cast(prefix.data()),
                thrust::raw_pointer_cast(graph.vertex_weights.data()), stats.capacity,
                thrust::raw_pointer_cast(representatives.data()));
            CUDA_CHECK(cudaGetLastError());
            isolated_commit_kernel<<<blocks,256>>>(count,
                thrust::raw_pointer_cast(isolated.data()), thrust::raw_pointer_cast(prefix.data()),
                thrust::raw_pointer_cast(graph.vertex_weights.data()), stats.capacity,
                thrust::raw_pointer_cast(representatives.data()),
                thrust::raw_pointer_cast(clusters.data()), thrust::raw_pointer_cast(cluster_weights.data()));
            CUDA_CHECK(cudaGetLastError());
            cluster_count = static_cast<std::int64_t>(thrust::count_if(
                detail::scratch_policy(), cluster_weights.begin(), cluster_weights.end(), SclpNonzeroWeight{}));
            std::cout << "ml_gpu_isolated_pack level=" << level << " isolated_vertices=" << count
                      << " isolated_weight=" << total << " coarse_vertices=" << cluster_count << '\n';
        }
    }

    // Simple two-hop fallback: remaining singleton vertices with the same
    // one-hop favorite form at most one deterministic capacity-bounded group.
    // This is a fallback, not part of the SCLP quality claim.
    const bool two_hop_triggered = two_hop_enabled &&
        static_cast<double>(cluster_count) > two_hop_threshold * n;
    if (two_hop_triggered || diagnostics) {
        GpuEventTimer two_hop_timer;
        const auto fallback_cut_before = diagnostics ? device_cluster_cut() : 0;
        form_exact_proposals(4, false, 0, false);
        auto& favorites = ws.favorites;
        favorites.resize(static_cast<std::size_t>(n));
        sclp_singleton_favorite_kernel<<<vertex_blocks, 256>>>(
            n, thrust::raw_pointer_cast(graph.vertex_weights.data()),
            thrust::raw_pointer_cast(cluster_weights.data()),
            thrust::raw_pointer_cast(clusters.data()),
            thrust::raw_pointer_cast(proposals.data()),
            thrust::raw_pointer_cast(favorites.data()));
        CUDA_CHECK(cudaGetLastError());
        const auto singleton_candidates = build_admission_order(
            favorites, gains, proposal_ties, row_gain_bits);
        stats.singleton_with_favorite = static_cast<std::uint64_t>(
            singleton_candidates);
        if (singleton_candidates > 0) {
            const int blocks = static_cast<int>((singleton_candidates + 255) / 256);
            auto& pair_ones = ws.pair_ones;
            auto& pair_ranks = ws.pair_ranks;
            pair_ones.resize(static_cast<std::size_t>(singleton_candidates));
            pair_ranks.resize(static_cast<std::size_t>(singleton_candidates));
            thrust::fill(detail::scratch_policy(),pair_ones.begin(), pair_ones.end(), std::uint64_t{1});
            thrust::inclusive_scan_by_key(
                detail::scratch_policy(), ordered_targets.begin(),
                ordered_targets.begin() + singleton_candidates,
                pair_ones.begin(), pair_ranks.begin());
            auto& pair_flags = ws.pair_flags;
            auto& pair_positions = ws.pair_positions;
            pair_flags.resize(static_cast<std::size_t>(singleton_candidates));
            pair_positions.resize(static_cast<std::size_t>(singleton_candidates));
            sclp_pair_flags_kernel<<<blocks, 256>>>(
                singleton_candidates, thrust::raw_pointer_cast(order.data()),
                thrust::raw_pointer_cast(ordered_weights.data()),
                thrust::raw_pointer_cast(pair_ranks.data()), stats.capacity,
                thrust::raw_pointer_cast(pair_flags.data()));
            CUDA_CHECK(cudaGetLastError());
            thrust::exclusive_scan(
                detail::scratch_policy(), pair_flags.begin(), pair_flags.end(), pair_positions.begin());
            const auto pair_count = static_cast<std::uint64_t>(thrust::count(
                detail::scratch_policy(), pair_flags.begin(), pair_flags.end(), std::int32_t{1}));
            stats.pairable_singletons = 2 * pair_count;
            const auto merge_budget = static_cast<std::uint64_t>(
                std::max<std::int64_t>(0, cluster_count - desired_clusters));
            const auto selected_count = std::min(pair_count, merge_budget);
            if (two_hop_triggered && selected_count > 0) {
                auto* merge_counter = diagnostics
                    ? thrust::raw_pointer_cast(counters.data()) : nullptr;
                if (diagnostics) {
                    CUDA_CHECK(cudaMemset(
                        merge_counter, 0, sizeof(unsigned long long)));
                }
                sclp_two_hop_pair_commit_kernel<<<blocks, 256>>>(
                    singleton_candidates, thrust::raw_pointer_cast(order.data()),
                    thrust::raw_pointer_cast(pair_flags.data()),
                    thrust::raw_pointer_cast(pair_positions.data()), merge_budget,
                    thrust::raw_pointer_cast(ordered_weights.data()),
                    thrust::raw_pointer_cast(clusters.data()),
                    thrust::raw_pointer_cast(cluster_weights.data()),
                    merge_counter);
                CUDA_CHECK(cudaGetLastError());
                stats.two_hop_merged = selected_count;
                if (diagnostics) {
                    CUDA_CHECK(cudaMemcpy(
                        &stats.two_hop_merged, merge_counter,
                        sizeof(stats.two_hop_merged), cudaMemcpyDeviceToHost));
                }
            }
        }
        cluster_count = static_cast<std::int64_t>(thrust::count_if(
            detail::scratch_policy(), cluster_weights.begin(), cluster_weights.end(), SclpNonzeroWeight{}));
        if (diagnostics) {
            const auto fallback_cut_after = device_cluster_cut();
            if (fallback_cut_after > fallback_cut_before) {
                throw std::runtime_error("SCLP two-hop pairing increased cluster cut");
            }
            std::cout << "ml_gpu_sclp_two_hop level=" << level
                      << " enabled=" << (two_hop_enabled ? 1 : 0)
                      << " threshold=" << two_hop_threshold
                      << " triggered=" << (two_hop_triggered ? 1 : 0)
                      << " singleton_with_favorite="
                      << stats.singleton_with_favorite
                      << " pairable_singletons=" << stats.pairable_singletons
                      << " merged=" << stats.two_hop_merged
                      << " cut_before=" << fallback_cut_before
                      << " cut_after=" << fallback_cut_after
                      << " actual_gain="
                      << (fallback_cut_before - fallback_cut_after) << '\n';
        }
        stats.two_hop_seconds = two_hop_timer.seconds();
    }

    GpuEventTimer compact_timer;
    auto& nonempty_flags = ws.nonempty_flags;
    auto& compact_ids = ws.compact_ids;
    nonempty_flags.resize(static_cast<std::size_t>(n));
    compact_ids.resize(static_cast<std::size_t>(n));
    sclp_nonempty_cluster_kernel<<<vertex_blocks, 256>>>(
        n, thrust::raw_pointer_cast(cluster_weights.data()),
        thrust::raw_pointer_cast(nonempty_flags.data()));
    CUDA_CHECK(cudaGetLastError());
    thrust::exclusive_scan(detail::scratch_policy(), nonempty_flags.begin(), nonempty_flags.end(),
                           compact_ids.begin());

    DeviceAggregateResult out;
    out.coarse_vertices = static_cast<std::int32_t>(cluster_count);
    out.capacity = stats.capacity;
    out.map.resize(static_cast<std::size_t>(n));
    sclp_compact_map_kernel<<<vertex_blocks, 256>>>(
        n, thrust::raw_pointer_cast(clusters.data()),
        thrust::raw_pointer_cast(compact_ids.data()),
        thrust::raw_pointer_cast(out.map.data()));
    CUDA_CHECK(cudaGetLastError());
    out.vertex_weights.resize(static_cast<std::size_t>(out.coarse_vertices));
    thrust::fill(detail::scratch_policy(),
        out.vertex_weights.begin(), out.vertex_weights.end(),
        gpart::GraphTypes::WeightT{0});
    coarse_vertex_weights_kernel<<<vertex_blocks, 256>>>(
        n, thrust::raw_pointer_cast(graph.vertex_weights.data()),
        thrust::raw_pointer_cast(out.map.data()),
        thrust::raw_pointer_cast(out.vertex_weights.data()));
    CUDA_CHECK(cudaGetLastError());
    CUDA_CHECK(cudaDeviceSynchronize());
    out.maximum_weight = thrust::reduce(
        detail::scratch_policy(), out.vertex_weights.begin(), out.vertex_weights.end(),
        std::uint64_t{0}, thrust::maximum<std::uint64_t>());
    if (ws.track_weight_invariants) ws.maximum_vertex_weight = out.maximum_weight;
    if (out.maximum_weight > stats.capacity) {
        throw std::runtime_error("SCLP coarsening exceeded cluster capacity");
    }
    stats.compact_seconds = compact_timer.seconds();
    stats.aggregate_seconds = aggregate_timer.seconds();
    std::uint64_t weight_p50 = 0;
    std::uint64_t weight_p90 = 0;
    std::uint64_t weight_p99 = 0;
    if (diagnostics) {
        // A singleton cluster has exactly one member; count it from the compact
        // map rather than comparing vertex and aggregate weights.
        auto& member_counts = ws.diagnostic_member_counts;
        auto& unit_weights = ws.diagnostic_unit_weights;
        member_counts.resize(static_cast<std::size_t>(out.coarse_vertices));
        unit_weights.resize(static_cast<std::size_t>(n));
        thrust::fill(detail::scratch_policy(),member_counts.begin(), member_counts.end(), std::uint64_t{0});
        thrust::fill(detail::scratch_policy(),unit_weights.begin(), unit_weights.end(), std::uint64_t{1});
        coarse_vertex_weights_kernel<<<vertex_blocks, 256>>>(
            n, thrust::raw_pointer_cast(unit_weights.data()),
            thrust::raw_pointer_cast(out.map.data()),
            thrust::raw_pointer_cast(member_counts.data()));
        CUDA_CHECK(cudaGetLastError());
        stats.singleton_count = static_cast<std::uint64_t>(thrust::count(
            detail::scratch_policy(), member_counts.begin(), member_counts.end(), std::uint64_t{1}));
        auto& sorted_cluster_weights = ws.diagnostic_sorted_cluster_weights;
        sorted_cluster_weights.assign(out.vertex_weights.begin(),out.vertex_weights.end());
        thrust::sort(detail::scratch_policy(), sorted_cluster_weights.begin(), sorted_cluster_weights.end());
        const auto weight_percentile = [&](double fraction) {
            const auto index = std::min<std::size_t>(
                sorted_cluster_weights.size() - 1,
                static_cast<std::size_t>(fraction * static_cast<double>(
                    sorted_cluster_weights.size() - 1)));
            return static_cast<std::uint64_t>(sorted_cluster_weights[index]);
        };
        weight_p50 = weight_percentile(0.50);
        weight_p90 = weight_percentile(0.90);
        weight_p99 = weight_percentile(0.99);
    }
    const double capacity_rejection_ratio = stats.proposal_count == 0 ? 0.0 :
        static_cast<double>(stats.capacity_rejected) /
        static_cast<double>(stats.proposal_count);
    std::cout << "ml_gpu_sclp level=" << level
              << " fine_vertices=" << n
              << " coarse_vertices=" << out.coarse_vertices
              << " contraction_ratio="
              << static_cast<double>(out.coarse_vertices) / static_cast<double>(n)
              << " beta=" << cluster_size_factor
              << " cluster_cap=" << stats.capacity
              << " lp_rounds=" << stats.rounds
              << " two_hop_enabled=" << (two_hop_enabled ? 1 : 0)
              << " two_hop_threshold=" << two_hop_threshold;
    if (diagnostics) {
        std::cout << " lp_accepted=" << stats.lp_accepted
              << " capacity_rejected=" << stats.capacity_rejected
              << " capacity_rejection_ratio=" << capacity_rejection_ratio
              << " singleton=" << stats.singleton_count
              << " positive_gain_vertices=" << stats.positive_gain_vertices
              << " role_blocked=" << stats.role_blocked_vertices
              << " role_blocked_gain=" << stats.role_blocked_gain
              << " singleton_with_favorite=" << stats.singleton_with_favorite
              << " pairable_singletons=" << stats.pairable_singletons
              << " two_hop_merged=" << stats.two_hop_merged
              << " weight_p50=" << weight_p50
              << " weight_p90=" << weight_p90
              << " weight_p99=" << weight_p99
              << " affinity_seconds=" << stats.affinity_seconds
              << " admission_seconds=" << stats.admission_seconds
              << " two_hop_seconds=" << stats.two_hop_seconds;
    }
    std::cout
              << " weight_max=" << out.maximum_weight
              << " weight_max_over_cap="
              << static_cast<double>(out.maximum_weight) /
                 static_cast<double>(stats.capacity)
              << " low_vertices=" << low_count
              << " medium_vertices=" << medium_count
              << " high_vertices=" << high_count
              << " hub_edge_entries=" << high_edge_count
              << " hub_sort_fraction="
              << (m == 0 ? 0.0 :
                  static_cast<double>(high_edge_count) / static_cast<double>(m))
              << " seed=" << seed
              << " diagnostics=" << (diagnostics ? 1 : 0) << '\n';
    return out;
}

DeviceAggregateResult aggregate(
    const DeviceWeightedGraph& graph, SclpWorkspace& workspace,
    int parts, std::uint32_t seed, int level, SclpStats& stats, bool diagnostics,
    int cluster_size_factor, bool pack_isolated, bool seed_matching, bool capacity_safe_fast_path) {
    if (parts < 2 || parts > kMaxParts || cluster_size_factor < 2)
        throw std::invalid_argument("invalid SCLP cluster capacity options");
    if (workspace.impl->packed_weights)
        return aggregate_typed<std::uint32_t>(graph, workspace, parts, seed, level, stats, diagnostics, cluster_size_factor, pack_isolated, seed_matching, capacity_safe_fast_path);
    return aggregate_typed<std::uint64_t>(graph, workspace, parts, seed, level, stats, diagnostics, cluster_size_factor, pack_isolated, seed_matching, capacity_safe_fast_path);
}


DeviceWeightedGraph contract_short_rows(
    const DeviceWeightedGraph& fine, DeviceAggregateResult& aggregate,
    SclpWorkspace& workspace, ContractionTimings& timings,
    std::uint64_t raw_row_bound) {
    using OffsetT = gpart::GraphTypes::OffsetT;
    auto& ws = *workspace.impl;
    const auto n = fine.vertices(), m = fine.edges();
    const auto rows = static_cast<std::int64_t>(aggregate.coarse_vertices);
    auto& raw_offsets = [&]() -> auto& {
        if constexpr (sizeof(OffsetT) == 4) return ws.compact_ids;
        else return ws.raw_row_offsets;
    }();
    auto& cursors = [&]() -> auto& {
        if constexpr (sizeof(OffsetT) == 4) return ws.nonempty_flags;
        else return ws.raw_row_cursors;
    }();
    GpuEventTimer bucket_timer;
    raw_offsets.resize(static_cast<std::size_t>(rows) + 1);
    cursors.resize(static_cast<std::size_t>(rows));
    // Raw row counts were accumulated with the record bounds; reuse them.
    thrust::exclusive_scan(detail::scratch_policy(), raw_offsets.begin(), raw_offsets.end(), raw_offsets.begin());
    thrust::copy(detail::scratch_policy(), raw_offsets.begin(), raw_offsets.begin() + rows, cursors.begin());
    ws.raw_neighbors.resize(static_cast<std::size_t>(m));
    ws.raw_weights.resize(static_cast<std::size_t>(m));
    contraction_row_scatter<<<static_cast<int>((n + 31) / 32), 256>>>(n,
        thrust::raw_pointer_cast(fine.offsets.data()), thrust::raw_pointer_cast(fine.neighbors.data()),
        thrust::raw_pointer_cast(fine.edge_weights.data()), thrust::raw_pointer_cast(aggregate.map.data()),
        thrust::raw_pointer_cast(cursors.data()), thrust::raw_pointer_cast(ws.raw_neighbors.data()),
        thrust::raw_pointer_cast(ws.raw_weights.data()));
    CUDA_CHECK(cudaGetLastError());
    timings.compact_seconds = bucket_timer.seconds();
    DeviceWeightedGraph coarse;
    coarse.offsets.resize(static_cast<std::size_t>(rows) + 1);
    GpuEventTimer sort_timer;
    contraction_sort_rows<<<static_cast<int>((rows + 7) / 8), 256>>>(rows,
        thrust::raw_pointer_cast(raw_offsets.data()), thrust::raw_pointer_cast(ws.raw_neighbors.data()),
        thrust::raw_pointer_cast(ws.raw_weights.data()), thrust::raw_pointer_cast(coarse.offsets.data()));
    CUDA_CHECK(cudaGetLastError());
    if (raw_row_bound > 128) {
        contraction_sort_rows<true><<<static_cast<int>((rows + 7) / 8), 256>>>(rows,
            thrust::raw_pointer_cast(raw_offsets.data()), thrust::raw_pointer_cast(ws.raw_neighbors.data()),
            thrust::raw_pointer_cast(ws.raw_weights.data()), thrust::raw_pointer_cast(coarse.offsets.data()));
        CUDA_CHECK(cudaGetLastError());
    }
    timings.sort_seconds = sort_timer.seconds();
    GpuEventTimer scan_timer;
    thrust::exclusive_scan(detail::scratch_policy(), coarse.offsets.begin(), coarse.offsets.end(), coarse.offsets.begin());
    OffsetT edges = 0;
    CUDA_CHECK(cudaMemcpy(&edges, thrust::raw_pointer_cast(coarse.offsets.data()) + rows,
                           sizeof(edges), cudaMemcpyDeviceToHost));
    timings.reduce_seconds = scan_timer.seconds();
    GpuEventTimer output_timer;
    coarse.neighbors.resize(static_cast<std::size_t>(edges));
    coarse.edge_weights.resize(static_cast<std::size_t>(edges));
    contraction_copy_rows<<<static_cast<int>((rows + 31) / 32), 256>>>(rows,
        thrust::raw_pointer_cast(raw_offsets.data()), thrust::raw_pointer_cast(ws.raw_neighbors.data()),
        thrust::raw_pointer_cast(ws.raw_weights.data()), thrust::raw_pointer_cast(coarse.offsets.data()),
        thrust::raw_pointer_cast(coarse.neighbors.data()), thrust::raw_pointer_cast(coarse.edge_weights.data()));
    CUDA_CHECK(cudaGetLastError());
    coarse.vertex_weights = std::move(aggregate.vertex_weights);
    timings.csr_build_seconds = output_timer.seconds();
    return coarse;
}

template <typename ValueT>
DeviceWeightedGraph contract_typed(
    const DeviceWeightedGraph& fine, DeviceAggregateResult&& aggregate,
    SclpWorkspace& workspace, ContractionTimings& timings,
    DeviceWeightedGraph* recycle) {
    GpuEventTimer contraction_timer;
    auto& ws = *workspace.impl;
    const auto n = fine.vertices();
    const auto m = fine.edges();
    const int warp_blocks = static_cast<int>(
        (n + WARPS_PER_BLOCK - 1) / WARPS_PER_BLOCK);
    auto& keys = ws.affinity_keys;
    auto& values = ws.template values<ValueT>();
    auto& unique_keys = ws.unique_keys;
    auto& unique_values = ws.template reduced_values<ValueT>();
    std::uint64_t coarse_row_bound = 0;
    std::uint64_t coarse_raw_row_bound = UINT64_MAX;
    using OffsetT = gpart::GraphTypes::OffsetT;
    auto& raw_offsets = [&]() -> auto& {
        if constexpr (sizeof(OffsetT) == 4) return ws.compact_ids;
        else return ws.raw_row_offsets;
    }();
    const bool count_raw = ws.row_local_contraction && ws.record_bound_known &&
        ws.positive_edge_weights && n >= 65536 && fine.maximum_degree <= 512;
    if (count_raw) {
        raw_offsets.resize(static_cast<std::size_t>(aggregate.coarse_vertices) + 1);
        CUDA_CHECK(cudaMemsetAsync(thrust::raw_pointer_cast(raw_offsets.data()), 0,
                                   raw_offsets.size() * sizeof(OffsetT)));
    }
    if (ws.record_bound_known) {
        ws.next_row_weight_bounds.resize(static_cast<std::size_t>(aggregate.coarse_vertices));
        thrust::fill(detail::scratch_policy(),ws.next_row_weight_bounds.begin(), ws.next_row_weight_bounds.end(), 0ULL);
        contract_record_bounds<<<static_cast<int>((n + 255) / 256), 256>>>(
            n, thrust::raw_pointer_cast(aggregate.map.data()),
            thrust::raw_pointer_cast(ws.row_weight_bounds.data()),
            thrust::raw_pointer_cast(ws.next_row_weight_bounds.data()),
            thrust::raw_pointer_cast(fine.offsets.data()),
            count_raw ? thrust::raw_pointer_cast(raw_offsets.data()) : nullptr);
        CUDA_CHECK(cudaGetLastError());
        if (count_raw) {
            const auto limits = thrust::transform_reduce(detail::scratch_policy(),
                thrust::make_counting_iterator<std::int64_t>(0),
                thrust::make_counting_iterator<std::int64_t>(aggregate.coarse_vertices),
                RowLimitsAt<OffsetT>{thrust::raw_pointer_cast(ws.next_row_weight_bounds.data()),
                                    thrust::raw_pointer_cast(raw_offsets.data())},
                RowLimits{0, 0}, RowLimitsMaximum{});
            coarse_row_bound = limits.weight; coarse_raw_row_bound = limits.records;
        } else coarse_row_bound = thrust::reduce(detail::scratch_policy(), ws.next_row_weight_bounds.begin(),
            ws.next_row_weight_bounds.end(), 0ULL, thrust::maximum<unsigned long long>());
    }
    // Preserve the old bound used by seed eligibility, independently of the
    // CSR execution path. A tighter metadata bound must not change clustering.
    const auto next_degree_bound = count_raw && fine.maximum_degree <= 128
        ? coarse_raw_row_bound : coarse_row_bound;
    const bool short_rows = count_raw && coarse_raw_row_bound <= 512;
    if (short_rows) {
        auto coarse = contract_short_rows(fine, aggregate, workspace, timings, coarse_raw_row_bound);
        coarse.incident_weight_bound = coarse_row_bound;
        coarse.maximum_degree = next_degree_bound;
        coarse.has_heavy_rows = coarse.maximum_degree >= 4096;
        ws.maximum_row_weight = coarse_row_bound;
        ws.row_weight_bounds.swap(ws.next_row_weight_bounds);
        timings.total_seconds = contraction_timer.seconds();
        std::cout << "ml_gpu_contract_row_local=1 row_bound=" << coarse_row_bound
                  << " raw_row_records=" << coarse_raw_row_bound
                  << " input_edge_entries=" << m << " coarse_edges=" << coarse.edges() << '\n';
        return coarse;
    }
    // Let global radix buffers reuse the local scratch pages at this level.
    {
        ws.raw_neighbors = {}; ws.raw_weights = {};
        ws.raw_row_offsets = {}; ws.raw_row_cursors = {};
    }
    const auto record_layout = ws.record_layout(aggregate.coarse_vertices, coarse_row_bound);
    if (keys.size() < static_cast<std::size_t>(m)) {
        keys.resize(static_cast<std::size_t>(m));
    }
    if (!record_layout.packed() && values.size() < static_cast<std::size_t>(m)) {
        values.resize(static_cast<std::size_t>(m));
    }
    GpuEventTimer compact_timer;
    std::int64_t cross_edges = 0;
    const bool compact_records=record_layout.packed() && m>=(1LL<<20) &&
        m/n>=8 && !fine.has_heavy_rows;
    if (n > 0) {
        encode_contraction_edges_kernel<<<warp_blocks, 256>>>(
            n, thrust::raw_pointer_cast(fine.offsets.data()),
            thrust::raw_pointer_cast(fine.neighbors.data()),
            thrust::raw_pointer_cast(fine.edge_weights.data()),
            thrust::raw_pointer_cast(aggregate.map.data()),
            thrust::raw_pointer_cast(keys.data()),
            thrust::raw_pointer_cast(values.data()), record_layout,compact_records);
        CUDA_CHECK(cudaGetLastError());
    }
    if (unique_keys.size() < static_cast<std::size_t>(m)) {
        unique_keys.resize(static_cast<std::size_t>(m));
    }
    if (!record_layout.packed() && unique_values.size() < static_cast<std::size_t>(m)) {
        unique_values.resize(static_cast<std::size_t>(m));
    }
    auto sorted_entries=m;
    if (compact_records) {
        ws.cross_counter.resize(1);
        auto* selected=thrust::raw_pointer_cast(ws.cross_counter.data());
        std::size_t bytes=0;
        CUDA_CHECK(cub::DeviceSelect::If(nullptr,bytes,
            thrust::raw_pointer_cast(keys.data()),thrust::raw_pointer_cast(unique_keys.data()),
            selected,static_cast<gpart::GraphTypes::OffsetT>(m),ExternalContractionRecord{}));
        if(ws.radix_temp.size()<bytes) ws.radix_temp.resize(bytes);
        CUDA_CHECK(cub::DeviceSelect::If(thrust::raw_pointer_cast(ws.radix_temp.data()),bytes,
            thrust::raw_pointer_cast(keys.data()),thrust::raw_pointer_cast(unique_keys.data()),
            selected,static_cast<gpart::GraphTypes::OffsetT>(m),ExternalContractionRecord{}));
        unsigned long long count=0;
        CUDA_CHECK(cudaMemcpy(&count,selected,sizeof(count),cudaMemcpyDeviceToHost));
        sorted_entries=cross_edges=static_cast<std::int64_t>(count);
        keys.swap(unique_keys);
    }
    timings.compact_seconds = compact_timer.seconds();
    std::int64_t coarse_edges = 0;
    if (record_layout.packed()) {
        GpuEventTimer sort_timer;
        sort_packed_records(keys, unique_keys, ws.radix_temp,
            static_cast<gpart::GraphTypes::OffsetT>(sorted_entries), record_layout);
        if (!compact_records) cross_edges = thrust::lower_bound(detail::scratch_policy(), unique_keys.begin(),
            unique_keys.begin() + m, std::uint64_t{UINT64_MAX}) - unique_keys.begin();
        timings.sort_seconds = sort_timer.seconds();
        GpuEventTimer reduce_timer;
        coarse_edges = reduce_packed_records(keys, unique_keys, cross_edges, record_layout);
        timings.reduce_seconds = reduce_timer.seconds();
    } else {
        std::size_t contraction_radix_bytes = 0;
        cub::DoubleBuffer<std::uint64_t> sort_keys(
            thrust::raw_pointer_cast(keys.data()),
            thrust::raw_pointer_cast(unique_keys.data()));
        cub::DoubleBuffer<ValueT> sort_values(
            thrust::raw_pointer_cast(values.data()),
            thrust::raw_pointer_cast(unique_values.data()));
        CUDA_CHECK(cub::DeviceRadixSort::SortPairs(
            nullptr, contraction_radix_bytes, sort_keys, sort_values,
            static_cast<gpart::GraphTypes::OffsetT>(m), 0, 2 * record_layout.vertex_bits));
        ws.radix_temp.resize(contraction_radix_bytes);
        GpuEventTimer sort_timer;
        auto call_radix_bytes = contraction_radix_bytes;
        CUDA_CHECK(cub::DeviceRadixSort::SortPairs(
            thrust::raw_pointer_cast(ws.radix_temp.data()), call_radix_bytes,
            sort_keys, sort_values,
            static_cast<gpart::GraphTypes::OffsetT>(m), 0, 2 * record_layout.vertex_bits));
        if (sort_keys.Current() == thrust::raw_pointer_cast(keys.data())) {
            keys.swap(unique_keys);
            values.swap(unique_values);
        }
        cross_edges = thrust::lower_bound(detail::scratch_policy(), unique_keys.begin(),
            unique_keys.begin() + m, std::uint64_t{UINT64_MAX}) - unique_keys.begin();
        timings.sort_seconds = sort_timer.seconds();
        GpuEventTimer reduce_timer;
        const auto reduced = thrust::reduce_by_key(
            detail::scratch_policy(), unique_keys.begin(),
            unique_keys.begin() + cross_edges,
            unique_values.begin(), keys.begin(), values.begin());
        timings.reduce_seconds = reduce_timer.seconds();
        coarse_edges = static_cast<std::int64_t>(reduced.first - keys.begin());
    }
    std::cout << "ml_gpu_contract_cross_edge_entries=" << cross_edges
              << " input_edge_entries=" << m
              << " scratch_record_bytes=" << (record_layout.packed() ? 8 : 8 + sizeof(ValueT))
              << " sorted_entries=" << sorted_entries
              << " chunk_precombined=" << compact_records
              << " record_fraction="
              << (m == 0 ? 0.0 :
                  static_cast<double>(cross_edges) / static_cast<double>(m))
              << '\n';

    DeviceWeightedGraph coarse;
    if (recycle != nullptr) coarse = std::move(*recycle);
    coarse.implicit_unit_weights=false;
    coarse.incident_weight_bound=ws.record_bound_known ? coarse_row_bound : UINT64_MAX;
    if (ws.record_bound_known && ws.positive_edge_weights) {
        // Each positive integral edge contributes at least one to this bound.
        // It bounds degree conservatively; it is not an exact degree count.
        coarse.maximum_degree = next_degree_bound;
        coarse.has_heavy_rows = coarse.maximum_degree >= 4096;
    }
    GpuEventTimer vertex_weight_timer;
    // aggregate already owns the exact output weights; transfer ownership
    // rather than allocating and copying a second identical array.
    coarse.vertex_weights = std::move(aggregate.vertex_weights);
    timings.vertex_weight_seconds = vertex_weight_timer.seconds();
    GpuEventTimer csr_build_timer;
    coarse.offsets.resize(static_cast<std::size_t>(aggregate.coarse_vertices) + 1);
    thrust::fill(detail::scratch_policy(),
        coarse.offsets.begin(), coarse.offsets.end(), coarse_edges);
    coarse.neighbors.resize(static_cast<std::size_t>(coarse_edges));
    coarse.edge_weights.resize(static_cast<std::size_t>(coarse_edges));
    if (coarse_edges > 0) {
        const int blocks = static_cast<int>((coarse_edges + 255) / 256);
        write_coarse_csr_kernel<<<blocks, 256>>>(
            coarse_edges, thrust::raw_pointer_cast(keys.data()),
            thrust::raw_pointer_cast(values.data()),
            thrust::raw_pointer_cast(coarse.neighbors.data()),
            thrust::raw_pointer_cast(coarse.edge_weights.data()),
            thrust::raw_pointer_cast(coarse.offsets.data()), record_layout);
        CUDA_CHECK(cudaGetLastError());
    }
    thrust::inclusive_scan(
        detail::scratch_policy(), coarse.offsets.rbegin(), coarse.offsets.rend(),
        coarse.offsets.rbegin(),
        thrust::minimum<gpart::GraphTypes::OffsetT>());
    timings.csr_build_seconds = csr_build_timer.seconds();
    timings.total_seconds = contraction_timer.seconds();
    if (ws.record_bound_known) {
        ws.maximum_row_weight = coarse_row_bound;
        ws.row_weight_bounds.swap(ws.next_row_weight_bounds);
    }
    return coarse;
}

DeviceWeightedGraph contract_impl(
    const DeviceWeightedGraph& fine, DeviceAggregateResult&& aggregate,
    SclpWorkspace& workspace, ContractionTimings& timings,
    DeviceWeightedGraph* recycle) {
    if (workspace.impl->packed_weights)
        return contract_typed<std::uint32_t>(fine, std::move(aggregate), workspace, timings, recycle);
    return contract_typed<std::uint64_t>(fine, std::move(aggregate), workspace, timings, recycle);
}

DeviceWeightedGraph contract(
    DeviceWeightedGraph fine, DeviceAggregateResult&& aggregate,
    SclpWorkspace& workspace, ContractionTimings& timings) {
    return contract_impl(fine, std::move(aggregate), workspace, timings, &fine);
}

namespace {

void validate_coarsening_step(
    const WeightedGraph& fine, const WeightedGraph& coarse,
    const std::vector<gpart::GraphTypes::VertexT>& map,
    std::uint64_t cluster_cap, int level, bool strict_verify) {
    using VertexT = gpart::GraphTypes::VertexT;
    if (map.size() != static_cast<std::size_t>(fine.vertices())) {
        throw std::runtime_error("coarsening map has the wrong length");
    }
    if (coarse.vertices() <= 0 || coarse.vertices() > fine.vertices()) {
        throw std::runtime_error("coarsening produced an invalid vertex count");
    }
    std::vector<std::uint64_t> recomputed(
        static_cast<std::size_t>(coarse.vertices()), 0);
    std::vector<std::uint64_t> coverage(
        static_cast<std::size_t>(coarse.vertices()), 0);
    for (std::int64_t v = 0; v < fine.vertices(); ++v) {
        const auto c = map[static_cast<std::size_t>(v)];
        if (c < 0 || c >= coarse.vertices()) {
            throw std::runtime_error("coarsening map contains an out-of-range id");
        }
        recomputed[static_cast<std::size_t>(c)] += static_cast<std::uint64_t>(
            fine.vertex_weights[static_cast<std::size_t>(v)]);
        ++coverage[static_cast<std::size_t>(c)];
    }
    const auto sum_weights = [](const auto& weights) {
        return std::accumulate(
            weights.begin(), weights.end(), std::uint64_t{0},
            [](std::uint64_t total, auto value) {
                return total + static_cast<std::uint64_t>(value);
            });
    };
    if (sum_weights(fine.vertex_weights) != sum_weights(coarse.vertex_weights)) {
        throw std::runtime_error("coarsening did not conserve vertex weight");
    }
    for (std::int64_t c = 0; c < coarse.vertices(); ++c) {
        if (coverage[static_cast<std::size_t>(c)] == 0 ||
            recomputed[static_cast<std::size_t>(c)] != static_cast<std::uint64_t>(
                coarse.vertex_weights[static_cast<std::size_t>(c)])) {
            throw std::runtime_error("coarsening cluster weight mismatch");
        }
        if (static_cast<std::uint64_t>(
                coarse.vertex_weights[static_cast<std::size_t>(c)]) > cluster_cap) {
            throw std::runtime_error("coarse point exceeds configured weight cap");
        }
    }
    if (strict_verify) {
        validate_weighted_csr(coarse, false);
    } else {
        validate_weighted_shape(coarse, false);
    }

    std::vector<VertexT> coarse_labels(
        static_cast<std::size_t>(coarse.vertices()));
    for (std::int64_t c = 0; c < coarse.vertices(); ++c) {
        coarse_labels[static_cast<std::size_t>(c)] =
            static_cast<VertexT>((c * 2654435761ULL + 17) % 23);
    }
    std::vector<VertexT> fine_labels(map.size());
    for (std::size_t v = 0; v < map.size(); ++v) {
        fine_labels[v] = coarse_labels[static_cast<std::size_t>(map[v])];
    }
    if (host_cut(fine, fine_labels) != host_cut(coarse, coarse_labels)) {
        throw std::runtime_error("cut is not conserved by coarse projection");
    }
    std::cout << "ml_layer_verify level=" << level
              << " map=ok weights=ok csr=ok projection_cut=ok\n";
}

}  // namespace

template <bool Resident>
auto coarsen_impl(
    const WeightedGraph* graph, DeviceWeightedGraph current,
    const CoarsenOptions& options) {
    using VertexT = gpart::GraphTypes::VertexT;
    if (options.parts < 2 || options.parts > kMaxParts || options.cluster_size_factor < 2 ||
        options.max_levels < 0 || options.heavy_edge_degree_limit < 2 || options.heavy_edge_degree_limit > 256 || options.progressive_fine_factor < 2 || options.progressive_capacity_growth < 2 || options.progressive_capacity_growth > 16 || !std::isfinite(options.stop_contraction_ratio) ||
        options.stop_contraction_ratio <= 0 || options.stop_contraction_ratio > 1)
        throw std::invalid_argument("invalid coarsening options");
    const bool diagnostics = std::getenv("SCLP_DIAGNOSTICS") != nullptr;
    const char* coarsening_name = "regret_capacity";
    GpuTimingScope timing_scope(options.detailed_timings || diagnostics);
    std::cout << "ml_gpu_component_timings_enabled=" << gpu_component_timings << '\n';
    const bool verify = options.strict_verify;
    std::conditional_t<Resident, DeviceHierarchy, Hierarchy> hierarchy;
    // Thrust device_vector's move constructor is not noexcept. Without this
    // reservation, std::vector growth copies all existing device graphs/maps
    // to preserve its exception guarantee (including the original full CSR).
    // There are at most max_levels contractions plus the input graph.
    const auto maximum_levels = static_cast<std::size_t>(std::max(0, options.max_levels));
    hierarchy.levels.reserve(maximum_levels + 1);
    hierarchy.fine_to_coarse.reserve(maximum_levels);
    double host_graph_build_seconds = 0.0;
    double input_verify_seconds = 0.0;
    if constexpr (!Resident) {
        const auto build_start = std::chrono::steady_clock::now();
        hierarchy.levels.push_back(*graph);
        host_graph_build_seconds = std::chrono::duration<double>(
            std::chrono::steady_clock::now() - build_start).count();
        const auto verify_start = std::chrono::steady_clock::now();
        if (options.strict_verify) {
            validate_weighted_csr(hierarchy.levels.front(), true);
        } else {
            validate_weighted_shape(hierarchy.levels.front(), true);
        }
        input_verify_seconds = std::chrono::duration<double>(
            std::chrono::steady_clock::now() - verify_start).count();
    }
    std::cout << "ml_input_verify_seconds=" << input_verify_seconds
              << " status=ok mode="
              << (options.strict_verify ? "strict" : "fast") << '\n';

    const auto device_input_start = std::chrono::steady_clock::now();
    if constexpr (!Resident) current = make_device_weighted(hierarchy.levels.front());
    SclpWorkspace workspace;
    if (current.vertices() > 0) {
        auto& ws = *workspace.impl;
        ws.row_local_contraction = options.row_local_contraction;
        ws.track_weight_invariants = true;
        ws.cross_counter.assign(4, 0ULL);
        ws.row_weight_bounds.resize(static_cast<std::size_t>(current.vertices()));
        const auto bounds = [&](auto width) {
            constexpr int Width = decltype(width)::value;
            record_bound_kernel<gpart::GraphTypes::OffsetT, gpart::GraphTypes::WeightT, Width>
                <<<static_cast<int>((current.vertices() + 256 / Width - 1) / (256 / Width)), 256>>>(
                current.vertices(), thrust::raw_pointer_cast(current.offsets.data()),
                thrust::raw_pointer_cast(current.edge_weights.data()),
                thrust::raw_pointer_cast(current.neighbors.data()),
                thrust::raw_pointer_cast(ws.row_weight_bounds.data()),
                thrust::raw_pointer_cast(ws.cross_counter.data()));
        };
        if (current.edges() / current.vertices() < 8) bounds(std::integral_constant<int, 8>{});
        else bounds(std::integral_constant<int, 32>{});
        CUDA_CHECK(cudaGetLastError());
        unsigned long long metadata[4] = {};
        CUDA_CHECK(cudaMemcpy(metadata, thrust::raw_pointer_cast(ws.cross_counter.data()),
            sizeof(metadata), cudaMemcpyDeviceToHost));
        ws.record_bound_known = true;
        ws.original_vertices = current.vertices();
        ws.maximum_row_weight = metadata[0];
        current.incident_weight_bound=metadata[0];
        ws.sorted_unique_rows = metadata[1] == 0;
        ws.positive_edge_weights = (metadata[2] & 1ULL) == 0;
        ws.unit_edge_weights = (metadata[2] & 2ULL) == 0;
        current.maximum_degree = metadata[3];
        current.has_heavy_rows = metadata[3] >= 4096;
    }
    if (workspace.impl->unit_edge_weights) {
        // The existing scan proves every edge is one. Its directed sum is
        // exactly M, including parallel entries; no second edge scan needed.
        workspace.impl->packed_weights = static_cast<std::uint64_t>(current.edges()) <= UINT32_MAX;
    } else if constexpr (sizeof(gpart::GraphTypes::WeightT) == 4) {
        // With Standard's 32-bit offsets and weights, this sum fits uint64.
        const auto directed_weight = thrust::reduce(detail::scratch_policy(), current.edge_weights.begin(),
            current.edge_weights.end(), std::uint64_t{0}, thrust::plus<std::uint64_t>());
        workspace.impl->packed_weights = directed_weight <= std::numeric_limits<std::uint32_t>::max();
    }
    // Low-degree layers can contract locally; global edge buffers grow only
    // if/when a hub or a later level actually needs global sorting.
    if (!options.row_local_contraction || !current.vertices() ||
        current.edges() / current.vertices() >= 64)
        workspace.reserve_contract_buffers(current.edges());
    CUDA_CHECK(cudaDeviceSynchronize());
    const auto device_input_seconds = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - device_input_start).count();
    std::cout << "ml_gpu_device_input_seconds=" << device_input_seconds
              << " method=" << coarsening_name << '\n';

    const std::int64_t cutoff = std::max<std::int64_t>(
        32, options.cluster_size_factor * static_cast<std::int64_t>(options.parts));
    const auto core_start = std::chrono::steady_clock::now();
    double device_algorithm_seconds = 0.0;
    double aggregate_wall_seconds = 0.0;
    double contraction_wall_seconds = 0.0;
    double snapshot_seconds = 0.0;
    double aggregate_gpu_seconds = 0.0;
    double affinity_gpu_seconds = 0.0;
    double admission_gpu_seconds = 0.0;
    double two_hop_gpu_seconds = 0.0;
    double compact_gpu_seconds = 0.0;
    double contraction_gpu_seconds = 0.0;
    double contraction_compact_gpu_seconds = 0.0;
    double contraction_sort_gpu_seconds = 0.0;
    double contraction_reduce_gpu_seconds = 0.0;
    double contraction_csr_gpu_seconds = 0.0;
    double contraction_vertex_weight_gpu_seconds = 0.0;
    int level = 0;
    for (; level < options.max_levels && current.vertices() > cutoff; ++level) {
        const auto level_seed = options.seed + static_cast<std::uint32_t>(level);
        std::cout << "ml_coarsen_begin level=" << level
                  << " vertices=" << current.vertices()
                  << " edges=" << current.edges()
                  << " method=" << coarsening_name << " seed=" << level_seed << '\n';
        SclpStats stats;
        const auto aggregate_start = std::chrono::steady_clock::now();
        int level_factor=options.cluster_size_factor;
        if (options.progressive_cluster_capacity) {
            const auto fine_factor=std::max(options.progressive_fine_factor,(512+options.parts-1)/options.parts);
            const auto denominator=static_cast<std::int64_t>(options.progressive_capacity_growth)*options.parts;
            const auto remaining_factor=(current.vertices()+denominator-1)/denominator;
            level_factor=static_cast<int>(std::max<std::int64_t>(level_factor,
                std::min<std::int64_t>(fine_factor,remaining_factor)));
        }
        const bool try_matching = options.seed_matching &&
            current.vertices() >= 65536 && !current.has_heavy_rows &&
            (current.edges() / current.vertices() < 8 || current.maximum_degree <= 256) &&
            current.edges() / current.vertices() < options.heavy_edge_degree_limit &&
            workspace.impl->sorted_unique_rows && workspace.impl->positive_edge_weights;
        auto aggregate_result = aggregate(current, workspace, options.parts, level_seed,
            level, stats, diagnostics, level_factor, options.pack_isolated, try_matching, options.capacity_safe_fast_path);
        current.has_heavy_rows=stats.has_heavy_rows;
        current.maximum_degree=stats.maximum_degree;
        const auto level_aggregate_wall = std::chrono::duration<double>(
            std::chrono::steady_clock::now() - aggregate_start).count();
        device_algorithm_seconds += level_aggregate_wall;
        aggregate_wall_seconds += level_aggregate_wall;
        const double contraction =
            static_cast<double>(aggregate_result.coarse_vertices) /
            static_cast<double>(current.vertices());
        affinity_gpu_seconds += stats.affinity_seconds;
        admission_gpu_seconds += stats.admission_seconds;
        two_hop_gpu_seconds += stats.two_hop_seconds;
        compact_gpu_seconds += stats.compact_seconds;
        aggregate_gpu_seconds += stats.aggregate_seconds;
        const auto aggregate_other_seconds = std::max(
            0.0, stats.aggregate_seconds - stats.affinity_seconds -
            stats.admission_seconds - stats.two_hop_seconds -
            stats.compact_seconds);
        std::cout << "ml_coarsen_map level=" << level
                  << " coarse_vertices=" << aggregate_result.coarse_vertices
                  << " ratio=" << contraction
                  << " maximum_weight=" << aggregate_result.maximum_weight
                  << " capacity=" << aggregate_result.capacity << '\n';
        if (aggregate_result.coarse_vertices >= current.vertices() ||
            contraction > options.stop_contraction_ratio) {
            std::cout << "ml_gpu_timing level=" << level
                      << " affinity_seconds=" << stats.affinity_seconds
                      << " admission_seconds=" << stats.admission_seconds
                      << " two_hop_seconds=" << stats.two_hop_seconds
                      << " compact_seconds=" << stats.compact_seconds
                      << " aggregate_other_seconds=" << aggregate_other_seconds
                      << " aggregate_total_seconds=" << stats.aggregate_seconds
                      << " contraction_seconds=0\n";
            std::cout << "ml_coarsen_stop reason=insufficient_contraction\n";
            hierarchy.stop_reason = "insufficient_contraction";
            break;
        }

        ContractionTimings contract_timings;
        const auto contract_wall_start = std::chrono::steady_clock::now();
        auto coarse_device = contract_impl(
            current, std::move(aggregate_result), workspace, contract_timings,
            Resident ? nullptr : &current);
        const auto level_contract_wall = std::chrono::duration<double>(
            std::chrono::steady_clock::now() - contract_wall_start).count();
        device_algorithm_seconds += level_contract_wall;
        contraction_wall_seconds += level_contract_wall;
        contraction_gpu_seconds += contract_timings.total_seconds;
        contraction_compact_gpu_seconds += contract_timings.compact_seconds;
        contraction_sort_gpu_seconds += contract_timings.sort_seconds;
        contraction_reduce_gpu_seconds += contract_timings.reduce_seconds;
        contraction_csr_gpu_seconds += contract_timings.csr_build_seconds;
        contraction_vertex_weight_gpu_seconds +=
            contract_timings.vertex_weight_seconds;
        std::cout << "ml_gpu_timing level=" << level
                  << " affinity_seconds=" << stats.affinity_seconds
                  << " admission_seconds=" << stats.admission_seconds
                  << " two_hop_seconds=" << stats.two_hop_seconds
                  << " compact_seconds=" << stats.compact_seconds
                  << " aggregate_other_seconds=" << aggregate_other_seconds
                  << " aggregate_total_seconds=" << stats.aggregate_seconds
                  << " contraction_seconds=" << contract_timings.total_seconds
                  << '\n';
        std::cout << "ml_gpu_contraction_timing level=" << level
                  << " compact_seconds=" << contract_timings.compact_seconds
                  << " sort_seconds=" << contract_timings.sort_seconds
                  << " reduce_seconds=" << contract_timings.reduce_seconds
                  << " csr_build_seconds=" << contract_timings.csr_build_seconds
                  << " vertex_weight_seconds="
                  << contract_timings.vertex_weight_seconds
                  << " total_seconds=" << contract_timings.total_seconds << '\n';
        std::cout << "ml_gpu_contract_seconds level=" << level
                  << " seconds=" << contract_timings.total_seconds
                  << " coarse_edges=" << coarse_device.edges() << '\n';

        const auto snapshot_start = std::chrono::steady_clock::now();
        if constexpr (Resident) {
            // Debug verification may inspect host copies, but production does
            // not download any level or map here.
            if (verify) {
                std::vector<VertexT> host_map(aggregate_result.map.size());
                thrust::copy(aggregate_result.map.begin(), aggregate_result.map.end(),
                             host_map.begin());
                auto fine_host = copy_device_weighted(current);
                auto coarse_host = copy_device_weighted(coarse_device);
                validate_coarsening_step(fine_host, coarse_host, host_map,
                    aggregate_result.capacity, level, true);
            }
            hierarchy.levels.push_back(std::move(current));
            hierarchy.fine_to_coarse.push_back(std::move(aggregate_result.map));
        } else {
            std::vector<VertexT> host_map(aggregate_result.map.size());
            thrust::copy(aggregate_result.map.begin(), aggregate_result.map.end(),
                         host_map.begin());
            auto coarse_host = copy_device_weighted(coarse_device);
            if (verify) {
                validate_coarsening_step(hierarchy.levels.back(), coarse_host, host_map,
                    aggregate_result.capacity, level, options.strict_verify);
            }
            hierarchy.fine_to_coarse.push_back(std::move(host_map));
            hierarchy.levels.push_back(std::move(coarse_host));
        }
        const auto snapshot = std::chrono::duration<double>(
            std::chrono::steady_clock::now() - snapshot_start).count();
        snapshot_seconds += Resident && !verify ? 0.0 : snapshot;
        std::cout << "ml_gpu_device_snapshot_seconds level=" << level
                  << " seconds=" << (Resident && !verify ? 0.0 : snapshot) << '\n';
        current = std::move(coarse_device);
        // Contraction reduces duplicate keys and emits each row in key order.
        workspace.impl->sorted_unique_rows = true;
    }
    if (level == options.max_levels && current.vertices() > cutoff) {
        hierarchy.stop_reason = "max_levels";
    }
    if constexpr (Resident) hierarchy.levels.push_back(std::move(current));
    hierarchy.hierarchy_loop_seconds = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - core_start).count();
    hierarchy.snapshot_seconds = snapshot_seconds;
    std::cout << "ml_gpu_device_core_seconds=" << device_algorithm_seconds
              << " aggregate_plus_contract=1 method=" << coarsening_name << '\n';
    std::cout << "ml_gpu_timing_total"
              << " affinity_seconds=" << affinity_gpu_seconds
              << " admission_seconds=" << admission_gpu_seconds
              << " two_hop_seconds=" << two_hop_gpu_seconds
              << " compact_seconds=" << compact_gpu_seconds
              << " aggregate_other_seconds=" << std::max(
                     0.0, aggregate_gpu_seconds - affinity_gpu_seconds -
                     admission_gpu_seconds - two_hop_gpu_seconds -
                     compact_gpu_seconds)
              << " aggregate_total_seconds=" << aggregate_gpu_seconds
              << " contraction_seconds=" << contraction_gpu_seconds << '\n';
    std::cout << "ml_gpu_contraction_timing_total"
              << " compact_seconds=" << contraction_compact_gpu_seconds
              << " sort_seconds=" << contraction_sort_gpu_seconds
              << " reduce_seconds=" << contraction_reduce_gpu_seconds
              << " csr_build_seconds=" << contraction_csr_gpu_seconds
              << " vertex_weight_seconds="
              << contraction_vertex_weight_gpu_seconds
              << " total_seconds=" << contraction_gpu_seconds << '\n';
    const auto& scratch = *workspace.impl;
    const auto edge_scratch_bytes =
        (scratch.affinity_keys.capacity() + scratch.unique_keys.capacity() +
         scratch.affinity_values.capacity() + scratch.unique_values.capacity()) * sizeof(std::uint64_t) +
        (scratch.packed_affinity_values.capacity() + scratch.packed_unique_values.capacity()) * sizeof(std::uint32_t) +
        scratch.raw_neighbors.capacity() * sizeof(gpart::GraphTypes::VertexT) +
        scratch.raw_weights.capacity() * sizeof(gpart::GraphTypes::WeightT);
    std::cout << "ml_wall_timing_total"
              << " host_graph_build_seconds=" << host_graph_build_seconds
              << " input_verify_seconds=" << input_verify_seconds
              << " device_input_seconds=" << device_input_seconds
              << " aggregate_seconds=" << aggregate_wall_seconds
              << " contraction_seconds=" << contraction_wall_seconds
              << " snapshot_seconds=" << snapshot_seconds
              << " edge_scratch_bytes=" << edge_scratch_bytes << '\n';
    std::cout << "ml_hierarchy_loop_seconds="
              << hierarchy.hierarchy_loop_seconds
              << " includes_snapshot_and_verify=1 method=" << coarsening_name << '\n';
    return hierarchy;
}

Hierarchy coarsen(const WeightedGraph& graph, const CoarsenOptions& options) {
    return coarsen_impl<false>(&graph, {}, options);
}

DeviceHierarchy coarsen(DeviceWeightedGraph&& graph, const CoarsenOptions& options) {
    return coarsen_impl<true>(nullptr, std::move(graph), options);
}







}  // namespace gpart
