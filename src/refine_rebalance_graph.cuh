#pragma once
// Included in gpart after the ordinary rebalance kernels. This changes
// GPU repair loop with source loss quotas and receiver weight tickets.
namespace {
struct RebalanceLoopState {
    std::int64_t delta=0;
    std::uint64_t gain=0,loss=0,movers=0;
    int iterations=0,batches=0,feasible=0,validation_errors=0;
};

// Compact one selected warp with one reservation. All physical lanes
// participate in ballot/shuffle, including the padded last warp. Selection
// is unchanged; exact cut/cache updates own edges by vertex ID, not list order.
// All points in overloaded sources remain eligible, including interior
// vertices. Only non-overloaded sources are removed from subsequent scans.
template <typename V>
__global__ void collect_rebalance_donors(std::int64_t n,const V* labels,
    const unsigned long long* loads,std::uint64_t capacity,V* donors,std::int64_t* count) {
    const auto v=static_cast<std::int64_t>(blockIdx.x)*blockDim.x+threadIdx.x;
    append_warp(static_cast<V>(v),v<n && loads[labels[v]]>capacity,
        donors,reinterpret_cast<unsigned long long*>(count));
}

template <typename V>
__global__ void compact_rebalance_movers(std::int64_t n,const int* flags,V* movers,std::int64_t* count,
    const V* donors=nullptr,const std::int64_t* donor_count=nullptr) {
    const auto limit=donor_count ? *donor_count : n;
    for(auto base=static_cast<std::int64_t>(blockIdx.x)*blockDim.x;base<limit;
        base+=static_cast<std::int64_t>(gridDim.x)*blockDim.x) {
        const auto index=base+threadIdx.x;
        const auto v=index<limit ? (donors ? donors[index] : static_cast<V>(index)) : V{0};
        append_warp(v,index<limit && flags[v],movers,reinterpret_cast<unsigned long long*>(count));
    }
}

// Strict-mode oracle: independently sum all 800 entries in source order.
__global__ void validate_balance_prefix(const unsigned long long* counts,
    const unsigned long long* prefix,RebalanceLoopState* state) {
    if (threadIdx.x) return;
    unsigned long long expected=0;
    for (int b=0;b<kBalanceWidth;++b) {
        const auto index=blockIdx.x*kBalanceWidth+b;
        if (prefix[index]!=expected) atomicAdd(&state->validation_errors,1);
        expected+=counts[index];
    }
}

__global__ void finish_rebalance_iteration(int k,const unsigned long long* loads,
    std::uint64_t capacity,const std::int64_t* count,const std::int64_t* delta,
    RebalanceLoopState* state,cudaGraphConditionalHandle condition) {
    if (threadIdx.x) return;
    ++state->iterations;
    if (*count) {
        ++state->batches;
        state->movers+=*count;state->delta+=*delta;
        if (*delta>=0) state->gain+=*delta;
        else state->loss+=static_cast<std::uint64_t>(-*delta);
    }
    unsigned long long largest=0;
    for (int p=0;p<k;++p) largest=max(largest,loads[p]);
    state->feasible=largest<=capacity;
    cudaGraphSetConditional(condition,!state->validation_errors && !state->feasible && *count && state->iterations<2*k+4);
}

__global__ void initialize_receiver_slack(int k,const unsigned long long* loads,
    std::uint64_t capacity,unsigned long long* slack,unsigned long long* requests) {
    for (int p=threadIdx.x;p<k;p+=blockDim.x) {
        slack[p]=loads[p]<capacity ? capacity-loads[p] : 0;requests[p]=0;
    }
}

__device__ unsigned long long load_receiver_slack(unsigned long long* value) {
    cuda::atomic_ref<unsigned long long,cuda::thread_scope_device> ref(*value);
    return ref.load(cuda::memory_order_relaxed);
}

template <typename V,typename W>
__global__ void count_receiver_admissions(std::int64_t n,const int* flags,
    const int* targets,const W* weights,unsigned long long* counts) {
    const auto v=static_cast<std::int64_t>(blockIdx.x)*blockDim.x+threadIdx.x;
    if(v<n && flags[v]) atomicAdd(counts+targets[v],static_cast<unsigned long long>(weights[v]));
}

__global__ void check_receiver_admissions(int k,const unsigned long long* counts,
    const unsigned long long* slack,RebalanceLoopState* state) {
    for (int p=threadIdx.x;p<k;p+=blockDim.x)
        if(counts[p]>slack[p]) atomicAdd(&state->validation_errors,1);
}

// Preserve the source loss/weight quota. Within each destination, a warp
// reserves a whole-vertex weighted prefix with one fetch-add; unreserved donors
// try their next-best destination in this same repair batch.
template <typename V,typename W,typename C,int Words=2>
__global__ void reserve_receiver_prefixes(std::int64_t n,int k,const V* labels,
    const W* weights,AffinityView<C> cache,const int* ids,const std::uint64_t* ranks,
    const unsigned long long* prefix,const unsigned long long* loads,
    std::uint64_t capacity,const unsigned long long* slack,
    unsigned long long* requests,int* targets,int* flags,
    const V* donors=nullptr,const std::int64_t* donor_count=nullptr) {
    const int lane=threadIdx.x&31;
    const auto limit=donor_count ? *donor_count : n;
    for(auto base=static_cast<std::int64_t>(blockIdx.x)*blockDim.x;base<limit;
        base+=static_cast<std::int64_t>(gridDim.x)*blockDim.x) {
    const auto index=base+threadIdx.x;
    const auto v=index<limit ? (donors ? donors[index] : static_cast<V>(index)) : V{0};
    bool donor=false,done=false;
    unsigned long long weight=0;
    unsigned long long tried[Words]={};
    if(index<limit) {
        flags[v]=0;
        const int b=ids[v];
        if(b>=0 && prefix[b]+ranks[v]<loads[b/kBalanceWidth]-capacity) {
            donor=true;weight=weights[v];
        }
    }
    for(int attempt=0;attempt<k;++attempt) {
        int target=-1;
        if(donor && !done) {
            if(!attempt) target=targets[v];
            else {
                C best=0;unsigned long long room=0;
                for(int p=0;p<k;++p) {
                    if(p==labels[v] || (tried[p/64]&(1ULL<<(p&63)))) continue;
                    const auto taken=load_receiver_slack(requests+p);
                    const auto available=taken<slack[p] ? slack[p]-taken : 0ULL;
                    if(available<weight) continue;
                    const auto connection=cache.get(v,p);
                    if(target<0 || connection>best || (connection==best && available>room)) {
                        target=p;best=connection;room=available;
                    }
                }
            }
        }
        const auto active=__ballot_sync(0xffffffffU,target>=0);
        if(!active) break;
        if(target<0) continue;
        tried[target/64]|=1ULL<<(target&63);
        const auto group=__match_any_sync(active,target);
        const int leader=__ffs(group)-1;
        unsigned long long before=0,total=0;
        if(__all_sync(group,weight==1)) {
            before=__popc(group&((1U<<lane)-1));total=__popc(group);
        } else {
            for(auto peers=group;peers;peers&=peers-1) {
                const int peer=__ffs(peers)-1;
                const auto value=__shfl_sync(group,weight,peer);
                total+=value;
                if(peer<lane) before+=value;
            }
        }
        const auto end=before+weight;
        auto begin=lane==leader ? atomicAdd(requests+target,total) : 0ULL;
        begin=__shfl_sync(group,begin,leader);
        const auto room=slack[target];
        // Virtual ticket ranges may exceed capacity; only complete vertices
        // whose ranges lie inside the immutable room are actually admitted.
        // A vertex requests each part at most once, bounding every counter
        // by the total donor weight and avoiding retry contention.
        if(begin<=room && end<=room-begin) { targets[v]=target;flags[v]=1;done=true; }
    }
    if(index<limit && !flags[v]) targets[v]=-1;
    }
}

// A graph is instantiated once per refined layer, then reused by every LP
// phase. Both its setup and destruction remain inside the algorithm timer.
template <typename CacheT>
class RebalanceGraph {
    cudaGraph_t graph_=nullptr;
    cudaGraphExec_t executable_=nullptr;
    cudaGraphNode_t node_=nullptr;
    cudaGraphConditionalHandle condition_{};
    cudaStream_t stream_=nullptr;
    cudaEvent_t ready_=nullptr;
    detail::ScratchBuffer<std::int64_t> count_;
    detail::ScratchBuffer<gpart::GraphTypes::VertexT> donors_;
    detail::ScratchBuffer<std::int64_t> donor_count_;
    detail::ScratchBuffer<RebalanceLoopState> state_;
    detail::ScratchBuffer<unsigned long long> receiver_slack_;
    detail::ScratchBuffer<unsigned long long> receiver_requests_;
public:
    RebalanceGraph(RefineDeviceContext& c,AffinityView<CacheT> cache,int k,RepairSample* samples,bool verify,
        const gpart::GraphTypes::VertexT* heavy_rows,unsigned int heavy_count,
        cudaGraph_t external_root=nullptr,cudaGraph_t parent=nullptr) {
        auto& w=c.workspace;
        const auto n=c.n;
        auto* labels=thrust::raw_pointer_cast(c.partition.data());
        auto* loads=thrust::raw_pointer_cast(c.part_weights.data());
        auto* targets=thrust::raw_pointer_cast(w.incremental_targets.data());
        auto* flags=thrust::raw_pointer_cast(w.incremental_flags.data());
        auto* movers=thrust::raw_pointer_cast(w.incremental_movers.data());
        auto* locks=thrust::raw_pointer_cast(w.incremental_locks.data());
        auto* delta=thrust::raw_pointer_cast(w.incremental_delta.data());
        auto* ids=thrust::raw_pointer_cast(w.balance_bucket_ids.data());
        auto* ranks=thrust::raw_pointer_cast(w.balance_bucket_ranks.data());
        auto* counts=thrust::raw_pointer_cast(w.balance_bucket_counts.data());
        auto* prefix=thrust::raw_pointer_cast(w.balance_bucket_offsets.data());
        auto* vw=thrust::raw_pointer_cast(c.graph.vertex_weights.data());
        auto* offsets=thrust::raw_pointer_cast(c.graph.offsets.data());
        auto* neighbors=thrust::raw_pointer_cast(c.graph.neighbors.data());
        auto* edges=thrust::raw_pointer_cast(c.graph.edge_weights.data());
        count_.resize(1);state_.resize(1);receiver_slack_.resize(k);receiver_requests_.resize(k);
        auto* count=thrust::raw_pointer_cast(count_.data());
        const bool compact_donors=n>=65536;
        if(compact_donors) { donors_.resize(n);donor_count_.resize(1); }
        auto* donors=compact_donors ? thrust::raw_pointer_cast(donors_.data()) : nullptr;
        auto* donor_count=compact_donors ? thrust::raw_pointer_cast(donor_count_.data()) : nullptr;
        const int donor_blocks=compact_donors ? std::min(c.vertex_blocks,2048) : c.vertex_blocks;
        CUDA_CHECK(cudaStreamCreateWithFlags(&stream_,cudaStreamNonBlocking));
        CUDA_CHECK(cudaEventCreateWithFlags(&ready_,cudaEventDisableTiming));
        if (!external_root) CUDA_CHECK(cudaGraphCreate(&graph_,0));
        const auto root=external_root ? external_root : graph_;
        if (!parent) parent=root;
        CUDA_CHECK(cudaGraphConditionalHandleCreate(&condition_,root,external_root ? 0 : 1,cudaGraphCondAssignDefault));
        const auto condition=condition_;
        cudaGraphNodeParams params{};params.type=cudaGraphNodeTypeConditional;
        params.conditional.handle=condition;params.conditional.type=cudaGraphCondTypeWhile;
        params.conditional.size=1;
        CUDA_CHECK(cudaGraphAddNode(&node_,parent,nullptr,nullptr,0,&params));
        const auto body=params.conditional.phGraph_out[0];
        CUDA_CHECK(cudaStreamBeginCaptureToGraph(stream_,body,nullptr,nullptr,0,cudaStreamCaptureModeThreadLocal));
        const auto histogram_bytes=k*kBalanceWidth*sizeof(unsigned long long);
        if(compact_donors) {
            CUDA_CHECK(cudaMemsetAsync(flags,0,n*sizeof(*flags),stream_));
            CUDA_CHECK(cudaMemsetAsync(donor_count,0,sizeof(*donor_count),stream_));
            collect_rebalance_donors<<<c.vertex_blocks,256,0,stream_>>>(n,labels,loads,c.capacity,donors,donor_count);
        }
        CUDA_CHECK(cudaMemsetAsync(counts,0,histogram_bytes,stream_));
        incremental_rebalance_proposals<<<donor_blocks,256,0,stream_>>>(n,cache,labels,vw,k,loads,c.capacity,targets,ids,ranks,counts,donors,donor_count);
        balance_scan_buckets<<<k,32,0,stream_>>>(counts,prefix);
        if (verify) validate_balance_prefix<<<k,32,0,stream_>>>(counts,prefix,thrust::raw_pointer_cast(state_.data()));
        initialize_receiver_slack<<<1,32,0,stream_>>>(k,loads,c.capacity,thrust::raw_pointer_cast(receiver_slack_.data()),thrust::raw_pointer_cast(receiver_requests_.data()));
        reserve_receiver_prefixes<<<donor_blocks,256,0,stream_>>>(n,k,labels,vw,cache,ids,ranks,prefix,loads,c.capacity,thrust::raw_pointer_cast(receiver_slack_.data()),thrust::raw_pointer_cast(receiver_requests_.data()),targets,flags,donors,donor_count);
        if(verify) {
            CUDA_CHECK(cudaMemsetAsync(counts,0,k*sizeof(*counts),stream_));
            count_receiver_admissions<gpart::GraphTypes::VertexT><<<c.vertex_blocks,256,0,stream_>>>(n,flags,targets,vw,counts);
            check_receiver_admissions<<<1,32,0,stream_>>>(k,counts,thrust::raw_pointer_cast(receiver_slack_.data()),thrust::raw_pointer_cast(state_.data()));
        }
        CUDA_CHECK(cudaMemsetAsync(count,0,sizeof(*count),stream_));
        compact_rebalance_movers<<<donor_blocks,256,0,stream_>>>(n,flags,movers,count,donors,donor_count);
        CUDA_CHECK(cudaMemsetAsync(delta,0,sizeof(*delta),stream_));
        if (cache.sparse()) CUDA_CHECK(cudaMemsetAsync(cache.dirty_count,0,sizeof(*cache.dirty_count),stream_));
        incremental_update_cache_and_cut<<<std::min(c.warp_blocks,2048),256,0,stream_>>>(n,movers,offsets,neighbors,edges,labels,targets,flags,k,cache,delta,vw,samples,heavy_count!=0,count);
        if (heavy_count)
            incremental_heavy_update_cache_and_cut<<<heavy_count*kRefineHeavyBlocks,256,0,stream_>>>(heavy_rows,offsets,neighbors,edges,labels,targets,flags,k,cache,delta,vw,samples);
        incremental_commit<<<std::min(c.vertex_blocks,2048),256,0,stream_>>>(n,movers,labels,targets,vw,loads,locks,false,cache,count);
        if (cache.sparse())
            launch_affinity_build(n,offsets,neighbors,edges,labels,k,cache,
                static_cast<gpart::GraphTypes::VertexT*>(nullptr),static_cast<unsigned int*>(nullptr),static_cast<CacheT*>(nullptr),true,stream_);
        finish_rebalance_iteration<<<1,32,0,stream_>>>(k,loads,c.capacity,count,delta,thrust::raw_pointer_cast(state_.data()),condition);
        CUDA_CHECK(cudaGetLastError());
        cudaGraph_t captured;
        CUDA_CHECK(cudaStreamEndCapture(stream_,&captured));
        if (!external_root) CUDA_CHECK(cudaGraphInstantiate(&executable_,graph_,0));
    }
    ~RebalanceGraph() {
        if (executable_) cudaGraphExecDestroy(executable_);
        if (graph_) cudaGraphDestroy(graph_);
        if (stream_) cudaStreamDestroy(stream_);
        if (ready_) cudaEventDestroy(ready_);
    }
    RebalanceGraph(const RebalanceGraph&)=delete;
    RebalanceGraph& operator=(const RebalanceGraph&)=delete;
    cudaGraphNode_t node() const { return node_; }
    cudaGraphConditionalHandle condition() const { return condition_; }
    RebalanceLoopState* state() { return thrust::raw_pointer_cast(state_.data()); }
    RebalanceLoopState run() {
        // Scratch allocations and preceding LP updates belong to stream 0.
        // Capture only records kernels; execution must wait for their inputs.
        CUDA_CHECK(cudaEventRecord(ready_,nullptr));
        CUDA_CHECK(cudaStreamWaitEvent(stream_,ready_,0));
        CUDA_CHECK(cudaMemsetAsync(thrust::raw_pointer_cast(state_.data()),0,sizeof(RebalanceLoopState),stream_));
        CUDA_CHECK(cudaGraphLaunch(executable_,stream_));
        RebalanceLoopState state;
        CUDA_CHECK(cudaMemcpyAsync(&state,thrust::raw_pointer_cast(state_.data()),sizeof(state),cudaMemcpyDeviceToHost,stream_));
        CUDA_CHECK(cudaStreamSynchronize(stream_));
        return state;
    }
};
} // namespace
