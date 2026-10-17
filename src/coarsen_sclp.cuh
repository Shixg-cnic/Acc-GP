#pragma once
// SCLP affinity, capacity admission and two-hop device implementation.
// Included inside gpart's anonymous namespace after shared contraction helpers.

template <typename OffsetT>
__global__ void sclp_compact_degree_classes(std::int64_t n,const OffsetT* offsets,
    std::int32_t* low,std::int32_t* medium,std::int32_t* high,
    unsigned long long* counts) {
    const int lane=threadIdx.x&31;
    const auto v=static_cast<std::int64_t>(blockIdx.x)*blockDim.x+threadIdx.x;
    const auto degree=v<n ? offsets[v+1]-offsets[v] : OffsetT{0};
    const auto maximum=__reduce_max_sync(0xffffffffU,static_cast<unsigned int>(min(static_cast<unsigned long long>(degree),static_cast<unsigned long long>(UINT32_MAX))));
    if(!lane) atomicMax(counts+4,static_cast<unsigned long long>(maximum));
    const int category=degree<=SCLP_LOW_DEGREE ? 0 : degree<=SCLP_MEDIUM_DEGREE ? 1 : 2;
    const auto heavy=__ballot_sync(0xffffffffU,v<n && degree>=4096);
    if(heavy && !lane) atomicExch(counts+3,1ULL);
    for(int c=0;c<3;++c) {
        const auto mask=__ballot_sync(0xffffffffU,v<n && category==c);
        if(!mask) continue;
        unsigned long long begin=0;
        if(!lane) begin=atomicAdd(counts+c,static_cast<unsigned long long>(__popc(mask)));
        begin=__shfl_sync(0xffffffffU,begin,0);
        if(v<n && category==c) {
            auto* queue=c==0 ? low : c==1 ? medium : high;
            queue[begin+__popc(mask&((1U<<lane)-1))]=static_cast<std::int32_t>(v);
        }
    }
}

template <typename OffsetT>
__global__ void sclp_compact_degree_classes_block(std::int64_t n, const OffsetT* offsets,
    std::int32_t* low, std::int32_t* medium, std::int32_t* high, unsigned long long* counts) {
    __shared__ unsigned int sizes[3][8];
    __shared__ unsigned long long starts[3][8];
    __shared__ unsigned int maxima[8], heavy_rows[8];
    const int lane = threadIdx.x & 31, warp = threadIdx.x / 32;
    const auto v = static_cast<std::int64_t>(blockIdx.x) * 256 + threadIdx.x;
    const auto degree = v < n ? offsets[v + 1] - offsets[v] : OffsetT{0};
    const int category = degree <= SCLP_LOW_DEGREE ? 0 : degree <= SCLP_MEDIUM_DEGREE ? 1 : 2;
    unsigned int own_mask = 0;
    for (int c = 0; c < 3; ++c) {
        const auto mask = __ballot_sync(0xffffffffU, v < n && category == c);
        if (c == category) own_mask = mask;
        if (!lane) sizes[c][warp] = __popc(mask);
    }
    const auto largest = __reduce_max_sync(0xffffffffU, static_cast<unsigned int>(
        min(static_cast<unsigned long long>(degree), static_cast<unsigned long long>(UINT32_MAX))));
    const auto heavy = __ballot_sync(0xffffffffU, v < n && degree >= 4096);
    if (!lane) { maxima[warp] = largest; heavy_rows[warp] = heavy; }
    __syncthreads();
    if (threadIdx.x < 3) {
        const int c = threadIdx.x;
        unsigned int total = 0;
        for (int w = 0; w < 8; ++w) total += sizes[c][w];
        auto next = total ? atomicAdd(counts + c, static_cast<unsigned long long>(total)) : 0ULL;
        for (int w = 0; w < 8; ++w) { starts[c][w] = next; next += sizes[c][w]; }
    }
    if (threadIdx.x == 3) {
        unsigned int largest_block = 0, heavy_block = 0;
        for (int w = 0; w < 8; ++w) {
            largest_block = max(largest_block, maxima[w]); heavy_block |= heavy_rows[w];
        }
        atomicMax(counts + 4, static_cast<unsigned long long>(largest_block));
        if (heavy_block) atomicExch(counts + 3, 1ULL);
    }
    __syncthreads();
    if (v < n) {
        auto* queue = category == 0 ? low : category == 1 ? medium : high;
        queue[starts[category][warp] + __popc(own_mask & ((1U << lane) - 1))] = v;
    }
}

__device__ __forceinline__ bool sclp_cluster_is_mover(
    std::int32_t cluster, std::uint32_t role_salt,
    std::uint32_t mover_threshold, const std::uint8_t* roles = nullptr) {
    return roles[cluster] != 0;
}

