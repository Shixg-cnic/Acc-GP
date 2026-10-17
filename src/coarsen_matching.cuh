#pragma once
#include "detail/edge_weight.hpp"

namespace gpart {
namespace {

__device__ __forceinline__ std::uint32_t matching_mix(std::uint32_t x) {
    x ^= x >> 16; x *= 0x7feb352dU; x ^= x >> 15; x *= 0x846ca68bU;
    return x ^ (x >> 16);
}

template <int Width, typename OffsetT, typename WeightT>
__global__ void matching_choose(std::int64_t n, const OffsetT* offsets,
    const std::int32_t* neighbors, const WeightT* edge_weights,
    const WeightT* vertex_weights, const std::int32_t* matched,
    std::int32_t* choices, std::uint64_t capacity, std::uint32_t salt,
    unsigned long long* maximum_degree) {
    const auto thread = static_cast<std::int64_t>(blockIdx.x) * 256 + threadIdx.x;
    const auto v = thread / Width;
    const int lane = threadIdx.x & (Width - 1);
    const auto degree = v < n ? offsets[v + 1] - offsets[v] : OffsetT{0};
    if (maximum_degree) {
        __shared__ unsigned int maxima[8];
        const auto largest = __reduce_max_sync(0xffffffffU, static_cast<unsigned int>(
            min(static_cast<unsigned long long>(degree), static_cast<unsigned long long>(UINT32_MAX))));
        if (!(threadIdx.x & 31)) maxima[threadIdx.x / 32] = largest;
        __syncthreads();
        if (!threadIdx.x) {
            unsigned int block_max = 0;
            for (int w = 0; w < 8; ++w) block_max = max(block_max, maxima[w]);
            atomicMax(maximum_degree, static_cast<unsigned long long>(block_max));
        }
    }
    if (v >= n) return;
    if (!lane) choices[v] = -1;
    // Sparse graphs with hubs need not serialize a huge row here. If this
    // prevents useful matching, the caller falls back to the SCLP hub path.
    if (matched[v] >= 0 || degree > 1024) return;
    const auto weight = static_cast<std::uint64_t>(vertex_weights[v]);
    int best = -1;
    WeightT best_weight = 0;
    std::uint32_t best_hash = 0;
    for (auto e = offsets[v] + lane; e < offsets[v + 1]; e += Width) {
        const auto u = neighbors[e];
        if (u == v || matched[u] >= 0 || weight > capacity ||
            static_cast<std::uint64_t>(vertex_weights[u]) > capacity - weight) continue;
        const auto low = min(static_cast<std::int32_t>(v), u);
        const auto high = max(static_cast<std::int32_t>(v), u);
        // A symmetric, total edge order makes mutual choices conflict free.
        const auto hash = matching_mix(low ^ matching_mix(high ^ salt));
        const auto ew = detail::edge_weight(edge_weights,e);
        if (best < 0 || ew > best_weight ||
            (ew == best_weight && (hash > best_hash || (hash == best_hash && u > best)))) {
            best = u; best_weight = ew; best_hash = hash;
        }
    }
    if constexpr (Width == 32) {
        for (int delta = 16; delta; delta >>= 1) {
            const auto other = __shfl_down_sync(0xffffffffU, best, delta);
            const auto other_weight = static_cast<WeightT>(__shfl_down_sync(
                0xffffffffU, static_cast<unsigned long long>(best_weight), delta));
            const auto other_hash = __shfl_down_sync(0xffffffffU, best_hash, delta);
            if (lane + delta < 32 && other >= 0 && (best < 0 || other_weight > best_weight ||
                (other_weight == best_weight && (other_hash > best_hash ||
                    (other_hash == best_hash && other > best))))) {
                best = other; best_weight = other_weight; best_hash = other_hash;
            }
        }
    }
    if (!lane) choices[v] = best;
}

__global__ void matching_commit(std::int64_t n, const std::int32_t* choices,
                                std::int32_t* matched) {
    const auto v = static_cast<std::int64_t>(blockIdx.x) * 256 + threadIdx.x;
    if (v >= n) return;
    const auto u = choices[v];
    if (u > v && choices[u] == v) {
        matched[v] = u; matched[u] = static_cast<std::int32_t>(v);
    }
}

__global__ void matching_roots(std::int64_t n, std::int32_t* matched,
                               std::int32_t* root_flags) {
    const auto v = static_cast<std::int64_t>(blockIdx.x) * 256 + threadIdx.x;
    if (v >= n) return;
    const auto partner = matched[v];
    const auto root = partner < 0 ? static_cast<std::int32_t>(v)
                                 : min(static_cast<std::int32_t>(v), partner);
    matched[v] = root; root_flags[v] = root == v;
}

} // namespace
} // namespace gpart
