#pragma once
#include "detail/edge_weight.hpp"

// Exact short-row CSR contraction. No approximate matching or edge dropping.
namespace gpart {
namespace {

template <typename OffsetT>
__device__ __forceinline__ OffsetT row_atomic_add(OffsetT* address, OffsetT value) {
    if constexpr (sizeof(OffsetT) == 4)
        return static_cast<OffsetT>(atomicAdd(reinterpret_cast<unsigned int*>(address),
                                             static_cast<unsigned int>(value)));
    else
        return static_cast<OffsetT>(atomicAdd(reinterpret_cast<unsigned long long*>(address),
                                             static_cast<unsigned long long>(value)));
}

template <typename OffsetT, typename WeightT>
__global__ void contraction_row_scatter(std::int64_t n, const OffsetT* offsets,
    const std::int32_t* neighbors, const WeightT* weights, const std::int32_t* map,
    OffsetT* cursors, std::int32_t* bucket_neighbors, WeightT* bucket_weights) {
    constexpr int width = 8;
    const auto v = (static_cast<std::int64_t>(blockIdx.x) * blockDim.x + threadIdx.x) / width;
    const int lane = threadIdx.x & (width - 1);
    const unsigned mask = 0xffU << (threadIdx.x & 24);
    if (v >= n) return;
    const auto source = map[v];
    const auto begin = offsets[v], end = offsets[v + 1];
    OffsetT output = 0;
    if (!lane) output = row_atomic_add(cursors + source, end - begin);
    output = __shfl_sync(mask, output, 0, width);
    for (auto e = begin + lane; e < end; e += width) {
        const auto target = map[neighbors[e]];
        const auto position = output + (e - begin);
        bucket_neighbors[position] = source == target ? INT32_MAX : target;
        bucket_weights[position] = detail::edge_weight(weights,e);
    }
}

template <int Items, typename WeightT>
__device__ __forceinline__ void contraction_warp_sort(
    std::int32_t (&keys)[Items], WeightT (&weights)[Items], int lane) {
    // A striped bitonic network. Every row owns a complete warp; equality
    // leaves the payload attached to its key. Integer reduction is exact.
    for (int size = 2; size <= 32 * Items; size <<= 1) {
        for (int distance = size >> 1; distance; distance >>= 1) {
            std::int32_t next_keys[Items];
            WeightT next_weights[Items];
            #pragma unroll
            for (int item = 0; item < Items; ++item) {
                const int index = item * 32 + lane;
                std::int32_t other_key;
                WeightT other_weight;
                if (distance >= 32) {
                    other_key = keys[item ^ (distance / 32)];
                    other_weight = weights[item ^ (distance / 32)];
                } else {
                    other_key = __shfl_xor_sync(0xffffffffU, keys[item], distance);
                    other_weight = __shfl_xor_sync(0xffffffffU, weights[item], distance);
                }
                const bool lower = ((index & distance) == 0) == ((index & size) == 0);
                const bool take = lower ? other_key < keys[item] : other_key > keys[item];
                next_keys[item] = take ? other_key : keys[item];
                next_weights[item] = take ? other_weight : weights[item];
            }
            #pragma unroll
            for (int item = 0; item < Items; ++item) {
                keys[item] = next_keys[item]; weights[item] = next_weights[item];
            }
        }
    }
}

template <int Items, typename OffsetT, typename WeightT>
__device__ __forceinline__ OffsetT contraction_sort_row(
    OffsetT begin, OffsetT degree, std::int32_t* neighbors, WeightT* weights, int lane) {
    std::int32_t keys[Items]; WeightT values[Items];
    #pragma unroll
    for (int item = 0; item < Items; ++item) {
        const auto position = lane + 32 * item;
        keys[item] = position < degree ? neighbors[begin + position] : INT32_MAX;
        values[item] = position < degree ? weights[begin + position] : WeightT{0};
    }
    contraction_warp_sort(keys, values, lane);
    // All input payloads are now in registers. Reduce duplicate keys with
    // a segmented warp scan, carrying a run across 32-entry stripes.
    OffsetT count = 0;
    std::int32_t carry_key = INT32_MAX;
    WeightT carry_sum = 0;
    #pragma unroll
    for (int item = 0; item < Items; ++item) {
        const auto key = keys[item];
        WeightT sum = values[item];
        if (!lane && key == carry_key) sum += carry_sum;
        #pragma unroll
        for (int delta = 1; delta < 32; delta <<= 1) {
            const auto other_key = __shfl_up_sync(0xffffffffU, key, delta);
            const auto other_sum = __shfl_up_sync(0xffffffffU, sum, delta);
            if (lane >= delta && key == other_key) sum += other_sum;
        }
        const auto next_stripe = item + 1 < Items ? keys[item + 1] : INT32_MAX;
        const auto following_lane = __shfl_down_sync(0xffffffffU, key, 1);
        const auto following_stripe = __shfl_sync(0xffffffffU, next_stripe, 0);
        const auto next_key = lane < 31 ? following_lane : following_stripe;
        const bool emit = key != INT32_MAX && key != next_key;
        const auto mask = __ballot_sync(0xffffffffU, emit);
        if (emit) {
            const auto output = begin + count + __popc(mask & ((1U << lane) - 1U));
            neighbors[output] = key; weights[output] = sum;
        }
        count += __popc(mask);
        carry_key = __shfl_sync(0xffffffffU, key, 31);
        carry_sum = __shfl_sync(0xffffffffU, sum, 31);
    }
    return count;
}

template <bool LongRows = false, typename OffsetT, typename WeightT>
__global__ void contraction_sort_rows(std::int64_t rows, const OffsetT* raw_offsets,
    std::int32_t* neighbors, WeightT* weights, OffsetT* unique_counts) {
    const auto row = (static_cast<std::int64_t>(blockIdx.x) * blockDim.x + threadIdx.x) / 32;
    const int lane = threadIdx.x & 31;
    if (row >= rows) return;
    const auto begin = raw_offsets[row], degree = raw_offsets[row + 1] - begin;
    // Separate launches keep the 512-entry register footprint off short rows.
    OffsetT count;
    if constexpr (LongRows) {
        if (degree <= 128) return;
        count = degree <= 256 ? contraction_sort_row<8>(begin, degree, neighbors, weights, lane)
                              : contraction_sort_row<16>(begin, degree, neighbors, weights, lane);
    } else {
        if (degree > 128) return;
        count = degree <= 32 ? contraction_sort_row<1>(begin, degree, neighbors, weights, lane)
              : degree <= 64 ? contraction_sort_row<2>(begin, degree, neighbors, weights, lane)
                             : contraction_sort_row<4>(begin, degree, neighbors, weights, lane);
    }
    if (!lane) unique_counts[row] = count;
}

template <typename OffsetT, typename WeightT>
__global__ void contraction_copy_rows(std::int64_t rows, const OffsetT* raw_offsets,
    const std::int32_t* raw_neighbors, const WeightT* raw_weights,
    const OffsetT* offsets, std::int32_t* neighbors, WeightT* weights) {
    constexpr int width = 8;
    const auto row = (static_cast<std::int64_t>(blockIdx.x) * blockDim.x + threadIdx.x) / width;
    const int lane = threadIdx.x & (width - 1);
    if (row >= rows) return;
    const auto begin = offsets[row], end = offsets[row + 1];
    const auto raw = raw_offsets[row];
    for (auto e = begin + lane; e < end; e += width) {
        neighbors[e] = raw_neighbors[raw + e - begin];
        weights[e] = raw_weights[raw + e - begin];
    }
}

} // namespace
} // namespace gpart