__device__ __forceinline__ bool sclp_better_candidate(
    unsigned long long affinity, unsigned long long tie,
    unsigned long long other_affinity, unsigned long long other_tie) {
    return affinity > other_affinity ||
           (affinity == other_affinity && affinity != 0 && tie > other_tie);
}

__device__ __forceinline__ void sclp_update_best(
    unsigned long long affinity, unsigned long long tie,
    unsigned long long& best_affinity, unsigned long long& best_tie) {
    if (sclp_better_candidate(affinity, tie, best_affinity, best_tie)) {
        best_affinity = affinity;
        best_tie = tie;
    }
}

// Inputs must represent distinct target clusters (hash/reduce has already
// combined parallel edges). Equal maxima count as two alternatives.
__device__ __forceinline__ void sclp_update_two(
    unsigned long long value, unsigned long long tie,
    unsigned long long& best, unsigned long long& best_tie,
    unsigned long long& second) {
    if (sclp_better_candidate(value, tie, best, best_tie)) {
        second = max(second, best);
        best = value;
        best_tie = tie;
    } else second = max(second, value);
}

__device__ __forceinline__ void sclp_finish_warp_affinity(
    std::int32_t v, unsigned long long local_current,
    unsigned long long local_unrestricted,
    unsigned long long local_best_affinity, unsigned long long local_best_tie,
    unsigned long long* current_affinity,
    unsigned long long* best_affinity, unsigned long long* best_ties,
    unsigned long long* unrestricted_best_affinity,
    unsigned long long local_second = 0, unsigned long long* second = nullptr) {
    constexpr unsigned mask = 0xffffffffU;
    const int lane = threadIdx.x & (WARP_SIZE - 1);
    for (int offset = WARP_SIZE / 2; offset > 0; offset /= 2) {
        local_current = max(
            local_current, __shfl_down_sync(mask, local_current, offset));
        local_unrestricted = max(
            local_unrestricted,
            __shfl_down_sync(mask, local_unrestricted, offset));
        const auto other_affinity =
            __shfl_down_sync(mask, local_best_affinity, offset);
        const auto other_tie = __shfl_down_sync(mask, local_best_tie, offset);
        if (second) {
            const auto other_second = __shfl_down_sync(mask, local_second, offset);
            sclp_update_two(other_affinity, other_tie,
                            local_best_affinity, local_best_tie, local_second);
            local_second = max(local_second, other_second);
        } else sclp_update_best(other_affinity, other_tie,
                                 local_best_affinity, local_best_tie);
    }
    if (lane == 0) {
        current_affinity[v] = local_current;
        unrestricted_best_affinity[v] = local_unrestricted;
        best_affinity[v] = local_best_affinity;
        best_ties[v] = local_best_tie;
        if (second) second[v] = local_second;
    }
}

__device__ __forceinline__ void sclp_finish_subwarp_affinity(
    std::int32_t v, unsigned mask, int lane_in_subwarp,
    unsigned long long local_current,
    unsigned long long local_unrestricted,
    unsigned long long local_best_affinity, unsigned long long local_best_tie,
    unsigned long long* current_affinity,
    unsigned long long* best_affinity, unsigned long long* best_ties,
    unsigned long long* unrestricted_best_affinity,
    unsigned long long local_second = 0, unsigned long long* second = nullptr) {
    constexpr int SUBWARP_SIZE = 8;
    for (int offset = SUBWARP_SIZE / 2; offset > 0; offset /= 2) {
        local_current = max(
            local_current, __shfl_down_sync(mask, local_current, offset));
        local_unrestricted = max(
            local_unrestricted,
            __shfl_down_sync(mask, local_unrestricted, offset));
        const auto other_affinity =
            __shfl_down_sync(mask, local_best_affinity, offset);
        const auto other_tie = __shfl_down_sync(mask, local_best_tie, offset);
        if (second) {
            const auto other_second = __shfl_down_sync(mask, local_second, offset);
            sclp_update_two(other_affinity, other_tie,
                            local_best_affinity, local_best_tie, local_second);
            local_second = max(local_second, other_second);
        } else sclp_update_best(other_affinity, other_tie,
                                 local_best_affinity, local_best_tie);
    }
    if (lane_in_subwarp == 0) {
        current_affinity[v] = local_current;
        unrestricted_best_affinity[v] = local_unrestricted;
        best_affinity[v] = local_best_affinity;
        best_ties[v] = local_best_tie;
        if (second) second[v] = local_second;
    }
}

