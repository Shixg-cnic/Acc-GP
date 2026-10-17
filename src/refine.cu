#include "refine.hpp"

#include "check.hpp"
#include "detail/scratch_pool.hpp"
#include "detail/scratch_buffer.hpp"
#include "detail/group_record.hpp"
#include "graph_types.hpp"
#include "partition_capacity.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <climits>
#include <cfloat>
#include <cstdint>
#include <cstddef>
#include <cstdlib>
#include <memory>
#include <iostream>
#include <limits>
#include <numeric>
#include <stdexcept>
#include <type_traits>
#include <utility>
#include <vector>

#include <cuda/atomic>
#include <cuda/std/tuple>
#include <cub/device/device_radix_sort.cuh>
#include <thrust/copy.h>
#include <thrust/count.h>
#include <thrust/device_vector.h>
#include <thrust/execution_policy.h>
#include <thrust/fill.h>
#include <thrust/equal.h>
#include <thrust/functional.h>
#include <thrust/iterator/counting_iterator.h>
#include <thrust/reduce.h>
#include <thrust/remove.h>
#include <thrust/sequence.h>
#include <thrust/sort.h>
#include <thrust/unique.h>
#include <thrust/transform_reduce.h>

namespace gpart {
namespace {

constexpr int kWarpSize = 32;
constexpr int kWarpsPerBlock = 8;

__device__ __forceinline__ std::uint32_t refine_mix32(std::uint32_t x) {
    x ^= x >> 16;
    x *= 0x7feb352dU;
    x ^= x >> 15;
    x *= 0x846ca68bU;
    return x ^ (x >> 16);
}

struct RepairSample {
    long long loss=0;
    unsigned long long weight=0;
};

template <typename OffsetT, typename WeightT, typename VertexT>
__global__ void refine_cut_kernel(
    std::int64_t n,
    const OffsetT* offsets,
    const VertexT* neighbors,
    const WeightT* edge_weights,
    const VertexT* partition,
    unsigned long long* directed_cut) {
    const int lane = threadIdx.x & (kWarpSize - 1);
    const int warp = threadIdx.x / kWarpSize;
    const auto vertex = static_cast<std::int64_t>(blockIdx.x) *
        kWarpsPerBlock + warp;
    __shared__ unsigned long long warp_cuts[kWarpsPerBlock];
    unsigned long long local = 0;
    if (vertex < n) {
        const auto source = partition[vertex];
        for (std::int64_t edge = static_cast<std::int64_t>(offsets[vertex]) + lane;
             edge < static_cast<std::int64_t>(offsets[vertex + 1]); edge += kWarpSize) {
            if (source != partition[neighbors[edge]]) {
                local += static_cast<unsigned long long>(detail::edge_weight(edge_weights,edge));
            }
        }
    }
    // Sum the same directed entries as before, using exact uint64 arithmetic.
    // Tail warps participate with zero so every thread reaches the barrier.
    for (int delta = kWarpSize / 2; delta; delta /= 2)
        local += __shfl_down_sync(0xffffffffU, local, delta);
    if (lane == 0) warp_cuts[warp] = local;
    __syncthreads();
    if (warp == 0) {
        local = lane < kWarpsPerBlock ? warp_cuts[lane] : 0;
        for (int delta = kWarpSize / 2; delta; delta /= 2)
            local += __shfl_down_sync(0xffffffffU, local, delta);
        if (lane == 0 && local != 0) atomicAdd(directed_cut, local);
    }
}

template <typename VertexT>
__global__ void project_partition_kernel(
    std::int64_t n,
    const VertexT* fine_to_coarse,
    const VertexT* coarse_partition,
    VertexT* fine_partition) {
    const auto vertex = static_cast<std::int64_t>(blockIdx.x) *
        blockDim.x + threadIdx.x;
    if (vertex < n) {
        fine_partition[vertex] = coarse_partition[fine_to_coarse[vertex]];
    }
}

template <typename WeightT, typename VertexT>
__global__ void accumulate_part_weights_kernel(
    std::int64_t n,
    const WeightT* vertex_weights,
    const VertexT* partition,
    unsigned long long* part_weights) {
    const auto vertex = static_cast<std::int64_t>(blockIdx.x) *
        blockDim.x + threadIdx.x;
    if (vertex < n) {
        atomicAdd(
            part_weights + partition[vertex],
            static_cast<unsigned long long>(vertex_weights[vertex]));
    }
}

std::uint64_t device_cut_value(
    const DeviceWeightedGraph& graph,
    const detail::ScratchBuffer<gpart::GraphTypes::VertexT>& partition,
    detail::ScratchBuffer<unsigned long long>& cut_counter) {
    const auto n = graph.vertices();
    if (n == 0) return 0;
    const int blocks = static_cast<int>((n + kWarpsPerBlock - 1) / kWarpsPerBlock);
    CUDA_CHECK(cudaMemsetAsync(thrust::raw_pointer_cast(cut_counter.data()),0,sizeof(unsigned long long)));
    refine_cut_kernel<<<blocks, 256>>>(
        n,
        thrust::raw_pointer_cast(graph.offsets.data()),
        thrust::raw_pointer_cast(graph.neighbors.data()),
        thrust::raw_pointer_cast(graph.edge_weights.data()),
        thrust::raw_pointer_cast(partition.data()),
        thrust::raw_pointer_cast(cut_counter.data()));
    CUDA_CHECK(cudaGetLastError());
    unsigned long long directed = 0;
    CUDA_CHECK(cudaMemcpy(
        &directed, thrust::raw_pointer_cast(cut_counter.data()),
        sizeof(directed), cudaMemcpyDeviceToHost));
    if ((directed & 1ULL) != 0) {
        throw std::runtime_error("refinement cut is not symmetric");
    }
    return static_cast<std::uint64_t>(directed / 2);
}

void device_part_weights(
    const DeviceWeightedGraph& graph,
    const detail::ScratchBuffer<gpart::GraphTypes::VertexT>& partition,
    detail::ScratchBuffer<unsigned long long>& weights,
    int parts) {
    weights.resize(static_cast<std::size_t>(parts));
    CUDA_CHECK(cudaMemsetAsync(thrust::raw_pointer_cast(weights.data()),0,parts*sizeof(unsigned long long)));
    const auto n = graph.vertices();
    const int blocks = static_cast<int>((n + 255) / 256);
    accumulate_part_weights_kernel<<<blocks, 256>>>(
        n,
        thrust::raw_pointer_cast(graph.vertex_weights.data()),
        thrust::raw_pointer_cast(partition.data()),
        thrust::raw_pointer_cast(weights.data()));
    CUDA_CHECK(cudaGetLastError());
}

std::uint64_t refinement_capacity(
    std::uint64_t total_weight, int parts, double imbalance_ratio) {
    return partition_capacity(total_weight, parts, imbalance_ratio);
}

std::vector<std::uint64_t> validate_and_measure_partition(
    const WeightedGraph& graph,
    const std::vector<gpart::GraphTypes::VertexT>& partition,
    int parts,
    std::uint64_t& total_weight) {
    if (partition.size() != static_cast<std::size_t>(graph.vertices())) {
        throw std::invalid_argument("refinement partition has the wrong length");
    }
    std::vector<std::uint64_t> weights(static_cast<std::size_t>(parts), 0);
    total_weight = 0;
    for (std::size_t v = 0; v < partition.size(); ++v) {
        const auto part = partition[v];
        if (part < 0 || part >= parts) {
            throw std::invalid_argument("refinement partition has an invalid part id");
        }
        const auto weight = static_cast<std::uint64_t>(graph.vertex_weights[v]);
        if (weights[part] > std::numeric_limits<std::uint64_t>::max() - weight ||
            total_weight > std::numeric_limits<std::uint64_t>::max() - weight) {
            throw std::overflow_error("refinement vertex weight sum overflow");
        }
        weights[part] += weight;
        total_weight += weight;
    }
    return weights;
}

}  // namespace

#include "refine_affinity.cuh"

#include "refine_groups.cuh"
#include "refine_joint.cuh"

// Each cache build writes all n*k affinity entries and n row totals before
// any read. A raw pool allocation avoids device_vector's redundant zero fill.
// Resizing discards the previous level; this is not a preserving vector.
template <typename T>
class RefinementCache {
    detail::ScratchAllocator<T> allocator_;
    typename detail::ScratchAllocator<T>::pointer pointer_{};
    std::size_t size_=0;
public:
    RefinementCache()=default;
    RefinementCache(const RefinementCache&)=delete;
    RefinementCache& operator=(const RefinementCache&)=delete;
    ~RefinementCache() { if (size_) allocator_.deallocate(pointer_,size_); }
    std::size_t size() const { return size_; }
    auto data() { return pointer_; }
    auto begin() { return pointer_; }
    void resize(std::size_t required) {
        if (required<=size_) return;
        if (size_) { allocator_.deallocate(pointer_,size_);pointer_=typename detail::ScratchAllocator<T>::pointer{};size_=0; }
        pointer_=allocator_.allocate(required);size_=required;
    }
};

class RefineWorkspace {
public:
    using VertexT = gpart::GraphTypes::VertexT;
    detail::ScratchBuffer<VertexT> previous_partition;
    detail::ScratchBuffer<unsigned long long> previous_part_weights;
    detail::ScratchBuffer<unsigned long long> cut_counter;
    RefinementCache<std::uint64_t> dense_affinity;
    RefinementCache<std::uint32_t> dense_affinity32;
    RefinementCache<std::uint8_t> affinity_keys;
    RefinementCache<std::uint8_t> affinity_counts;
    detail::ScratchBuffer<std::int32_t> frontier_rows;
    detail::ScratchBuffer<std::int32_t> frontier_members;
    detail::ScratchBuffer<unsigned long long> frontier_count;
    detail::ScratchBuffer<std::int32_t> affinity_dirty;
    detail::ScratchBuffer<std::int32_t> affinity_dirty_rows;
    detail::ScratchBuffer<unsigned long long> affinity_dirty_count;
    detail::ScratchBuffer<std::int32_t> incremental_targets;
    detail::ScratchBuffer<std::int64_t> incremental_gains;
    detail::ScratchBuffer<std::int32_t> incremental_locks;
    detail::ScratchBuffer<std::int32_t> incremental_flags;
    detail::ScratchBuffer<VertexT> incremental_movers;
    detail::ScratchBuffer<std::int64_t> incremental_delta;
    // Bound the heavy-row queue by CSR entries / threshold, not by vertices.
    detail::ScratchBuffer<VertexT> incremental_heavy_rows;
    detail::ScratchBuffer<unsigned int> incremental_heavy_count;
    detail::ScratchBuffer<std::int64_t> incremental_heavy_corrections;
    detail::ScratchBuffer<std::int32_t> balance_bucket_ids;
    detail::ScratchBuffer<std::uint64_t> balance_bucket_ranks;
    detail::ScratchBuffer<unsigned long long> balance_bucket_counts;
    detail::ScratchBuffer<unsigned long long> balance_bucket_offsets;
    detail::ScratchBuffer<JointMove> joint_moves;
    detail::ScratchBuffer<unsigned long long> joint_quotient, joint_seeds, joint_events;
    detail::ScratchBuffer<int> joint_partner, joint_visits, joint_stops, joint_selected;
    detail::ScratchBuffer<BoundaryGroup> boundary_groups;
    detail::ScratchBuffer<GroupTransaction> group_transactions;
    detail::ScratchBuffer<std::int32_t> group_order;
    detail::ScratchBuffer<GroupRadixKey> group_sort_keys,group_sort_other;
    detail::ScratchBuffer<std::uint8_t> group_sort_temp;
    detail::ScratchBuffer<unsigned int> group_sort_errors;
    detail::ScratchBuffer<unsigned long long> group_sort_limits;
    detail::ScratchBuffer<std::int32_t> group_weight_order;
    detail::ScratchBuffer<std::int32_t> group_tree;
    detail::ScratchBuffer<GroupRange> group_ranges;
    detail::ScratchBuffer<int> group_active_pairs;
    detail::ScratchBuffer<GroupTransaction> group_candidates;
    detail::ScratchBuffer<double> repair_prices;
    detail::ScratchBuffer<RepairSample> repair_samples;
    double resize_seconds = 0.0;

