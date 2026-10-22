#pragma once
// Net-capacity-guided connected exchanges. Included inside namespace gpart.
// Quotient matching and exact-prefix selection are established techniques;
// the search couples forward/reverse connected growth before admission.
namespace {
constexpr int kJointSeeds=128;
constexpr int kJointSide=4;
constexpr int kJointArchive=4; // Short fragments; the original feasible path still grows to eight.
struct JointMove {
    int vertices[2*kJointSide]={-1,-1,-1,-1,-1,-1,-1,-1};
    int size=0,a=-1,b=-1,id=0;
    long long gain=0,net=0;
};
struct EmptyJointMove {
    __host__ __device__ bool operator()(const JointMove& x) const { return x.size==0; }
};
// Equality is by the complete vertex set and the canonical partition pair,
// not by weight or gain alone. Different shapes remain distinct candidates.
__host__ __device__ bool joint_same_move(const JointMove& x,const JointMove& y) {
    if(!x.size || x.size!=y.size || x.a!=y.a || x.b!=y.b ||
       x.gain!=y.gain || x.net!=y.net) return false;
    for(int j=0;j<x.size;++j) {
        bool found=false;
        for(int t=0;t<y.size;++t) found|=x.vertices[j]==y.vertices[t];
        if(!found) return false;
    }
    return true; // Grow guarantees distinct vertices within each move.
}
struct JointOrder {
    __host__ __device__ bool operator()(const JointMove& x,const JointMove& y) const {
        if ((x.size!=0)!=(y.size!=0)) return x.size!=0;
        if (x.a!=y.a) return x.a<y.a;
        if (x.gain!=y.gain) return x.gain>y.gain;
        return x.id<y.id;
    }
};
__device__ long long joint_gap(long long net,long long lo,long long hi) {
    return net<lo ? lo-net : net>hi ? net-hi : 0;
}

template<class CacheT>
__global__ void joint_quotient(int n,const int* labels,AffinityView<CacheT> cache,
                              unsigned long long* quotient) {
    for(int v=blockIdx.x*blockDim.x+threadIdx.x;v<n;v+=gridDim.x*blockDim.x) {
        const int a=labels[v];
        for(int i=0;i<(cache.direct() ? cache.k : cache.entries(v));++i) {
            const int b=cache.direct() ? i : cache.part(v,i);
            // Enumerate direct-view partitions once: neighbor labels can repeat,
            // but each partition affinity must contribute exactly once.
            const auto w=cache.direct() ? cache.get(v,b) : cache.value(v,i);
            if(a<b && w) atomicAdd(quotient+a*cache.k+b,static_cast<unsigned long long>(w));
        }
    }
}
__global__ void joint_match(int k,const unsigned long long* quotient,int* partner,int* visits) {
    __shared__ int choice[kMaxParts],progress;
    const int p=threadIdx.x;
    if(p<k) partner[p]=-1;
    __syncthreads();
    for(int round=0;round<k/2;++round) {
        if(!p) progress=0;
        int best=-1;double score=-1;
        if(p<k && partner[p]<0) for(int q=0;q<k;++q) if(q!=p && partner[q]<0) {
            const int pair=min(p,q)*k+max(p,q);
            if(!quotient[pair]) continue;
            const double penalty=1.0+visits[pair];
            const double value=static_cast<double>(quotient[pair])/(penalty*penalty);
            // A shared edge order guarantees at least one mutual choice.
            if(value>score || (value==score && q<best)) {score=value;best=q;}
        }
        if(p<k) choice[p]=best;
        __syncthreads();
        if(p<k && best>=0 && choice[best]==p) {
            partner[p]=best;
            if(p<best) {++visits[p*k+best];atomicAdd(&progress,1);}
        }
        __syncthreads();
        const int gained=progress;
        __syncthreads(); // All warps consume progress before the next reset.
        if(!gained) break;
    }
}
template<class CacheT>
__global__ void joint_seeds(int n,const int* labels,AffinityView<CacheT> cache,
    const int* partner,unsigned long long* seeds,int seed_width,int pass) {
    for(int v=blockIdx.x*blockDim.x+threadIdx.x;v<n;v+=gridDim.x*blockDim.x) {
        int p=labels[v],q=partner[p];
        if(q<0 || !cache.get(v,q)) continue;
        const auto h=refine_mix32(static_cast<unsigned>(v)^refine_mix32(pass+17));
        atomicMin(seeds+p*seed_width+(h%seed_width),
                  (static_cast<unsigned long long>(h)<<32)|static_cast<unsigned>(v));
    }
}

template<class CacheT>
__global__ void joint_grow(int slots,int seed_width,const unsigned long long* seeds,const int* partner,
    const int* offsets,const int* neighbors,const std::uint32_t* edges,
    const std::uint32_t* masses,const int* labels,AffinityView<CacheT> cache,
    const unsigned long long* loads,unsigned long long capacity,JointMove* moves,JointMove* archive) {
    const int lane=threadIdx.x&31;
    const int slot=blockIdx.x*8+threadIdx.x/32;
    if(slot>=slots) return;
    const int seed_slot=slot/2,policy=slot%2;
    JointMove best;best.id=slot;
    if(!lane) {
        moves[slot]=best;
        for(int j=0;j<kJointArchive;++j) archive[slot*kJointArchive+j]=JointMove{};
    }
    const auto encoded=seeds[seed_slot];
    if(encoded==ULLONG_MAX) return;
    const int root=static_cast<unsigned>(encoded),source=labels[root],target=partner[source];
    if(target<0) return;
    int members[8]={root,-1,-1,-1,-1,-1,-1,-1};
    int size=1,counts[2]={1,0};
    long long net=masses[root];
    const long long lo=static_cast<long long>(loads[source])-static_cast<long long>(capacity);
    const long long hi=static_cast<long long>(capacity)-static_cast<long long>(loads[target]);
    long long gain=static_cast<long long>(cache.get(root,target))-static_cast<long long>(cache.get(root,source));
    for(int step=0;step<8;++step) {
        if(!lane && gain>0 && size<=kJointArchive) {
            JointMove state;state.size=size;state.a=min(source,target);state.b=max(source,target);
            state.gain=gain;state.net=source==state.a ? net : -net;state.id=slot*kJointArchive+step;
            for(int j=0;j<size;++j) {
                int pos=j;
                while(pos && state.vertices[pos-1]>members[j]) {state.vertices[pos]=state.vertices[pos-1];--pos;}
                state.vertices[pos]=members[j];
            }
            archive[slot*kJointArchive+step]=state;
        }
        if(gain>best.gain && !joint_gap(net,lo,hi)) {
            best.size=size;best.a=min(source,target);best.b=max(source,target);
            best.gain=gain;best.net=source==best.a ? net : -net;
            for(int j=0;j<size;++j) best.vertices[j]=members[j];
        }
        if(size==8) break;
        long long chosen_gain=LLONG_MIN,chosen_gap=LLONG_MAX;
        int chosen=INT_MAX;
        // Each lane nominates candidates. Bounded rows cap search work;
        // accepted transaction gains always use complete incident edges.
        // policy=0 prioritizes capacity repair; policy=1 prioritizes gain.
        for(int origin=-1;origin<size;++origin) {
            const bool reverse_seed=origin<0;
            if(reverse_seed && counts[1]) continue;
            const int m=reverse_seed ? -1 : members[origin];
            const int begin=reverse_seed ? 0 : offsets[m];
            const int end=reverse_seed ? seed_width : min(offsets[m+1],begin+128);
            for(int e=begin+lane;e<end;e+=32) {
                int u;
                if(reverse_seed) {
                    auto value=seeds[target*seed_width+e];
                    if(value==ULLONG_MAX) continue;
                    u=static_cast<unsigned>(value);
                } else u=neighbors[e];
                const int p=labels[u];
                if(p!=source && p!=target) continue;
                const int side=p==source ? 0 : 1;
                if(counts[side]>=kJointSide) continue;
                // Nonempty sides grow through their own members only.
                if(!reverse_seed && p!=labels[m]) continue;
                bool duplicate=false;
                for(int j=0;j<size;++j) duplicate|=u==members[j];
                if(duplicate || offsets[u+1]-offsets[u]>1024) continue;
                const long long candidate_net=net+(side ? -static_cast<long long>(masses[u]) : masses[u]);
                const auto gap=joint_gap(candidate_net,lo,hi);
                // While infeasible, grow only the side that repays the gap.
                if(net>hi && !side) continue;
                if(net<lo && side) continue;
                long long marginal=static_cast<long long>(cache.get(u,side ? source : target))-
                                   static_cast<long long>(cache.get(u,p));
                // Edge-local nomination is cheap; after selecting a member,
                // the complete joint marginal is recomputed by the warp.
                if(!reverse_seed) marginal+=2LL*detail::edge_weight(edges,e);
                bool better=policy==0 && joint_gap(net,lo,hi) ?
                    (gap<chosen_gap || (gap==chosen_gap && (marginal>chosen_gain || (marginal==chosen_gain && u<chosen)))) :
                    (marginal>chosen_gain || (marginal==chosen_gain && (gap<chosen_gap || (gap==chosen_gap && u<chosen))));
                if(better) { chosen=u;chosen_gain=marginal;chosen_gap=gap; }
            }
        }
        const bool gap_first=policy==0 && joint_gap(net,lo,hi);
        for(int d=16;d;d/=2) {
            int u=__shfl_down_sync(0xffffffffU,chosen,d);
            auto g=__shfl_down_sync(0xffffffffU,chosen_gain,d);
            auto gap=__shfl_down_sync(0xffffffffU,chosen_gap,d);
            bool better=gap_first ? (gap<chosen_gap || (gap==chosen_gap && (g>chosen_gain || (g==chosen_gain && u<chosen)))) :
                (g>chosen_gain || (g==chosen_gain && (gap<chosen_gap || (gap==chosen_gap && u<chosen))));
            if(lane+d<32 && better) {chosen=u;chosen_gain=g;chosen_gap=gap;}
        }
        chosen=__shfl_sync(0xffffffffU,chosen,0);
        chosen_gain=__shfl_sync(0xffffffffU,chosen_gain,0);
        if(chosen==INT_MAX) break;
        const int side=labels[chosen]==source ? 0 : 1;
        long long correction=0;
        for(int e=offsets[chosen]+lane;e<offsets[chosen+1];e+=32)
            for(int j=0;j<size;++j) if(neighbors[e]==members[j])
                correction+=(labels[members[j]]==labels[chosen] ? 2LL : -2LL)*detail::edge_weight(edges,e);
        for(int d=16;d;d/=2) correction+=__shfl_down_sync(0xffffffffU,correction,d);
        chosen_gain=static_cast<long long>(cache.get(chosen,side ? source : target))-
                    static_cast<long long>(cache.get(chosen,labels[chosen]))+
                    __shfl_sync(0xffffffffU,correction,0);
        members[size++]=chosen;++counts[side];gain+=chosen_gain;
        net+=side ? -static_cast<long long>(masses[chosen]) : masses[chosen];
    }
    if(!lane) moves[slot]=best;
}
__global__ void joint_claim(int count,const JointMove* moves,int* owners) {
    const int i=blockIdx.x*blockDim.x+threadIdx.x;
    if(i<count && moves[i].size) for(int j=0;j<moves[i].size;++j)
        atomicMin(owners+moves[i].vertices[j],i);
}
__global__ void joint_resolve(int count,JointMove* moves,const int* owners) {
    const int i=blockIdx.x*blockDim.x+threadIdx.x;
    if(i>=count) return;
    for(int j=0;j<moves[i].size;++j) if(owners[moves[i].vertices[j]]!=i) {
        moves[i].size=0;break; // Reject the entire exchange, never one side.
    }
}
__global__ void joint_mark(int count,const JointMove* moves,const int* labels,
                          int* owners,int* targets) {
    const int i=blockIdx.x*blockDim.x+threadIdx.x;
    if(i<count) for(int j=0;j<moves[i].size;++j) {
        const int v=moves[i].vertices[j];owners[v]=i;
        targets[v]=labels[v]==moves[i].a ? moves[i].b : moves[i].a;
    }
}
// Every affected undirected edge emits at most two events in transaction
// order. Their prefix sums are exact even when transactions share edges.
__global__ void joint_events(int count,const JointMove* moves,const int* owners,
    const int* targets,const int* labels,const int* offsets,const int* neighbors,
    const std::uint32_t* edges,unsigned long long* events) {
    const int lane=threadIdx.x&31,i=blockIdx.x*8+threadIdx.x/32;
    if(i>=count) return;
    if(!moves[i].size) return; // Uniform across this transaction's warp.
    // One warp owns transaction i. Accumulate its event locally; only the
    // other transaction's event needs a per-edge atomic. Unsigned arithmetic
    // preserves the original modulo-2^64 sum of signed edge contributions.
    unsigned long long own_event=0;
    for(int j=0;j<moves[i].size;++j) {
        const int v=moves[i].vertices[j];
        for(int e=offsets[v]+lane;e<offsets[v+1];e+=32) {
            const int u=neighbors[e],other=owners[u];
            if(u==v || (other!=INT_MAX && v>u)) continue;
            if(other!=INT_MAX && labels[u]!=moves[i].a && labels[u]!=moves[i].b) continue;
            const long long w=detail::edge_weight(edges,e);
            const int before=labels[v]!=labels[u];
            if(other==i || other==INT_MAX) {
                const int after=targets[v]!=(other==i ? targets[u] : labels[u]);
                own_event+=static_cast<unsigned long long>((before-after)*w);
            } else {
                const int middle=i<other ? targets[v]!=labels[u] : labels[v]!=targets[u];
                const int after=targets[v]!=targets[u];
                const auto first_event=static_cast<unsigned long long>((before-middle)*w);
                const auto last_event=static_cast<unsigned long long>((middle-after)*w);
                own_event+=i<other ? first_event : last_event;
                atomicAdd(events+other,i<other ? last_event : first_event);
            }
        }
    }
    for(int d=16;d;d/=2)
        own_event+=__shfl_down_sync(0xffffffffU,own_event,d);
    // Other warps may also contribute to events[i], so keep an atomic flush.
    if(!lane && own_event) atomicAdd(events+i,own_event);
}
__global__ void joint_prefix(int count,int k,const JointMove* moves,
    const unsigned long long* events,const unsigned long long* loads,
    unsigned long long capacity,int* stops,long long* gains=nullptr,int* counts=nullptr) {
    const int a=blockIdx.x*blockDim.x+threadIdx.x;
    if(a>=k) return;
    long long gain=0,net=0,best=0;int stop=-1,accepted=0,best_count=0;
    // Input is sorted by canonical partition pair; failed claims retain a.
    // Binary-search the segment instead of rescanning all M records for each p.
    int low=0,high=count;
    while(low<high) {const int mid=(low+high)/2;if(moves[mid].a<a) low=mid+1;else high=mid;}
    for(int i=low;i<count && moves[i].a==a;++i) if(moves[i].size) {
        ++accepted;
        gain+=static_cast<long long>(events[i]);net+=moves[i].net;
        const int b=moves[i].b;
        const long long lo=static_cast<long long>(loads[a])-static_cast<long long>(capacity);
        const long long hi=static_cast<long long>(capacity)-static_cast<long long>(loads[b]);
        if(!joint_gap(net,lo,hi) && gain>best) {best=gain;stop=i;best_count=accepted;}
    }
    stops[a]=stop;
    if(gains) gains[a]=best;
    if(counts) counts[a]=best_count;
}
__global__ void joint_accept(int count,const JointMove* moves,const int* stops,int* flags) {
    const int i=blockIdx.x*blockDim.x+threadIdx.x;
    if(i<count && moves[i].size && i<=stops[moves[i].a])
        for(int j=0;j<moves[i].size;++j) flags[moves[i].vertices[j]]=1;
}
} // namespace

#include "complementary_moves.cuh"