template <typename OffsetT, typename WeightT,int Width=32>
__global__ void sclp_singleton_affinity_kernel(
    std::int64_t n, const OffsetT* offsets, const std::int32_t* neighbors,
    const WeightT* weights, std::uint32_t role_salt, std::uint32_t mover_threshold,
    std::uint32_t tie_salt, bool filter_roles, bool filter_sources,
    unsigned long long* current_affinity, unsigned long long* best_affinity,
    unsigned long long* best_ties, unsigned long long* unrestricted_best_affinity,
    const std::int32_t* vertices=nullptr, bool split_heavy=false, SclpResidualPolicy policy = {}) {
    const int lane=threadIdx.x&(Width-1);
    const auto index=static_cast<std::int64_t>(blockIdx.x)*(256/Width)+threadIdx.x/Width;
    if (index>=n) return;
    const auto v=vertices ? static_cast<std::int64_t>(vertices[index]) : index;
    if (split_heavy && offsets[v+1]-offsets[v]>=4096) return;
    if (filter_sources && !sclp_cluster_is_mover(static_cast<std::int32_t>(v),role_salt,mover_threshold,policy.roles)) return;
    unsigned long long best = 0, tie = 0, unrestricted = 0, second = 0;
    for (std::int64_t e = static_cast<std::int64_t>(offsets[v])+lane; e < offsets[v+1]; e += Width) {
        const auto target = neighbors[e];
        if (target == v) continue;
        const auto weight = static_cast<unsigned long long>(detail::edge_weight(weights,e));
        unrestricted = max(unrestricted,weight);
        if (filter_roles && (sclp_cluster_is_mover(target,role_salt,mover_threshold,policy.roles) ||
            !policy.admissible(static_cast<std::int32_t>(v),target))) continue;
        const auto hash = mix32(static_cast<std::uint32_t>(v) ^ mix32(static_cast<std::uint32_t>(target)) ^ tie_salt);
        const auto key = (static_cast<unsigned long long>(hash)<<32) |
            (0xffffffffU-static_cast<std::uint32_t>(target));
        if (policy.second) sclp_update_two(weight,key,best,tie,second);
        else sclp_update_best(weight,key,best,tie);
    }
    if constexpr (Width==8) {
        const unsigned mask=0xffU<<(threadIdx.x&24);
        sclp_finish_subwarp_affinity(static_cast<std::int32_t>(v),mask,lane,0,unrestricted,best,tie,
            current_affinity,best_affinity,best_ties,unrestricted_best_affinity,second,policy.second);
    } else sclp_finish_warp_affinity(static_cast<std::int32_t>(v),0,unrestricted,best,tie,
        current_affinity,best_affinity,best_ties,unrestricted_best_affinity,second,policy.second);
}

template <typename OffsetT>
struct SclpHeavySingletonRow {
    const OffsetT* offsets;
    __host__ __device__ bool operator()(std::int32_t v) const { return offsets[v+1]-offsets[v]>=4096; }
};

template <typename OffsetT, typename WeightT>
__global__ void sclp_singleton_heavy_affinity_kernel(
    const std::int32_t* vertices, const OffsetT* offsets, const std::int32_t* neighbors,
    const WeightT* weights, std::uint32_t role_salt, std::uint32_t mover_threshold,
    std::uint32_t tie_salt, bool filter_roles, bool filter_sources,
    unsigned long long* current_affinity, unsigned long long* best_affinity,
    unsigned long long* best_ties, unsigned long long* unrestricted_best_affinity, SclpResidualPolicy policy = {}) {
    const auto v=vertices[blockIdx.x];
    if (filter_sources && !sclp_cluster_is_mover(v,role_salt,mover_threshold,policy.roles)) return;
    unsigned long long best=0,tie=0,unrestricted=0,second=0;
    for(auto e=static_cast<std::int64_t>(offsets[v])+threadIdx.x;e<offsets[v+1];e+=256) {
        const auto target=neighbors[e];
        if(target==v) continue;
        const auto weight=static_cast<unsigned long long>(detail::edge_weight(weights,e));
        unrestricted=max(unrestricted,weight);
        if(filter_roles && (sclp_cluster_is_mover(target,role_salt,mover_threshold,policy.roles) ||
            !policy.admissible(v,target))) continue;
        const auto hash=mix32(v^mix32(static_cast<std::uint32_t>(target))^tie_salt);
        const auto key=(static_cast<unsigned long long>(hash)<<32)|(0xffffffffU-static_cast<std::uint32_t>(target));
        if (policy.second) sclp_update_two(weight,key,best,tie,second);
        else sclp_update_best(weight,key,best,tie);
    }
    for(int delta=16;delta;delta>>=1) {
        const auto other=__shfl_down_sync(0xffffffffU,best,delta);
        const auto other_tie=__shfl_down_sync(0xffffffffU,tie,delta);
        unrestricted=max(unrestricted,__shfl_down_sync(0xffffffffU,unrestricted,delta));
        if (policy.second) {
            const auto other_second=__shfl_down_sync(0xffffffffU,second,delta);
            sclp_update_two(other,other_tie,best,tie,second);
            second=max(second,other_second);
        } else sclp_update_best(other,other_tie,best,tie);
    }
    __shared__ unsigned long long values[8],ties[8],maxima[8],seconds[8];
    const int lane=threadIdx.x&31,warp=threadIdx.x/32;
    if(!lane) {values[warp]=best;ties[warp]=tie;maxima[warp]=unrestricted;seconds[warp]=second;}
    __syncthreads();
    if(!warp) {
        best=lane<8 ? values[lane] : 0;
        tie=lane<8 ? ties[lane] : 0;
        unrestricted=lane<8 ? maxima[lane] : 0;
        second=lane<8 ? seconds[lane] : 0;
        sclp_finish_warp_affinity(v,0,unrestricted,best,tie,
            current_affinity,best_affinity,best_ties,unrestricted_best_affinity,second,policy.second);
    }
}