    template <typename Buffer>
    void grow(Buffer& buffer, std::size_t required) {
        if (buffer.size() < required) {
            const auto start = std::chrono::steady_clock::now();
            buffer.resize(required);
            resize_seconds += std::chrono::duration<double>(
                std::chrono::steady_clock::now() - start).count();
        }
    }

    void initialize(std::size_t vertices, std::size_t parts) {
        grow(previous_partition, vertices);
        grow(previous_part_weights, parts);
        grow(cut_counter, 1);
    }
};

class RefineDeviceContext {
public:
    using VertexT = gpart::GraphTypes::VertexT;
    DeviceWeightedGraph graph;
    detail::ScratchBuffer<VertexT> partition;
    detail::ScratchBuffer<unsigned long long> part_weights;
    RefineWorkspace& workspace;
    std::vector<std::uint64_t> host_part_weights;
    std::uint64_t capacity;
    std::uint64_t known_cut=0;
    bool has_known_cut=false;
    std::int64_t n;
    int vertex_blocks;
    int warp_blocks;

    RefineDeviceContext(
        const WeightedGraph& input,
        const std::vector<VertexT>& labels,
        const RefineOptions& options,
        RefineWorkspace& temporary)
        : workspace(temporary),
          n(input.vertices()),
          vertex_blocks(static_cast<int>((n + 255) / 256)),
          warp_blocks(static_cast<int>(
              (n + kWarpsPerBlock - 1) / kWarpsPerBlock)) {
        if (options.parts < 2 || options.parts > kMaxParts ||
            options.max_rounds < 0 || options.max_rounds > 64 ||
            options.stale_rounds < 1 || options.stale_rounds > 64 ||
            options.joint_rounds < 0 || options.joint_rounds > 32 ||
            options.joint_conflict_rounds < 1 || options.joint_conflict_rounds > 4 ||
            options.boundary_group_rounds < 0 || options.boundary_group_rounds > 8 ||
            !std::isfinite(options.refinement_growth_ratio) || options.refinement_growth_ratio < 1.0 ||
            !std::isfinite(options.imbalance_ratio) ||
            options.imbalance_ratio < 1.0 || n <= 0) {
            throw std::invalid_argument("invalid refinement options");
        }
        if (input.offsets.size() != input.vertex_weights.size() + 1 ||
            input.offsets.empty() || input.offsets.front() != 0 ||
            input.offsets.back() != input.edges() ||
            input.neighbors.size() != input.edge_weights.size()) {
            throw std::invalid_argument("invalid weighted CSR for refinement");
        }
        std::uint64_t total_weight = 0;
        host_part_weights = validate_and_measure_partition(
            input, labels, options.parts, total_weight);
        capacity = refinement_capacity(
            total_weight, options.parts, options.imbalance_ratio);
        if (!options.allow_initial_imbalance && *std::max_element(
                host_part_weights.begin(), host_part_weights.end()) >
            capacity) {
            throw std::invalid_argument(
                "initial refinement partition is imbalanced");
        }
        graph = make_device_weighted(input);
        partition.assign(labels.begin(), labels.end());
        part_weights.assign(
            host_part_weights.begin(), host_part_weights.end());
        initialize_buffers();
    }

