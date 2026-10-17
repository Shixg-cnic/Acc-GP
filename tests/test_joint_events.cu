#include "graph_types.hpp"
#include "check.hpp"
#include "detail/edge_weight.hpp"
#include <cuda/atomic>
#include <thrust/device_vector.h>
#include <thrust/copy.h>
#include <thrust/fill.h>
#include <algorithm>
#include <climits>
#include <cstdint>
#include <iostream>
#include <map>
#include <random>
#include <stdexcept>
#include <vector>
namespace gpart {
__device__ unsigned refine_mix32(unsigned x) { return x*0x9e3779b9U; }
#include "../src/refine_affinity.cuh"
#include "../src/refine_joint.cuh"
}

namespace {
template<class T> auto device_ptr(T& x) {return thrust::raw_pointer_cast(x.data());}
void require(bool ok,const char* message) {if(!ok) throw std::runtime_error(message);}
bool overlaps(const gpart::JointMove& a,const gpart::JointMove& b) {
    for(int i=0;i<a.size;++i) for(int j=0;j<b.size;++j)
        if(a.vertices[i]==b.vertices[j]) return true;
    return false;
}
std::vector<gpart::JointMove> filter_gpu(const std::vector<gpart::JointMove>& input,int n,int rounds) {
    const int count=input.size();
    thrust::device_vector<gpart::JointMove> moves=input;
    thrust::device_vector<int> owners(n,INT_MAX),occupied(n,-1),accepted(count,0);
    if(rounds==0) { // Unmodified original path, used as a one-round oracle.
        gpart::joint_claim<<<(count+255)/256,256>>>(count,device_ptr(moves),device_ptr(owners));
        gpart::joint_resolve<<<(count+255)/256,256>>>(count,device_ptr(moves),device_ptr(owners));
    } else {
        for(int r=0;r<rounds;++r) {
            thrust::fill(owners.begin(),owners.end(),INT_MAX);
            gpart::joint_retry_claim<<<(count+255)/256,256>>>(count,device_ptr(moves),device_ptr(accepted),device_ptr(occupied),device_ptr(owners));
            gpart::joint_retry_resolve<<<(count+255)/256,256>>>(count,device_ptr(moves),device_ptr(owners),device_ptr(accepted),device_ptr(occupied));
        }
        gpart::joint_retry_finish<<<(count+255)/256,256>>>(count,device_ptr(moves),device_ptr(accepted));
    }
    CUDA_CHECK(cudaGetLastError());CUDA_CHECK(cudaDeviceSynchronize());
    std::vector<gpart::JointMove> out(count);thrust::copy(moves.begin(),moves.end(),out.begin());return out;
}
void check_conflicts() {
    std::mt19937 rng(9671);
    for(int trial=0;trial<32;++trial) {
        constexpr int n=64,count=80;
        std::vector<gpart::JointMove> input(count);
        for(int i=0;i<count;++i) {
            auto& m=input[i];m.a=0;m.b=1;m.id=i;m.gain=count-i;
            const int size=rng()%9; // Include empty and eight-member moves.
            while(m.size<size) {
                int v=rng()%n;bool duplicate=false;
                for(int j=0;j<m.size;++j) duplicate|=m.vertices[j]==v;
                if(!duplicate) m.vertices[m.size++]=v;
            }
        }
        std::vector<bool> selected(count);
        auto original=filter_gpu(input,n,0);
        for(int rounds=1;rounds<=4;++rounds) {
            // Independent CPU oracle on the conflict graph: local priority
            // minima among vertices not adjacent to any previously selected one.
            std::vector<bool> eligible(count),next=selected;
            for(int i=0;i<count;++i) {
                eligible[i]=input[i].size && !selected[i];
                for(int j=0;j<count;++j)
                    if(selected[j] && overlaps(input[i],input[j])) eligible[i]=false;
            }
            for(int i=0;i<count;++i) if(eligible[i]) {
                bool lower=false;
                for(int j=0;j<i;++j) lower|=eligible[j] && overlaps(input[i],input[j]);
                if(!lower) next[i]=true;
            }
            selected=next;
            const auto actual=filter_gpu(input,n,rounds);
            for(int i=0;i<count;++i) {
                require((actual[i].size!=0)==selected[i],"retry differs from CPU conflict-graph oracle");
                if(rounds==1) require(actual[i].size==original[i].size,"one retry round changed original survivors");
                if(original[i].size) require(actual[i].size!=0,"retry lost a first-round survivor");
                if(actual[i].size) {
                    require(actual[i].size==input[i].size,"retry split a transaction");
                    for(int j=0;j<i;++j) if(actual[j].size)
                        require(!overlaps(actual[i],actual[j]),"survivors overlap");
                }
            }
        }
    }
    // Review's H={a}, X={a,b}, Y={b,c}: X loses a but must not
    // permanently block Y at b. Verify gain using the full real CSR below.
    std::vector<gpart::JointMove> input(3);
    for(int i=0;i<3;++i) {input[i].a=0;input[i].b=1;input[i].id=i;input[i].gain=10-i;}
    input[0].vertices[0]=0;input[0].size=1;input[0].net=1;
    input[1].vertices[0]=0;input[1].vertices[1]=1;input[1].size=2;input[1].net=2;
    input[2].vertices[0]=1;input[2].vertices[1]=2;input[2].size=2;input[2].net=2;
    const std::vector<int> offsets{0,2,5,7,8,10},neighbors{1,4,0,2,3,1,4,1,0,2};
    const std::vector<std::uint32_t> weights{1,11,1,1,1,1,10,1,11,10},masses{1,1,1,97,100};
    const std::vector<int> initial{0,0,0,0,1};
    for(int rounds : {1,2,4}) {
        auto kept=filter_gpu(input,5,rounds);
        require(kept[0].size==1 && kept[1].size==0 && (kept[2].size!=0)==(rounds>1),"shadow fixture survivors wrong");
        thrust::device_vector<gpart::JointMove> dm=kept;
        thrust::device_vector<int> dl=initial,owners(5,INT_MAX),targets(5,-1),stops(2,-1),flags(5,0),doo=offsets,dn=neighbors;
        thrust::device_vector<std::uint32_t> dw=weights;
        thrust::device_vector<unsigned long long> events(3,0),loads(2,100);
        gpart::joint_mark<<<1,256>>>(3,device_ptr(dm),device_ptr(dl),device_ptr(owners),device_ptr(targets));
        gpart::joint_events<<<1,256>>>(3,device_ptr(dm),device_ptr(owners),device_ptr(targets),device_ptr(dl),device_ptr(doo),device_ptr(dn),device_ptr(dw),device_ptr(events));
        gpart::joint_prefix<<<1,128>>>(3,2,device_ptr(dm),device_ptr(events),device_ptr(loads),103,device_ptr(stops));
        gpart::joint_accept<<<1,256>>>(3,device_ptr(dm),device_ptr(stops),device_ptr(flags));
        CUDA_CHECK(cudaGetLastError());CUDA_CHECK(cudaDeviceSynchronize());
        std::vector<int> chosen(5);thrust::copy(flags.begin(),flags.end(),chosen.begin());
        auto labels=initial;unsigned long long load[2]={0,0};long long cut=0;
        for(int v=0;v<5;++v) {if(chosen[v]) labels[v]=1-labels[v];load[labels[v]]+=masses[v];}
        for(int v=0;v<5;++v) for(int e=offsets[v];e<offsets[v+1];++e)
            if(v<neighbors[e] && labels[v]!=labels[neighbors[e]]) cut+=weights[e];
        require(load[0]<=103 && load[1]<=103,"shadow fixture capacity violated");
        require(cut==(rounds==1 ? 11 : 1),"shadow fixture full cut incorrect");
    }
}
void check_policy_dedup() {
    std::vector<gpart::JointMove> input(8);
    for(int i=0;i<8;++i) {
        input[i].size=2;input[i].a=0;input[i].b=1;input[i].id=i;
        input[i].gain=5;input[i].net=0;input[i].vertices[0]=0;input[i].vertices[1]=1;
    }
    std::swap(input[1].vertices[0],input[1].vertices[1]);
    input[3].vertices[1]=2; // Same weight/gain, different shape must survive.
    input[5].b=2; // Same set, different destination must survive.
    input[6].size=0; // An empty first policy cannot suppress a valid second.
    thrust::device_vector<gpart::JointMove> dm=input;
    gpart::joint_deduplicate_policies<<<1,256>>>(8,device_ptr(dm));
    CUDA_CHECK(cudaGetLastError());CUDA_CHECK(cudaDeviceSynchronize());
    std::vector<gpart::JointMove> out(8);thrust::copy(dm.begin(),dm.end(),out.begin());
    for(int i=0;i<8;++i) require(out[i].size==((i==1 || i==6) ? 0 : 2),"policy dedup removed a distinct candidate");
}
void check_prefix_limit() {
    std::vector<gpart::JointMove> moves(3);
    const long long gain[3]={10,9,8},net[3]={2,2,-1};
    for(int i=0;i<3;++i) {moves[i].size=1;moves[i].vertices[0]=i;moves[i].a=0;moves[i].b=1;moves[i].net=net[i];}
    thrust::device_vector<gpart::JointMove> dm=moves;
    thrust::device_vector<unsigned long long> events(3),loads(2,100);
    thrust::device_vector<int> stops(2,-1);
    for(int i=0;i<3;++i) events[i]=gain[i];
    gpart::joint_prefix<<<1,128>>>(3,2,device_ptr(dm),device_ptr(events),device_ptr(loads),102,device_ptr(stops));
    CUDA_CHECK(cudaGetLastError());CUDA_CHECK(cudaDeviceSynchronize());
    require(static_cast<int>(stops[0])==0,"best exact prefix changed unexpectedly");
    long long best_subset=0;
    for(int mask=0;mask<8;++mask) {
        long long g=0,d=0;
        for(int i=0;i<3;++i) if(mask&(1<<i)) {g+=gain[i];d+=net[i];}
        if(d>=-2 && d<=2) best_subset=std::max(best_subset,g);
    }
    require(best_subset==18,"non-prefix capacity-complement example incorrect");
    // This is a documented search limitation, not a fix in this revision.
}
} // namespace
int main() {
    try {
        check_conflicts();check_policy_dedup();check_prefix_limit();
        std::mt19937 rng(41289);
        constexpr int n=96,k=4,count=32;
        for(int trial=0;trial<20;++trial) {
            std::vector<int> labels(n),targets(n),owners(n,INT_MAX),offsets{0},neighbors;
            std::vector<std::uint32_t> weights;
            std::vector<std::map<int,std::uint32_t>> rows(n);
            for(int v=0;v<n;++v) {
                labels[v]=v%k;
                for(int e=0;e<12;++e) {
                    int u=rng()%n;
                    std::uint32_t w=1+rng()%10000000;
                    rows[v][u]+=w;if(u!=v) rows[u][v]+=w;
                }
            }
            for(auto& row:rows) {
                for(auto [u,w]:row) {neighbors.push_back(u);weights.push_back(w);}
                offsets.push_back(neighbors.size());
            }
            std::vector<gpart::JointMove> moves(count);
            std::vector<bool> used(n);
            for(int i=0;i<count;++i) {
                auto& m=moves[i];m.a=i<16 ? 0 : 2;m.b=m.a+1;m.id=i;
                int size=1+rng()%3;
                for(int j=0;j<size;++j) {
                    int v=rng()%n,tries=0;
                    while((used[v] || labels[v]/2!=m.a/2) && ++tries<n) v=(v+1)%n;
                    if(tries==n) break;
                    used[v]=true;m.vertices[m.size++]=v;owners[v]=i;
                    targets[v]=labels[v]==m.a ? m.b : m.a;
                    m.net+=labels[v]==m.a ? 1 : -1;
                }
            }
            thrust::device_vector<int> dl=labels,dt=targets,doo=owners,doff=offsets,dn=neighbors,stops(k,-1);
            thrust::device_vector<std::uint32_t> dw=weights;
            thrust::device_vector<gpart::JointMove> dm=moves;
            thrust::device_vector<unsigned long long> events(count,0),loads(k,n/k);
            auto ptr=[](auto& x) {return thrust::raw_pointer_cast(x.data());};
            gpart::joint_events<<<(count+7)/8,256>>>(count,ptr(dm),ptr(doo),ptr(dt),ptr(dl),ptr(doff),ptr(dn),ptr(dw),ptr(events));
            gpart::joint_prefix<<<1,128>>>(count,k,ptr(dm),ptr(events),ptr(loads),n/k+4,ptr(stops));
            CUDA_CHECK(cudaGetLastError());CUDA_CHECK(cudaDeviceSynchronize());
            std::vector<unsigned long long> actual(count);thrust::copy(events.begin(),events.end(),actual.begin());
            std::vector<int> actual_stop(k);thrust::copy(stops.begin(),stops.end(),actual_stop.begin());
            auto cut=[&](const std::vector<int>& p) {
                long long value=0;
                for(int v=0;v<n;++v) for(int e=offsets[v];e<offsets[v+1];++e)
                    if(v<neighbors[e] && p[v]!=p[neighbors[e]]) value+=weights[e];
                return value;
            };
            const auto initial=cut(labels);
            for(int a : {0,2}) {
                auto p=labels;long long prefix=0,best=0,net=0;int expected_stop=-1;
                for(int i=0;i<count;++i) if(moves[i].size && moves[i].a==a) {
                    for(int j=0;j<moves[i].size;++j) p[moves[i].vertices[j]]=targets[moves[i].vertices[j]];
                    prefix+=static_cast<long long>(actual[i]);net+=moves[i].net;
                    if(prefix!=initial-cut(p)) throw std::runtime_error("edge events differ from independent complete cut at a prefix");
                    if(net>=-4 && net<=4 && prefix>best) {best=prefix;expected_stop=i;}
                }
                if(actual_stop[a]!=expected_stop) throw std::runtime_error("best feasible prefix differs from CPU enumeration");
            }
        }
        std::cout << "joint oracles: conflict recovery, policy dedup, prefix limitation and 20 weighted random event graphs passed\n";
    } catch(const std::exception& e) {std::cerr<<e.what()<<'\n';return 1;}
}