template <typename OffsetT, typename WeightT>
__global__ void sclp_affinity_low_match_kernel(
    std::int64_t count, const std::int32_t* vertices,
    const OffsetT* offsets, const std::int32_t* neighbors,
    const WeightT* edge_weights, const std::int32_t* clusters,
    std::uint32_t role_salt, std::uint32_t mover_threshold,
    std::uint32_t tie_salt, bool filter_roles, bool filter_sources,
    unsigned long long* current_affinity,
    unsigned long long* best_affinity, unsigned long long* best_ties,
    unsigned long long* unrestricted_best_affinity, SclpResidualPolicy policy = {}) {
    constexpr int SUBWARP_SIZE = 8;
    const int lane = threadIdx.x & (WARP_SIZE - 1);
    const int lane_in_subwarp = lane & (SUBWARP_SIZE - 1);
    const int subwarp_in_warp = lane / SUBWARP_SIZE;
    const auto warp = static_cast<std::int64_t>(blockIdx.x) *
                      WARPS_PER_BLOCK + threadIdx.x / WARP_SIZE;
    const auto vertex_index = warp * (WARP_SIZE / SUBWARP_SIZE) +
                              subwarp_in_warp;
    if (vertex_index >= count) return;
    const auto v = vertices ? vertices[vertex_index] : static_cast<std::int32_t>(vertex_index);
    if (filter_sources && !sclp_cluster_is_mover(clusters[v],role_salt,mover_threshold,policy.roles)) return;
    const auto begin = offsets[v];
    const auto degree = offsets[v + 1] - begin;
    const int subwarp_begin = subwarp_in_warp * SUBWARP_SIZE;
    const unsigned subwarp_mask =
        ((1U << SUBWARP_SIZE) - 1U) << subwarp_begin;
    const bool valid = lane_in_subwarp < degree &&
                       neighbors[begin + lane_in_subwarp] != v;
    const unsigned active = __ballot_sync(subwarp_mask, valid);
    std::int32_t target = SCLP_INVALID;
    unsigned long long connection = 0;
    bool leader = false;
    if (valid) {
        target = clusters[neighbors[begin + lane_in_subwarp]];
        const unsigned peers = __match_any_sync(active, target);
        leader = lane == (__ffs(peers) - 1);
        const auto my_weight =
            static_cast<unsigned long long>(
                detail::edge_weight(edge_weights,begin + lane_in_subwarp));
        for (int source_lane = subwarp_begin;
             source_lane < subwarp_begin + SUBWARP_SIZE; ++source_lane) {
            const auto peer_weight =
                __shfl_sync(active, my_weight, source_lane);
            if (leader && (peers & (1U << source_lane))) {
                connection += peer_weight;
            }
        }
    }
    unsigned long long local_current = 0;
    unsigned long long local_unrestricted = 0;
    unsigned long long best_value = 0;
    unsigned long long best_tie = 0;
    unsigned long long second = 0;
    const auto source = clusters[v];
    if (leader && target == source) local_current = connection;
    if (leader && target != source) {
        local_unrestricted = connection;
        if (!filter_roles || (!sclp_cluster_is_mover(
                target, role_salt, mover_threshold,policy.roles) && policy.admissible(source,target))) {
            const auto hash = mix32(
                static_cast<std::uint32_t>(v) ^
                mix32(static_cast<std::uint32_t>(target)) ^ tie_salt);
            best_value = connection;
            best_tie = (static_cast<unsigned long long>(hash) << 32) |
                       (0xffffffffULL - static_cast<std::uint32_t>(target));
        }
    }
    sclp_finish_subwarp_affinity(
        v, subwarp_mask, lane_in_subwarp,
        local_current, local_unrestricted,
        best_value, best_tie,
        current_affinity, best_affinity, best_ties,
        unrestricted_best_affinity, second, policy.second);
}

