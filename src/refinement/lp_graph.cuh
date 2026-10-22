#pragma once
// Included after the shared LP and repair kernels. The host implementation
// remains available as a reference; this records the same rounds and repair
// rules into one GPU-controlled loop, including conditional checkpoints.
namespace {
// A deliberately simple independent CSR oracle for captured verification.
// No block-wide reduction/barrier state is reused across conditional rounds.
template <typename O,typename V,typename W>
__global__ void lp_verify_directed_cut(std::int64_t n,const O* offsets,
    const V* neighbors,const W* weights,const V* labels,unsigned long long* cut) {
    const auto v=static_cast<std::int64_t>(blockIdx.x)*blockDim.x+threadIdx.x;
    if(v>=n) return;
    unsigned long long sum=0;
    for(auto e=offsets[v];e<offsets[v+1];++e)
        if(labels[v]!=labels[neighbors[e]]) sum+=static_cast<unsigned long long>(detail::edge_weight(weights,e));
    if(sum) atomicAdd(cut,sum);
}

struct LPLoopState {
    RefineStats stats{};
    std::uint64_t cut=0,best=0,revision=0,best_revision=0,last_count=0;
    int stale=0,empty=0,errors=0;
};

__device__ bool lp_update_cut(LPLoopState* state,std::int64_t delta) {
    if (delta>=0) {
        if (static_cast<std::uint64_t>(delta)>state->cut) { state->errors=1;return false; }
        state->cut-=static_cast<std::uint64_t>(delta);
    } else state->cut+=static_cast<std::uint64_t>(-delta);
    return true;
}

__global__ void prepare_lp_repair(int k,const unsigned long long* loads,
    std::uint64_t capacity,const unsigned long long* count,const std::int64_t* delta,
    LPLoopState* state,RebalanceLoopState* repair,cudaGraphConditionalHandle condition,
    const unsigned long long* exact_cut=nullptr,const unsigned int* errors=nullptr) {
    if (threadIdx.x) return;
    ++state->stats.rounds;
    state->last_count=*count;
    state->stats.proposals+=*count;
    if (*count) {
        state->stats.accepted+=*count;++state->revision;
        if (*delta>=0) state->stats.lp_cut_gain+=static_cast<std::uint64_t>(*delta);
        else state->stats.lp_cut_loss+=static_cast<std::uint64_t>(-*delta);
        lp_update_cut(state,*delta);
    }
    if (errors && (*errors || (*exact_cut&1ULL) || *exact_cut/2!=state->cut)) state->errors=1;
    unsigned long long largest=0;
    for (int p=0;p<k;++p) largest=max(largest,loads[p]);
    // No repair body executes for a feasible batch. The empty-batch path
    // leaves prices and checkpoints unchanged, as in the host loop.
    *repair=RebalanceLoopState{};
    repair->feasible=largest<=capacity;
    cudaGraphSetConditional(condition,!state->errors && *count && !repair->feasible);
}

__global__ void finish_lp_round(int rounds,int stale_limit,
    LPLoopState* state,const RebalanceLoopState* repair,
    const RepairSample* samples,double* prices,int k,
    cudaGraphConditionalHandle checkpoint,cudaGraphConditionalHandle loop,
    const unsigned long long* exact_cut=nullptr,const unsigned int* errors=nullptr) {
    if (threadIdx.x) return;
    bool save=false,stop=state->errors!=0;
    if (!state->last_count) {
        if (++state->empty>=2) stop=true;
        else ++state->stale;
    } else {
        state->empty=0;
        state->stats.admission_iterations+=repair->iterations;
        state->stats.accepted+=repair->movers;
        state->stats.rebalance_cut_gain+=repair->gain;
        state->stats.rebalance_cut_loss+=repair->loss;
        state->revision+=repair->batches;
        if (repair->validation_errors || !lp_update_cut(state,repair->delta)) state->errors=1;
        if (!repair->feasible) { ++state->stats.admission_fallbacks;stop=true; }
        else {
            if (prices) for (int p=0;p<k;++p) if (samples[p].weight)
                prices[p]=samples[p].loss>0 ? static_cast<double>(samples[p].loss)/samples[p].weight : 0.0;
            ++state->stale;
            if (state->cut<state->best) {
                // Exact integer form of cut < 0.999 * best, without an
                // overflowing multiplication or device long-double rounding.
                if (state->best-state->cut>state->best/1000) state->stale=0;
                state->best=state->cut;state->best_revision=state->revision;
                ++state->stats.checkpoint_updates;save=true;
            }
        }
    }
    if (errors && (*errors || (*exact_cut&1ULL) || *exact_cut/2!=state->cut)) state->errors=1;
    cudaGraphSetConditional(checkpoint,save && !state->errors);
    cudaGraphSetConditional(loop,!stop && !state->errors && state->stats.rounds<rounds && state->stale<stale_limit);
}

// Every recorded segment is a linear stream chain. Read its final dependency
// before ending capture so it can precede a nested conditional node.
inline cudaGraphNode_t end_lp_capture(cudaStream_t stream) {
    cudaStreamCaptureStatus status;
    const cudaGraphNode_t* dependencies=nullptr;
    std::size_t count=0;
    CUDA_CHECK(cudaStreamGetCaptureInfo(stream,&status,nullptr,nullptr,&dependencies,nullptr,&count));
    if (count!=1) throw std::runtime_error("LP graph capture is not a linear chain");
    const auto last=dependencies[0];
    cudaGraph_t captured=nullptr;
    CUDA_CHECK(cudaStreamEndCapture(stream,&captured));
    return last;
}

template <typename CacheT>
class LPGraph {
    cudaGraph_t graph_=nullptr;
    cudaGraphExec_t executable_=nullptr;
    cudaStream_t stream_=nullptr;
    cudaEvent_t ready_=nullptr;
    detail::ScratchBuffer<LPLoopState> state_;
    detail::ScratchBuffer<unsigned int> errors_;
    std::unique_ptr<RebalanceGraph<CacheT>> repair_;
public:
    LPGraph(RefineDeviceContext& c,AffinityView<CacheT> cache,CacheT* row_totals,
        const RefineOptions& options,int rounds,double filter,double* prices,RepairSample* samples,
        const gpart::GraphTypes::VertexT* heavy_rows,unsigned int heavy_count,std::int64_t* corrections) {
        using V=gpart::GraphTypes::VertexT;
        auto& w=c.workspace;
        const auto n=c.n;
        const int k=options.parts;
        auto* labels=thrust::raw_pointer_cast(c.partition.data());
        auto* loads=thrust::raw_pointer_cast(c.part_weights.data());
        auto* targets=thrust::raw_pointer_cast(w.incremental_targets.data());
        auto* gains=thrust::raw_pointer_cast(w.incremental_gains.data());
        auto* flags=thrust::raw_pointer_cast(w.incremental_flags.data());
        auto* movers=thrust::raw_pointer_cast(w.incremental_movers.data());
        auto* locks=thrust::raw_pointer_cast(w.incremental_locks.data());
        auto* delta=thrust::raw_pointer_cast(w.incremental_delta.data());
        auto* candidates=thrust::raw_pointer_cast(w.balance_bucket_ids.data());
        auto* candidate_count=thrust::raw_pointer_cast(w.cut_counter.data());
        auto* mover_count=thrust::raw_pointer_cast(w.balance_bucket_counts.data());
        auto* boundary_count=mover_count+1;
        auto* vw=thrust::raw_pointer_cast(c.graph.vertex_weights.data());
        auto* offsets=thrust::raw_pointer_cast(c.graph.offsets.data());
        auto* neighbors=thrust::raw_pointer_cast(c.graph.neighbors.data());
        auto* edges=thrust::raw_pointer_cast(c.graph.edge_weights.data());
        state_.resize(1);
        if (options.strict_verify) errors_.resize(1);
        auto* errors=options.strict_verify ? thrust::raw_pointer_cast(errors_.data()) : nullptr;
        auto* exact=options.strict_verify ? candidate_count : nullptr;
        auto* state=thrust::raw_pointer_cast(state_.data());
        CUDA_CHECK(cudaStreamCreateWithFlags(&stream_,cudaStreamNonBlocking));
        CUDA_CHECK(cudaEventCreateWithFlags(&ready_,cudaEventDisableTiming));
        CUDA_CHECK(cudaGraphCreate(&graph_,0));
        cudaGraphConditionalHandle loop,checkpoint;
        CUDA_CHECK(cudaGraphConditionalHandleCreate(&loop,graph_,1,cudaGraphCondAssignDefault));
        CUDA_CHECK(cudaGraphConditionalHandleCreate(&checkpoint,graph_,0,cudaGraphCondAssignDefault));
        cudaGraphNodeParams loop_params{};loop_params.type=cudaGraphNodeTypeConditional;
        loop_params.conditional.handle=loop;loop_params.conditional.type=cudaGraphCondTypeWhile;
        loop_params.conditional.size=1;
        cudaGraphNode_t loop_node;
        CUDA_CHECK(cudaGraphAddNode(&loop_node,graph_,nullptr,nullptr,0,&loop_params));
        const auto body=loop_params.conditional.phGraph_out[0];
        repair_=std::make_unique<RebalanceGraph<CacheT>>(c,cache,k,samples,options.strict_verify,heavy_rows,heavy_count,graph_,body);
        const auto verify=[&]() {
            if (!options.strict_verify) return;
            CUDA_CHECK(cudaMemsetAsync(errors,0,sizeof(*errors),stream_));
            incremental_build_affinity<gpart::GraphTypes::OffsetT,V,gpart::GraphTypes::WeightT,CacheT,true><<<std::min(c.warp_blocks,2048),256,8*k*sizeof(std::uint64_t),stream_>>>(n,offsets,neighbors,edges,labels,k,cache,
                static_cast<V*>(nullptr),static_cast<unsigned int*>(nullptr),row_totals,false,errors);
            CUDA_CHECK(cudaMemsetAsync(exact,0,sizeof(*exact),stream_));
            lp_verify_directed_cut<<<c.vertex_blocks,256,0,stream_>>>(n,offsets,neighbors,edges,labels,exact);
        };
        CUDA_CHECK(cudaStreamBeginCaptureToGraph(stream_,body,nullptr,nullptr,0,cudaStreamCaptureModeThreadLocal));
        if (samples) CUDA_CHECK(cudaMemsetAsync(samples,0,k*sizeof(RepairSample),stream_));
        CUDA_CHECK(cudaMemsetAsync(candidate_count,0,sizeof(*candidate_count),stream_));
        CUDA_CHECK(cudaMemsetAsync(mover_count,0,2*sizeof(*mover_count),stream_));
        if (cache.frontier_count) {
            launch_lp_proposals(std::min(c.warp_blocks,2048),cache.frontier_rows,cache.frontier_count,cache,labels,k,filter,vw,loads,c.capacity,prices,targets,gains,locks,flags,row_totals,stream_);
            incremental_collect_proposals<<<std::min(c.vertex_blocks,1024),256,0,stream_>>>(cache.frontier_rows,cache.frontier_count,targets,candidates,candidate_count);
        } else if (k<=32) {
            incremental_lp_proposals<<<c.vertex_blocks,256,0,stream_>>>(n,cache,row_totals,labels,k,filter,vw,loads,c.capacity,prices,locks,targets,gains,flags,candidates,candidate_count);
        } else {
            incremental_collect_boundaries<<<c.vertex_blocks,256,0,stream_>>>(n,cache,row_totals,labels,k,locks,targets,gains,flags,movers,boundary_count);
            launch_lp_proposals(std::min(c.warp_blocks,2048),movers,boundary_count,cache,labels,k,filter,vw,loads,c.capacity,prices,targets,gains,nullptr,nullptr,static_cast<const CacheT*>(nullptr),stream_);
            incremental_collect_proposals<<<std::min(c.vertex_blocks,1024),256,0,stream_>>>(movers,boundary_count,targets,candidates,candidate_count);
        }
        incremental_priority_filter<<<std::min(c.warp_blocks,1024),256,0,stream_>>>(candidates,candidate_count,offsets,neighbors,edges,labels,targets,gains,vw,loads,c.capacity,prices,flags,heavy_count!=0);
        if (heavy_count) {
            CUDA_CHECK(cudaMemsetAsync(corrections,0,heavy_count*sizeof(*corrections),stream_));
            incremental_heavy_priority<<<heavy_count*kRefineHeavyBlocks,256,0,stream_>>>(heavy_rows,offsets,neighbors,edges,labels,targets,gains,corrections);
            incremental_finish_heavy_priority<<<(heavy_count+255)/256,256,0,stream_>>>(static_cast<int>(heavy_count),heavy_rows,labels,targets,gains,corrections,vw,loads,c.capacity,prices,flags);
        }
        incremental_compact_candidates<<<std::min(c.vertex_blocks,1024),256,0,stream_>>>(candidates,candidate_count,flags,movers,mover_count);
        CUDA_CHECK(cudaMemsetAsync(delta,0,sizeof(*delta),stream_));
        if (cache.sparse()) CUDA_CHECK(cudaMemsetAsync(cache.dirty_count,0,sizeof(*cache.dirty_count),stream_));
        const auto* live_count=reinterpret_cast<const std::int64_t*>(mover_count);
        incremental_update_cache_and_cut<<<std::min(c.warp_blocks,2048),256,0,stream_>>>(n,movers,offsets,neighbors,edges,labels,targets,flags,k,cache,delta,vw,static_cast<RepairSample*>(nullptr),heavy_count!=0,live_count);
        if (heavy_count)
            incremental_heavy_update_cache_and_cut<<<heavy_count*kRefineHeavyBlocks,256,0,stream_>>>(heavy_rows,offsets,neighbors,edges,labels,targets,flags,k,cache,delta,vw,static_cast<RepairSample*>(nullptr));
        incremental_commit<<<std::min(c.vertex_blocks,2048),256,0,stream_>>>(n,movers,labels,targets,vw,loads,locks,true,cache,live_count);
        if (cache.sparse())
            launch_affinity_build(n,offsets,neighbors,edges,labels,k,cache,static_cast<V*>(nullptr),static_cast<unsigned int*>(nullptr),static_cast<CacheT*>(nullptr),true,stream_);
        verify();
        prepare_lp_repair<<<1,32,0,stream_>>>(k,loads,c.capacity,mover_count,delta,state,repair_->state(),repair_->condition(),exact,errors);
        const auto prefix=end_lp_capture(stream_);
        const auto repair_node=repair_->node();
        CUDA_CHECK(cudaGraphAddDependencies(body,&prefix,&repair_node,nullptr,1));
        CUDA_CHECK(cudaStreamBeginCaptureToGraph(stream_,body,&repair_node,nullptr,1,cudaStreamCaptureModeThreadLocal));
        verify();
        finish_lp_round<<<1,32,0,stream_>>>(rounds,options.stale_rounds,state,repair_->state(),samples,prices,k,checkpoint,loop,exact,errors);
        const auto finish=end_lp_capture(stream_);
        cudaGraphNodeParams save_params{};save_params.type=cudaGraphNodeTypeConditional;
        save_params.conditional.handle=checkpoint;save_params.conditional.type=cudaGraphCondTypeIf;
        save_params.conditional.size=1;
        cudaGraphNode_t save_node;
        CUDA_CHECK(cudaGraphAddNode(&save_node,body,&finish,nullptr,1,&save_params));
        CUDA_CHECK(cudaStreamBeginCaptureToGraph(stream_,save_params.conditional.phGraph_out[0],nullptr,nullptr,0,cudaStreamCaptureModeThreadLocal));
        CUDA_CHECK(cudaMemcpyAsync(thrust::raw_pointer_cast(w.previous_partition.data()),labels,n*sizeof(V),cudaMemcpyDeviceToDevice,stream_));
        CUDA_CHECK(cudaMemcpyAsync(thrust::raw_pointer_cast(w.previous_part_weights.data()),loads,k*sizeof(*loads),cudaMemcpyDeviceToDevice,stream_));
        end_lp_capture(stream_);
        CUDA_CHECK(cudaGetLastError());
        CUDA_CHECK(cudaGraphInstantiate(&executable_,graph_,0));
    }
    ~LPGraph() {
        if (executable_) cudaGraphExecDestroy(executable_);
        repair_.reset();
        if (graph_) cudaGraphDestroy(graph_);
        if (stream_) cudaStreamDestroy(stream_);
        if (ready_) cudaEventDestroy(ready_);
    }
    LPGraph(const LPGraph&)=delete;
    LPLoopState run(LPLoopState state) {
        CUDA_CHECK(cudaEventRecord(ready_,nullptr));
        CUDA_CHECK(cudaStreamWaitEvent(stream_,ready_,0));
        CUDA_CHECK(cudaMemcpyAsync(thrust::raw_pointer_cast(state_.data()),&state,sizeof(state),cudaMemcpyHostToDevice,stream_));
        CUDA_CHECK(cudaGraphLaunch(executable_,stream_));
        CUDA_CHECK(cudaMemcpyAsync(&state,thrust::raw_pointer_cast(state_.data()),sizeof(state),cudaMemcpyDeviceToHost,stream_));
        CUDA_CHECK(cudaStreamSynchronize(stream_));
        if (state.errors) throw std::runtime_error("GPU LP loop cut/cache validation failed");
        return state;
    }
};
} // namespace
