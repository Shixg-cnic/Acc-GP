#pragma once
// Included inside namespace gpart after RefineDeviceContext and gain validation.
// Jet supplies the exploration / priority-correction reference. This CUDA
// implementation uses a dense affinity cache for small k, fused exact cut/cache
// updates, and source-quota plus destination-capacity GPU rebalancing.
namespace {
constexpr std::int64_t kRefineHeavyDegree=4096;
constexpr int kRefineHeavyBlocks=32;

template <typename OffsetT, typename VertexT, typename WeightT,typename CacheT>
__global__ void incremental_build_affinity(
    std::int64_t n, const OffsetT* offsets, const VertexT* neighbors,
    const WeightT* weights, const VertexT* labels, int k, CacheT* cache,
    VertexT* heavy_rows=nullptr,unsigned int* heavy_count=nullptr) {
    const int lane=threadIdx.x&31;
    const int warp=threadIdx.x/32;
    const auto v=static_cast<std::int64_t>(blockIdx.x)*8+warp;
    if (v>=n) return;
    if (!lane && heavy_rows && offsets[v+1]-offsets[v]>=kRefineHeavyDegree)
        heavy_rows[atomicAdd(heavy_count,1U)]=static_cast<VertexT>(v);
    using SumT=std::conditional_t<sizeof(CacheT)==4,unsigned int,unsigned long long>;
    __shared__ SumT values[8*32];
    auto* row=values+warp*32;
    row[lane]=0;
    __syncwarp();
    for (std::int64_t e=static_cast<std::int64_t>(offsets[v])+lane; e<offsets[v+1]; e+=32) {
        const auto u=neighbors[e];
        if (u!=v) atomicAdd(row+labels[u],static_cast<SumT>(weights[e]));
    }
    __syncwarp();
    if (lane<k) cache[v*k+lane]=row[lane];
}

__device__ double estimated_repair_cost(int part,std::uint64_t weight,
    const unsigned long long* loads,std::uint64_t capacity,const double* prices) {
    const auto slack=capacity-loads[part];
    return weight>slack ? prices[part]*static_cast<double>(weight-slack) : 0.0;
}
__global__ void publish_repair_prices(int k,const RepairSample* samples,double* prices) {
    const int p=threadIdx.x;
    if (p<k && samples[p].weight)
        prices[p]=samples[p].loss>0 ? static_cast<double>(samples[p].loss)/samples[p].weight : 0.0;
}

template <typename VertexT,typename WeightT,typename CacheT>
__global__ void incremental_lp_proposals(
    std::int64_t n, const CacheT* cache, const VertexT* labels, int k,
    double filter,const WeightT* vertex_weights,const unsigned long long* loads,
    std::uint64_t capacity,const double* prices,
    std::int32_t* locks, std::int32_t* targets, std::int64_t* gains) {
    const auto v=static_cast<std::int64_t>(blockIdx.x)*blockDim.x+threadIdx.x;
    if (v>=n) return;
    targets[v]=-1;gains[v]=INT64_MIN;
    if (locks[v]) { locks[v]=0;return; }
    const auto source=labels[v];
    std::uint64_t best=0;
    int target=-1;
    double best_score=-DBL_MAX;
    for (int p=0;p<k;++p) {
        const auto connection=cache[v*k+p];
        if (p==source || !connection) continue;
        if (prices) {
            const double score=static_cast<double>(connection)-estimated_repair_cost(p,vertex_weights[v],loads,capacity,prices);
            if (score>best_score) { best_score=score;best=connection;target=p; }
        } else if (connection>best) { best=connection;target=p; }
    }
    const auto current=cache[v*k+source];
    if (target>=0 && (best>=current || current-best<static_cast<std::uint64_t>(filter*current))) {
        targets[v]=target;
        gains[v]=best>=current ? static_cast<std::int64_t>(best-current) : -static_cast<std::int64_t>(current-best);
    }
}

template <typename OffsetT, typename VertexT, typename WeightT>
__global__ void incremental_priority_filter(
    std::int64_t n,const OffsetT* offsets,const VertexT* neighbors,const WeightT* weights,
    const VertexT* labels,const std::int32_t* targets,const std::int64_t* gains,
    const WeightT* vertex_weights,const unsigned long long* loads,
    std::uint64_t capacity,const double* prices,std::int32_t* flags,bool split_heavy) {
    const int lane=threadIdx.x&31;
    const auto v=static_cast<std::int64_t>(blockIdx.x)*8+threadIdx.x/32;
    if (v>=n) return;
    if (targets[v]<0) { if (!lane) flags[v]=0;return; }
    if (split_heavy && offsets[v+1]-offsets[v]>=kRefineHeavyDegree) return;
    const auto source=labels[v],target=targets[v];
    const auto gain=gains[v];
    long long correction=0;
    for (std::int64_t e=static_cast<std::int64_t>(offsets[v])+lane;e<offsets[v+1];e+=32) {
        const auto u=neighbors[e];
        if (u==v || targets[u]<0 || !(gains[u]>gain || (gains[u]==gain && u<v))) continue;
        const auto w=static_cast<long long>(weights[e]);
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
        correction+=static_cast<long long>(weights[e])*
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
    const std::int32_t* targets,const std::int32_t* flags,int k,CacheT* cache) {
    if (u==v) return 0;
    const auto source=labels[v],target=targets[v];
    const auto weight=static_cast<unsigned long long>(edge_weight);
    if constexpr (sizeof(CacheT)==4) {
        atomicAdd(cache+static_cast<std::int64_t>(u)*k+source,0U-static_cast<unsigned int>(weight));
        atomicAdd(cache+static_cast<std::int64_t>(u)*k+target,static_cast<unsigned int>(weight));
    } else {
        atomicAdd(reinterpret_cast<unsigned long long*>(cache+static_cast<std::int64_t>(u)*k+source),0ULL-weight);
        atomicAdd(reinterpret_cast<unsigned long long*>(cache+static_cast<std::int64_t>(u)*k+target),weight);
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
    int k,CacheT* cache,std::int64_t* delta,
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
        gain+=incremental_update_edge(v,neighbors[e],weights[e],labels,targets,flags,k,cache);
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
    const std::int32_t* flags,int k,CacheT* cache,std::int64_t* delta,
    const WeightT* vertex_weights,RepairSample* samples) {
    const auto v=heavy_rows[blockIdx.x/kRefineHeavyBlocks];
    if (!flags[v]) return;
    long long gain=0;
    for (std::int64_t e=static_cast<std::int64_t>(offsets[v])+
            (blockIdx.x%kRefineHeavyBlocks)*blockDim.x+threadIdx.x;
         e<offsets[v+1];e+=kRefineHeavyBlocks*blockDim.x)
        gain+=incremental_update_edge(v,neighbors[e],weights[e],labels,targets,flags,k,cache);
    for (int shift=16;shift;shift/=2) gain+=__shfl_down_sync(0xffffffffU,gain,shift);
    if (!(threadIdx.x&31)) {
        atomicAdd(reinterpret_cast<unsigned long long*>(delta),static_cast<unsigned long long>(gain));
        if (samples) atomicAdd(reinterpret_cast<unsigned long long*>(&samples[labels[v]].loss),
                               static_cast<unsigned long long>(-gain));
    }
    if (samples && !(blockIdx.x%kRefineHeavyBlocks) && !threadIdx.x)
        atomicAdd(&samples[labels[v]].weight,static_cast<unsigned long long>(vertex_weights[v]));
}

template <typename VertexT,typename WeightT>
__global__ void incremental_commit(
    std::int64_t count,const VertexT* movers,VertexT* labels,const std::int32_t* targets,
    const WeightT* vertex_weights,unsigned long long* part_weights,std::int32_t* locks,bool lp,
    const std::int64_t* live_count=nullptr) {
    if (live_count) count=*live_count;
    for (auto i=static_cast<std::int64_t>(blockIdx.x)*blockDim.x+threadIdx.x; i<count; i+=static_cast<std::int64_t>(gridDim.x)*blockDim.x) {
    const auto v=movers[i],source=labels[v];
    const auto target=targets[v];
    const auto weight=static_cast<unsigned long long>(vertex_weights[v]);
    atomicAdd(part_weights+source,0ULL-weight);atomicAdd(part_weights+target,weight);
    labels[v]=static_cast<VertexT>(target);
    if (lp) locks[v]=1;
    }
}

template <typename VertexT,typename WeightT,typename CacheT>
__global__ void incremental_rebalance_proposals(
    std::int64_t n,const CacheT* cache,const VertexT* labels,const WeightT* vertex_weights,
    int k,const unsigned long long* part_weights,std::uint64_t capacity,
    std::int32_t* targets,RebalanceProposal* proposals) {
    const auto v=static_cast<std::int64_t>(blockIdx.x)*blockDim.x+threadIdx.x;
    if (v>=n) return;
    RebalanceProposal proposal{kInvalidTarget, 0.0};
    const auto source=labels[v];
    const auto weight=static_cast<std::uint64_t>(vertex_weights[v]);
    targets[v]=-1;
    if (part_weights[source]>capacity) {
        int best=-1;
        std::uint64_t best_conn=0,best_slack=0;
        for (int p=0;p<k;++p) {
            if (p==source || part_weights[p]>=capacity || weight>capacity-part_weights[p]) continue;
            const auto value=cache[v*k+p];
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
            const auto current=cache[v*k+source];
            const double gain=best_conn>=current ? static_cast<double>(best_conn-current) : -static_cast<double>(current-best_conn);
            proposal.source=source;
            // Score loss by actual overload relief: a vertex heavier than
            // the excess cannot provide more than that excess in this step.
            // This normalization also appears in Jet's strong rebalance.
            const auto excess=static_cast<std::uint64_t>(part_weights[source]-capacity);
            const auto relief=weight<excess ? weight : excess;
            proposal.gain_per_weight=gain/relief;
            targets[v]=best;
        }
    }
    proposals[v]=proposal;
}

struct IncrementalFlag {
    __host__ __device__ bool operator()(std::int32_t flag) const { return flag!=0; }
};

constexpr int kBalanceBuckets=50;
constexpr int kBalanceSections=16;
constexpr int kBalanceWidth=kBalanceBuckets*kBalanceSections;

__device__ int balance_gain_bucket(double gain) {
    if (gain>0) return 0;
    if (gain==0) return 1;
    return max(2,min(49,25+static_cast<int>(ceil(log(-gain)/log(1.5)))));
}

template <typename WeightT>
__global__ void balance_source_histogram(
    std::int64_t n,const RebalanceProposal* proposals,const WeightT* weights,
    std::int32_t* bucket_ids,std::uint64_t* ranks,unsigned long long* counts) {
    const auto v=static_cast<std::int64_t>(blockIdx.x)*blockDim.x+threadIdx.x;
    if (v>=n) return;
    const auto proposal=proposals[v];
    bucket_ids[v]=-1;
    if (proposal.source==kInvalidTarget) return;
    const int bucket=proposal.source*kBalanceWidth+balance_gain_bucket(proposal.gain_per_weight)*kBalanceSections+
        refine_mix32(static_cast<std::uint32_t>(v))%kBalanceSections;
    bucket_ids[v]=bucket;
    ranks[v]=atomicAdd(counts+bucket,static_cast<unsigned long long>(weights[v]));
}

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

template <typename Types,typename CacheT>
RefineStats run_incremental_refinement_typed(
    RefineDeviceContext<Types>& context,const RefineOptions& options,int rounds) {
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
    ws.grow(affinity,static_cast<std::size_t>(n)*k);
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
    auto* cache=thrust::raw_pointer_cast(affinity.data());
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
    thrust::fill(ws.incremental_locks.begin(),ws.incremental_locks.begin()+n,0);
    incremental_build_affinity<<<context.warp_blocks,256>>>(n,offsets,neighbors,weights,labels,k,cache,heavy_rows,heavy_count_device);
    CUDA_CHECK(cudaGetLastError());
    RefineStats stats;
    stats.affinity_counter_bits=sizeof(CacheT)*8;
    stats.initial_cut=context.cut();
    unsigned int heavy_count=0;
    if (heavy_bound) CUDA_CHECK(cudaMemcpy(&heavy_count,heavy_count_device,sizeof(heavy_count),cudaMemcpyDeviceToHost));
    if (heavy_count>heavy_bound) throw std::runtime_error("refinement heavy-row queue overflow");
    auto current_cut=stats.initial_cut,best_cut=current_cut;
    std::uint64_t revision=0,best_revision=0;
    const auto checkpoint=[&]() {
        thrust::copy(context.partition.begin(),context.partition.end(),ws.previous_partition.begin());
        thrust::copy(context.part_weights.begin(),context.part_weights.end(),ws.previous_part_weights.begin());
        best_revision=revision;
    };
    checkpoint();
    const auto maximum=[&]() { return *std::max_element(context.host_part_weights.begin(),context.host_part_weights.end()); };
    const auto all=thrust::make_counting_iterator<typename Types::VertexT>(0);
    const auto compact_movers=[&]() {
        const auto end=thrust::copy_if(thrust::device,all,all+n,ws.incremental_flags.begin(),ws.incremental_movers.begin(),IncrementalFlag{});
        return static_cast<std::int64_t>(end-ws.incremental_movers.begin());
    };
    enum class MovePhase { LP, Group };
    const auto apply=[&](std::int64_t count,MovePhase phase) {
        CUDA_CHECK(cudaMemset(thrust::raw_pointer_cast(ws.incremental_delta.data()),0,sizeof(std::int64_t)));
        incremental_update_cache_and_cut<<<static_cast<int>((count+7)/8),256>>>(count,movers,offsets,neighbors,weights,labels,targets,flags,k,cache,thrust::raw_pointer_cast(ws.incremental_delta.data()),vertex_weights,nullptr,heavy_count!=0);
        CUDA_CHECK(cudaGetLastError());
        if (heavy_count) {
            incremental_heavy_update_cache_and_cut<<<heavy_count*kRefineHeavyBlocks,256>>>(heavy_rows,offsets,neighbors,weights,labels,targets,flags,k,cache,thrust::raw_pointer_cast(ws.incremental_delta.data()),vertex_weights,static_cast<RepairSample*>(nullptr));
            CUDA_CHECK(cudaGetLastError());
        }
        incremental_commit<<<static_cast<int>((count+255)/256),256>>>(count,movers,labels,targets,vertex_weights,part_weights,locks,phase==MovePhase::LP);
        CUDA_CHECK(cudaGetLastError());
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
            detail::ScratchVector<std::uint64_t> check_cache(static_cast<std::size_t>(n)*k);
            incremental_build_affinity<<<context.warp_blocks,256>>>(n,offsets,neighbors,weights,labels,k,thrust::raw_pointer_cast(check_cache.data()));
            CUDA_CHECK(cudaGetLastError());
            if (!thrust::equal(check_cache.begin(),check_cache.end(),affinity.begin()))
                throw std::runtime_error("incremental affinity cache differs from CSR rebuild");
        }
    };
    std::unique_ptr<RebalanceGraph<Types,CacheT>> rebalance_graph;
    const auto rebalance=[&]() {
        if (maximum()<=context.capacity) return true;
        if (!rebalance_graph) rebalance_graph=std::make_unique<RebalanceGraph<Types,CacheT>>(context,cache,k,samples,options.strict_verify,heavy_rows,heavy_count);
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
            detail::ScratchVector<std::uint64_t> check(static_cast<std::size_t>(n)*k);
            incremental_build_affinity<<<context.warp_blocks,256>>>(n,offsets,neighbors,weights,labels,k,thrust::raw_pointer_cast(check.data()));
            CUDA_CHECK(cudaGetLastError());
            if (!thrust::equal(check.begin(),check.end(),affinity.begin())) throw std::runtime_error("GPU rebalance cache mismatch");
        }
        return state.feasible!=0;
    };
    using WeightT=typename Types::WeightT;
    const auto maximum_edge=thrust::reduce(graph.edge_weights.begin(),graph.edge_weights.end(),WeightT{0},thrust::maximum<WeightT>());
    const double filter=maximum_edge<=1 ? 0.25 : 0.75;
    int stale=0,empty=0;
    for (int phase=0;phase<rounds && stale<options.stale_rounds;++phase) {
        stats.rounds=phase+1;
        if (samples) CUDA_CHECK(cudaMemset(samples,0,k*sizeof(RepairSample)));
        incremental_lp_proposals<<<context.vertex_blocks,256>>>(n,cache,labels,k,filter,vertex_weights,part_weights,context.capacity,prices,locks,targets,gains);
        CUDA_CHECK(cudaGetLastError());
        incremental_priority_filter<<<context.warp_blocks,256>>>(n,offsets,neighbors,weights,labels,targets,gains,vertex_weights,part_weights,context.capacity,prices,flags,heavy_count!=0);
        CUDA_CHECK(cudaGetLastError());
        if (heavy_count) {
            CUDA_CHECK(cudaMemset(heavy_corrections,0,heavy_count*sizeof(std::int64_t)));
            incremental_heavy_priority<<<heavy_count*kRefineHeavyBlocks,256>>>(heavy_rows,offsets,neighbors,weights,labels,targets,gains,heavy_corrections);
            CUDA_CHECK(cudaGetLastError());
            incremental_finish_heavy_priority<<<(heavy_count+255)/256,256>>>(static_cast<int>(heavy_count),heavy_rows,labels,targets,gains,heavy_corrections,vertex_weights,part_weights,context.capacity,prices,flags);
            CUDA_CHECK(cudaGetLastError());
        }
        const auto count=compact_movers();
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
    stats.checkpoint_discarded_cut=current_cut>best_cut ? current_cut-best_cut : 0;
    const bool restored=revision!=best_revision;
    if (restored) {
        thrust::copy(ws.previous_partition.begin(),ws.previous_partition.begin()+n,context.partition.begin());
        thrust::copy(ws.previous_part_weights.begin(),ws.previous_part_weights.begin()+k,context.part_weights.begin());
        context.sync_part_weights();
    }
    current_cut=best_cut;
    // Restrict group search to small layers; avoid another large original
    // graph scan. Starting from the feasible checkpoint prevents repair losses
    // from contaminating either the shortlist or the transaction capacities.
    if (rounds>0 && options.boundary_group_rounds>0 && n<=65536) {
        ws.grow(ws.boundary_groups,n*kGroupSize);
        ws.grow(ws.group_transactions,k*k);
        ws.grow(ws.group_order,n*kGroupSize);
        ws.grow(ws.group_weight_order,n*kGroupSize);
        ws.grow(ws.group_candidates,n*kGroupSize);
        ws.grow(ws.group_ranges,k*k);
        if (restored) {
            incremental_build_affinity<<<context.warp_blocks,256>>>(n,offsets,neighbors,weights,labels,k,cache);
            CUDA_CHECK(cudaGetLastError());
        }
        for (int pass=0;pass<options.boundary_group_rounds;++pass) {
            auto* groups=thrust::raw_pointer_cast(ws.boundary_groups.data());
            auto* transactions=thrust::raw_pointer_cast(ws.group_transactions.data());
            boundary_group_proposals<<<context.warp_blocks,256>>>(n,offsets,neighbors,weights,vertex_weights,labels,cache,k,groups);
            CUDA_CHECK(cudaGetLastError());
            const int slots=static_cast<int>(n)*kGroupSize;
            auto order_begin=ws.group_order.begin();
            thrust::sequence(order_begin,order_begin+slots);
            thrust::sort(order_begin,order_begin+slots,GroupOrder{groups,labels,k});
            const auto unique_end=thrust::unique(order_begin,order_begin+slots,SameGroup{groups,labels,k});
            auto* order=thrust::raw_pointer_cast(ws.group_order.data());
            const auto end=thrust::copy_if(thrust::device,order_begin,unique_end,
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
            group_tree_leaves<<<(base+255)/256,256>>>(base,candidates,tree);
            CUDA_CHECK(cudaGetLastError());
            for (int begin=base/2;begin;begin/=2) {
                group_tree_level<<<(begin+255)/256,256>>>(begin,tree,order,groups);
                CUDA_CHECK(cudaGetLastError());
            }
            auto* proposals=thrust::raw_pointer_cast(ws.group_candidates.data());
            boundary_group_transactions<<<(candidates+7)/8,256>>>(candidates,order,ranges,base,tree,
                offsets,neighbors,weights,labels,k,groups,part_weights,context.capacity,proposals);
            CUDA_CHECK(cudaGetLastError());
            group_reduce_transactions<<<k*k,256>>>(k,ranges,proposals,transactions);
            CUDA_CHECK(cudaGetLastError());
            thrust::sort(ws.group_transactions.begin(),ws.group_transactions.begin()+k*k,TransactionOrder{});
            CUDA_CHECK(cudaMemset(flags,0,n*sizeof(std::int32_t)));
            boundary_group_admit<<<1,1>>>(k,groups,transactions,labels,part_weights,context.capacity,flags,targets);
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
    // Every committed batch updates the exact affected-edge cut. Strict mode
    // additionally checks the entire CSR; production reuses the maintained cut.
    rebalance_graph.reset();
    stats.final_cut=options.strict_verify ? context.cut() : current_cut;
    stats.final_max_part_weight=maximum();
    if (stats.final_cut!=best_cut || stats.final_cut>stats.initial_cut || maximum()>context.capacity)
        throw std::runtime_error("incremental refinement postcondition failed");
    stats.seconds=std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count();
    return stats;
}

template <typename Types>
RefineStats run_incremental_refinement(
    RefineDeviceContext<Types>& context,const RefineOptions& options,int rounds) {
    if (context.graph.incident_weight_bound<=std::numeric_limits<std::uint32_t>::max())
        return run_incremental_refinement_typed<Types,std::uint32_t>(context,options,rounds);
    return run_incremental_refinement_typed<Types,std::uint64_t>(context,options,rounds);
}