template <typename OffsetT, typename WeightT>
__global__ void sclp_affinity_medium_hash_kernel(
    std::int64_t count, const std::int32_t* vertices,
    const OffsetT* offsets, const std::int32_t* neighbors,
    const WeightT* edge_weights, const std::int32_t* clusters,
    std::uint32_t role_salt, std::uint32_t mover_threshold,
    std::uint32_t tie_salt, bool filter_roles, bool filter_sources,
    unsigned long long* current_affinity,
    unsigned long long* best_affinity, unsigned long long* best_ties,
    unsigned long long* unrestricted_best_affinity, SclpResidualPolicy policy = {}) {
    extern __shared__ unsigned char storage[];
    auto* all_keys = reinterpret_cast<std::int32_t*>(storage);
    auto* all_values = reinterpret_cast<unsigned long long*>(
        all_keys + SCLP_AFFINITY_WARPS_PER_BLOCK * SCLP_MEDIUM_HASH_SIZE);
    const int warp_in_block = threadIdx.x / WARP_SIZE;
    const int lane = threadIdx.x & (WARP_SIZE - 1);
    const auto warp = static_cast<std::int64_t>(blockIdx.x) *
                      SCLP_AFFINITY_WARPS_PER_BLOCK + warp_in_block;
    if (warp >= count) return;
    const auto v = vertices[warp];
    if (filter_sources && !sclp_cluster_is_mover(clusters[v],role_salt,mover_threshold,policy.roles)) return;
    auto* keys = all_keys + warp_in_block * SCLP_MEDIUM_HASH_SIZE;
    auto* values = all_values + warp_in_block * SCLP_MEDIUM_HASH_SIZE;
    // At most degree distinct neighbor clusters: a half-full power-of-two
    // table is sufficient. Keep the original shared-memory reservation.
    const auto degree = static_cast<unsigned int>(offsets[v+1]-offsets[v]);
    int hash_size = 32;
    while (hash_size < 2*degree) hash_size <<= 1;
    for (int slot = lane; slot < hash_size; slot += WARP_SIZE) {
        keys[slot] = -1;
        values[slot] = 0;
    }
    __syncwarp();
    for (auto e = offsets[v] + lane; e < offsets[v + 1]; e += WARP_SIZE) {
        if (neighbors[e] == v) continue;
        const auto target = clusters[neighbors[e]];
        int slot = static_cast<int>(mix32(static_cast<std::uint32_t>(target))) &
                   (hash_size - 1);
        while (true) {
            const auto found = atomicCAS(keys + slot, -1, target);
            if (found == -1 || found == target) {
                atomicAdd(values + slot,
                          static_cast<unsigned long long>(detail::edge_weight(edge_weights,e)));
                break;
            }
            slot = (slot + 1) & (hash_size - 1);
        }
    }
    __syncwarp();
    unsigned long long local_current = 0;
    unsigned long long local_unrestricted = 0;
    unsigned long long best_value = 0;
    unsigned long long best_tie = 0;
    unsigned long long second = 0;
    const auto source = clusters[v];
    for (int slot = lane; slot < hash_size; slot += WARP_SIZE) {
        const auto target = keys[slot];
        if (target < 0) continue;
        const auto connection = values[slot];
        if (target == source) {
            local_current = connection;
            continue;
        }
        local_unrestricted = max(local_unrestricted, connection);
        if (filter_roles && (sclp_cluster_is_mover(
                target, role_salt, mover_threshold,policy.roles) || !policy.admissible(source,target))) continue;
        const auto hash = mix32(
            static_cast<std::uint32_t>(v) ^
            mix32(static_cast<std::uint32_t>(target)) ^ tie_salt);
        const auto tie = (static_cast<unsigned long long>(hash) << 32) |
                         (0xffffffffULL - static_cast<std::uint32_t>(target));
        if (policy.second) sclp_update_two(connection, tie, best_value, best_tie, second);
        else sclp_update_best(connection, tie, best_value, best_tie);
    }
    sclp_finish_warp_affinity(
        v, local_current, local_unrestricted,
        best_value, best_tie,
        current_affinity, best_affinity, best_ties,
        unrestricted_best_affinity, second, policy.second);
}

template <typename OffsetT>
__global__ void sclp_high_edge_counts_kernel(
    std::int64_t count, const std::int32_t* vertices,
    const OffsetT* offsets, const std::int32_t* clusters,
    std::uint32_t role_salt, std::uint32_t mover_threshold, bool filter_sources, std::int64_t* counts, SclpResidualPolicy policy = {}) {
    const auto i = static_cast<std::int64_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (i < count) {
        const auto v = vertices[i];
        counts[i] = !filter_sources || sclp_cluster_is_mover(clusters[v],role_salt,mover_threshold,policy.roles)
            ? offsets[v + 1] - offsets[v] : 0;
    }
}

