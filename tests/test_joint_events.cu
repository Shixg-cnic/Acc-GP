#include "graph_types.hpp"
#include "check.hpp"
#include "detail/edge_weight.hpp"
#include <cuda/atomic>
#include <thrust/device_vector.h>
#include <thrust/copy.h>
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
int main() {
    try {
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
        std::cout << "joint exact-prefix oracle: 20 weighted random graphs, two simultaneous block pairs, self loops and cross-transaction edges passed\n";
    } catch(const std::exception& e) {std::cerr<<e.what()<<'\n';return 1;}
}