    RefineDeviceContext(
        DeviceWeightedGraph&& device_graph,
        detail::ScratchBuffer<VertexT>&& device_partition,
        detail::ScratchBuffer<unsigned long long>&& device_part_weights,
        std::vector<std::uint64_t> measured_part_weights,
        const RefineOptions& options,
        RefineWorkspace& temporary)
        : graph(std::move(device_graph)),
          partition(std::move(device_partition)),
          part_weights(std::move(device_part_weights)),
          workspace(temporary),
          host_part_weights(std::move(measured_part_weights)),
          n(graph.vertices()),
          vertex_blocks(static_cast<int>((n + 255) / 256)),
          warp_blocks(static_cast<int>(
              (n + kWarpsPerBlock - 1) / kWarpsPerBlock)) {
        std::uint64_t total_weight = 0;
        for (const auto weight : host_part_weights) {
            if (total_weight >
                std::numeric_limits<std::uint64_t>::max() - weight) {
                throw std::overflow_error("refinement vertex weight overflow");
            }
            total_weight += weight;
        }
        capacity = refinement_capacity(
            total_weight, options.parts, options.imbalance_ratio);
        if (partition.size() != static_cast<std::size_t>(n) ||
            part_weights.size() != static_cast<std::size_t>(options.parts) ||
            (!options.allow_initial_imbalance && *std::max_element(
                host_part_weights.begin(), host_part_weights.end()) >
                capacity)) {
            throw std::invalid_argument("invalid resident refinement state");
        }
        initialize_buffers();
    }