template <typename OffsetT, typename WeightT, typename ValueT>
__global__ void sclp_fill_affinity_high_kernel(
    std::int64_t count, const std::int32_t* vertices,
    const std::int64_t* compact_offsets,
    const OffsetT* offsets, const std::int32_t* neighbors,
    const WeightT* edge_weights, const std::int32_t* clusters,
    std::uint32_t role_salt, std::uint32_t mover_threshold, bool filter_sources,
    std::uint64_t* keys, ValueT* values, SclpRecordLayout layout, SclpResidualPolicy policy = {}) {
    const auto i = static_cast<std::int64_t>(blockIdx.x);
    if (i >= count) return;
    const auto v = vertices[i];
    if (filter_sources && !sclp_cluster_is_mover(clusters[v],role_salt,mover_threshold,policy.roles)) return;
    const auto begin = offsets[v];
    const auto compact_begin = compact_offsets[i];
    for (auto e = begin + threadIdx.x; e < offsets[v + 1]; e += blockDim.x) {
        const auto output = compact_begin + (e - begin);
        if (neighbors[e] == v) {
            keys[output] = INVALID_KEY;
            if (!layout.packed()) values[output] = 0;
            continue;
        }
        keys[output] = layout.encode(v, clusters[neighbors[e]], detail::edge_weight(edge_weights,e));
        if (!layout.packed()) values[output] = detail::edge_weight(edge_weights,e);
    }
}

template <typename ValueT>
__global__ void sclp_affinity_baseline_kernel(
    std::int64_t count, const std::uint64_t* keys,
    const ValueT* connections, const std::int32_t* clusters,
    std::uint32_t role_salt, std::uint32_t mover_threshold,
    bool filter_roles, unsigned long long* current_affinity,
    unsigned long long* best_affinity,
    unsigned long long* unrestricted_best_affinity, SclpRecordLayout layout, SclpResidualPolicy policy = {}) {
    const auto i = static_cast<std::int64_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (i >= count) return;
    const auto v = layout.source(keys[i]);
    const auto target = static_cast<std::int32_t>(layout.target(keys[i]));
    const auto connection = layout.packed() ? keys[i] & layout.weight_mask : connections[i];
    const auto source = clusters[v];
    if (target == source) {
        current_affinity[v] = static_cast<unsigned long long>(connection);
        return;
    }
    atomicMax(unrestricted_best_affinity + v,
              static_cast<unsigned long long>(connection));
    if (filter_roles && (sclp_cluster_is_mover(
            target, role_salt, mover_threshold,policy.roles) || !policy.admissible(source,target))) return;
    const auto value = static_cast<unsigned long long>(connection);
    const auto previous = atomicMax(best_affinity + v, value);
    if (policy.second) atomicMax(policy.second + v, min(previous, value));
}

template <typename ValueT>
__global__ void sclp_best_tie_kernel(
    std::int64_t count, const std::uint64_t* keys,
    const ValueT* connections, const std::int32_t* clusters,
    const unsigned long long* best_affinity, std::uint32_t tie_salt,
    std::uint32_t role_salt, std::uint32_t mover_threshold,
    bool filter_roles, unsigned long long* best_ties, SclpRecordLayout layout, SclpResidualPolicy policy = {}) {
    const auto i = static_cast<std::int64_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (i >= count) return;
    const auto v = layout.source(keys[i]);
    const auto target = static_cast<std::int32_t>(layout.target(keys[i]));
    const auto source = clusters[v];
    if (target == source) return;
    const auto hash = mix32(v ^ mix32(static_cast<std::uint32_t>(target)) ^ tie_salt);
    const auto key = (static_cast<unsigned long long>(hash) << 32) |
                     (0xffffffffULL - static_cast<std::uint32_t>(target));
    const auto connection = layout.packed() ? keys[i] & layout.weight_mask : connections[i];
    if (connection != best_affinity[v] ||
        (filter_roles && (sclp_cluster_is_mover(
             target, role_salt, mover_threshold,policy.roles) || !policy.admissible(source,target)))) return;
    atomicMax(best_ties + v, key);
}

