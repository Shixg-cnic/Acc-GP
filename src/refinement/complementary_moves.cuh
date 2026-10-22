#pragma once
// Bounded positive-prefix archive, net-weight pairing, for the single-plan exchange.
// Included inside namespace gpart, after the original joint implementation.
namespace {
struct JointNetOrder {
    __host__ __device__ bool operator()(const JointMove& x,const JointMove& y) const {
        if(x.a!=y.a) return x.a<y.a;
        if(x.net!=y.net) return x.net<y.net;
        if(x.gain!=y.gain) return x.gain>y.gain;
        if(x.size!=y.size) return x.size<y.size;
        for(int j=0;j<x.size;++j) if(x.vertices[j]!=y.vertices[j]) return x.vertices[j]<y.vertices[j];
        return x.id<y.id;
    }
};
struct JointSameCanonical {
    __host__ __device__ bool operator()(const JointMove& x,const JointMove& y) const {
        return joint_same_move(x,y);
    }
};
__device__ int joint_net_bound(const JointMove* records,int count,int a,long long net,bool upper) {
    int lo=0,hi=count;
    while(lo<hi) {
        const int mid=(lo+hi)/2;const auto& x=records[mid];
        if(x.a<a || (x.a==a && (x.net<net || (upper && x.net==net)))) lo=mid+1;
        else hi=mid;
    }
    return lo;
}
// At most four representatives of the exact complementary weight interval.
// This is bounded sampling, not an exhaustive best-partner search.
__global__ void joint_combine(int count,const JointMove* archive,
    const int* offsets,const int* neighbors,const std::uint32_t* edges,const int* labels,
    const unsigned long long* loads,unsigned long long capacity,int id_base,JointMove* out) {
    const int lane=threadIdx.x&31,i=blockIdx.x*8+threadIdx.x/32;
    if(i>=count) return;
    const JointMove x=archive[i];
    const long long lo=static_cast<long long>(loads[x.a])-static_cast<long long>(capacity);
    const long long hi=static_cast<long long>(capacity)-static_cast<long long>(loads[x.b]);
    if(!lane) {
        out[i]=x;out[i].id=id_base+i;
        if(joint_gap(x.net,lo,hi)) out[i].size=0;
        out[count+i]=JointMove{};
    }
    const int begin=joint_net_bound(archive,count,x.a,lo-x.net,false);
    const int end=joint_net_bound(archive,count,x.a,hi-x.net,true);
    long long best_gain=0;int best=-1,previous=-1;
    for(int r=0;r<4 && begin<end;++r) {
        const int j=begin+static_cast<int>((static_cast<long long>(end-begin-1)*r)/3);
        if(j==previous) continue;previous=j;
        if(j==i) continue;
        const JointMove y=archive[j];
        if(y.a!=x.a || y.b!=x.b || x.size+y.size>8) continue;
        bool overlap=false;
        for(int u=0;u<x.size;++u) for(int v=0;v<y.size;++v) overlap|=x.vertices[u]==y.vertices[v];
        if(overlap) continue;
        long long correction=0;
        // Scan only x->y incidences, once per undirected cross-fragment edge.
        for(int u=0;u<x.size;++u) {
            const int v=x.vertices[u];
            for(int e=offsets[v]+lane;e<offsets[v+1];e+=32)
                for(int t=0;t<y.size;++t) if(neighbors[e]==y.vertices[t])
                    correction+=(labels[v]==labels[neighbors[e]] ? 2LL : -2LL)*detail::edge_weight(edges,e);
        }
        for(int d=16;d;d/=2) correction+=__shfl_down_sync(0xffffffffU,correction,d);
        const long long gain=x.gain+y.gain+__shfl_sync(0xffffffffU,correction,0);
        if(gain>best_gain || (gain==best_gain && gain>0 && j<best)) {best_gain=gain;best=j;}
    }
    if(!lane && best>=0) {
        auto result=x;const auto y=archive[best];
        for(int j=0;j<y.size;++j) result.vertices[result.size++]=y.vertices[j];
        result.gain=best_gain;result.net+=y.net;result.id=id_base+count+i;
        // The union is an indivisible transaction; connectivity is not required.
        out[count+i]=result;
    }
}
} // namespace
