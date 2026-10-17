#pragma once
// Included inside namespace gpart after RefineDeviceContext and gain validation.
// Jet supplies the exploration / priority-correction reference. This CUDA
// implementation uses a dense affinity cache for small k, fused exact cut/cache
// updates, and source-quota plus destination-capacity GPU rebalancing.
namespace {
constexpr std::int64_t kRefineHeavyDegree=4096;
constexpr int kRefineHeavyBlocks=32;

// Most sparse rows have only a handful of entries. Give each such row a
// thread and accumulate a sorted register list, avoiding k histogram zeros
// and a full warp for a degree-two/four row. Arbitrary/long rows retain the
// shared-memory warp builder below. Both paths write exactly the same rows.
template <typename OffsetT,typename VertexT,typename WeightT,typename CacheT>
__global__ void incremental_build_short_sparse(
    std::int64_t n,const OffsetT* offsets,const VertexT* neighbors,
    const WeightT* weights,const VertexT* labels,AffinityView<CacheT> cache,
    CacheT* row_totals,bool dirty_only) {
    const auto limit=dirty_only ? static_cast<std::int64_t>(*cache.dirty_count) : n;
    for (auto i=static_cast<std::int64_t>(blockIdx.x)*blockDim.x+threadIdx.x;
         i<limit;i+=static_cast<std::int64_t>(gridDim.x)*blockDim.x) {
        const auto v=dirty_only ? static_cast<std::int64_t>(cache.dirty_rows[i]) : i;
        const auto begin=static_cast<std::int64_t>(offsets[v]),end=static_cast<std::int64_t>(offsets[v+1]);
        if (end-begin>16) continue;
        int keys[16],count=0;
        CacheT values[16],total=0;
        for (auto e=begin;e<end;++e) {
            if (neighbors[e]==v) continue;
            const auto p=labels[neighbors[e]];
            const auto weight=static_cast<CacheT>(detail::edge_weight(weights,e));
            total+=weight;
            int pos=0;
            while (pos<count && keys[pos]<p) ++pos;
            if (pos<count && keys[pos]==p) values[pos]+=weight;
            else if (weight) {
                for (int j=count;j>pos;--j) { keys[j]=keys[j-1];values[j]=values[j-1]; }
                keys[pos]=p;values[pos]=weight;++count;
            }
        }
        for (int j=0;j<count;++j) { cache.keys[begin+j]=keys[j];cache.values[begin+j]=values[j]; }
        cache.counts[v]=count;cache.dirty[v]=0;
        if (row_totals) row_totals[v]=total;
    }
}

template <typename OffsetT,typename V,typename W,typename C>
__global__ void build_direct_totals(std::int64_t n,const OffsetT* offsets,
    const V* neighbors,const W* weights,C* totals,V* heavy_rows,unsigned int* heavy_count) {
    const auto v=static_cast<std::int64_t>(blockIdx.x)*blockDim.x+threadIdx.x;
    if (v>=n) return;
    if (heavy_rows && offsets[v+1]-offsets[v]>=kRefineHeavyDegree)
        heavy_rows[atomicAdd(heavy_count,1U)]=static_cast<V>(v);
    if (totals) {
        C sum=0;
        for(auto e=offsets[v];e<offsets[v+1];++e) if(neighbors[e]!=v) sum+=static_cast<C>(detail::edge_weight(weights,e));
        totals[v]=sum;
    }
}

template <typename OffsetT, typename VertexT, typename WeightT,typename CacheT,bool Verify=false>
__global__ void incremental_build_affinity(
    std::int64_t n, const OffsetT* offsets, const VertexT* neighbors,
    const WeightT* weights, const VertexT* labels, int k, AffinityView<CacheT> cache,
    VertexT* heavy_rows=nullptr,unsigned int* heavy_count=nullptr,
    CacheT* row_totals=nullptr,bool dirty_only=false,unsigned int* mismatch=nullptr) {
    const int lane=threadIdx.x&31;
    const int warp=threadIdx.x/32;
    const auto limit=dirty_only ? static_cast<std::int64_t>(*cache.dirty_count) : n;
    for (auto index=static_cast<std::int64_t>(blockIdx.x)*8+warp;index<limit;
         index+=static_cast<std::int64_t>(gridDim.x)*8) {
    const auto v=dirty_only ? static_cast<std::int64_t>(cache.dirty_rows[index]) : index;
    if (!lane && heavy_rows && offsets[v+1]-offsets[v]>=kRefineHeavyDegree)
        heavy_rows[atomicAdd(heavy_count,1U)]=static_cast<VertexT>(v);
    if constexpr (!Verify) if (cache.sparse() && offsets[v+1]-offsets[v]<=16) continue;
    using SumT=std::conditional_t<!Verify && sizeof(CacheT)==4,unsigned int,unsigned long long>;
    extern __shared__ unsigned long long storage[];
    auto* row=reinterpret_cast<SumT*>(storage)+warp*k;
    for (int p=lane;p<k;p+=32) row[p]=0;
    __syncwarp();
    if constexpr (!Verify && sizeof(CacheT)==4) {
        for (auto base=static_cast<std::int64_t>(offsets[v]);base<offsets[v+1];base+=32) {
            const auto e=base+lane;
            const bool valid=e<offsets[v+1] && neighbors[e]!=v;
            const auto mask=__ballot_sync(0xffffffffU,valid);
            if (valid) {
                const auto p=labels[neighbors[e]];
                const auto peers=__match_any_sync(mask,p);
                const auto sum=__reduce_add_sync(peers,static_cast<unsigned int>(detail::edge_weight(weights,e)));
                if (lane==__ffs(peers)-1) atomicAdd(row+p,sum);
            }
        }
    } else {
        // Independent Verify=true deliberately retains the 64-bit CSR path.
        for (std::int64_t e=static_cast<std::int64_t>(offsets[v])+lane;e<offsets[v+1];e+=32) {
            const auto u=neighbors[e];
            if (u!=v) atomicAdd(row+labels[u],static_cast<SumT>(detail::edge_weight(weights,e)));
        }
    }
    __syncwarp();
    if constexpr (Verify) {
        bool bad=false;
        unsigned long long total=0;
        for (int p=lane;p<k;p+=32) {
            bad|=static_cast<unsigned long long>(cache.get(v,p))!=row[p];
            total+=row[p];
        }
        for(int shift=16;shift;shift/=2) total+=__shfl_down_sync(0xffffffffU,total,shift);
        if(!lane && row_totals) bad|=static_cast<unsigned long long>(row_totals[v])!=total;
        if (__any_sync(0xffffffffU,bad) && !lane) atomicAdd(mismatch,1U);
        continue;
    }
    if (!cache.sparse()) {
        for (int p=lane;p<k;p+=32) cache.values[v*k+p]=row[p];
    } else {
        int count=0;
        const auto start=static_cast<std::int64_t>(offsets[v]);
        for (int base=0;base<k;base+=32) {
            const int p=base+lane;
            const auto value=p<k ? row[p] : SumT{0};
            const auto mask=__ballot_sync(0xffffffffU,value!=0);
            if (value) {
                const auto slot=start+count+__popc(mask&((1U<<lane)-1));
                cache.keys[slot]=p;cache.values[slot]=value;
            }
            count+=__popc(mask);
        }
        if (!lane) { cache.counts[v]=count;cache.dirty[v]=0; }
    }
    if (row_totals) {
        SumT total=0;
        for (int p=lane;p<k;p+=32) total+=row[p];
        for (int shift=16;shift;shift/=2) total+=__shfl_down_sync(0xffffffffU,total,shift);
        if (!lane) row_totals[v]=static_cast<CacheT>(total);
    }
    __syncwarp();
    }
}

template <typename OffsetT,typename VertexT,typename WeightT,typename CacheT>
void launch_affinity_build(std::int64_t n,const OffsetT* offsets,const VertexT* neighbors,
    const WeightT* weights,const VertexT* labels,int k,AffinityView<CacheT> cache,
    VertexT* heavy_rows=nullptr,unsigned int* heavy_count=nullptr,
    CacheT* totals=nullptr,bool dirty_only=false,cudaStream_t stream=nullptr) {
    if (cache.direct()) {
        build_direct_totals<<<static_cast<int>((n+255)/256),256,0,stream>>>(n,offsets,neighbors,weights,totals,heavy_rows,heavy_count);
        return;
    }
    if (cache.sparse())
        incremental_build_short_sparse<<<static_cast<int>(std::min<std::int64_t>((n+255)/256,2048)),256,0,stream>>>(n,offsets,neighbors,weights,labels,cache,totals,dirty_only);
    incremental_build_affinity<<<static_cast<int>(std::min<std::int64_t>((n+7)/8,2048)),256,8*k*sizeof(CacheT),stream>>>(n,offsets,neighbors,weights,labels,k,cache,heavy_rows,heavy_count,totals,dirty_only);
}

__device__ double estimated_repair_cost(int part,std::uint64_t weight,
    const unsigned long long* loads,std::uint64_t capacity,const double* prices) {
    const auto slack=capacity-loads[part];
    return weight>slack ? prices[part]*static_cast<double>(weight-slack) : 0.0;
}
__global__ void publish_repair_prices(int k,const RepairSample* samples,double* prices) {
    for (int p=threadIdx.x;p<k;p+=blockDim.x) if (samples[p].weight)
        prices[p]=samples[p].loss>0 ? static_cast<double>(samples[p].loss)/samples[p].weight : 0.0;
}

template <typename VertexT,typename WeightT,typename CacheT>
__device__ bool incremental_lp_proposal(
    std::int64_t v, AffinityView<CacheT> cache, const CacheT* row_totals,
    const VertexT* labels, int k,
    double filter,const WeightT* vertex_weights,const unsigned long long* loads,
    std::uint64_t capacity,const double* prices,
    std::int32_t* locks, std::int32_t* targets, std::int64_t* gains) {
    targets[v]=-1;gains[v]=INT64_MIN;
    if (locks[v]) { locks[v]=0;return false; }
    const auto source=labels[v];
    const auto current=cache.get(v,source);
    // Incident weight is invariant under label moves. Equality proves that
    // this row has no external affinity, without reading all k cache entries.
    if (current==row_totals[v]) return false;
    std::uint64_t best=0;
    int target=-1;
    double best_score=-DBL_MAX;
    for (int i=0;i<cache.entries(v);++i) {
        const int p=cache.part(v,i);
        const auto connection=cache.value(v,i);
        if (p==source || !connection) continue;
        if (prices) {
            const double score=static_cast<double>(connection)-estimated_repair_cost(p,vertex_weights[v],loads,capacity,prices);
            if (score>best_score || (score==best_score && (target<0 || p<target))) { best_score=score;best=connection;target=p; }
        } else if (connection>best || (connection==best && (target<0 || p<target))) { best=connection;target=p; }
    }
    if (target>=0 && (best>=current || current-best<static_cast<std::uint64_t>(filter*current))) {
        targets[v]=target;
        gains[v]=best>=current ? static_cast<std::int64_t>(best-current) : -static_cast<std::int64_t>(current-best);
        return true;
    }
    return false;
}

template <typename VertexT>
__device__ void append_warp(VertexT v,bool active,VertexT* queue,unsigned long long* count) {
    const int lane=threadIdx.x&31;
    const auto mask=__ballot_sync(0xffffffffU,active);
    unsigned long long begin=0;
    if (!lane && mask) begin=atomicAdd(count,static_cast<unsigned long long>(__popc(mask)));
    begin=__shfl_sync(0xffffffffU,begin,0);
    if (active) queue[begin+__popc(mask&((1U<<lane)-1U))]=v;
}

// A conservative frontier retains every vertex that was ever a boundary
// during this layer. Updates append affected rows at most once. Entries that
// become interior remain in the list and are filtered on the next proposal.
// This preserves proposals while avoiding an n-vertex scan every LP round.
template <typename V,typename C>
__global__ void initialize_affinity_frontier(std::int64_t n,AffinityView<C> cache,
    const C* totals,const V* labels,int k,int* members,V* rows,
    unsigned long long* count,int* targets,std::int64_t* gains,int* flags) {
    const auto v=static_cast<std::int64_t>(blockIdx.x)*blockDim.x+threadIdx.x;
    bool active=false;
    if(v<n) {
        active=cache.get(v,labels[v])!=totals[v];members[v]=active;
        targets[v]=-1;gains[v]=INT64_MIN;flags[v]=0;
    }
    append_warp(static_cast<V>(v),active,rows,count);
}

// Large k uses coalesced warp reads instead of a serial strided row scan.
// Integer affinity ties and priced ties retain the lowest destination ID.
template <typename VertexT,typename WeightT,typename CacheT,int Width=32>
__global__ void incremental_warp_lp_proposals(
    const VertexT* boundaries,const unsigned long long* boundary_count,AffinityView<CacheT> cache,
    const VertexT* labels,int k,double filter,const WeightT* vertex_weights,
    const unsigned long long* loads,std::uint64_t capacity,const double* prices,
    std::int32_t* targets,std::int64_t* gains,
    std::int32_t* locks=nullptr,std::int32_t* flags=nullptr,const CacheT* totals=nullptr) {
    const int lane=threadIdx.x&(Width-1);
    const unsigned mask=Width==32 ? 0xffffffffU : (0xffffffffU>>(32-Width))<<(threadIdx.x&31&~(Width-1));
    const auto count=*boundary_count;
    for (auto i=static_cast<unsigned long long>(blockIdx.x)*(256/Width)+threadIdx.x/Width;
         i<count;i+=static_cast<unsigned long long>(gridDim.x)*(256/Width)) {
        const auto v=static_cast<std::int64_t>(boundaries[i]);
        int source=0;
        unsigned long long current=0,weight=0;
        int active=1;
        if (!lane) {
            source=labels[v];current=cache.get(v,source);
            if (prices) weight=vertex_weights[v];
            if (locks) {
                targets[v]=-1;gains[v]=INT64_MIN;flags[v]=0;
                active=!locks[v] && current!=totals[v];locks[v]=0;
            }
        }
        active=__shfl_sync(mask,active,0,Width);
        if (!active) continue;
        source=__shfl_sync(mask,source,0,Width);
        current=__shfl_sync(mask,current,0,Width);
        weight=__shfl_sync(mask,weight,0,Width);
        unsigned long long best=0;
        double best_score=-DBL_MAX;
        int target=-1;
        for (int i=lane;i<cache.entries(v);i+=Width) {
            const int p=cache.part(v,i);
            const auto connection=static_cast<unsigned long long>(cache.value(v,i));
            if (p==source || !connection) continue;
            const double score=prices ? static_cast<double>(connection)-
                estimated_repair_cost(p,weight,loads,capacity,prices) : 0;
            if (target<0 || (prices ? score>best_score : connection>best) ||
                ((prices ? score==best_score : connection==best) && p<target)) {
                target=p;best=connection;best_score=score;
            }
        }
        for (int shift=Width/2;shift;shift/=2) {
            const auto other=__shfl_down_sync(mask,best,shift,Width);
            const auto other_score=__shfl_down_sync(mask,best_score,shift,Width);
            const int other_target=__shfl_down_sync(mask,target,shift,Width);
            const bool greater=prices ? other_score>best_score : other>best;
            const bool equal=prices ? other_score==best_score : other==best;
            if (lane+shift<Width && other_target>=0 &&
                (target<0 || greater || (equal && other_target<target))) {
                target=other_target;best=other;best_score=other_score;
            }
        }
        if (!lane && target>=0 &&
            (best>=current || current-best<static_cast<std::uint64_t>(filter*current))) {
            targets[v]=target;
            gains[v]=best>=current ? static_cast<std::int64_t>(best-current) : -static_cast<std::int64_t>(current-best);
        }
    }
}

template <typename V,typename W,typename C>
void launch_lp_proposals(int blocks,const V* boundaries,const unsigned long long* count,
    AffinityView<C> cache,const V* labels,int k,double filter,const W* weights,
    const unsigned long long* loads,std::uint64_t capacity,const double* prices,
    int* targets,std::int64_t* gains,int* locks=nullptr,int* flags=nullptr,
    const C* totals=nullptr,cudaStream_t stream=nullptr) {
    if (cache.sparse() || cache.direct())
        incremental_warp_lp_proposals<V,W,C,8><<<blocks,256,0,stream>>>(boundaries,count,cache,labels,k,filter,weights,loads,capacity,prices,targets,gains,locks,flags,totals);
    else
        incremental_warp_lp_proposals<V,W,C,32><<<blocks,256,0,stream>>>(boundaries,count,cache,labels,k,filter,weights,loads,capacity,prices,targets,gains,locks,flags,totals);
}

template <typename VertexT,typename CacheT>
__global__ void incremental_collect_boundaries(std::int64_t n,AffinityView<CacheT> cache,
    const CacheT* row_totals,const VertexT* labels,int k,std::int32_t* locks,
    std::int32_t* targets,std::int64_t* gains,std::int32_t* flags,
    VertexT* boundaries,unsigned long long* boundary_count) {
    const auto v=static_cast<std::int64_t>(blockIdx.x)*blockDim.x+threadIdx.x;
    bool active=false;
    if (v<n) {
        flags[v]=0;targets[v]=-1;gains[v]=INT64_MIN;
        if (locks[v]) locks[v]=0;
        else active=cache.get(v,labels[v])!=row_totals[v];
    }
    append_warp(static_cast<VertexT>(v),active,boundaries,boundary_count);
}

template <typename VertexT>
__global__ void incremental_collect_proposals(const VertexT* boundaries,
    const unsigned long long* boundary_count,const std::int32_t* targets,
    VertexT* candidates,unsigned long long* candidate_count) {
    const auto count=*boundary_count;
    for (auto base=static_cast<unsigned long long>(blockIdx.x)*blockDim.x;
         base<count;base+=static_cast<unsigned long long>(gridDim.x)*blockDim.x) {
        const auto i=base+threadIdx.x;
        const VertexT v=i<count ? boundaries[i] : VertexT{0};
        append_warp(v,i<count && targets[v]>=0,candidates,candidate_count);
    }
}

template <typename VertexT,typename WeightT,typename CacheT>
__global__ void incremental_lp_proposals(
    std::int64_t n,AffinityView<CacheT> cache,const CacheT* row_totals,
    const VertexT* labels,int k,double filter,const WeightT* vertex_weights,
    const unsigned long long* loads,std::uint64_t capacity,const double* prices,
    std::int32_t* locks,std::int32_t* targets,std::int64_t* gains,std::int32_t* flags,
    VertexT* candidates,unsigned long long* candidate_count) {
    const auto v=static_cast<std::int64_t>(blockIdx.x)*blockDim.x+threadIdx.x;
    if (v<n) flags[v]=0;
    const bool active=v<n && incremental_lp_proposal(v,cache,row_totals,labels,k,
        filter,vertex_weights,loads,capacity,prices,locks,targets,gains);
    append_warp(static_cast<VertexT>(v),active,candidates,candidate_count);
}

// Compact the proposal queue, not the whole vertex range. The count remains
// on device until the existing host-side decision to apply a migration batch.
template <typename VertexT>
__global__ void incremental_compact_candidates(
    const VertexT* candidates,const unsigned long long* candidate_count,
    const std::int32_t* flags,VertexT* movers,unsigned long long* mover_count) {
    const auto count=*candidate_count;
    for (auto base=static_cast<unsigned long long>(blockIdx.x)*blockDim.x;
         base<count;base+=static_cast<unsigned long long>(gridDim.x)*blockDim.x) {
        const auto i=base+threadIdx.x;
        const VertexT v=i<count ? candidates[i] : VertexT{0};
        const bool active=i<count && flags[v];
        append_warp(v,active,movers,mover_count);
    }
}

template <typename OffsetT, typename VertexT, typename WeightT>
__global__ void incremental_priority_filter(
    const VertexT* candidates,const unsigned long long* candidate_count,
    const OffsetT* offsets,const VertexT* neighbors,const WeightT* weights,
    const VertexT* labels,const std::int32_t* targets,const std::int64_t* gains,
    const WeightT* vertex_weights,const unsigned long long* loads,
    std::uint64_t capacity,const double* prices,std::int32_t* flags,bool split_heavy) {
    const int lane=threadIdx.x&31;
    const auto count=*candidate_count;
    for (auto i=static_cast<unsigned long long>(blockIdx.x)*8+threadIdx.x/32;
         i<count;i+=static_cast<unsigned long long>(gridDim.x)*8) {
    const auto v=candidates[i];
    if (split_heavy && offsets[v+1]-offsets[v]>=kRefineHeavyDegree) continue;
    const auto source=labels[v],target=targets[v];
    const auto gain=gains[v];
    long long correction=0;
    for (std::int64_t e=static_cast<std::int64_t>(offsets[v])+lane;e<offsets[v+1];e+=32) {
        const auto u=neighbors[e];
        if (u==v || targets[u]<0 || !(gains[u]>gain || (gains[u]==gain && u<v))) continue;
        const auto w=static_cast<long long>(detail::edge_weight(weights,e));
        correction+=w*((targets[u]==target)-(targets[u]==source)-(labels[u]==target)+(labels[u]==source));
    }
    for (int shift=16;shift;shift/=2) correction+=__shfl_down_sync(0xffffffffU,correction,shift);
    if (!lane) {
        if (prices) {
            const auto weight=static_cast<std::uint64_t>(vertex_weights[v]);
            const double adjustment=estimated_repair_cost(source,weight,loads,capacity,prices)-
                estimated_repair_cost(target,weight,loads,capacity,prices);
            flags[v]=static_cast<double>(gain+correction)+adjustment>=0;
        } else flags[v]=gain+correction>=0;
    }
    }
}

// A few circuit rows have over a million neighbors. Split their exact integer
// correction across CTAs instead of serializing that entire row on one warp.
template <typename OffsetT,typename VertexT,typename WeightT>
__global__ void incremental_heavy_priority(
    const VertexT* heavy_rows,const OffsetT* offsets,const VertexT* neighbors,
    const WeightT* weights,const VertexT* labels,const std::int32_t* targets,
    const std::int64_t* gains,std::int64_t* corrections) {
    const auto i=blockIdx.x/kRefineHeavyBlocks;
    const auto v=heavy_rows[i];
    if (targets[v]<0) return;
    const auto source=labels[v],target=targets[v];
    const auto gain=gains[v];
    long long correction=0;
    for (std::int64_t e=static_cast<std::int64_t>(offsets[v])+
            (blockIdx.x%kRefineHeavyBlocks)*blockDim.x+threadIdx.x;
         e<offsets[v+1];e+=kRefineHeavyBlocks*blockDim.x) {
        const auto u=neighbors[e];
        if (u==v || targets[u]<0 || !(gains[u]>gain || (gains[u]==gain && u<v))) continue;
        correction+=static_cast<long long>(detail::edge_weight(weights,e))*
            ((targets[u]==target)-(targets[u]==source)-(labels[u]==target)+(labels[u]==source));
    }
    for (int shift=16;shift;shift/=2) correction+=__shfl_down_sync(0xffffffffU,correction,shift);
    if (!(threadIdx.x&31)) atomicAdd(reinterpret_cast<unsigned long long*>(corrections+i),
                                    static_cast<unsigned long long>(correction));
}

template <typename VertexT,typename WeightT>
__global__ void incremental_finish_heavy_priority(
    int count,const VertexT* heavy_rows,const VertexT* labels,const std::int32_t* targets,
    const std::int64_t* gains,const std::int64_t* corrections,const WeightT* vertex_weights,
    const unsigned long long* loads,std::uint64_t capacity,const double* prices,
    std::int32_t* flags) {
    const int i=blockIdx.x*blockDim.x+threadIdx.x;
    if (i>=count) return;
    const auto v=heavy_rows[i];
    if (targets[v]<0) { flags[v]=0;return; }
    const auto corrected=gains[v]+corrections[i];
    if (prices) {
        const auto weight=static_cast<std::uint64_t>(vertex_weights[v]);
        const double adjustment=estimated_repair_cost(labels[v],weight,loads,capacity,prices)-
            estimated_repair_cost(targets[v],weight,loads,capacity,prices);
        flags[v]=static_cast<double>(corrected)+adjustment>=0;
    } else flags[v]=corrected>=0;
}

template <typename VertexT,typename WeightT,typename CacheT>
__device__ __forceinline__ long long incremental_update_edge(
    VertexT v,VertexT u,WeightT edge_weight,const VertexT* labels,
    const std::int32_t* targets,const std::int32_t* flags,int k,AffinityView<CacheT> cache) {
    if (u==v) return 0;
    cache.touch(u);
    const auto source=labels[v],target=targets[v];
    const auto weight=static_cast<unsigned long long>(edge_weight);
    if (cache.direct()) {
        // CSR-backed affinities see the newly committed labels directly.
    } else if (cache.sparse()) {
        if (!atomicExch(cache.dirty+u,1)) {
            const auto slot=atomicAdd(cache.dirty_count,1ULL);
            cache.dirty_rows[slot]=u;
        }
    } else if constexpr (sizeof(CacheT)==4) {
        atomicAdd(cache.values+static_cast<std::int64_t>(u)*k+source,0U-static_cast<unsigned int>(weight));
        atomicAdd(cache.values+static_cast<std::int64_t>(u)*k+target,static_cast<unsigned int>(weight));
    } else {
        atomicAdd(reinterpret_cast<unsigned long long*>(cache.values+static_cast<std::int64_t>(u)*k+source),0ULL-weight);
        atomicAdd(reinterpret_cast<unsigned long long*>(cache.values+static_cast<std::int64_t>(u)*k+target),weight);
    }
    if (!flags[u] || u>v) {
        const auto new_neighbor=flags[u] ? targets[u] : labels[u];
        return static_cast<long long>(weight)*((source!=labels[u])-(target!=new_neighbor));
    }
    return 0;
}

template <typename OffsetT,typename VertexT,typename WeightT,typename CacheT>
__global__ void incremental_update_cache_and_cut(
    std::int64_t count,const VertexT* movers,const OffsetT* offsets,const VertexT* neighbors,
    const WeightT* weights,const VertexT* labels,const std::int32_t* targets,const std::int32_t* flags,
    int k,AffinityView<CacheT> cache,std::int64_t* delta,
    const WeightT* vertex_weights,RepairSample* samples,bool split_heavy,
    const std::int64_t* live_count=nullptr) {
    if (live_count) count=*live_count;
    const int lane=threadIdx.x&31;
    for (auto i=static_cast<std::int64_t>(blockIdx.x)*8+threadIdx.x/32; i<count; i+=static_cast<std::int64_t>(gridDim.x)*8) {
    const auto v=movers[i],source=labels[v];
    if (split_heavy && offsets[v+1]-offsets[v]>=kRefineHeavyDegree) continue;
    long long gain=0;
    for (std::int64_t e=static_cast<std::int64_t>(offsets[v])+lane;e<offsets[v+1];e+=32) {
        // Each affected undirected edge contributes once, including edges
        // whose two endpoints move concurrently.
        gain+=incremental_update_edge(v,neighbors[e],detail::edge_weight(weights,e),labels,targets,flags,k,cache);
    }
    for (int shift=16;shift;shift/=2) gain+=__shfl_down_sync(0xffffffffU,gain,shift);
    if (!lane) {
        atomicAdd(reinterpret_cast<unsigned long long*>(delta),static_cast<unsigned long long>(gain));
        if (samples) {
            // Charge each affected edge exactly once, using the same edge
            // ownership as the maintained cut. No extra neighbor traversal.
            atomicAdd(reinterpret_cast<unsigned long long*>(&samples[source].loss),static_cast<unsigned long long>(-gain));
            atomicAdd(&samples[source].weight,static_cast<unsigned long long>(vertex_weights[v]));
        }
    }
    }
}

template <typename OffsetT,typename VertexT,typename WeightT,typename CacheT>
__global__ void incremental_heavy_update_cache_and_cut(
    const VertexT* heavy_rows,const OffsetT* offsets,const VertexT* neighbors,
    const WeightT* weights,const VertexT* labels,const std::int32_t* targets,
    const std::int32_t* flags,int k,AffinityView<CacheT> cache,std::int64_t* delta,
    const WeightT* vertex_weights,RepairSample* samples) {
    const auto v=heavy_rows[blockIdx.x/kRefineHeavyBlocks];
    if (!flags[v]) return;
    long long gain=0;
    for (std::int64_t e=static_cast<std::int64_t>(offsets[v])+
            (blockIdx.x%kRefineHeavyBlocks)*blockDim.x+threadIdx.x;
         e<offsets[v+1];e+=kRefineHeavyBlocks*blockDim.x)
        gain+=incremental_update_edge(v,neighbors[e],detail::edge_weight(weights,e),labels,targets,flags,k,cache);
    for (int shift=16;shift;shift/=2) gain+=__shfl_down_sync(0xffffffffU,gain,shift);
    if (!(threadIdx.x&31)) {
        atomicAdd(reinterpret_cast<unsigned long long*>(delta),static_cast<unsigned long long>(gain));
        if (samples) atomicAdd(reinterpret_cast<unsigned long long*>(&samples[labels[v]].loss),
                               static_cast<unsigned long long>(-gain));
    }
    if (samples && !(blockIdx.x%kRefineHeavyBlocks) && !threadIdx.x)
        atomicAdd(&samples[labels[v]].weight,static_cast<unsigned long long>(vertex_weights[v]));
}

template <typename VertexT,typename WeightT,typename CacheT>
__global__ void incremental_commit(
    std::int64_t count,const VertexT* movers,VertexT* labels,const std::int32_t* targets,
    const WeightT* vertex_weights,unsigned long long* part_weights,std::int32_t* locks,bool lp,
    AffinityView<CacheT> cache,const std::int64_t* live_count=nullptr) {
    if (live_count) count=*live_count;
    for (auto i=static_cast<std::int64_t>(blockIdx.x)*blockDim.x+threadIdx.x; i<count; i+=static_cast<std::int64_t>(gridDim.x)*blockDim.x) {
    const auto v=movers[i],source=labels[v];
    const auto target=targets[v];
    const auto weight=static_cast<unsigned long long>(vertex_weights[v]);
    atomicAdd(part_weights+source,0ULL-weight);atomicAdd(part_weights+target,weight);
    labels[v]=static_cast<VertexT>(target);
    cache.touch(v);
    if (lp) locks[v]=1;
    }
}

constexpr int kBalanceBuckets=50;
constexpr int kBalanceSections=16;
constexpr int kBalanceWidth=kBalanceBuckets*kBalanceSections;

__device__ int balance_gain_bucket(double gain) {
    if (gain>0) return 0;
    if (gain==0) return 1;
    return max(2,min(49,25+static_cast<int>(ceil(log(-gain)/log(1.5)))));
}

template <typename VertexT,typename WeightT,typename CacheT>
__global__ void incremental_rebalance_proposals(
    std::int64_t n,AffinityView<CacheT> cache,const VertexT* labels,const WeightT* vertex_weights,
    int k,const unsigned long long* part_weights,std::uint64_t capacity,
    std::int32_t* targets,std::int32_t* bucket_ids,std::uint64_t* ranks,unsigned long long* counts,
    const VertexT* donors=nullptr,const std::int64_t* donor_count=nullptr) {
    const auto limit=donor_count ? *donor_count : n;
    for(auto index=static_cast<std::int64_t>(blockIdx.x)*blockDim.x+threadIdx.x;
        index<limit;index+=static_cast<std::int64_t>(gridDim.x)*blockDim.x) {
    const auto v=donors ? static_cast<std::int64_t>(donors[index]) : index;
    const auto source=labels[v];
    const auto weight=static_cast<std::uint64_t>(vertex_weights[v]);
    targets[v]=-1;
    bucket_ids[v]=-1;
    if (part_weights[source]>capacity) {
        int best=-1;
        std::uint64_t best_conn=0,best_slack=0;
        for (int p=0;p<k;++p) {
            if (p==source || part_weights[p]>=capacity || weight>capacity-part_weights[p]) continue;
            const auto value=cache.get(v,p);
            const auto slack=capacity-part_weights[p];
            if (best<0 || value>best_conn || (value==best_conn && slack>best_slack)) {
                best=p;best_conn=value;best_slack=slack;
            }
        }
        // Spread vertices with no destination affinity across available slack,
        // instead of sending every isolated vertex to the same partition.
        if (best>=0 && best_conn==0) {
            std::uint64_t total_slack=0;
            for (int p=0;p<k;++p)
                if (p!=source && part_weights[p]<capacity && weight<=capacity-part_weights[p])
                    total_slack=UINT64_MAX-total_slack<capacity-part_weights[p] ? UINT64_MAX : total_slack+capacity-part_weights[p];
            auto ticket=static_cast<std::uint64_t>(refine_mix32(static_cast<std::uint32_t>(v)))%total_slack;
            for (int p=0;p<k;++p) {
                if (p==source || part_weights[p]>=capacity || weight>capacity-part_weights[p]) continue;
                const auto slack=capacity-part_weights[p];
                if (ticket<slack) { best=p;break; }
                ticket-=slack;
            }
        }
        if (best>=0) {
            const auto current=cache.get(v,source);
            const double gain=best_conn>=current ? static_cast<double>(best_conn-current) : -static_cast<double>(current-best_conn);
            // Score loss by actual overload relief: a vertex heavier than
            // the excess cannot provide more than that excess in this step.
            // This normalization also appears in Jet's strong rebalance.
            const auto excess=static_cast<std::uint64_t>(part_weights[source]-capacity);
            const auto relief=weight<excess ? weight : excess;
            const auto gain_per_weight=gain/relief;
            targets[v]=best;
            const int bucket=source*kBalanceWidth+balance_gain_bucket(gain_per_weight)*kBalanceSections+
                refine_mix32(static_cast<std::uint32_t>(v))%kBalanceSections;
            bucket_ids[v]=bucket;
            ranks[v]=atomicAdd(counts+bucket,static_cast<unsigned long long>(weight));
        }
    }
    }
}

struct IncrementalFlag {
    __host__ __device__ bool operator()(std::int32_t flag) const { return flag!=0; }
};

__global__ void balance_scan_buckets(
    const unsigned long long* counts,unsigned long long* offsets) {
    // Exactly one full warp owns a part. No inter-warp barrier is needed.
    constexpr int items=(kBalanceWidth+31)/32;
    const int lane=threadIdx.x;
    unsigned long long values[items],total=0;
    #pragma unroll
    for (int i=0;i<items;++i) {
        const int b=lane*items+i;
        values[i]=b<kBalanceWidth ? counts[blockIdx.x*kBalanceWidth+b] : 0;
        total+=values[i];
    }
    auto sum=total;
    for (int shift=1;shift<32;shift*=2) {
        const auto previous=__shfl_up_sync(0xffffffffU,sum,shift);
        if (lane>=shift) sum+=previous;
    }
    auto prefix=sum-total;
    #pragma unroll
    for (int i=0;i<items;++i) {
        const int b=lane*items+i;
        if (b<kBalanceWidth) offsets[blockIdx.x*kBalanceWidth+b]=prefix;
        prefix+=values[i];
    }
}

} // namespace

