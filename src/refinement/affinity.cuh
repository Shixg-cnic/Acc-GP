#pragma once
// Exact dense, sparse and on-demand partition affinity views.
// Included inside namespace gpart before the refinement workspace.

// Dense rows are useful when k is small. Sparse rows reserve at most one
// slot per CSR entry and store only nonzero part affinities. All rows affected
// by a migration are rebuilt after committing the batch, on the same stream.
// No reader observes a partially rebuilt row or a stale neighbor label.
template <typename T>
struct AffinityView {
    T* values=nullptr;
    std::uint8_t* keys=nullptr;
    std::uint8_t* counts=nullptr;
    std::int32_t* dirty=nullptr;
    std::int32_t* dirty_rows=nullptr;
    unsigned long long* dirty_count=nullptr;
    const std::int32_t* offsets=nullptr;
    int k=0;
    std::int32_t* frontier_rows=nullptr;
    std::int32_t* frontier_members=nullptr;
    unsigned long long* frontier_count=nullptr;
    const std::int32_t* direct_labels=nullptr;
    const std::int32_t* direct_neighbors=nullptr;
    const std::uint32_t* direct_weights=nullptr;
    const T* row_totals=nullptr; // Immutable incident weight, excluding self loops.
    bool repair_enumeration=false;
    const unsigned long long* repair_slack_cdf=nullptr; // k inclusive sums + minimum positive slack.
    __host__ __device__ bool direct() const { return direct_labels!=nullptr; }
    __device__ T direct_weight(std::int64_t e) const {
        if (!direct_weights) return T{1};
        return static_cast<T>(direct_weights[e]);
    }
    __device__ void touch(std::int32_t v) const {
        if (!frontier_count) return;
        cuda::atomic_ref<std::int32_t,cuda::thread_scope_device> member(frontier_members[v]);
        if (!member.load(cuda::memory_order_relaxed) && !member.exchange(1,cuda::memory_order_relaxed)) {
            const auto slot=atomicAdd(frontier_count,1ULL);
            frontier_rows[slot]=v;
        }
    }
    __host__ __device__ bool sparse() const { return keys!=nullptr; }
    __device__ std::int64_t begin(std::int64_t v) const {
        return offsets[v];
    }
    __device__ T get(std::int64_t v,int p) const {
        if (direct()) {
            T sum=0;
            for (auto e=begin(v);e<begin(v+1);++e)
                if (direct_neighbors[e]!=v && direct_labels[direct_neighbors[e]]==p) sum+=direct_weight(e);
            return sum;
        }
        if (!sparse()) return values[v*k+p];
        const auto start=begin(v);
        for (int i=0;i<counts[v];++i) if (keys[start+i]==p) return values[start+i];
        return 0;
    }
    __device__ int entries(std::int64_t v) const {
        if (direct()) { const auto degree=begin(v+1)-begin(v);return degree<=16 ? static_cast<int>(degree) : k; }
        return sparse() ? counts[v] : k;
    }
    __device__ int part(std::int64_t v,int i) const {
        if (direct()) return begin(v+1)-begin(v)<=16 ? direct_labels[direct_neighbors[begin(v)+i]] : i;
        return sparse() ? keys[begin(v)+i] : i;
    }
    __device__ T value(std::int64_t v,int i) const { return direct() ? get(v,part(v,i)) : values[sparse() ? begin(v)+i : v*k+i]; }
};