__global__ void sclp_decode_gain_kernel(
    std::int64_t n, const std::int32_t* clusters,
    const unsigned long long* current_affinity,
    const unsigned long long* best_affinity,
    const unsigned long long* best_ties,
    const unsigned long long* unrestricted_best_affinity,
    std::uint32_t role_salt, std::uint32_t mover_threshold,
    bool filter_roles, std::int32_t* proposals,
    unsigned long long* gains, std::uint32_t* proposal_ties,
    unsigned long long* role_diagnostics, SclpResidualPolicy policy = {}) {
    const auto v = static_cast<std::int64_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (v >= n) return;
    proposals[v] = SCLP_INVALID;
    gains[v] = 0;
    proposal_ties[v] = 0;
    const auto source = clusters[v];
    // Residual two-hop also skips established clusters. Their scratch can be
    // untouched even though receiver role filtering is disabled for favorites.
    if (policy.roles && !policy.roles[source]) return;
    const bool source_can_move = !filter_roles || sclp_cluster_is_mover(source,role_salt,mover_threshold,policy.roles);
    // Production skips affinity work for these source rows. Their proposal
    // is already invalid; do not read their deliberately untouched scratch.
    if (role_diagnostics == nullptr && !source_can_move) return;
    const auto unrestricted_gain = unrestricted_best_affinity[v] > current_affinity[v]
        ? unrestricted_best_affinity[v] - current_affinity[v] : 0ULL;
    if (role_diagnostics != nullptr && unrestricted_gain > 0) {
        atomicAdd(role_diagnostics, 1ULL);
    }
    const auto role_gain = source_can_move && best_affinity[v] > current_affinity[v]
        ? best_affinity[v] - current_affinity[v] : 0ULL;
    if (role_diagnostics != nullptr && unrestricted_gain > role_gain) {
        atomicAdd(role_diagnostics + 1, 1ULL);
        atomicAdd(role_diagnostics + 2, unrestricted_gain - role_gain);
    }
    if (role_gain == 0) return;
    const auto target = static_cast<std::int32_t>(
        0xffffffffULL - (best_ties[v] & 0xffffffffULL));
    if (target < 0 || target == source) return;
    proposals[v] = target;
    gains[v] = best_affinity[v] - current_affinity[v];
    // Affinity kernels have completed; this vertex owns its scratch slot.
    // Invalid proposals are compacted out before priority reads.
    if (policy.second) policy.second[v] = best_affinity[v] - policy.second[v];
    proposal_ties[v] = static_cast<std::uint32_t>(best_ties[v] >> 32);
}

using detail::SclpAdmissionKey;

template <typename GainT>
struct SclpAdmissionKeyDecomposer {
    __host__ __device__ auto operator()(SclpAdmissionKey<GainT>& key) const {
        return cuda::std::tie(
            key.target, key.reverse_gain, key.reverse_tie);
    }
};


template <typename GainT>
struct SclpAdmissionRecord {
    const std::int32_t* targets;
    const unsigned long long* gains;
    const std::uint32_t* ties;
    int gain_bits;
    __host__ __device__ SclpAdmissionKey<GainT> operator()(std::int32_t v) const {
        return SclpAdmissionKey<GainT>::encode(static_cast<std::uint32_t>(targets[v]),
            static_cast<GainT>(gains[v]), ties[v], static_cast<std::uint32_t>(v), gain_bits);
    }
};

struct SclpValidProposal {
    __host__ __device__ bool operator()(std::int32_t target) const { return target != SCLP_INVALID; }
};

template <typename GainT>
__global__ void sclp_selected_admission_keys(std::int64_t count, const std::int32_t* vertices,
    SclpAdmissionRecord<GainT> record, SclpAdmissionKey<GainT>* keys) {
    const auto i = static_cast<std::int64_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (i < count) keys[i] = record(vertices[i]);
}

template <typename WeightT,typename GainT>
__global__ void sclp_decode_admission_keys_kernel(
    std::int64_t count, const SclpAdmissionKey<GainT>* keys,
    const WeightT* vertex_weights, std::int32_t* order,
    std::int32_t* targets, std::uint64_t* weights, int gain_bits) {
    const auto i = static_cast<std::int64_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (i >= count) return;
    const auto v = static_cast<std::int32_t>(keys[i].vertex);
    order[i] = v;
    targets[i] = static_cast<std::int32_t>(keys[i].decode_target(gain_bits));
    weights[i] = vertex_weights[v];
}

struct SclpNonzeroWeight {
    __host__ __device__ bool operator()(unsigned long long value) const {
        return value != 0;
    }
};

__global__ void sclp_clear_high_affinity(std::int64_t count, const std::int32_t* rows,
    unsigned long long* current, unsigned long long* best,
    unsigned long long* ties, unsigned long long* unrestricted,
    unsigned long long* second = nullptr) {
    const auto i = static_cast<std::int64_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (i < count) {
        const auto v = rows[i];
        current[v] = best[v] = ties[v] = unrestricted[v] = 0;
        if (second) second[v] = 0;
    }
}

__global__ void sclp_commit_kernel(
    std::int64_t count, const std::int32_t* order,
    const std::int32_t* targets, const std::uint64_t* weights,
    const std::uint64_t* prefix_weights,
    const unsigned long long* base_cluster_weights, std::uint64_t capacity,
    const unsigned long long* gains,
    std::int32_t* clusters, unsigned long long* cluster_weights,
    unsigned long long* accepted, unsigned long long* rejected,
    unsigned long long* predicted_gain) {
    const auto i = static_cast<std::int64_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (i >= count) return;
    const auto target = targets[i];
    const auto base = static_cast<std::uint64_t>(base_cluster_weights[i]);
    const auto prefix = prefix_weights[i];
    const auto v = order[i];
    const auto source = clusters[v];
    const auto weight = static_cast<unsigned long long>(weights[i]);
    if (base <= capacity && prefix <= capacity - base) {
        atomicAdd(cluster_weights + source, 0ULL - weight);
        atomicAdd(cluster_weights + target, weight);
        clusters[v] = target;
        if (accepted != nullptr) {
            atomicAdd(accepted, 1ULL);
            atomicAdd(predicted_gain, gains[v]);
        }
    } else {
        if (rejected != nullptr) atomicAdd(rejected, 1ULL);
    }
}