    void initialize_buffers() {
        workspace.initialize(static_cast<std::size_t>(n), part_weights.size());
    }

    std::uint64_t cut() {
        return device_cut_value(graph, partition, workspace.cut_counter);
    }

    void sync_part_weights() {
        // uint64_t is unsigned long on this host, whereas the CUDA atomic
        // counter is unsigned long long. Thrust treats that as conversion,
        // allocating a device temporary and launching a kernel on every poll.
        // Both are exact unsigned 64-bit representations; transfer the bits.
        static_assert(sizeof(std::uint64_t)==sizeof(unsigned long long) &&
                      std::numeric_limits<unsigned long long>::digits==64);
        CUDA_CHECK(cudaMemcpy(host_part_weights.data(),thrust::raw_pointer_cast(part_weights.data()),
            host_part_weights.size()*sizeof(std::uint64_t),cudaMemcpyDeviceToHost));
    }

    void export_partition(std::vector<VertexT>& labels) {
        thrust::copy(partition.begin(), partition.end(), labels.begin());
    }
};

void validate_refinement_gain_range(const WeightedGraph& graph) {
    constexpr auto signed_limit = static_cast<std::uint64_t>(
        std::numeric_limits<std::int64_t>::max()) / 2;
    constexpr auto max_weight = static_cast<std::uint64_t>(
        std::numeric_limits<gpart::GraphTypes::WeightT>::max());
    // A type/size bound proves exactly the old safety condition without
    // touching edge data. Division avoids overflow in the bound itself.
    if (graph.edge_weights.size() <= signed_limit / max_weight) return;
    std::uint64_t directed_weight = 0;
    for (const auto edge_weight : graph.edge_weights) {
        const auto weight = static_cast<std::uint64_t>(edge_weight);
        if (weight > signed_limit ||
            directed_weight > signed_limit - weight) {
            throw std::overflow_error(
                "refinement signed gain range exceeded");
        }
        directed_weight += weight;
    }
}

struct RefinementWeightSum {
    __host__ __device__ std::uint64_t operator()(std::uint64_t a, std::uint64_t b) const {
        constexpr auto limit = std::uint64_t(INT64_MAX) / 2;
        return a > limit || b > limit || a > limit - b ? limit + 1 : a + b;
    }
};

void validate_refinement_gain_range(const DeviceWeightedGraph& graph) {
    constexpr auto limit = std::uint64_t(INT64_MAX) / 2;
    constexpr auto max_weight = std::numeric_limits<gpart::GraphTypes::WeightT>::max();
    if (graph.implicit_unit_weights) {
        if (static_cast<std::uint64_t>(graph.edges())>limit)
            throw std::overflow_error("refinement signed gain range exceeded");
        return;
    }
    if (graph.edge_weights.size() <= limit / max_weight) return;
    if (thrust::reduce(detail::scratch_policy(), graph.edge_weights.begin(), graph.edge_weights.end(),
                       std::uint64_t{0}, RefinementWeightSum{}) > limit) {
        throw std::overflow_error("refinement signed gain range exceeded");
    }
}

struct InvalidId {
    std::int64_t bound;
    template <typename T>
    __host__ __device__ bool operator()(T id) const { return id < 0 || id >= bound; }
};

struct CheckedWeight {
    std::uint64_t value;
    std::uint64_t overflow;
    __host__ __device__ CheckedWeight(std::uint64_t v = 0) : value(v), overflow(false) {}
};
struct CheckedWeightAdd {
    __host__ __device__ CheckedWeight operator()(CheckedWeight a, CheckedWeight b) const {
        CheckedWeight out(a.value + b.value);
        out.overflow = a.overflow || b.overflow || out.value < a.value;
        return out;
    }
};
struct ToCheckedWeight {
    template <typename W>
    __host__ __device__ CheckedWeight operator()(W weight) const { return CheckedWeight(weight); }
};

#include "refine_incremental.cuh"

void refine_partition(
    const WeightedGraph& graph,
    std::vector<gpart::GraphTypes::VertexT>& partition,
    const RefineOptions& options,
    RefineStats* output_stats) {
    RefineWorkspace workspace;
    RefineDeviceContext context(graph, partition, options, workspace);
    auto stats = run_incremental_refinement(context, options, options.max_rounds);
    if (stats.initial_repair_failed) throw std::runtime_error("initial refinement capacity repair failed");
    context.export_partition(partition);
    if (output_stats != nullptr) *output_stats = stats;
}

template <bool Resident, typename H, typename P>
DeviceUncoarsenResult refine_hierarchy_impl(
    H& hierarchy, P&& coarsest_partition,
    const RefineOptions& options) {
    using VertexT = gpart::GraphTypes::VertexT;
    if (options.parts < 2 || options.parts > kMaxParts || options.max_rounds < 0 ||
        options.max_rounds > 64 || options.stale_rounds < 1 || options.stale_rounds > 64 ||
        options.joint_rounds < 0 || options.joint_rounds > 32 ||
            options.joint_conflict_rounds < 1 || options.joint_conflict_rounds > 4 ||
            options.boundary_group_rounds < 0 || options.boundary_group_rounds > 8 ||
        !std::isfinite(options.refinement_growth_ratio) || options.refinement_growth_ratio < 1.0 ||
        !std::isfinite(options.imbalance_ratio) ||
        options.imbalance_ratio < 1.0) {
        throw std::invalid_argument("invalid refinement options");
    }
    if (hierarchy.levels.empty() ||
        hierarchy.fine_to_coarse.size() + 1 != hierarchy.levels.size()) {
        throw std::invalid_argument("resident refinement requires a complete hierarchy");
    }
    // Validate once before any refinement, including externally built
    // hierarchies; do not assume their coarse edge weights are bounded by
    // the original graph's weight sum.
    for (std::size_t level = 0; level < hierarchy.levels.size(); ++level) {
        validate_refinement_gain_range(hierarchy.levels[level]);
    }
    RefineWorkspace workspace;
    auto& coarsest = hierarchy.levels.back();
    const bool projection_timings = options.strict_verify || std::getenv("GPART_GPU_TIMINGS") != nullptr;
    std::cout << "refine_projection_timings_enabled=" << projection_timings << '\n';
    std::uint64_t total_weight = 0;
    const auto initial_h2d_start = std::chrono::steady_clock::now();
    DeviceWeightedGraph current_graph;
    detail::ScratchBuffer<VertexT> current_partition;
    detail::ScratchBuffer<unsigned long long> current_part_weights;
    std::vector<std::uint64_t> current_host_weights;
    if constexpr (Resident) {
        if (coarsest_partition.size() != static_cast<std::size_t>(coarsest.vertices()) ||
            thrust::count_if(detail::scratch_policy(), coarsest_partition.begin(), coarsest_partition.end(),
                             InvalidId{options.parts}) != 0) {
            throw std::invalid_argument("invalid coarsest device partition");
        }
        const auto sum = thrust::transform_reduce(detail::scratch_policy(), coarsest.vertex_weights.begin(),
            coarsest.vertex_weights.end(), ToCheckedWeight{}, CheckedWeight{}, CheckedWeightAdd{});
        if (sum.overflow) throw std::overflow_error("refinement vertex weight sum overflow");
        total_weight = sum.value;
        current_graph = std::move(coarsest);
        current_partition.assign(coarsest_partition.begin(), coarsest_partition.end());
        // Keep the public interface unchanged; release the consumed ordinary
        // vector inside native timing after its small coarsest copy completes.
        thrust::device_vector<VertexT>{}.swap(coarsest_partition);
        device_part_weights(current_graph, current_partition, current_part_weights, options.parts);
        current_host_weights.resize(options.parts);
        CUDA_CHECK(cudaMemcpy(current_host_weights.data(),thrust::raw_pointer_cast(current_part_weights.data()),options.parts*sizeof(std::uint64_t),cudaMemcpyDeviceToHost));
    } else {
        current_host_weights = validate_and_measure_partition(
            coarsest, coarsest_partition, options.parts, total_weight);
        current_graph = make_device_weighted(coarsest);
        current_partition.assign(coarsest_partition.begin(), coarsest_partition.end());
        current_part_weights.assign(current_host_weights.begin(), current_host_weights.end());
    }
    if (!options.allow_initial_imbalance && *std::max_element(current_host_weights.begin(), current_host_weights.end()) >
        refinement_capacity(total_weight, options.parts, options.imbalance_ratio)) {
        throw std::invalid_argument("initial refinement partition is imbalanced");
    }
    double pending_graph_h2d = Resident ? 0.0 : std::chrono::duration<double>(
        std::chrono::steady_clock::now() - initial_h2d_start).count();
    workspace.grow(workspace.cut_counter, 1);
    auto& cut_counter = workspace.cut_counter;

    DeviceUncoarsenResult result;
    result.levels.reserve(hierarchy.levels.size() - 1);
    std::uint64_t last_cut=0;
    auto last_refined_vertices=current_graph.vertices();
    {
        RefineDeviceContext context(std::move(current_graph),
            std::move(current_partition), std::move(current_part_weights),
            current_host_weights, options, workspace);
        const auto stats = run_incremental_refinement(context, options, options.max_rounds);
        last_cut=stats.final_cut;
        std::cout << "refine_coarsest vertices=" << context.n
                  << " initial_cut=" << stats.initial_cut
                  << " final_cut=" << stats.final_cut
                  << " rounds=" << stats.rounds
                  << " lp_cut_gain=" << stats.lp_cut_gain
                  << " affinity_counter_bits=" << stats.affinity_counter_bits
                  << " sparse_affinity=" << stats.sparse_affinity
                  << " on_demand_affinity=" << stats.on_demand_affinity
                  << " frontier_vertices_initial=" << stats.frontier_vertices_initial
                  << " affinity_bytes=" << stats.affinity_bytes
                  << " lp_cut_loss=" << stats.lp_cut_loss
                  << " rebalance_cut_gain=" << stats.rebalance_cut_gain
                  << " rebalance_cut_loss=" << stats.rebalance_cut_loss
                  << " group_cut_gain=" << stats.group_cut_gain
                  << " group_accepted=" << stats.group_accepted
                  << " seconds=" << stats.seconds << '\n';
        current_graph = std::move(context.graph);
        current_partition = std::move(context.partition);
        current_part_weights = std::move(context.part_weights);
        current_host_weights = context.host_part_weights;
    }

    for (std::size_t coarse_level = hierarchy.levels.size() - 1;
         coarse_level > 0; --coarse_level) {
        const auto fine_level = coarse_level - 1;
        auto& fine = hierarchy.levels[fine_level];
        auto& map = hierarchy.fine_to_coarse[fine_level];
        if (map.size() != static_cast<std::size_t>(fine.vertices())) {
            throw std::invalid_argument("fine-to-coarse map has wrong length");
        }
        if constexpr (Resident) {
            if (thrust::count_if(detail::scratch_policy(), map.begin(), map.end(), InvalidId{current_graph.vertices()}) != 0) {
                throw std::invalid_argument("fine-to-coarse map contains an invalid id");
            }
        } else {
            for (const auto coarse_vertex : map) {
                if (coarse_vertex < 0 || coarse_vertex >= current_graph.vertices()) {
                    throw std::invalid_argument("fine-to-coarse map contains an invalid id");
                }
            }
        }

        const auto workspace_start = result.levels.empty()
            ? 0.0 : workspace.resize_seconds;
        RefineLevelResult report;
        report.level = fine_level;
        report.vertices = fine.vertices();
        report.edge_entries = fine.edges();
        const auto graph_h2d_start = std::chrono::steady_clock::now();
        DeviceWeightedGraph fine_graph;
        detail::ScratchVector<VertexT> device_map;
        if constexpr (Resident) {
            fine_graph = std::move(fine);
            device_map = std::move(map);
        } else {
            fine_graph = make_device_weighted(fine);
            device_map = map;
        }
        detail::ScratchBuffer<VertexT> fine_partition(
            static_cast<std::size_t>(report.vertices));
        report.timings.graph_h2d_seconds = Resident ? 0.0 : pending_graph_h2d +
            std::chrono::duration<double>(
                std::chrono::steady_clock::now() - graph_h2d_start).count();
        pending_graph_h2d = 0.0;

        const auto projection_start = std::chrono::steady_clock::now();
        const int projection_blocks = static_cast<int>(
            (report.vertices + 255) / 256);
        project_partition_kernel<<<projection_blocks, 256>>>(
            report.vertices, thrust::raw_pointer_cast(device_map.data()),
            thrust::raw_pointer_cast(current_partition.data()),
            thrust::raw_pointer_cast(fine_partition.data()));
        CUDA_CHECK(cudaGetLastError());
        // Producers and consumers share the default stream; nested LP graphs
        // already wait on its ready event. Sync only for requested telemetry.
        if (projection_timings) CUDA_CHECK(cudaDeviceSynchronize());
        report.timings.projection_gpu_seconds = projection_timings ? std::chrono::duration<double>(
            std::chrono::steady_clock::now() - projection_start).count() : 0.0;

        detail::ScratchBuffer<unsigned long long> fine_part_weights;
        auto projected_weights = current_host_weights;
        if (options.strict_verify) {
            const auto verification_start = std::chrono::steady_clock::now();
            device_part_weights(
                fine_graph, fine_partition, fine_part_weights, options.parts);
            CUDA_CHECK(cudaMemcpy(projected_weights.data(),thrust::raw_pointer_cast(fine_part_weights.data()),options.parts*sizeof(std::uint64_t),cudaMemcpyDeviceToHost));
            report.projection_cut = device_cut_value(
                fine_graph, fine_partition, cut_counter);
            const auto coarse_cut = device_cut_value(
                current_graph, current_partition, cut_counter);
            std::vector<std::uint64_t> coarse_weights(
                static_cast<std::size_t>(options.parts));
            CUDA_CHECK(cudaMemcpy(coarse_weights.data(),thrust::raw_pointer_cast(current_part_weights.data()),options.parts*sizeof(std::uint64_t),cudaMemcpyDeviceToHost));
            if (coarse_cut != report.projection_cut ||
                coarse_weights != projected_weights) {
                throw std::runtime_error(
                    "GPU projection failed cut or part-weight preservation");
            }
            report.timings.verification_seconds = std::chrono::duration<double>(
                std::chrono::steady_clock::now() - verification_start).count();
        } else {
            // Projection preserves part weights; capacity needs no rescan.
            fine_part_weights = std::move(current_part_weights);
        }
        report.projection_max_part_weight = *std::max_element(
            projected_weights.begin(), projected_weights.end());
        const auto projected_total = std::accumulate(
            projected_weights.begin(), projected_weights.end(),
            std::uint64_t{0});
        report.projection_imbalance = projected_total == 0 ? 0.0 :
            static_cast<double>(report.projection_max_part_weight) *
            options.parts / static_cast<double>(projected_total);

        RefineDeviceContext context(
            std::move(fine_graph), std::move(fine_partition),
            std::move(fine_part_weights), projected_weights, options, workspace);
        context.known_cut=last_cut;context.has_known_cut=true;
        auto resize_before_stage = workspace.resize_seconds;
        const bool refine_this_level = fine_level==0 ||
            report.projection_max_part_weight>context.capacity ||
            report.vertices>=options.refinement_growth_ratio*last_refined_vertices;
        if (refine_this_level) {
            report.refinement = run_incremental_refinement(context, options, options.max_rounds);
            if (!report.refinement.initial_repair_failed) last_refined_vertices=report.vertices;
        } else {
            // Projection preserves cut and part weights. Avoid rebuilding
            // the affinity cache when this level adds little resolution.
            report.refinement.initial_cut=report.refinement.final_cut=last_cut;
            report.refinement.final_max_part_weight=report.projection_max_part_weight;
        }
        if (!options.strict_verify) {
            report.projection_cut = report.refinement.initial_cut;
        }
        report.timings.refinement_seconds = report.refinement.seconds -
            (workspace.resize_seconds - resize_before_stage);
        report.timings.workspace_resize_seconds = workspace.resize_seconds - workspace_start;
        last_cut = report.refinement.final_cut;
        current_host_weights = context.host_part_weights;
        current_graph = std::move(context.graph);
        current_partition = std::move(context.partition);
        current_part_weights = std::move(context.part_weights);
        result.levels.push_back(std::move(report));
    }

    if (*std::max_element(current_host_weights.begin(), current_host_weights.end()) >
        refinement_capacity(total_weight, options.parts, options.imbalance_ratio))
        throw std::runtime_error("final original partition violates capacity");
    result.final_cut = last_cut;
    result.final_part_weights = current_host_weights;
    const auto directed_edge_weight = current_graph.implicit_unit_weights
        ? static_cast<std::uint64_t>(current_graph.edges()) : thrust::reduce(
        detail::scratch_policy(), current_graph.edge_weights.begin(), current_graph.edge_weights.end(),
        std::uint64_t{0});
    if ((directed_edge_weight & 1ULL) != 0) {
        throw std::runtime_error("symmetric graph has odd directed edge weight");
    }
    result.total_edge_weight = directed_edge_weight / 2;
    if constexpr (Resident) {
        // Final output ownership remains the public ordinary device_vector.
        // Its allocation and this D2D copy are both inside native timing;
        // working labels and their pool pages are released before pool trim.
        result.device_partition.assign(current_partition.begin(), current_partition.end());
    } else {
        result.partition.resize(static_cast<std::size_t>(current_graph.vertices()));
        const auto final_d2h_start = std::chrono::steady_clock::now();
        thrust::copy(current_partition.begin(), current_partition.end(), result.partition.begin());
        result.final_d2h_seconds = std::chrono::duration<double>(
            std::chrono::steady_clock::now() - final_d2h_start).count();
    }
    return result;
}

DeviceUncoarsenResult refine_hierarchy_device(
    const Hierarchy& hierarchy,
    const std::vector<gpart::GraphTypes::VertexT>& partition, const RefineOptions& options) {
    return refine_hierarchy_impl<false>(hierarchy, partition, options);
}

DeviceUncoarsenResult refine_hierarchy_device(
    DeviceHierarchy& hierarchy,
    thrust::device_vector<gpart::GraphTypes::VertexT>&& partition, const RefineOptions& options) {
    return refine_hierarchy_impl<true>(hierarchy, std::move(partition), options);
}






}  // namespace gpart
