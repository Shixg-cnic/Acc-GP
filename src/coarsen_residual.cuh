#pragma once
// Included inside the coarsening anonymous namespace. Frozen per-round roles
// separate singleton donors from stable receivers; committed clusters never split.
struct SclpResidualPolicy {
    const std::uint8_t* roles = nullptr;
    const unsigned long long* weights = nullptr;
    std::uint64_t capacity = 0;
    // Exact runner-up, reused in-place as regret after proposal decoding.
    // Null only during two-hop favorite selection, which needs no regret order.
    unsigned long long* second = nullptr;

    __device__ __forceinline__ bool admissible(std::int32_t source,
                                              std::int32_t target) const {
        const auto base = weights[target];
        return base != 0 && base <= capacity && weights[source] <= capacity - base;
    }
};

template <typename WeightT>
__global__ void residual_seed_weights(std::int64_t n, const std::int32_t* clusters,
    const WeightT* vertex_weights, unsigned long long* cluster_weights) {
    const auto v = static_cast<std::int64_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (v < n) atomicAdd(cluster_weights + clusters[v],
                        static_cast<unsigned long long>(vertex_weights[v]));
}

template <typename WeightT>
__global__ void residual_freeze_roles(std::int64_t n, const std::int32_t* clusters,
    const WeightT* vertex_weights, const unsigned long long* cluster_weights,
    std::uint32_t salt, std::uint32_t threshold, bool all_singletons,
    std::uint8_t* roles) {
    const auto v = static_cast<std::int64_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (v >= n) return;
    // Positive vertex weights make this equality an exact singleton test.
    // Roots of established clusters are always receivers. Empty roots are
    // never targets, and all their former members refer to the new root.
    roles[v] = clusters[v] == v && cluster_weights[v] ==
        static_cast<unsigned long long>(vertex_weights[v]) &&
        (all_singletons || mix32(static_cast<std::uint32_t>(v) ^ salt) < threshold);
}

// Only used after the host proves every possible incoming request fits.
// Frozen donor/receiver roles ensure no receiver is also removed this round.
template <typename WeightT>
__global__ void residual_commit_all(std::int64_t n, const std::int32_t* proposals,
    const WeightT* vertex_weights, const unsigned long long* gains,
    std::int32_t* clusters, unsigned long long* cluster_weights,
    unsigned long long* counters) {
    const auto v = static_cast<std::int64_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (v >= n || proposals[v] == SCLP_INVALID) return;
    const auto target = proposals[v];
    const auto weight = static_cast<unsigned long long>(vertex_weights[v]);
    clusters[v] = target;
    cluster_weights[v] = 0;
    atomicAdd(cluster_weights + target, weight);
    if (counters) {
        atomicAdd(counters, 1ULL);
        atomicAdd(counters + 2, gains[v]);
    }
}