template <typename WeightT>
__global__ void sclp_singleton_favorite_kernel(
    std::int64_t n, const WeightT* vertex_weights,
    const unsigned long long* cluster_weights, const std::int32_t* clusters,
    const std::int32_t* proposals, std::int32_t* favorites) {
    const auto v = static_cast<std::int64_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (v >= n) return;
    const auto source = clusters[v];
    favorites[v] = cluster_weights[source] == vertex_weights[v]
        ? proposals[v] : SCLP_INVALID;
}

__global__ void sclp_pair_flags_kernel(
    std::int64_t count, const std::int32_t* order,
    const std::uint64_t* ordered_weights,
    const std::uint64_t* ranks, std::uint64_t capacity,
    std::int32_t* pair_flags) {
    const auto i = static_cast<std::int64_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (i >= count) return;
    const bool second = (ranks[i] & 1ULL) == 0ULL;
    pair_flags[i] = second && i > 0 &&
        ordered_weights[i - 1] <= capacity - ordered_weights[i] ? 1 : 0;
}

__global__ void sclp_two_hop_pair_commit_kernel(
    std::int64_t count, const std::int32_t* order,
    const std::int32_t* pair_flags, const std::int32_t* pair_positions,
    std::uint64_t merge_budget, const std::uint64_t* weights,
    std::int32_t* clusters,
    unsigned long long* cluster_weights, unsigned long long* merged) {
    const auto i = static_cast<std::int64_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (i >= count || !pair_flags[i] ||
        static_cast<std::uint64_t>(pair_positions[i]) >= merge_budget) return;
    const auto v = order[i];
    const auto source = clusters[v];
    const auto target = clusters[order[i - 1]];
    if (source == target) return;
    const auto weight = static_cast<unsigned long long>(weights[i]);
    atomicAdd(cluster_weights + source, 0ULL - weight);
    atomicAdd(cluster_weights + target, weight);
    clusters[v] = target;
    if (merged != nullptr) atomicAdd(merged, 1ULL);
}

__global__ void sclp_nonempty_cluster_kernel(
    std::int64_t n, const unsigned long long* cluster_weights,
    std::int32_t* flags) {
    const auto c = static_cast<std::int64_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (c < n) flags[c] = cluster_weights[c] > 0 ? 1 : 0;
}

template <typename OffsetT>
struct ZeroDegreeVertex {
    const OffsetT* offsets;
    __host__ __device__ bool operator()(std::int32_t v) const {
        return offsets[v] == offsets[v+1];
    }
};

template <typename WeightT>
__global__ void isolated_representative_kernel(
    std::int64_t count, const std::int32_t* vertices,
    const std::uint64_t* prefix, const WeightT* weights,
    std::uint64_t capacity, std::int32_t* representatives) {
    const auto i = static_cast<std::int64_t>(blockIdx.x)*blockDim.x+threadIdx.x;
    if (i >= count) return;
    const auto v = vertices[i];
    const auto first_bin = (prefix[i]-weights[v])/capacity;
    const auto last_bin = (prefix[i]-1)/capacity;
    // A vertex crossing a bin boundary stays separate. Fully contained
    // vertices in each bin have combined weight <= capacity.
    if (first_bin == last_bin) atomicMin(representatives+first_bin, v);
}

template <typename WeightT>
__global__ void isolated_commit_kernel(
    std::int64_t count, const std::int32_t* vertices,
    const std::uint64_t* prefix, const WeightT* weights,
    std::uint64_t capacity, const std::int32_t* representatives,
    std::int32_t* clusters, unsigned long long* cluster_weights) {
    const auto i = static_cast<std::int64_t>(blockIdx.x)*blockDim.x+threadIdx.x;
    if (i >= count) return;
    const auto v = vertices[i];
    const auto first_bin = (prefix[i]-weights[v])/capacity;
    const auto last_bin = (prefix[i]-1)/capacity;
    if (first_bin != last_bin) return;
    const auto target = representatives[first_bin];
    if (target == v) return;
    clusters[v] = target;
    cluster_weights[v] = 0;
    atomicAdd(cluster_weights+target, static_cast<unsigned long long>(weights[v]));
}

__global__ void sclp_compact_map_kernel(
    std::int64_t n, const std::int32_t* clusters,
    const std::int32_t* compact_ids, std::int32_t* map) {
    const auto v = static_cast<std::int64_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (v < n) map[v] = compact_ids[clusters[v]];
}
