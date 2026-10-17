#pragma once
// Included inside namespace gpart. Connected groups and reciprocal transactions
// use the current affinity cache; all proposal/admission work stays on the GPU.
namespace {
constexpr int kGroupSize=4;

struct BoundaryGroup {
    std::int32_t vertices[kGroupSize]={-1,-1,-1,-1};
    std::int32_t size=0,target=-1;
    std::int64_t gain=0;
    std::uint64_t weight=0;
};
struct GroupTransaction {
    std::int32_t a=-1,b=-1;
    std::int64_t gain=0;
};

// Every lane owns four or sixteen partition affinities, selected by k. The collective destination can
// differ from every member's individual favorite. Prefix gain is exact from
// cached affinities and internal-edge weight; only the new member scans CSR.
template <int Tiles>
__device__ int collective_target(int lane,int k,int source,
    const unsigned long long (&affinity)[Tiles],unsigned long long& best) {
    unsigned long long value=0;int target=INT_MAX;
    for(int tile=0;tile<Tiles;++tile) {
        const int p=lane+32*tile;
        if(p<k && p!=source && (affinity[tile]>value || (affinity[tile]==value && p<target))) {
            value=affinity[tile];target=p;
        }
    }
    for (int shift=16;shift;shift/=2) {
        const auto other=__shfl_down_sync(0xffffffffU,value,shift);
        const int other_target=__shfl_down_sync(0xffffffffU,target,shift);
        if (lane+shift<32 && (other>value || (other==value && other_target<target))) {
            value=other;target=other_target;
        }
    }
    best=__shfl_sync(0xffffffffU,value,0);
    return __shfl_sync(0xffffffffU,target,0);
}
template <typename OffsetT,typename VertexT,typename WeightT,typename CacheT,int Tiles=4>
__global__ void boundary_group_proposals(
    std::int64_t n,const OffsetT* offsets,const VertexT* neighbors,const WeightT* edges,
    const WeightT* weights,const VertexT* labels,AffinityView<CacheT> cache,int k,
    BoundaryGroup* groups) {
    const int lane=threadIdx.x&31;
    const auto v=static_cast<std::int64_t>(blockIdx.x)*8+threadIdx.x/32;
    if (v>=n) return;
    BoundaryGroup group;
    if (!lane) for (int i=0;i<kGroupSize;++i) groups[v*kGroupSize+i]=BoundaryGroup{};
    const int source=labels[v];
    unsigned long long affinity[Tiles]={},best=0;
    for(int tile=0;tile<Tiles;++tile) {
        const int p=lane+32*tile;
        if(p<k) affinity[tile]=cache.get(v,p);
    }
    int target=collective_target(lane,k,source,affinity,best);
    if (!best) return;
    const auto own=__shfl_sync(0xffffffffU,affinity[source/32],source&31);
    group.vertices[0]=static_cast<std::int32_t>(v);group.size=1;group.target=target;
    group.weight=static_cast<std::uint64_t>(weights[v]);
    group.gain=static_cast<std::int64_t>(best)-static_cast<std::int64_t>(own);
    unsigned long long internal_weight=0;
    if (!lane) groups[v*kGroupSize]=group;
    for (int step=1;step<kGroupSize;++step) {
        long long score=LLONG_MIN;
        int candidate=INT_MAX;
        // This edge-local score nominates one neighbor. It must not decide
        // whether to stop: multiple internal edges or a new destination can
        // make the actual group marginal positive even when this score is not.
        for (int j=0;j<group.size;++j) {
            const auto member=group.vertices[j];
            for (std::int64_t e=static_cast<std::int64_t>(offsets[member])+lane;e<offsets[member+1];e+=32) {
                const auto u=neighbors[e];
                if (labels[u]!=source) continue;
                bool present=false;
                for (int q=0;q<group.size;++q) present|=u==group.vertices[q];
                if (present) continue;
                const long long marginal=static_cast<long long>(cache.get(u,target))-
                    static_cast<long long>(cache.get(u,source))+2LL*static_cast<long long>(detail::edge_weight(edges,e));
                if (marginal>score || (marginal==score && u<candidate)) { score=marginal;candidate=u; }
            }
        }
        for (int shift=16;shift;shift/=2) {
            const auto other=__shfl_down_sync(0xffffffffU,score,shift);
            const int other_id=__shfl_down_sync(0xffffffffU,candidate,shift);
            if (lane+shift<32 && (other>score || (other==score && other_id<candidate))) { score=other;candidate=other_id; }
        }
        candidate=__shfl_sync(0xffffffffU,candidate,0);
        if (candidate==INT_MAX) break;
        unsigned long long joined=0;
        for (std::int64_t e=static_cast<std::int64_t>(offsets[candidate])+lane;e<offsets[candidate+1];e+=32)
            for (int q=0;q<group.size;++q) if (neighbors[e]==group.vertices[q]) joined+=detail::edge_weight(edges,e);
        for (int shift=16;shift;shift/=2) joined+=__shfl_down_sync(0xffffffffU,joined,shift);
        joined=__shfl_sync(0xffffffffU,joined,0);
        const auto proposed_internal=internal_weight+joined;
        for(int tile=0;tile<Tiles;++tile) {
            const int p=lane+32*tile;
            if(p<k) affinity[tile]+=cache.get(candidate,p);
        }
        const int proposed_target=collective_target(lane,k,source,affinity,best);
        const auto outside_own=__shfl_sync(0xffffffffU,affinity[source/32],source&31)-2*proposed_internal;
        const auto gain=static_cast<std::int64_t>(best)-static_cast<std::int64_t>(outside_own);
        // Prefixes are virtual: a losing extension can expose an improving
        // full group. Retain all connected prefixes up to the fixed size
        // budget; only feasible, positive-gain transactions may be committed.
        internal_weight=proposed_internal;target=proposed_target;
        group.vertices[group.size++]=candidate;group.weight+=static_cast<std::uint64_t>(weights[candidate]);
        group.target=target;group.gain=gain;
        if (!lane) {
            auto stored=group;
            for (int a=1;a<stored.size;++a) for (int b=a;b>0 && stored.vertices[b]<stored.vertices[b-1];--b) {
                const int tmp=stored.vertices[b];stored.vertices[b]=stored.vertices[b-1];stored.vertices[b-1]=tmp;
            }
            groups[v*kGroupSize+step]=stored;
        }
    }
}

__device__ int group_pair(const BoundaryGroup& group,const std::int32_t* labels,int k) {
    return group.size ? labels[group.vertices[0]]*k+group.target : k*k;
}
struct ValidBoundaryGroup {
    const BoundaryGroup* groups;
    __device__ bool operator()(int index) const { return groups[index].size>0; }
};
struct GroupOrder {
    const BoundaryGroup* groups;
    const std::int32_t* labels;
    int k;
    __device__ bool operator()(int a,int b) const {
        const auto x=groups[a],y=groups[b];
        const int px=group_pair(x,labels,k),py=group_pair(y,labels,k);
        if (px!=py) return px<py;
        if (x.weight!=y.weight) return x.weight<y.weight;
        if (x.gain!=y.gain) return x.gain>y.gain;
        for (int i=0;i<kGroupSize;++i) if (x.vertices[i]!=y.vertices[i]) return x.vertices[i]<y.vertices[i];
        return a<b;
    }
};

// Materialize the complete comparator key once. Sorting indices with a
// comparator repeatedly gathers two 40-byte groups and their labels. This
// lossless 210-bit maximum key replaces those random gathers with radix
// passes over contiguous records; stable sorting supplies the final index
// tie, since the compacted input is in ascending slot order.
// Larger batches drop only provably unused field bits using measured maxima.
using GroupRadixKey = detail::GroupSortRecord;
struct GroupRadixDecomposer {
    __host__ __device__ auto operator()(GroupRadixKey& x) const {
        return cuda::std::tie(x.d,x.c,x.b,x.a);
    }
};
__global__ void encode_group_order(int count,const int* order,
    const BoundaryGroup* groups,const int* labels,int k,GroupRadixKey* keys,
    detail::GroupSortLayout layout) {
    const int i=blockIdx.x*blockDim.x+threadIdx.x;
    if (i>=count) return;
    const int index=order[i];
    const auto g=groups[index];
    keys[i]=layout.encode(group_pair(g,labels,k),g.weight,g.gain,g.vertices,index);
}
__global__ void group_order_limits(int count,const int* order,
    const BoundaryGroup* groups,unsigned long long* limits) {
    const int i=blockIdx.x*blockDim.x+threadIdx.x;
    unsigned long long weight=0,gain=0;
    if (i<count) {
        const auto g=groups[order[i]];
        weight=g.weight;gain=detail::GroupSortLayout::magnitude(g.gain);
    }
    for(int delta=16;delta;delta>>=1) {
        weight=max(weight,__shfl_down_sync(0xffffffffU,weight,delta));
        gain=max(gain,__shfl_down_sync(0xffffffffU,gain,delta));
    }
    __shared__ unsigned long long weights[8],gains[8];
    if (!(threadIdx.x&31)) { weights[threadIdx.x/32]=weight;gains[threadIdx.x/32]=gain; }
    __syncthreads();
    if (!threadIdx.x) {
        weight=0;gain=0;
        for(int w=0;w<8;++w) { weight=max(weight,weights[w]);gain=max(gain,gains[w]); }
        atomicMax(limits,weight);atomicMax(limits+1,gain);
    }
}
__global__ void decode_group_order(int count,const GroupRadixKey* keys,int* order) {
    const int i=blockIdx.x*blockDim.x+threadIdx.x;
    if (i<count) order[i]=keys[i].index;
}
__global__ void validate_group_order(int count,const int* order,
    GroupOrder compare,unsigned int* errors) {
    const int i=blockIdx.x*blockDim.x+threadIdx.x;
    if (i>0 && i<count && compare(order[i],order[i-1])) atomicAdd(errors,1U);
}
struct SameGroup {
    const BoundaryGroup* groups;
    const std::int32_t* labels;
    int k;
    __device__ bool operator()(int a,int b) const {
        const auto x=groups[a],y=groups[b];
        if (group_pair(x,labels,k)!=group_pair(y,labels,k) || x.size!=y.size) return false;
        for (int i=0;i<kGroupSize;++i) if (x.vertices[i]!=y.vertices[i]) return false;
        return true;
    }
};
struct KeepGroupWeights {
    const int* order;
    const BoundaryGroup* groups;
    const std::int32_t* labels;
    int k;
    __device__ bool operator()(int i) const {
        const auto x=groups[order[i]];
        if (!x.size) return false;
        // Keep the two best distinct shapes of each exact weight, rather
        // than letting high gain/weight candidates erase load alternatives.
        if (i<2) return true;
        const auto y=groups[order[i-2]];
        return x.weight!=y.weight || group_pair(x,labels,k)!=group_pair(y,labels,k);
    }
};
struct GroupRange { int begin=0,end=0; };
struct NonemptyGroupPair {
    const GroupRange* ranges;
    __device__ bool operator()(int pair) const { return ranges[pair].begin<ranges[pair].end; }
};
__global__ void group_ranges(int n,const int* order,const BoundaryGroup* groups,
    const std::int32_t* labels,int k,GroupRange* ranges) {
    const int i=blockIdx.x*blockDim.x+threadIdx.x;
    if (i>=n) return;
    const int pair=group_pair(groups[order[i]],labels,k);
    if (!i || group_pair(groups[order[i-1]],labels,k)!=pair) ranges[pair].begin=i;
    if (i+1==n || group_pair(groups[order[i+1]],labels,k)!=pair) ranges[pair].end=i+1;
}
__device__ int group_winner(int a,int b,const int* order,const BoundaryGroup* groups) {
    if (a<0) return b;
    if (b<0) return a;
    const auto ga=groups[order[a]].gain,gb=groups[order[b]].gain;
    return ga>gb || (ga==gb && a<b) ? a : b;
}
// Build eight tree levels per launch. A tile owns a complete subtree, so
// block barriers suffice; subsequent launches join the tile roots. Shared
// gains avoid reloading group records for each pair at every tree level.
__global__ void group_tree_tile(int start,int base,int count,int* tree,
    const int* order,const BoundaryGroup* groups) {
    __shared__ int positions[512];
    __shared__ std::int64_t gains[512];
    const int width=min(start,256),t=threadIdx.x;
    if(t<width) {
        const int i=blockIdx.x*width+t;
        const int position=start==base ? (i<count ? i : -1) : tree[start+i];
        if(start==base) tree[start+i]=position;
        positions[width+t]=position;
        gains[width+t]=position<0 ? 0 : groups[order[position]].gain;
    }
    for(int stride=width/2;stride;stride/=2) {
        __syncthreads();
        if(t<stride) {
            const int left=2*(stride+t),right=left+1;
            const int a=positions[left],b=positions[right];
            const bool choose_a=b<0 || (a>=0 && (gains[left]>gains[right] || (gains[left]==gains[right] && a<b)));
            const int chosen=choose_a ? left : right;
            const int position=positions[chosen];
            positions[stride+t]=position;gains[stride+t]=gains[chosen];
            tree[start/(width/stride)+blockIdx.x*stride+t]=position;
        }
    }
}
__device__ int group_range_best(int begin,int end,int base,const int* tree,
    const int* order,const BoundaryGroup* groups) {
    int best=-1;
    for (int a=begin+base,b=end+base;a<b;a/=2,b/=2) {
        if (a&1) best=group_winner(best,tree[a++],order,groups);
        if (b&1) best=group_winner(best,tree[--b],order,groups);
    }
    return best;
}

// Index lookup first enforces net-weight feasibility. Only the two highest
// reverse gains in that interval require CSR scans for exact interaction gain.
template <typename OffsetT,typename VertexT,typename WeightT>
__global__ void boundary_group_transactions(
    int count,const int* order,const GroupRange* ranges,int base,const int* tree,
    const OffsetT* offsets,const VertexT* neighbors,const WeightT* edges,
    const VertexT* labels,int k,const BoundaryGroup* groups,
    const unsigned long long* loads,std::uint64_t capacity,GroupTransaction* candidates) {
    const int i=blockIdx.x*8+threadIdx.x/32,lane=threadIdx.x&31;
    if (i>=count) return;
    const int a=order[i];
    const auto ga=groups[a];
    const int source=labels[ga.vertices[0]],target=ga.target;
    GroupTransaction best;
    const auto slack_a=capacity-loads[source],slack_b=capacity-loads[target];
    if (ga.weight<=slack_b && ga.gain>0) best={a,-1,ga.gain};
    const auto reverse=ranges[target*k+source];
    const auto minimum=ga.weight>slack_b ? ga.weight-slack_b : 0;
    const auto maximum=~std::uint64_t{0}-ga.weight<slack_a ? ~std::uint64_t{0} : ga.weight+slack_a;
    int low=reverse.begin,high=reverse.end;
    while (low<high) { const int mid=low+(high-low)/2;if (groups[order[mid]].weight<minimum) low=mid+1;else high=mid; }
    const int begin=low;
    high=reverse.end;
    while (low<high) { const int mid=low+(high-low)/2;if (groups[order[mid]].weight<=maximum) low=mid+1;else high=mid; }
    const int end=low;
    int chosen=group_range_best(begin,end,base,tree,order,groups);
    // Evaluate both directions. Keeping directed records also permits solo
    // transfers into slack without requiring a reciprocal group to exist.
    for (int attempt=0;attempt<2 && chosen>=0;++attempt) {
        const int b=order[chosen];
        const auto gb=groups[b];
        if (ga.gain+gb.gain>best.gain) {
            long long cross=0;
            for (int q=0;q<ga.size;++q) {
                const auto v=ga.vertices[q];
                for (std::int64_t e=static_cast<std::int64_t>(offsets[v])+lane;e<offsets[v+1];e+=32)
                    for (int r=0;r<gb.size;++r) if (neighbors[e]==gb.vertices[r]) cross+=detail::edge_weight(edges,e);
            }
            for (int shift=16;shift;shift/=2) cross+=__shfl_down_sync(0xffffffffU,cross,shift);
            cross=__shfl_sync(0xffffffffU,cross,0);
            const auto gain=ga.gain+gb.gain-2*cross;
            if (gain>best.gain) best={a,b,gain};
        }
        if (!attempt) chosen=group_winner(group_range_best(begin,chosen,base,tree,order,groups),
            group_range_best(chosen+1,end,base,tree,order,groups),order,groups);
    }
    if (!lane) candidates[i]=best;
}
__global__ void group_reduce_transactions(int k,const GroupRange* ranges,
    const GroupTransaction* candidates,GroupTransaction* transactions,const int* active_pairs=nullptr) {
    const int pair=active_pairs ? active_pairs[blockIdx.x] : blockIdx.x;
    const auto range=ranges[pair];
    GroupTransaction best;
    for (int i=range.begin+threadIdx.x;i<range.end;i+=blockDim.x) {
        const auto other=candidates[i];
        if (other.gain>best.gain || (other.gain==best.gain && other.gain>0 && other.a<best.a)) best=other;
    }
    __shared__ GroupTransaction shared[256];
    shared[threadIdx.x]=best;
    __syncthreads();
    for (int stride=blockDim.x/2;stride;stride/=2) {
        if (threadIdx.x<stride) {
            const auto other=shared[threadIdx.x+stride];
            auto& own=shared[threadIdx.x];
            if (other.gain>own.gain || (other.gain==own.gain && other.gain>0 && other.a<own.a)) own=other;
        }
        __syncthreads();
    }
    if (!threadIdx.x) transactions[blockIdx.x]=shared[0];
}
struct TransactionOrder {
    __host__ __device__ bool operator()(const GroupTransaction& a,const GroupTransaction& b) const {
        return a.gain>b.gain || (a.gain==b.gain && (a.a<b.a || (a.a==b.a && a.b<b.b)));
    }
};

// Sort only k*k metadata records on the GPU; admit in one traversal instead
// of repeatedly scanning every part pair. Exact batch gain is still checked.
template <typename VertexT>
__global__ void boundary_group_admit(
    int k,int transaction_count,const BoundaryGroup* groups,const GroupTransaction* transactions,
    const VertexT* labels,const unsigned long long* loads,std::uint64_t capacity,
    std::int32_t* flags,std::int32_t* targets) {
    if (threadIdx.x || blockIdx.x) return;
    unsigned long long planned[kMaxParts];
    for (int p=0;p<k;++p) planned[p]=loads[p];
    for (int i=0;i<transaction_count;++i) {
        const auto txn=transactions[i];
        if (txn.gain<=0) break;
        const auto a=groups[txn.a],b=txn.b>=0 ? groups[txn.b] : BoundaryGroup{};
        bool conflict=false;
        for (int j=0;j<a.size;++j) conflict|=flags[a.vertices[j]]!=0;
        for (int j=0;j<b.size;++j) conflict|=flags[b.vertices[j]]!=0;
        if (conflict) continue;
        const int source=labels[a.vertices[0]],target=a.target;
        if (a.weight>b.weight ? a.weight-b.weight>capacity-planned[target] : b.weight-a.weight>capacity-planned[source]) continue;
        planned[source]=planned[source]-a.weight+b.weight;
        planned[target]=planned[target]-b.weight+a.weight;
        for (int j=0;j<a.size;++j) { flags[a.vertices[j]]=1;targets[a.vertices[j]]=target; }
        for (int j=0;j<b.size;++j) { flags[b.vertices[j]]=1;targets[b.vertices[j]]=source; }
    }
}

template <typename OffsetT,typename VertexT,typename WeightT>
__global__ void boundary_group_measure(
    std::int64_t count,const VertexT* movers,const OffsetT* offsets,
    const VertexT* neighbors,const WeightT* weights,const VertexT* labels,
    const std::int32_t* targets,const std::int32_t* flags,std::int64_t* delta) {
    const int lane=threadIdx.x&31;
    const auto i=static_cast<std::int64_t>(blockIdx.x)*8+threadIdx.x/32;
    if (i>=count) return;
    const auto v=movers[i];
    long long gain=0;
    for (std::int64_t e=static_cast<std::int64_t>(offsets[v])+lane;e<offsets[v+1];e+=32) {
        const auto u=neighbors[e];
        if (u!=v && (!flags[u] || u>v)) gain+=static_cast<long long>(detail::edge_weight(weights,e))*((labels[v]!=labels[u])-(targets[v]!=(flags[u] ? targets[u] : labels[u])));
    }
    for (int shift=16;shift;shift/=2) gain+=__shfl_down_sync(0xffffffffU,gain,shift);
    if (!lane) atomicAdd(reinterpret_cast<unsigned long long*>(delta),static_cast<unsigned long long>(gain));
}
} // namespace