#include "refine_rebalance_graph.cuh"
#include "refine_lp_graph.cuh"


template <typename CacheT>
RefineStats run_incremental_refinement_typed(
    RefineDeviceContext& context,const RefineOptions& options,int rounds) {
    const auto start=std::chrono::steady_clock::now();
    validate_refinement_gain_range(context.graph);
    auto& ws=context.workspace;
    auto& graph=context.graph;
    const auto n=context.n;
    const auto k=options.parts;
    auto& affinity=[&]() -> auto& {
        if constexpr (sizeof(CacheT)==4) return ws.dense_affinity32;
        else return ws.dense_affinity;
    }();
    // One invariant incident-weight value follows the dense rows. It uses the
    // same proven counter width; no second CSR traversal or per-move update.
    const auto dense_entries=static_cast<std::size_t>(n)*k;
    const auto sparse_entries=graph.neighbors.size();
    // Include keys, row counts, and dirty flags in the representation choice.
    static_assert(kMaxParts<=255,"sparse partition keys/counts must fit uint8");
    const auto sparse_bytes=sparse_entries*(sizeof(CacheT)+sizeof(std::uint8_t))+
        static_cast<std::size_t>(n)*(2*sizeof(std::int32_t)+sizeof(std::uint8_t));
    const auto dense_bytes=dense_entries*sizeof(CacheT);
    // Preserve every previously eligible sparse layout. The new boundary
    // cost guard only constrains cases made eligible by narrower metadata.
    const auto legacy_sparse_bytes=sparse_entries*(sizeof(CacheT)+sizeof(std::int32_t))+
        static_cast<std::size_t>(n)*3*sizeof(std::int32_t);
    // Small matrices and modest savings do not amortize sparse row metadata
    // and rebuild work. Explicit layouts are available for correctness tests.
    const bool direct=options.affinity_layout==AffinityLayout::OnDemand ||
        (options.affinity_layout==AffinityLayout::Automatic && n>=65536 &&
         graph.maximum_degree<=16 && context.has_known_cut &&
         context.known_cut<=static_cast<std::uint64_t>(n)/500);
    const bool sparse=options.affinity_layout==AffinityLayout::Sparse ||
        (options.affinity_layout==AffinityLayout::Automatic && !direct &&
         dense_bytes>=64ULL*1024*1024 && sparse_bytes<=dense_bytes-dense_bytes/4 &&
         !graph.has_heavy_rows &&
         (legacy_sparse_bytes<=dense_bytes/2 ||
          sparse_entries/static_cast<std::size_t>(n)<=8 ||
          (context.has_known_cut && context.known_cut<=sparse_entries/40)));
    const auto entries=direct ? std::size_t{0} : sparse ? sparse_entries : dense_entries;
    ws.grow(affinity,entries+n);
    if (sparse) {
        ws.grow(ws.affinity_keys,std::max<std::size_t>(sparse_entries,1));
        ws.grow(ws.affinity_counts,n);ws.grow(ws.affinity_dirty,n);
        ws.grow(ws.affinity_dirty_rows,n);ws.grow(ws.affinity_dirty_count,1);
    }
    ws.grow(ws.incremental_targets,n);ws.grow(ws.incremental_gains,n);
    ws.grow(ws.incremental_locks,n);ws.grow(ws.incremental_flags,n);
    ws.grow(ws.incremental_movers,n);ws.grow(ws.incremental_delta,1);
    ws.grow(ws.balance_bucket_ids,n);ws.grow(ws.balance_bucket_ranks,n);
    ws.grow(ws.balance_bucket_counts,k*kBalanceWidth);
    ws.grow(ws.balance_bucket_offsets,k*kBalanceWidth);
    const auto heavy_bound=std::min(static_cast<std::size_t>(n),
        graph.neighbors.size()/static_cast<std::size_t>(kRefineHeavyDegree));
    ws.grow(ws.incremental_heavy_rows,heavy_bound);
    ws.grow(ws.incremental_heavy_corrections,heavy_bound);
    ws.grow(ws.incremental_heavy_count,1);
    auto* heavy_rows=heavy_bound ? thrust::raw_pointer_cast(ws.incremental_heavy_rows.data()) : nullptr;
    auto* heavy_count_device=thrust::raw_pointer_cast(ws.incremental_heavy_count.data());
    auto* heavy_corrections=thrust::raw_pointer_cast(ws.incremental_heavy_corrections.data());
    CUDA_CHECK(cudaMemset(heavy_count_device,0,sizeof(unsigned int)));
    AffinityView<CacheT> cache{thrust::raw_pointer_cast(affinity.data()),
        sparse ? thrust::raw_pointer_cast(ws.affinity_keys.data()) : nullptr,
        sparse ? thrust::raw_pointer_cast(ws.affinity_counts.data()) : nullptr,
        sparse ? thrust::raw_pointer_cast(ws.affinity_dirty.data()) : nullptr,
        sparse ? thrust::raw_pointer_cast(ws.affinity_dirty_rows.data()) : nullptr,
        sparse ? thrust::raw_pointer_cast(ws.affinity_dirty_count.data()) : nullptr,
        thrust::raw_pointer_cast(graph.offsets.data()),k};
    if (direct) {
        cache.direct_labels=thrust::raw_pointer_cast(context.partition.data());
        cache.direct_neighbors=thrust::raw_pointer_cast(graph.neighbors.data());
        cache.direct_weights=thrust::raw_pointer_cast(graph.edge_weights.data());

    }
    auto* row_totals=cache.values+entries;
    // LP candidate lists are dead before rebalancing writes bucket IDs; the
    // cut scratch is also idle until after candidate filtering has finished.
    static_assert(std::is_same_v<gpart::GraphTypes::VertexT,std::int32_t>);
    auto* candidates=thrust::raw_pointer_cast(ws.balance_bucket_ids.data());
    auto* candidate_count=thrust::raw_pointer_cast(ws.cut_counter.data());
    auto* mover_count=thrust::raw_pointer_cast(ws.balance_bucket_counts.data());
    auto* boundary_count=mover_count+1;
    auto* targets=thrust::raw_pointer_cast(ws.incremental_targets.data());
    auto* gains=thrust::raw_pointer_cast(ws.incremental_gains.data());
    auto* locks=thrust::raw_pointer_cast(ws.incremental_locks.data());
    auto* flags=thrust::raw_pointer_cast(ws.incremental_flags.data());
    auto* labels=thrust::raw_pointer_cast(context.partition.data());
    auto* offsets=thrust::raw_pointer_cast(graph.offsets.data());
    auto* neighbors=thrust::raw_pointer_cast(graph.neighbors.data());
    auto* weights=thrust::raw_pointer_cast(graph.edge_weights.data());
    auto* vertex_weights=thrust::raw_pointer_cast(graph.vertex_weights.data());
    auto* part_weights=thrust::raw_pointer_cast(context.part_weights.data());
    auto* movers=thrust::raw_pointer_cast(ws.incremental_movers.data());
    double* prices=nullptr;
    RepairSample* samples=nullptr;
    const auto total_mass=std::accumulate(context.host_part_weights.begin(),context.host_part_weights.end(),std::uint64_t{0});
    if (total_mass>static_cast<std::uint64_t>(n)) {
        ws.grow(ws.repair_prices,k);ws.grow(ws.repair_samples,k);
        prices=thrust::raw_pointer_cast(ws.repair_prices.data());
        samples=thrust::raw_pointer_cast(ws.repair_samples.data());
        CUDA_CHECK(cudaMemset(prices,0,k*sizeof(double)));
    }
    CUDA_CHECK(cudaMemsetAsync(locks,0,n*sizeof(*locks)));
    launch_affinity_build(n,offsets,neighbors,weights,labels,k,cache,heavy_rows,heavy_count_device,row_totals);
    CUDA_CHECK(cudaGetLastError());
    RefineStats stats;
    stats.affinity_counter_bits=sizeof(CacheT)*8;
    stats.sparse_affinity=sparse;stats.on_demand_affinity=direct;
    stats.affinity_bytes=(direct ? 0 : sparse ? sparse_bytes : dense_bytes)+n*sizeof(CacheT);
    stats.initial_cut=context.has_known_cut && !options.strict_verify ? context.known_cut : context.cut();
    if (options.strict_verify && context.has_known_cut && stats.initial_cut!=context.known_cut)
        throw std::runtime_error("projected cut differs from known coarse cut");
    unsigned int heavy_count=0;
    if (heavy_bound) CUDA_CHECK(cudaMemcpy(&heavy_count,heavy_count_device,sizeof(heavy_count),cudaMemcpyDeviceToHost));
    if (heavy_count>heavy_bound) throw std::runtime_error("refinement heavy-row queue overflow");
    if (n>=65536 && rounds>0) {
        ws.grow(ws.frontier_rows,n);ws.grow(ws.frontier_members,n);ws.grow(ws.frontier_count,1);
        auto* count=thrust::raw_pointer_cast(ws.frontier_count.data());
        CUDA_CHECK(cudaMemset(count,0,sizeof(*count)));
        initialize_affinity_frontier<<<context.vertex_blocks,256>>>(n,cache,row_totals,labels,k,
            thrust::raw_pointer_cast(ws.frontier_members.data()),thrust::raw_pointer_cast(ws.frontier_rows.data()),count,targets,gains,flags);
        CUDA_CHECK(cudaGetLastError());
        unsigned long long size=0;
        CUDA_CHECK(cudaMemcpy(&size,count,sizeof(size),cudaMemcpyDeviceToHost));
        if (size<=static_cast<unsigned long long>(n)/4) {
            cache.frontier_rows=thrust::raw_pointer_cast(ws.frontier_rows.data());
            cache.frontier_members=thrust::raw_pointer_cast(ws.frontier_members.data());
            cache.frontier_count=count;
            stats.frontier_vertices_initial=size;
        }
    }
    auto current_cut=stats.initial_cut,best_cut=current_cut;
    std::uint64_t revision=0,best_revision=0;
    const auto checkpoint=[&]() {
        thrust::copy(detail::scratch_policy(),context.partition.begin(),context.partition.end(),ws.previous_partition.begin());
        thrust::copy(detail::scratch_policy(),context.part_weights.begin(),context.part_weights.end(),ws.previous_part_weights.begin());
        best_revision=revision;
    };
    const auto maximum=[&]() { return *std::max_element(context.host_part_weights.begin(),context.host_part_weights.end()); };
    const auto all=thrust::make_counting_iterator<gpart::GraphTypes::VertexT>(0);
    const auto compact_movers=[&]() {
        const auto end=thrust::copy_if(detail::scratch_policy(),all,all+n,ws.incremental_flags.begin(),ws.incremental_movers.begin(),IncrementalFlag{});
        return static_cast<std::int64_t>(end-ws.incremental_movers.begin());
    };
    enum class MovePhase { LP, Group };
    const auto apply=[&](std::int64_t count,MovePhase phase) {
        if (sparse) CUDA_CHECK(cudaMemset(cache.dirty_count,0,sizeof(*cache.dirty_count)));
        CUDA_CHECK(cudaMemset(thrust::raw_pointer_cast(ws.incremental_delta.data()),0,sizeof(std::int64_t)));
        incremental_update_cache_and_cut<<<static_cast<int>((count+7)/8),256>>>(count,movers,offsets,neighbors,weights,labels,targets,flags,k,cache,thrust::raw_pointer_cast(ws.incremental_delta.data()),vertex_weights,nullptr,heavy_count!=0);
        CUDA_CHECK(cudaGetLastError());
        if (heavy_count) {
            incremental_heavy_update_cache_and_cut<<<heavy_count*kRefineHeavyBlocks,256>>>(heavy_rows,offsets,neighbors,weights,labels,targets,flags,k,cache,thrust::raw_pointer_cast(ws.incremental_delta.data()),vertex_weights,static_cast<RepairSample*>(nullptr));
            CUDA_CHECK(cudaGetLastError());
        }
        incremental_commit<<<static_cast<int>((count+255)/256),256>>>(count,movers,labels,targets,vertex_weights,part_weights,locks,phase==MovePhase::LP,cache);
        CUDA_CHECK(cudaGetLastError());
        if (sparse) {
            launch_affinity_build(n,offsets,neighbors,weights,labels,k,cache,
                static_cast<gpart::GraphTypes::VertexT*>(nullptr),static_cast<unsigned int*>(nullptr),static_cast<CacheT*>(nullptr),true);
            CUDA_CHECK(cudaGetLastError());
        }
        std::int64_t delta=0;
        CUDA_CHECK(cudaMemcpy(&delta,thrust::raw_pointer_cast(ws.incremental_delta.data()),sizeof(delta),cudaMemcpyDeviceToHost));
        if (phase==MovePhase::Group) {
            if (delta<=0) throw std::runtime_error("non-improving boundary group batch");
            stats.group_cut_gain+=static_cast<std::uint64_t>(delta);
            stats.group_accepted+=count;
        } else {
            if (delta>=0) stats.lp_cut_gain+=static_cast<std::uint64_t>(delta);
            else stats.lp_cut_loss+=static_cast<std::uint64_t>(-delta);
        }
        if (delta>=0) {
            if (static_cast<std::uint64_t>(delta)>current_cut) throw std::runtime_error("incremental cut underflow");
            current_cut-=static_cast<std::uint64_t>(delta);
        } else current_cut+=static_cast<std::uint64_t>(-delta);
        context.sync_part_weights();
        ++revision;
        stats.accepted+=count;
        if (options.strict_verify) {
            if (context.cut()!=current_cut) throw std::runtime_error("incremental cut differs from CSR scan");
            detail::ScratchVector<unsigned int> errors(1,0U);
            incremental_build_affinity<gpart::GraphTypes::OffsetT,gpart::GraphTypes::VertexT,gpart::GraphTypes::WeightT,CacheT,true><<<std::min(context.warp_blocks,2048),256,8*k*sizeof(std::uint64_t)>>>(n,offsets,neighbors,weights,labels,k,cache,
                static_cast<gpart::GraphTypes::VertexT*>(nullptr),static_cast<unsigned int*>(nullptr),row_totals,false,thrust::raw_pointer_cast(errors.data()));
            CUDA_CHECK(cudaGetLastError());
            if (static_cast<unsigned int>(errors[0])) throw std::runtime_error("affinity cache differs from independent CSR rebuild");
        }
    };
    std::unique_ptr<RebalanceGraph<CacheT>> rebalance_graph;
    const auto rebalance=[&]() {
        if (maximum()<=context.capacity) return true;
        if (!rebalance_graph) rebalance_graph=std::make_unique<RebalanceGraph<CacheT>>(context,cache,k,samples,options.strict_verify,heavy_rows,heavy_count);
        const auto state=rebalance_graph->run();
        if (state.validation_errors) throw std::runtime_error("GPU bucket prefix mismatch");
        stats.admission_iterations+=state.iterations;
        stats.accepted+=state.movers;
        stats.rebalance_cut_gain+=state.gain;stats.rebalance_cut_loss+=state.loss;
        if (state.delta>=0) {
            if (static_cast<std::uint64_t>(state.delta)>current_cut) throw std::runtime_error("rebalance cut underflow");
            current_cut-=state.delta;
        } else current_cut+=static_cast<std::uint64_t>(-state.delta);
        revision+=state.batches;
        context.sync_part_weights();
        if (options.strict_verify) {
            if (context.cut()!=current_cut) throw std::runtime_error("GPU rebalance cut mismatch");
            detail::ScratchVector<unsigned int> errors(1,0U);
            incremental_build_affinity<gpart::GraphTypes::OffsetT,gpart::GraphTypes::VertexT,gpart::GraphTypes::WeightT,CacheT,true><<<std::min(context.warp_blocks,2048),256,8*k*sizeof(std::uint64_t)>>>(n,offsets,neighbors,weights,labels,k,cache,
                static_cast<gpart::GraphTypes::VertexT*>(nullptr),static_cast<unsigned int*>(nullptr),row_totals,false,thrust::raw_pointer_cast(errors.data()));
            CUDA_CHECK(cudaGetLastError());
            if (static_cast<unsigned int>(errors[0])) throw std::runtime_error("affinity cache differs from independent CSR rebuild");
        }
        return state.feasible!=0;
    };
    // Coarse indivisible vertices may require a finer representation. Keep
    // the one METIS partition, propagate any completed repair moves, and
    // retry the existing GPU repair after projection. Never save an infeasible
    // checkpoint or run cut optimization before the initial balance succeeds.
    if (maximum()>context.capacity) {
        if (samples) CUDA_CHECK(cudaMemset(samples,0,k*sizeof(RepairSample)));
        if (!rebalance()) {
            stats.initial_repair_failed=true;
            stats.final_cut=current_cut;
            stats.final_max_part_weight=maximum();
            stats.seconds=std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count();
            return stats;
        }
    }
    const auto feasible_start_cut=current_cut;
    best_cut=current_cut;
    checkpoint();
    using WeightT=gpart::GraphTypes::WeightT;
    const auto maximum_edge=graph.implicit_unit_weights ? WeightT{1} : thrust::reduce(detail::scratch_policy(), graph.edge_weights.begin(),graph.edge_weights.end(),WeightT{0},thrust::maximum<WeightT>());
    const double filter=maximum_edge<=1 ? 0.25 : 0.75;
    if (options.mode!=RefinementMode::Joint) {
    if (options.gpu_lp_loop && rounds>0 && n>=65536) {
        rebalance_graph.reset();
        LPGraph<CacheT> loop(context,cache,row_totals,options,rounds,filter,prices,samples,heavy_rows,heavy_count,heavy_corrections);
        LPLoopState initial;
        initial.stats=stats;initial.cut=current_cut;initial.best=best_cut;
        initial.revision=revision;initial.best_revision=best_revision;
        const auto state=loop.run(initial);
        stats=state.stats;current_cut=state.cut;best_cut=state.best;
        revision=state.revision;best_revision=state.best_revision;
        context.sync_part_weights();
    } else {
    int stale=0,empty=0;
    for (int phase=0;phase<rounds && stale<options.stale_rounds;++phase) {
        stats.rounds=phase+1;
        if (samples) CUDA_CHECK(cudaMemset(samples,0,k*sizeof(RepairSample)));
        CUDA_CHECK(cudaMemset(candidate_count,0,sizeof(unsigned long long)));
        CUDA_CHECK(cudaMemset(mover_count,0,2*sizeof(unsigned long long)));
        if (cache.frontier_count) {
            launch_lp_proposals(std::min(context.warp_blocks,2048),cache.frontier_rows,cache.frontier_count,cache,labels,k,filter,vertex_weights,part_weights,context.capacity,prices,targets,gains,locks,flags,row_totals);
            CUDA_CHECK(cudaGetLastError());
            incremental_collect_proposals<<<std::min(context.vertex_blocks,1024),256>>>(cache.frontier_rows,cache.frontier_count,targets,candidates,candidate_count);
        } else if (k<=32) {
            incremental_lp_proposals<<<context.vertex_blocks,256>>>(n,cache,row_totals,labels,k,filter,vertex_weights,part_weights,context.capacity,prices,locks,targets,gains,flags,candidates,candidate_count);
        } else {
            // Movers are scratch until admission. Proposal generation finishes
            // reading this boundary list before compaction overwrites it.
            incremental_collect_boundaries<<<context.vertex_blocks,256>>>(n,cache,row_totals,labels,k,locks,targets,gains,flags,movers,boundary_count);
            CUDA_CHECK(cudaGetLastError());
            launch_lp_proposals(std::min(context.warp_blocks,2048),movers,boundary_count,cache,labels,k,filter,vertex_weights,part_weights,context.capacity,prices,targets,gains);
            CUDA_CHECK(cudaGetLastError());
            incremental_collect_proposals<<<std::min(context.vertex_blocks,1024),256>>>(movers,boundary_count,targets,candidates,candidate_count);
        }
        CUDA_CHECK(cudaGetLastError());
        incremental_priority_filter<<<std::min(context.warp_blocks,1024),256>>>(candidates,candidate_count,offsets,neighbors,weights,labels,targets,gains,vertex_weights,part_weights,context.capacity,prices,flags,heavy_count!=0);
        CUDA_CHECK(cudaGetLastError());
        if (heavy_count) {
            CUDA_CHECK(cudaMemset(heavy_corrections,0,heavy_count*sizeof(std::int64_t)));
            incremental_heavy_priority<<<heavy_count*kRefineHeavyBlocks,256>>>(heavy_rows,offsets,neighbors,weights,labels,targets,gains,heavy_corrections);
            CUDA_CHECK(cudaGetLastError());
            incremental_finish_heavy_priority<<<(heavy_count+255)/256,256>>>(static_cast<int>(heavy_count),heavy_rows,labels,targets,gains,heavy_corrections,vertex_weights,part_weights,context.capacity,prices,flags);
            CUDA_CHECK(cudaGetLastError());
        }
        incremental_compact_candidates<<<std::min(context.vertex_blocks,1024),256>>>(candidates,candidate_count,flags,movers,mover_count);
        CUDA_CHECK(cudaGetLastError());
        unsigned long long compact_count=0;
        CUDA_CHECK(cudaMemcpy(&compact_count,mover_count,sizeof(compact_count),cudaMemcpyDeviceToHost));
        const auto count=static_cast<std::int64_t>(compact_count);
        stats.proposals+=count;
        if (!count) { if (++empty>=2) break;++stale;continue; }
        empty=0;
        apply(count,MovePhase::LP);
        if (!rebalance()) { ++stats.admission_fallbacks;break; }
        if (prices) {
            publish_repair_prices<<<1,32>>>(k,samples,prices);
            CUDA_CHECK(cudaGetLastError());
        }
        ++stale;
        if (current_cut<best_cut) {
            if (static_cast<long double>(current_cut)<0.999L*best_cut) stale=0;
            best_cut=current_cut;checkpoint();++stats.checkpoint_updates;
        }
    }
    } // host-controlled reference loop
    } // LP baseline / polish precursor
    stats.checkpoint_discarded_cut=current_cut>best_cut ? current_cut-best_cut : 0;
    const bool restored=revision!=best_revision;
    if (restored) {
        thrust::copy(detail::scratch_policy(),ws.previous_partition.begin(),ws.previous_partition.begin()+n,context.partition.begin());
        thrust::copy(detail::scratch_policy(),ws.previous_part_weights.begin(),ws.previous_part_weights.begin()+k,context.part_weights.begin());
        context.sync_part_weights();
    }
    current_cut=best_cut;
    // Restrict group search to small layers; avoid another large original
    // graph scan. Starting from the feasible checkpoint prevents repair losses
    // from contaminating either the shortlist or the transaction capacities.
    if (options.mode==RefinementMode::Legacy && rounds>0 && options.boundary_group_rounds>0 && n<=65536) {
        ws.grow(ws.boundary_groups,n*kGroupSize);
        ws.grow(ws.group_transactions,k*k);
        ws.grow(ws.group_order,n*kGroupSize);
        ws.grow(ws.group_weight_order,n*kGroupSize);
        ws.grow(ws.group_candidates,n*kGroupSize);
        ws.grow(ws.group_ranges,k*k);
        ws.grow(ws.group_active_pairs,k>=64 ? k*k : 0);
        if (restored) {
            launch_affinity_build(n,offsets,neighbors,weights,labels,k,cache);
            CUDA_CHECK(cudaGetLastError());
        }
        for (int pass=0;pass<options.boundary_group_rounds;++pass) {
            auto* groups=thrust::raw_pointer_cast(ws.boundary_groups.data());
            auto* transactions=thrust::raw_pointer_cast(ws.group_transactions.data());
            boundary_group_proposals<<<context.warp_blocks,256>>>(n,offsets,neighbors,weights,vertex_weights,labels,cache,k,groups);
            CUDA_CHECK(cudaGetLastError());
            const int slots=static_cast<int>(n)*kGroupSize;
            auto order_begin=ws.group_order.begin();
            const auto all_slots=thrust::make_counting_iterator<int>(0);
            const auto valid_end=thrust::copy_if(detail::scratch_policy(),all_slots,all_slots+slots,
                order_begin,ValidBoundaryGroup{groups});
            if(valid_end==order_begin) break;
            const int valid=static_cast<int>(valid_end-order_begin);
            ws.grow(ws.group_sort_keys,valid);ws.grow(ws.group_sort_other,valid);
            int pair_bits=0;
            for (int pair=k*k-1;pair;pair>>=1) ++pair_bits;
            detail::GroupSortLayout layout{17,64,64,pair_bits};
            if (options.compact_group_keys && valid>=8192) {
                ws.grow(ws.group_sort_limits,2);
                auto* limits=thrust::raw_pointer_cast(ws.group_sort_limits.data());
                CUDA_CHECK(cudaMemsetAsync(limits,0,2*sizeof(unsigned long long)));
                group_order_limits<<<(valid+255)/256,256>>>(valid,
                    thrust::raw_pointer_cast(ws.group_order.data()),groups,limits);
                CUDA_CHECK(cudaGetLastError());
                unsigned long long bounds[2]={};
                CUDA_CHECK(cudaMemcpy(bounds,limits,sizeof(bounds),cudaMemcpyDeviceToHost));
                layout=detail::GroupSortLayout::bounded(static_cast<int>(n),k,bounds[0],bounds[1]);
            }
            encode_group_order<<<(valid+255)/256,256>>>(valid,thrust::raw_pointer_cast(ws.group_order.data()),groups,labels,k,thrust::raw_pointer_cast(ws.group_sort_keys.data()),layout);
            std::cout << "refine_group_sort count=" << valid << " key_bits=" << layout.end_bit()
                      << " full_bits=" << 196+pair_bits << '\n';
            cub::DoubleBuffer<GroupRadixKey> buffers(thrust::raw_pointer_cast(ws.group_sort_keys.data()),thrust::raw_pointer_cast(ws.group_sort_other.data()));
            std::size_t bytes=0;
            CUDA_CHECK(cub::DeviceRadixSort::SortKeys(nullptr,bytes,buffers,valid,GroupRadixDecomposer{},0,layout.end_bit()));
            ws.grow(ws.group_sort_temp,bytes);
            CUDA_CHECK(cub::DeviceRadixSort::SortKeys(thrust::raw_pointer_cast(ws.group_sort_temp.data()),bytes,buffers,valid,GroupRadixDecomposer{},0,layout.end_bit()));
            decode_group_order<<<(valid+255)/256,256>>>(valid,buffers.Current(),thrust::raw_pointer_cast(ws.group_order.data()));
            CUDA_CHECK(cudaGetLastError());
            if (options.strict_verify) {
                ws.grow(ws.group_sort_errors,1);
                auto* errors=thrust::raw_pointer_cast(ws.group_sort_errors.data());
                CUDA_CHECK(cudaMemsetAsync(errors,0,sizeof(*errors)));
                validate_group_order<<<(valid+255)/256,256>>>(valid,thrust::raw_pointer_cast(ws.group_order.data()),GroupOrder{groups,labels,k},errors);
                unsigned int bad=0;
                CUDA_CHECK(cudaMemcpy(&bad,errors,sizeof(bad),cudaMemcpyDeviceToHost));
                if (bad) throw std::runtime_error("radix group order differs from complete comparator");
            }
            const auto unique_end=thrust::unique(detail::scratch_policy(),order_begin,valid_end,SameGroup{groups,labels,k});
            auto* order=thrust::raw_pointer_cast(ws.group_order.data());
            const auto end=thrust::copy_if(detail::scratch_policy(),order_begin,unique_end,
                thrust::make_counting_iterator<int>(0),ws.group_weight_order.begin(),KeepGroupWeights{order,groups,labels,k});
            const int candidates=static_cast<int>(end-ws.group_weight_order.begin());
            if (!candidates) break;
            order=thrust::raw_pointer_cast(ws.group_weight_order.data());
            auto* ranges=thrust::raw_pointer_cast(ws.group_ranges.data());
            CUDA_CHECK(cudaMemset(ranges,0,k*k*sizeof(GroupRange)));
            group_ranges<<<(candidates+255)/256,256>>>(candidates,order,groups,labels,k,ranges);
            CUDA_CHECK(cudaGetLastError());
            int base=1;
            while (base<candidates) base*=2;
            ws.grow(ws.group_tree,base*2);
            auto* tree=thrust::raw_pointer_cast(ws.group_tree.data());
            for (int start=base;;start/=256) {
                group_tree_tile<<<(start+255)/256,256>>>(start,base,candidates,tree,order,groups);
                CUDA_CHECK(cudaGetLastError());
                if(start<=256) break;
            }
            auto* proposals=thrust::raw_pointer_cast(ws.group_candidates.data());
            boundary_group_transactions<<<(candidates+7)/8,256>>>(candidates,order,ranges,base,tree,
                offsets,neighbors,weights,labels,k,groups,part_weights,context.capacity,proposals);
            CUDA_CHECK(cudaGetLastError());
            int transaction_count=k*k;
            int* active_pairs=nullptr;
            if(k>=64) {
                const auto first=thrust::make_counting_iterator<int>(0);
                const auto end=thrust::copy_if(detail::scratch_policy(),first,first+k*k,
                    ws.group_active_pairs.begin(),NonemptyGroupPair{ranges});
                transaction_count=static_cast<int>(end-ws.group_active_pairs.begin());
                active_pairs=thrust::raw_pointer_cast(ws.group_active_pairs.data());
            }
            if(!transaction_count) break;
            group_reduce_transactions<<<transaction_count,256>>>(k,ranges,proposals,transactions,active_pairs);
            CUDA_CHECK(cudaGetLastError());
            thrust::sort(detail::scratch_policy(), ws.group_transactions.begin(),ws.group_transactions.begin()+transaction_count,TransactionOrder{});
            CUDA_CHECK(cudaMemset(flags,0,n*sizeof(std::int32_t)));
            boundary_group_admit<<<1,1>>>(k,transaction_count,groups,transactions,labels,part_weights,context.capacity,flags,targets);
            CUDA_CHECK(cudaGetLastError());
            const auto count=compact_movers();
            if (!count) break;
            // Different accepted transactions can share edges. Measure their
            // complete batch gain exactly before mutating labels or the cache.
            CUDA_CHECK(cudaMemset(thrust::raw_pointer_cast(ws.incremental_delta.data()),0,sizeof(std::int64_t)));
            boundary_group_measure<<<static_cast<int>((count+7)/8),256>>>(count,movers,offsets,neighbors,weights,labels,targets,flags,thrust::raw_pointer_cast(ws.incremental_delta.data()));
            CUDA_CHECK(cudaGetLastError());
            std::int64_t gain=0;
            CUDA_CHECK(cudaMemcpy(&gain,thrust::raw_pointer_cast(ws.incremental_delta.data()),sizeof(gain),cudaMemcpyDeviceToHost));
            if (gain<=0) break;
            apply(count,MovePhase::Group);
            if (maximum()>context.capacity || current_cut!=best_cut-static_cast<std::uint64_t>(gain))
                throw std::runtime_error("boundary group transaction violated cut/capacity");
            best_cut=current_cut;
        }
    }
    if (options.mode!=RefinementMode::Legacy && rounds>0 && options.joint_rounds>0 &&
        (options.mode==RefinementMode::Joint || n<=65536)) {
        if (restored) {
            launch_affinity_build(n,offsets,neighbors,weights,labels,k,cache);
            CUDA_CHECK(cudaGetLastError());
        }
        const int seed_width=std::min(kJointSeeds,std::max(32,4096/k));
        const int slots=k*seed_width*2;
        ws.grow(ws.joint_moves,slots);ws.grow(ws.joint_quotient,k*k);
        ws.grow(ws.joint_visits,k*k);ws.grow(ws.joint_partner,k);
        ws.grow(ws.joint_seeds,k*seed_width);ws.grow(ws.joint_events,slots);
        ws.grow(ws.joint_stops,k);
        auto* joint=thrust::raw_pointer_cast(ws.joint_moves.data());
        auto* quotient=thrust::raw_pointer_cast(ws.joint_quotient.data());
        auto* visits=thrust::raw_pointer_cast(ws.joint_visits.data());
        auto* partner=thrust::raw_pointer_cast(ws.joint_partner.data());
        auto* seeds=thrust::raw_pointer_cast(ws.joint_seeds.data());
        auto* events=thrust::raw_pointer_cast(ws.joint_events.data());
        auto* stops=thrust::raw_pointer_cast(ws.joint_stops.data());
        CUDA_CHECK(cudaMemsetAsync(quotient,0,k*k*sizeof(*quotient)));
        CUDA_CHECK(cudaMemsetAsync(visits,0,k*k*sizeof(*visits)));
        joint_quotient<<<std::min(context.vertex_blocks,1024),256>>>(n,labels,cache,quotient);
        CUDA_CHECK(cudaGetLastError());
        int empty_joint=0;
        for (int pass=0;pass<options.joint_rounds;++pass) {
            joint_match<<<1,128>>>(k,quotient,partner,visits);
            CUDA_CHECK(cudaMemsetAsync(seeds,0xff,k*seed_width*sizeof(*seeds)));
            joint_seeds<<<std::min(context.vertex_blocks,1024),256>>>(n,labels,cache,partner,seeds,seed_width,pass);
            joint_grow<<<(slots+7)/8,256>>>(slots,seed_width,seeds,partner,offsets,neighbors,weights,vertex_weights,labels,cache,part_weights,context.capacity,joint);
            CUDA_CHECK(cudaGetLastError());
            const auto end=thrust::remove_if(detail::scratch_policy(),ws.joint_moves.begin(),ws.joint_moves.begin()+slots,EmptyJointMove{});
            const int active=static_cast<int>(end-ws.joint_moves.begin());
            if(!active) { if(++empty_joint>=2) break;continue; }
            thrust::sort(detail::scratch_policy(),ws.joint_moves.begin(),end,JointOrder{});
            thrust::fill(detail::scratch_policy(),ws.incremental_locks.begin(),ws.incremental_locks.begin()+n,INT_MAX);
            joint_claim<<<(active+255)/256,256>>>(active,joint,locks);
            joint_resolve<<<(active+255)/256,256>>>(active,joint,locks);
            thrust::fill(detail::scratch_policy(),ws.incremental_locks.begin(),ws.incremental_locks.begin()+n,INT_MAX);
            joint_mark<<<(active+255)/256,256>>>(active,joint,labels,locks,targets);
            CUDA_CHECK(cudaMemsetAsync(events,0,active*sizeof(*events)));
            joint_events<<<(active+7)/8,256>>>(active,joint,locks,targets,labels,offsets,neighbors,weights,events);
            joint_prefix<<<(k+127)/128,128>>>(active,k,joint,events,part_weights,context.capacity,stops);
            CUDA_CHECK(cudaMemsetAsync(flags,0,n*sizeof(*flags)));
            joint_accept<<<(active+255)/256,256>>>(active,joint,stops,flags);
            CUDA_CHECK(cudaGetLastError());
            const auto count=compact_movers();
            if (!count) { if(++empty_joint>=2) break;continue; }
            empty_joint=0;
            apply(count,MovePhase::Group);
            if(maximum()>context.capacity || current_cut>=best_cut)
                throw std::runtime_error("joint exchange violated cut/capacity");
            best_cut=current_cut;
        }
    }
    // Every committed batch updates the exact affected-edge cut. Strict mode
    // additionally checks the entire CSR; production reuses the maintained cut.
    rebalance_graph.reset();
    stats.final_cut=options.strict_verify ? context.cut() : current_cut;
    stats.final_max_part_weight=maximum();
    if (stats.final_cut!=best_cut || stats.final_cut>feasible_start_cut || maximum()>context.capacity)
        throw std::runtime_error("incremental refinement postcondition failed");
    stats.seconds=std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count();
    return stats;
}

RefineStats run_incremental_refinement(
    RefineDeviceContext& context,const RefineOptions& options,int rounds) {
    if (context.graph.incident_weight_bound<=std::numeric_limits<std::uint32_t>::max())
        return run_incremental_refinement_typed<std::uint32_t>(context,options,rounds);
    return run_incremental_refinement_typed<std::uint64_t>(context,options,rounds);
}
