#include <random>
#include "graph.hpp"
#include "graph_types.hpp"
#include "hierarchy.hpp"
#include "refine.hpp"
#include "uncoarsen.hpp"
#include "coarsen.hpp"
#include "detail/scratch_pool.hpp"
#include "detail/scratch_buffer.hpp"
#include "partition_capacity.hpp"
#include "../src/coarsen_rows.cuh"

#include <algorithm>
#include <thrust/sequence.h>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <map>
#include <stdexcept>
#include <vector>

namespace {

gpart::Hierarchy make_hierarchy() {
    using OffsetT = gpart::GraphTypes::OffsetT;
    using VertexT = gpart::GraphTypes::VertexT;
    using WeightT = gpart::GraphTypes::WeightT;
    gpart::WeightedGraph fine;
    fine.offsets = {OffsetT{0}, OffsetT{1}, OffsetT{3}, OffsetT{5}, OffsetT{6}};
    fine.neighbors = {
        VertexT{1}, VertexT{0}, VertexT{2},
        VertexT{1}, VertexT{3}, VertexT{2}};
    fine.edge_weights = {
        WeightT{1}, WeightT{1}, WeightT{5},
        WeightT{5}, WeightT{10}, WeightT{10}};
    fine.vertex_weights = {WeightT{1}, WeightT{1}, WeightT{1}, WeightT{1}};

    gpart::WeightedGraph coarse;
    coarse.offsets = {OffsetT{0}, OffsetT{1}, OffsetT{2}};
    coarse.neighbors = {VertexT{1}, VertexT{0}};
    coarse.edge_weights = {WeightT{5}, WeightT{5}};
    coarse.vertex_weights = {WeightT{2}, WeightT{2}};

    gpart::Hierarchy hierarchy;
    hierarchy.levels.push_back(std::move(fine));
    hierarchy.levels.push_back(std::move(coarse));
    hierarchy.fine_to_coarse.push_back(
        {VertexT{0}, VertexT{0}, VertexT{1}, VertexT{1}});
    return hierarchy;
}

void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}

void check_isolated_packing() {
    // Unequal weights include vertices crossing prefix-bin boundaries.
    gpart::WeightedGraph host;
    host.vertex_weights = {7,7,1,4,4,1,1,8,1,3,6,2};
    host.offsets = {0,1,2,2,2,2,2,2,2,2,2,2,2};
    host.neighbors = {1,0};
    host.edge_weights = {3,3};
    auto device = gpart::make_device_weighted(host);
    gpart::SclpWorkspace workspace;
    gpart::SclpStats before_stats, after_stats;
    auto before = gpart::aggregate(device, workspace, 2, 0, 0, before_stats, false, 2, false);
    auto after = gpart::aggregate(device, workspace, 2, 0, 0, after_stats, true, 2, true);
    require(after.coarse_vertices < before.coarse_vertices,
            "isolated packing failed to contract zero-degree vertices");
    require(after.maximum_weight <= after.capacity,
            "isolated packing exceeded cluster capacity");
    std::vector<gpart::GraphTypes::VertexT> mapping(after.map.size());
    thrust::copy(after.map.begin(), after.map.end(), mapping.begin());
    require(mapping[0] != mapping[1], "heavy connected vertices exceeded merge capacity");
    for (std::size_t v = 2; v < mapping.size(); ++v)
        require(mapping[v] != mapping[0] && mapping[v] != mapping[1],
                "isolated packing joined a connected cluster");
}

void check_coarsening_frontier() {
    using W = gpart::GraphTypes::WeightT;
    using V = gpart::GraphTypes::VertexT;
    W scale = 1;

    for (bool parallel : {false, true}) {
        gpart::WeightedGraph host;
        std::vector<std::vector<std::pair<V,W>>> rows(768);
        const auto add = [&](int a, int b, int w) {
            rows[a].push_back({b,scale*w}); rows[b].push_back({a,scale*w});
        };
        // Capacity-sized high/low vertices must remain singletons. Movable
        // high/medium/low rows exercise all affinity paths and two-hop.
        for (int v = 4; v < 344; ++v) { add(0,v,100); add(2,v,1); }
        for (int v = 350; v < 382; ++v) add(3,v,5);
        for (int v = 4; v < 7; ++v) add(1,v,100);
        for (int v = 4; v < 767; v += 2) add(v,v+1,10);
        if (parallel) { add(4,5,7); rows[2].push_back({2,scale*3}); }
        host.vertex_weights.assign(rows.size(),scale);
        host.vertex_weights[0] = host.vertex_weights[1] = scale*32;
        host.offsets.push_back(0);
        for (auto& row : rows) {
            std::sort(row.begin(),row.end());
            for (auto [u,w] : row) { host.neighbors.push_back(u); host.edge_weights.push_back(w); }
            host.offsets.push_back(host.neighbors.size());
        }
        auto device = gpart::make_device_weighted(host);
        for (unsigned seed = 0; seed < 3; ++seed) {
            gpart::SclpWorkspace fast_ws, full_ws;
            gpart::SclpStats fast_stats, full_stats;
            auto fast = gpart::aggregate(device,fast_ws,4,seed,0,fast_stats,false,8,false);
            auto full = gpart::aggregate(device,full_ws,4,seed,0,full_stats,true,8,false);
            std::vector<V> fast_map(fast.map.size()), full_map(full.map.size());
            thrust::copy(fast.map.begin(),fast.map.end(),fast_map.begin());
            thrust::copy(full.map.begin(),full.map.end(),full_map.begin());
            require(fast_map == full_map && fast_stats.rounds == full_stats.rounds,
                    "coarsening frontier differs from complete affinity scan");
            require(fast.coarse_vertices < host.vertices() && fast.maximum_weight <= fast.capacity,
                    "coarsening frontier failed to contract within capacity");
            for (int fixed : {0,1})
                require(std::count(fast_map.begin(),fast_map.end(),fast_map[fixed]) == 1,
                        "capacity-sized coarsening vertex absorbed another vertex");
        }
    }
}

void check_connected_group_exchange() {
    using W=gpart::GraphTypes::WeightT;
    using V=gpart::GraphTypes::VertexT;
    gpart::WeightedGraph graph;
    std::vector<std::vector<std::pair<int,W>>> rows(10);
    W scale=1;

    const auto add=[&](int a,int b,int w) {
        rows[a].push_back({b,scale*w});rows[b].push_back({a,scale*w});
    };
    for (int base : {0,3}) {
        for (int a=base;a<base+3;++a) for (int b=a+1;b<base+3;++b) add(a,b,10);
        for (int a=base;a<base+3;++a) add(a,base==0 ? 8 : 6,4);
    }
    // These cross-group edges remain cut after exchanging both groups. Their
    // contribution must be subtracted twice from the individual gain sum.
    for (int v=0;v<3;++v) add(v,v+3,1);
    add(6,7,100);add(8,9,100);
    graph.offsets.push_back(0);
    graph.vertex_weights={2,2,2,2,2,2,20,20,20,20};
    for (const auto& row:rows) {
        for (auto [u,w]:row) { graph.neighbors.push_back(u);graph.edge_weights.push_back(w); }
        graph.offsets.push_back(graph.neighbors.size());
    }
    const std::vector<V> original{0,0,0,1,1,1,0,0,1,1};
    auto labels=original;
    gpart::RefineOptions options;
    options.parts=2;options.strict_verify=true;options.boundary_group_rounds=0;
    gpart::RefineStats stats;
    gpart::refine_partition(graph,labels,options,&stats);
    require(labels==original,"group regression no longer exercises an LP local optimum");
    options.boundary_group_rounds=1;
    gpart::refine_partition(graph,labels,options,&stats);
    require(gpart::host_cut(graph,labels)==static_cast<std::uint64_t>(scale)*3 && stats.group_accepted==6 &&
            stats.group_cut_gain==static_cast<std::uint64_t>(scale)*24,
            "connected weighted groups failed to escape the single-vertex optimum");
    std::uint64_t loads[2]={0,0};
    for (int v=0;v<10;++v) loads[labels[v]]+=graph.vertex_weights[v];
    require(loads[0]==46 && loads[1]==46,"connected transaction lost capacity neutrality");
    // Unequal group weights are legal when their net difference fits slack.
    graph.vertex_weights[3]=1;
    labels=original;
    gpart::refine_partition(graph,labels,options,&stats);
    require(gpart::host_cut(graph,labels)==static_cast<std::uint64_t>(scale)*3 && stats.group_accepted==6,
            "unequal-weight group transaction failed");
    loads[0]=loads[1]=0;
    for (int v=0;v<10;++v) loads[labels[v]]+=graph.vertex_weights[v];
    require(loads[0]==45 && loads[1]==46,"unequal group weights exceeded integer capacity");
    // Production omits the final full-CSR cut scan. Its maintained cut must
    // still agree with the independent host oracle after group transactions.
    options.strict_verify=false;labels=original;
    gpart::refine_partition(graph,labels,options,&stats);
    require(stats.final_cut==gpart::host_cut(graph,labels) &&
            stats.final_cut==static_cast<std::uint64_t>(scale)*3,
            "production maintained cut differs after group exchange");


}

void check_joint_refinement() {
    // Two weighted triangles require crossing a negative singleton barrier.
    // Neither part can accommodate a triangle without simultaneous counterflow.
    gpart::WeightedGraph graph;
    std::vector<std::map<int,std::uint32_t>> rows(10);
    auto add=[&](int a,int b,int w) {rows[a][b]+=w;rows[b][a]+=w;};
    for(int base : {0,3}) {
        for(int a=base;a<base+3;++a) for(int b=a+1;b<base+3;++b) add(a,b,10);
        for(int a=base;a<base+3;++a) add(a,base==0 ? 8 : 6,4);
    }
    for(int v=0;v<3;++v) add(v,v+3,1);
    add(6,7,100);add(8,9,100);
    graph.vertex_weights={2,2,2,2,2,2,20,20,20,20};graph.offsets={0};
    for(auto& row:rows) {
        for(auto [u,w]:row) {graph.neighbors.push_back(u);graph.edge_weights.push_back(w);}
        graph.offsets.push_back(graph.neighbors.size());
    }
    for(auto layout : {gpart::AffinityLayout::Dense,gpart::AffinityLayout::Sparse,gpart::AffinityLayout::OnDemand})
    for(int conflict_rounds : {1,2,4}) for(bool dedup : {false,true}) {
        std::vector<int> labels{0,0,0,1,1,1,0,0,1,1};
        gpart::RefineOptions options;options.parts=2;options.mode=gpart::RefinementMode::Joint;
        options.affinity_layout=layout;options.strict_verify=true;options.joint_rounds=4;
        options.joint_conflict_rounds=conflict_rounds;options.joint_deduplicate=dedup;
        gpart::RefineStats stats;gpart::refine_partition(graph,labels,options,&stats);
        require(stats.lp_cut_gain==0 && stats.lp_cut_loss==0,"joint mode unexpectedly ran LP");
        require(stats.final_cut==3 && gpart::host_cut(graph,labels)==3 && stats.group_cut_gain==24,
                "joint growth did not cross the negative connected-group barrier");
    }
    // Random symmetric weighted inputs, exact initial balance, all supported k.
    std::mt19937 random(781);
    for(int k : {4,8,16,32,64,128}) for(int trial=0;trial<3;++trial) {
        const int n=k*8;
        gpart::WeightedGraph g;std::vector<std::map<int,std::uint32_t>> edges(n);
        std::vector<int> initial(n);
        for(int v=0;v<n;++v) {
            initial[v]=v/8;g.vertex_weights.push_back(1+v%8);
            for(int j=0;j<5;++j) {
                int u=random()%n;if(u==v) continue;
                auto w=1+random()%100;edges[v][u]+=w;edges[u][v]+=w;
            }
        }
        g.offsets={0};
        for(auto& row:edges) {
            for(auto [u,w]:row) {g.neighbors.push_back(u);g.edge_weights.push_back(w);}
            g.offsets.push_back(g.neighbors.size());
        }
        for(auto mode : {gpart::RefinementMode::Joint,gpart::RefinementMode::JointPolish}) {
        auto labels=initial;gpart::RefineOptions o;o.parts=k;o.strict_verify=true;
        o.mode=mode;o.joint_rounds=4;
        o.joint_conflict_rounds=trial+2;o.joint_deduplicate=trial!=1;
        o.joint_diagnostics=(k==4 && trial==0 && mode==gpart::RefinementMode::Joint);
        o.affinity_layout=trial==0 ? gpart::AffinityLayout::Dense : trial==1 ? gpart::AffinityLayout::Sparse : gpart::AffinityLayout::OnDemand;
        gpart::RefineStats stats;gpart::refine_partition(g,labels,o,&stats);
        std::vector<std::uint64_t> loads(k);
        for(int v=0;v<n;++v) loads[labels[v]]+=g.vertex_weights[v];
        require(*std::max_element(loads.begin(),loads.end())<=37,"joint random capacity violated");
        require(stats.final_cut==gpart::host_cut(g,labels) && stats.final_cut<=gpart::host_cut(g,initial),
                "joint random result violates exact monotonicity");
        }
    }
}

void check_heavy_refinement_rows() {
    using W=gpart::GraphTypes::WeightT;
    using V=gpart::GraphTypes::VertexT;
    constexpr int n=10000;
    W scale=3;

    std::vector<std::vector<int>> rows(n);
    const auto add=[&](int a,int b) { rows[a].push_back(b);rows[b].push_back(a); };
    // Both hubs exceed the segmented-row threshold and migrate concurrently.
    // Their common edge must be owned once; nonunit weights test exact deltas.
    for (int v=1;v<=1000;++v) add(0,v);
    for (int v=5000;v<n;++v) add(0,v);
    for (int v=1;v<5000;++v) add(5000,v);
    for (int v=5001;v<=6000;++v) add(5000,v);
    gpart::WeightedGraph graph;
    graph.vertex_weights.assign(n,2);
    graph.offsets.push_back(0);
    for (auto& row:rows) {
        std::sort(row.begin(),row.end());
        for (auto u:row) { graph.neighbors.push_back(u);graph.edge_weights.push_back(scale); }
        graph.offsets.push_back(graph.neighbors.size());
    }
    gpart::RefineOptions options;
    options.parts=2;options.strict_verify=true;options.boundary_group_rounds=0;
    // Standard: known incident bound selects 32-bit cache; unknown selects
    // 64-bit. Big additionally exercises affinities well above UINT32_MAX.
    for (bool known_bound:{true,false}) {
        options.affinity_layout=known_bound ? gpart::AffinityLayout::OnDemand : gpart::AffinityLayout::Automatic;
        gpart::DeviceHierarchy hierarchy;
        hierarchy.levels.push_back(gpart::make_device_weighted(graph));
        if (known_bound) hierarchy.levels[0].incident_weight_bound=std::uint64_t(scale)*6000;
        std::vector<V> labels(n);
        for (int v=0;v<n;++v) labels[v]=v/5000;
        thrust::device_vector<V> device_labels=labels;
        auto result=gpart::refine_hierarchy_device(hierarchy,std::move(device_labels),options);
        thrust::copy(result.device_partition.begin(),result.device_partition.end(),labels.begin());
        require(labels[0]==1 && labels[5000]==0,"heavy hubs failed simultaneous migration");
        require(result.final_cut==gpart::host_cut(graph,labels) &&
                result.final_cut<=6003*std::uint64_t(scale),"segmented heavy-row cut differs from CSR oracle");
        require(*std::max_element(result.final_part_weights.begin(),result.final_part_weights.end())<=
                gpart::partition_capacity(2*std::uint64_t(n),2,1.03),"segmented heavy rows exceeded capacity");
    }
}

void check_negative_group_prefix() {
    using V=gpart::GraphTypes::VertexT;
    using W=gpart::GraphTypes::WeightT;
    W scale=1;

    gpart::WeightedGraph graph;
    std::vector<std::vector<std::pair<V,W>>> rows(8);
    const auto add=[&](int a,int b,int w) {
        rows[a].push_back({b,scale*w});rows[b].push_back({a,scale*w});
    };
    for (int a=0;a<4;++a) {
        for (int b=a+1;b<4;++b) add(a,b,10);
        add(a,6,5);
    }
    add(4,5,100);add(6,7,100);
    graph.vertex_weights={1,1,1,1,66,66,68,68};graph.offsets.push_back(0);
    for (const auto& row:rows) {
        for (auto [u,w]:row) { graph.neighbors.push_back(u);graph.edge_weights.push_back(w); }
        graph.offsets.push_back(graph.neighbors.size());
    }
    const std::vector<V> original{0,0,0,0,0,0,1,1};
    auto labels=original;
    gpart::RefineOptions options;
    options.parts=2;options.imbalance_ratio=1.03;options.max_rounds=1;options.strict_verify=true;
    options.boundary_group_rounds=0;
    gpart::RefineStats stats;
    gpart::refine_partition(graph,labels,options,&stats);
    require(labels==original,"negative-prefix fixture escaped through LP");
    options.boundary_group_rounds=1;
    gpart::refine_partition(graph,labels,options,&stats);
    // Prefix gains are -25, -30, -15, +20. Stopping at the first losing
    // extension misses the profitable connected four-vertex transfer.
    require(stats.group_accepted==4 && stats.group_cut_gain==20*static_cast<std::uint64_t>(scale) &&
            stats.final_cut==0 && gpart::host_cut(graph,labels)==0 && stats.final_max_part_weight==140,
            "virtual losing prefixes failed to expose a feasible improving group");
}

void check_collective_group_target() {
    using V=gpart::GraphTypes::VertexT;
    using W=gpart::GraphTypes::WeightT;
    W scale=1;

    gpart::WeightedGraph graph;
    std::vector<std::vector<std::pair<V,W>>> rows(10);
    const auto add=[&](int a,int b,int w) {
        rows[a].push_back({b,scale*w});rows[b].push_back({a,scale*w});
    };
    add(0,1,20);add(0,4,10);add(0,6,9);add(1,8,10);add(1,6,9);
    for (int v : {2,4,6,8}) add(v,v+1,100);
    graph.vertex_weights={1,1,63,63,64,64,64,64,64,64};graph.offsets.push_back(0);
    for (const auto& row:rows) {
        for (auto [u,w]:row) { graph.neighbors.push_back(u);graph.edge_weights.push_back(w); }
        graph.offsets.push_back(graph.neighbors.size());
    }
    const std::vector<V> original{0,0,0,0,1,1,2,2,3,3};
    auto labels=original;
    gpart::RefineOptions options;
    options.parts=4;options.imbalance_ratio=1.03;options.max_rounds=1;
    options.strict_verify=true;options.boundary_group_rounds=0;
    gpart::RefineStats stats;
    gpart::refine_partition(graph,labels,options,&stats);
    require(labels==original,"collective-destination fixture escaped through LP");
    options.boundary_group_rounds=1;
    gpart::refine_partition(graph,labels,options,&stats);
    // Individual favorites are B and D (10 each). Together C is better (18),
    // although neither member prefers it alone. Fixed seed targets miss C.
    require(labels[0]==2 && labels[1]==2 && stats.group_accepted==2 &&
            stats.group_cut_gain==18*static_cast<std::uint64_t>(scale) &&
            stats.final_cut==20*static_cast<std::uint64_t>(scale) && stats.final_cut==gpart::host_cut(graph,labels),
            "connected group failed to choose its collective destination");
}

void check_collective_group_target_high_k() {
    using V=gpart::GraphTypes::VertexT;using W=gpart::GraphTypes::WeightT;
    const W scale=W{1};
    for(int k : {64,128}) {
        const int source=k-32,destination=k-1,first=1,last=33;
        gpart::WeightedGraph graph;
        std::vector<std::vector<std::pair<V,W>>> rows(k+6);
        const auto add=[&](int a,int b,int w) {
            rows[a].push_back({b,scale*w});rows[b].push_back({a,scale*w});
        };
        add(0,1,20);add(0,4,10);add(0,6,9);add(1,8,10);add(1,6,9);
        for(int v : {2,4,6,8}) add(v,v+1,100);
        graph.vertex_weights={1,1,63,63,64,64,64,64,64,64};
        std::vector<V> original{source,source,source,source,first,first,destination,destination,last,last};
        for(int p=0;p<k;++p) if(p!=source && p!=first && p!=destination && p!=last) {
            graph.vertex_weights.push_back(W{128});original.push_back(p);
        }
        graph.offsets.push_back(0);
        for(const auto& row:rows) {
            for(auto [u,w]:row) {graph.neighbors.push_back(u);graph.edge_weights.push_back(w);}
            graph.offsets.push_back(graph.neighbors.size());
        }
        gpart::RefineOptions options;options.parts=k;options.max_rounds=1;
        options.affinity_layout=gpart::AffinityLayout::Sparse;
        options.strict_verify=true;options.boundary_group_rounds=0;
        auto labels=original;gpart::RefineStats stats;
        gpart::refine_partition(graph,labels,options,&stats);
        require(labels==original,"high-k fixture escaped through LP");
        options.boundary_group_rounds=1;
        gpart::refine_partition(graph,labels,options,&stats);
        require(labels[0]==destination && labels[1]==destination && stats.group_accepted==2 &&
            stats.group_cut_gain==18*static_cast<std::uint64_t>(scale) &&
            stats.final_cut==20*static_cast<std::uint64_t>(scale) && stats.final_cut==gpart::host_cut(graph,labels),
            "high-k collective source or destination lost its affinity tile");
    }
}

void check_affinity_counter_width() {
    using V=gpart::GraphTypes::VertexT;
    using W=gpart::GraphTypes::WeightT;
    constexpr std::uint64_t scale=std::uint64_t{1}<<25;
    for (bool wide : {false,true}) {
        gpart::WeightedGraph graph;
        std::vector<std::vector<std::pair<V,W>>> rows(6);
        const auto add=[&](int a,int b,int w) {
            rows[a].push_back({b,static_cast<W>(scale*w)});
            rows[b].push_back({a,static_cast<W>(scale*w)});
        };
        add(0,1,1);add(0,3,4);add(1,2,4);add(2,3,1);
        add(1,4,100);add(3,5,100);
        if (wide) add(1,4,100);
        graph.vertex_weights.assign(6,1);graph.offsets.push_back(0);
        std::uint64_t bound=0;
        for (const auto& row:rows) {
            std::uint64_t sum=0;
            for (auto [u,w]:row) { graph.neighbors.push_back(u);graph.edge_weights.push_back(w);sum+=w; }
            bound=std::max(bound,sum);graph.offsets.push_back(graph.neighbors.size());
        }
        gpart::DeviceHierarchy hierarchy;
        hierarchy.levels.reserve(2);
        for (int level=0;level<2;++level) {
            auto device=gpart::make_device_weighted(graph);
            device.incident_weight_bound=bound;
            hierarchy.levels.push_back(std::move(device));
        }
        thrust::device_vector<V> identity(6);
        thrust::sequence(identity.begin(),identity.end());
        hierarchy.fine_to_coarse.push_back(std::move(identity));
        const std::vector<V> original{0,0,1,1,0,1};
        thrust::device_vector<V> labels(original);
        gpart::RefineOptions options;
        options.parts=2;options.strict_verify=true;
        auto result=gpart::refine_hierarchy_device(hierarchy,std::move(labels),options);
        std::vector<V> output(result.device_partition.size());
        thrust::copy(result.device_partition.begin(),result.device_partition.end(),output.begin());
        require(result.final_cut==2*scale && gpart::host_cut(graph,output)==2*scale,
                "counter precision changed exact weighted cut");
        require(result.levels.size()==1 && result.levels[0].refinement.affinity_counter_bits==(wide ? 64 : 32),
                "incident-weight bound chose an unsafe or unnecessary counter width");
    }
}

void check_weight_compatible_groups() {
    using V=gpart::GraphTypes::VertexT;
    using W=gpart::GraphTypes::WeightT;
    W scale=1;

    const auto make=[&](bool solo) {
        gpart::WeightedGraph graph;
        const int n=solo ? 7 : 11;
        std::vector<std::vector<std::pair<V,W>>> rows(n);
        const auto add=[&](int a,int b,int w) {
            rows[a].push_back({b,scale*w});rows[b].push_back({a,scale*w});
        };
        for (int a=0;a<3;++a) for (int b=a+1;b<3;++b) add(a,b,10);
        if (solo) {
            graph.vertex_weights={2,2,2,125,125,122,122};
            for (int v=0;v<3;++v) add(v,5,4);
            add(3,4,100);add(5,6,100);
        } else {
            graph.vertex_weights={2,2,2,2,2,2,2,20,20,21,21};
            for (int a=4;a<7;++a) for (int b=a+1;b<7;++b) add(a,b,10);
            for (int v=0;v<3;++v) { add(v,3,1);add(v,9,4);add(v,v+4,1); }
            for (int v=4;v<7;++v) add(v,7,4);
            add(3,9,2);add(7,8,100);add(9,10,100);
        }
        graph.offsets.push_back(0);
        for (const auto& row:rows) {
            for (auto [u,w]:row) { graph.neighbors.push_back(u);graph.edge_weights.push_back(w); }
            graph.offsets.push_back(graph.neighbors.size());
        }
        return graph;
    };
    for (bool solo : {false,true}) {
        auto graph=make(solo);
        const std::vector<V> original=solo ? std::vector<V>{0,0,0,0,0,1,1} :
            std::vector<V>{0,0,0,0,1,1,1,0,0,1,1};
        auto labels=original;
        gpart::RefineOptions options;
        options.parts=2;options.strict_verify=true;options.boundary_group_rounds=0;
        gpart::RefineStats stats;
        gpart::refine_partition(graph,labels,options,&stats);
        require(labels==original,"weight-range fixture no longer exercises an LP local optimum");
        options.boundary_group_rounds=1;
        gpart::refine_partition(graph,labels,options,&stats);
        // The best weight-8 group cannot pair with the reverse weight-6
        // group. Keeping its weight-6 growth prefix exposes a feasible gain.
        const auto expected=static_cast<std::uint64_t>(scale)*(solo ? 0 : 8);
        require(gpart::host_cut(graph,labels)==expected && stats.final_cut==expected,
                "weight-compatible prefix or solo connected transfer was missed");
        require(stats.group_accepted==(solo ? 3 : 6),"weight-compatible group transfer count differs");
        options.strict_verify=false;labels=original;
        gpart::refine_partition(graph,labels,options,&stats);
        require(stats.final_cut==gpart::host_cut(graph,labels) && stats.final_cut==expected,
                "production weight-compatible transaction differs from CPU oracle");
    }
}

void check_scratch_pool_lifetime() {
    const auto previous = gpart::detail::active_scratch_pool;
    gpart::detail::ScratchVector<int> retained(5, 2);
    {
        gpart::detail::ScratchPoolSession nested;
        gpart::detail::ScratchVector<int> temporary(17, 9);
        retained = std::move(temporary);
        nested.finish();
    }
    require(gpart::detail::active_scratch_pool == previous,
            "scratch session did not restore its caller's pool");
    retained.resize(33, 9);
    std::vector<int> values(retained.size());
    thrust::copy(retained.begin(), retained.end(), values.begin());
    require(values == std::vector<int>(33, 9),
            "scratch vector lost storage after its session finished");

    // Exercise stream ordering directly: vector operations may synchronize
    // internally and would otherwise hide an incorrectly ordered free/reuse.
    gpart::detail::ScratchPoolSession ordered;
    gpart::detail::ScratchAllocator<int> allocator;
    constexpr std::size_t count = 257;
    auto source = allocator.allocate(count);
    auto saved = allocator.allocate(count);
    CUDA_CHECK(cudaMemsetAsync(thrust::raw_pointer_cast(source), 0x11,
                              count * sizeof(int), nullptr));
    CUDA_CHECK(cudaMemcpyAsync(thrust::raw_pointer_cast(saved),
        thrust::raw_pointer_cast(source), count * sizeof(int),
        cudaMemcpyDeviceToDevice, nullptr));
    allocator.deallocate(source, count);
    auto reused = allocator.allocate(count);
    CUDA_CHECK(cudaMemsetAsync(thrust::raw_pointer_cast(reused), 0x22,
                              count * sizeof(int), nullptr));
    std::vector<int> saved_values(count);
    CUDA_CHECK(cudaMemcpy(saved_values.data(), thrust::raw_pointer_cast(saved),
                         count * sizeof(int), cudaMemcpyDeviceToHost));
    require(saved_values == std::vector<int>(count, 0x11111111),
            "scratch reuse overtook a pending default-stream read");
    allocator.deallocate(saved, count);
    allocator.deallocate(reused, count);
    ordered.finish();
}

void check_overwrite_growth_order() {
    constexpr std::size_t n=257;
    std::vector<int> result(n);
    gpart::detail::ScratchPoolSession pipeline;
    {
        gpart::detail::ScratchBuffer<int> source(n),saved(n);
        CUDA_CHECK(cudaMemsetAsync(thrust::raw_pointer_cast(source.data()),0x37,n*sizeof(int)));
        CUDA_CHECK(cudaMemcpyAsync(thrust::raw_pointer_cast(saved.data()),thrust::raw_pointer_cast(source.data()),
            n*sizeof(int),cudaMemcpyDeviceToDevice));
        source.reserve(2*n);
        require(source.size()==n,"overwrite reserve changed logical size");
        source.resize(2*n);
        CUDA_CHECK(cudaMemsetAsync(thrust::raw_pointer_cast(source.data()),0x51,2*n*sizeof(int)));
        CUDA_CHECK(cudaMemcpyAsync(result.data(),thrust::raw_pointer_cast(saved.data()),n*sizeof(int),cudaMemcpyDeviceToHost));
    }
    pipeline.finish();
    require(result==std::vector<int>(n,0x37373737),"overwrite growth overtook its pending reader");
}

void check_parallel_cut() {
    using V = gpart::GraphTypes::VertexT;
    using W = gpart::GraphTypes::WeightT;
    constexpr int n = 259;
    std::vector<std::vector<V>> rows(n);
    const auto add = [&](int v, int u) { rows[v].push_back(u); rows[u].push_back(v); };
    for (int v = 1; v < n - 1; ++v) {
        add(0, v);
        add(0, v); // Repeated entries must each contribute their weight.
        if (v > 1) add(v - 1, v);
    }
    gpart::WeightedGraph graph;
    graph.offsets.push_back(0);
    graph.vertex_weights.assign(n, 1);
    W weight = 7;

    for (auto& row : rows) {
        std::sort(row.begin(), row.end());
        graph.neighbors.insert(graph.neighbors.end(), row.begin(), row.end());
        graph.edge_weights.insert(graph.edge_weights.end(), row.size(), weight);
        graph.offsets.push_back(graph.neighbors.size());
    }
    // Hub, isolated tail vertex, partial final block and >32-bit cut totals.
    for (bool interleaved : {false, true}) {
        std::vector<V> labels(n);
        for (int v = 0; v < n; ++v) labels[v] = interleaved ? v % 4 : v / 65;
        const auto original = labels;
        const auto expected = gpart::host_cut(graph, labels);
        gpart::RefineOptions options;
        options.parts = 4;
        options.imbalance_ratio = 1.10;
        options.max_rounds = 0;
        options.strict_verify = true;
        gpart::RefineStats stats;
        gpart::refine_partition(graph, labels, options, &stats);
        require(labels == original && stats.initial_cut == expected && stats.final_cut == expected,
                "parallel cut differs from independent CPU cut");
    }
}

void check_cross_edge_contraction() {
    using V = gpart::GraphTypes::VertexT;
    using W = gpart::GraphTypes::WeightT;
    using O = gpart::GraphTypes::OffsetT;
    // Non-warp-aligned row count, empty rows, duplicate entries, self loops,
    // all-internal edges, and repeated calls using the same scratch buffers.
    gpart::SclpWorkspace workspace;
    for (bool unit : {false,true}) for (int groups : {7, 1, 7}) {
        constexpr int n = 35;
        gpart::WeightedGraph input, expected;
        std::vector<V> mapping(n);
        expected.vertex_weights.assign(groups, W{0});
        input.vertex_weights.assign(n, W{1});
        input.offsets.push_back(0);
        std::map<std::pair<V, V>, W> edges;
        W weight = unit ? W{1} : W{3};

        for (int v = 0; v < n; ++v) {
            mapping[v] = v % groups;
            ++expected.vertex_weights[mapping[v]];
            for (int u = 0; u < n - 1 && v < n - 1; ++u) {
                for (int duplicate = 0; duplicate < 2; ++duplicate) {
                    input.neighbors.push_back(u);
                    input.edge_weights.push_back(weight);
                    if (v % groups != u % groups)
                        edges[{v % groups, u % groups}] += weight;
                }
            }
            input.offsets.push_back(static_cast<O>(input.neighbors.size()));
        }
        expected.offsets.push_back(0);
        for (int v = 0; v < groups; ++v) {
            for (const auto& edge : edges) if (edge.first.first == v) {
                expected.neighbors.push_back(edge.first.second);
                expected.edge_weights.push_back(edge.second);
            }
            expected.offsets.push_back(static_cast<O>(expected.neighbors.size()));
        }
        for (bool omit : {false,true}) {
            auto device=gpart::make_device_weighted(input,omit);
            require(device.implicit_unit_weights==(unit && omit),"incorrect implicit unit metadata");
            require(device.edge_weights.size()==(unit && omit ? 0 : input.edges()),
                    "unit edge weights were not omitted exactly");
            const auto roundtrip=gpart::copy_device_weighted(device);
            require(roundtrip.offsets==input.offsets && roundtrip.neighbors==input.neighbors &&
                    roundtrip.edge_weights==input.edge_weights && roundtrip.vertex_weights==input.vertex_weights,
                    "implicit/explicit graph round trip differs");
        }
        gpart::DeviceAggregateResult aggregate;
        aggregate.map.assign(mapping.begin(), mapping.end());
        aggregate.vertex_weights.assign(expected.vertex_weights.begin(), expected.vertex_weights.end());
        aggregate.coarse_vertices = groups;
        gpart::ContractionTimings timing;
        auto actual = gpart::copy_device_weighted(gpart::contract(
            gpart::make_device_weighted(input), std::move(aggregate), workspace, timing));
        require(actual.offsets == expected.offsets && actual.neighbors == expected.neighbors &&
                actual.edge_weights == expected.edge_weights && actual.vertex_weights == expected.vertex_weights,
                "cross-edge contraction differs from independent CPU reduction");
    }
    for (bool empty : {false, true}) {
        auto input = make_hierarchy().levels.front();
        if (empty) {
            input.neighbors.clear();
            input.edge_weights.clear();
            input.offsets.assign(input.vertices() + 1, 0);
        }
        std::vector<V> identity{0, 1, 2, 3};
        gpart::DeviceAggregateResult aggregate;
        aggregate.coarse_vertices = 4;
        aggregate.map.assign(identity.begin(), identity.end());
        aggregate.vertex_weights.assign(input.vertex_weights.begin(), input.vertex_weights.end());
        gpart::ContractionTimings timing;
        auto actual = gpart::copy_device_weighted(gpart::contract(
            gpart::make_device_weighted(input), std::move(aggregate), workspace, timing));
        require(actual.offsets == input.offsets && actual.neighbors == input.neighbors &&
                actual.edge_weights == input.edge_weights && actual.vertex_weights == input.vertex_weights,
                "identity contraction changed singleton or empty CSR rows");
    }
}

void check_sort_weight_width() {
    using V = gpart::GraphTypes::VertexT;
    using W = gpart::GraphTypes::WeightT;
    // Exercise the hub-sort path, duplicate edges, and the >UINT32_MAX
    // total-weight fallback. Compare every level to the original 64-bit path.
    std::vector<W> tested_weights{W{1}, W{1000000}};

    for (W weight : tested_weights) {
        constexpr int n = 4096;
        std::vector<std::vector<V>> rows(n);
        const auto add = [&](int a, int b) { rows[a].push_back(b); rows[b].push_back(a); };
        for (int v = 0; v < n; ++v) add(v, (v + 1) % n);
        for (int v = 1; v <= 512; ++v) add(0, v);
        rows[0].push_back(0); // Hub sentinel must not collide with a packed key.
        gpart::WeightedGraph input;
        input.offsets.push_back(0);
        input.vertex_weights.assign(n, 1);
        for (auto& row : rows) {
            std::sort(row.begin(), row.end());
            input.neighbors.insert(input.neighbors.end(), row.begin(), row.end());
            input.edge_weights.insert(input.edge_weights.end(), row.size(), weight);
            input.offsets.push_back(input.neighbors.size());
        }
        gpart::CoarsenOptions options;
        auto candidate = gpart::coarsen(gpart::make_device_weighted(input), options);
        require(candidate.levels.capacity() >= static_cast<std::size_t>(options.max_levels) + 1 &&
                candidate.fine_to_coarse.capacity() >= static_cast<std::size_t>(options.max_levels),
                "device hierarchy growth can deep-copy previous GPU levels");
        auto reference = gpart::make_device_weighted(input);
        gpart::SclpWorkspace workspace; // Default standalone path is 64-bit.
        std::size_t produced = 1;
        for (int level = 0; level < options.max_levels && reference.vertices() > 1024; ++level) {
            gpart::SclpStats stats;
            auto aggregate = gpart::aggregate(reference, workspace, 4, level, level, stats, false);
            if (aggregate.coarse_vertices >= reference.vertices() ||
                double(aggregate.coarse_vertices) / reference.vertices() > options.stop_contraction_ratio) break;
            require(produced < candidate.levels.size(), "packed hierarchy ended early");
            std::vector<V> expected_map(aggregate.map.size()), actual_map(aggregate.map.size());
            thrust::copy(aggregate.map.begin(), aggregate.map.end(), expected_map.begin());
            thrust::copy(candidate.fine_to_coarse[level].begin(), candidate.fine_to_coarse[level].end(), actual_map.begin());
            require(expected_map == actual_map, "packed affinity changed mapping");
            gpart::ContractionTimings timing;
            reference = gpart::contract(std::move(reference), std::move(aggregate), workspace, timing);
            auto expected = gpart::copy_device_weighted(reference);
            auto actual = gpart::copy_device_weighted(candidate.levels[produced++]);
            require(expected.offsets == actual.offsets && expected.neighbors == actual.neighbors &&
                    expected.edge_weights == actual.edge_weights && expected.vertex_weights == actual.vertex_weights,
                    "packed sort/reduce changed CSR");
        }
        require(produced == candidate.levels.size(), "packed hierarchy has extra levels");
    }
}

void check_receiver_counterflow() {
    using W=gpart::GraphTypes::WeightT;
    using V=gpart::GraphTypes::VertexT;
    for(int k : {4,64,128}) {
    gpart::WeightedGraph graph;
    std::vector<std::vector<std::pair<int,W>>> rows(64*k);
    W scale=1;

    const auto add=[&](int a,int b,int w) {
        rows[a].push_back({b,scale*w});rows[b].push_back({a,scale*w});
    };
    for(int v=0;v<20;++v) {add(v,20,1);add(v,64,10);}
    for(int v=21;v<64;++v) add(v,20,100);
    for(int v=65;v<128;++v) {add(v,64,4);add(v,128,1);}
    for(int v=129;v<192;++v) add(v,128,100);
    for(int v=193;v<256;++v) add(v,192,100);
    graph.vertex_weights.assign(64*k,1);graph.offsets.push_back(0);
    for(const auto& row:rows) {
        for(auto [u,w]:row) {graph.neighbors.push_back(u);graph.edge_weights.push_back(w);}
        graph.offsets.push_back(graph.neighbors.size());
    }
    const int mapping[4]={k==4 ? 0 : k-2,k==4 ? 1 : k-1,k==4 ? 2 : k/2,k==4 ? 3 : 0};
    std::vector<V> labels;
    for(int v=0;v<256;++v) labels.push_back(mapping[v/64]);
    for(int p=0;p<k;++p) if(std::find(mapping,mapping+4,p)==mapping+4)
        for(int i=0;i<64;++i) labels.push_back(p);
    const auto before=gpart::host_cut(graph,labels);
    gpart::RefineOptions options;options.affinity_layout=gpart::AffinityLayout::Sparse;
    options.parts=k;options.max_rounds=1;options.boundary_group_rounds=0;options.strict_verify=true;
    gpart::RefineStats stats;
    gpart::refine_partition(graph,labels,options,&stats);
    // Twenty improving LP moves overload part 1. Every repair donor prefers
    // part 2, whose room is only one; remaining donors must reach other parts
    // in this same batch. The old one-destination repair needs more batches.
    require(stats.admission_iterations==1 && stats.admission_fallbacks==0 &&
            stats.final_cut<before && stats.final_cut==gpart::host_cut(graph,labels),
            "receiver tickets failed to finish unit-weight counterflow in one batch");
    std::vector<std::uint64_t> loads(k,0);
    for(const auto p:labels) ++loads[p];
    require(*std::max_element(loads.begin(),loads.end())<=65,"receiver tickets overfilled a destination");
    }
}

void check_refinement_gain_overflow() {

}

}  // namespace

// A small initial boundary must grow as adjacent vertices move. Strict CSR
// checks exercise the conservative frontier, both affinity widths, and IDs
// above 63; small fixtures alone never enable this path.
void check_frontier_growth() {
    using V=gpart::GraphTypes::VertexT;using W=gpart::GraphTypes::WeightT;
    constexpr int n=131072;
    for(int k : {4,64,128}) {
        gpart::WeightedGraph graph;graph.offsets.push_back(0);
        const W scale=W{1};
        std::vector<V> labels(n);
        for(int v=0;v<n;++v) {
            graph.neighbors.push_back((v+n-1)%n);graph.edge_weights.push_back(scale);
            graph.neighbors.push_back((v+1)%n);graph.edge_weights.push_back(scale);
            graph.offsets.push_back(graph.neighbors.size());graph.vertex_weights.push_back(W{1});
            labels[v]=v/(n/k);
        }
        for(int p=0;p<k;p+=2) std::swap(labels[p*(n/k)+2],labels[(p+1)*(n/k)+2]);
        const auto before=gpart::host_cut(graph,labels);
        const auto original=labels;
        gpart::RefineOptions options;options.parts=k;options.strict_verify=true;
        options.max_rounds=4;options.boundary_group_rounds=0;
        // Explicit sparse mode also exercises a 64-bit weighted cache whose
        // conservative weight bound would otherwise select dense storage.
        if(k>4) options.affinity_layout=gpart::AffinityLayout::Sparse;
        gpart::RefineStats stats;gpart::refine_partition(graph,labels,options,&stats);
        require(stats.accepted>0 && stats.final_cut<=before &&
                stats.final_cut==gpart::host_cut(graph,labels),"frontier growth lost cut or active vertices");
        std::vector<std::uint64_t> loads(k,0);
        for(auto part:labels) ++loads[part];
        require(*std::max_element(loads.begin(),loads.end())<=gpart::partition_capacity(n,k,1.03),
                "frontier refinement exceeded capacity");
        gpart::DeviceHierarchy hierarchy;
        auto device_graph=gpart::make_device_weighted(graph);
        device_graph.incident_weight_bound=2*static_cast<std::uint64_t>(scale);
        device_graph.has_heavy_rows=false;
        hierarchy.levels.push_back(std::move(device_graph));
        thrust::device_vector<V> resident_labels(original);
        options.affinity_layout=gpart::AffinityLayout::Automatic;
        options.affinity_layout=gpart::AffinityLayout::OnDemand;
        const auto resident=gpart::refine_hierarchy_device(hierarchy,std::move(resident_labels),options);
        std::vector<V> checked(n);
        thrust::copy(resident.device_partition.begin(),resident.device_partition.end(),checked.begin());
        require(resident.final_cut<before && resident.final_cut==gpart::host_cut(graph,checked),
                "resident frontier failed its 32/64-bit CSR check");
        // Force a repair-only batch on a large layer. Every vertex of the
        // overloaded source, including interior points, must remain eligible.
        gpart::DeviceHierarchy repair_hierarchy;
        auto repair_graph=gpart::make_device_weighted(graph);
        repair_graph.incident_weight_bound=2*static_cast<std::uint64_t>(scale);
        repair_graph.has_heavy_rows=false;
        repair_hierarchy.levels.push_back(std::move(repair_graph));
        std::vector<V> overloaded(n);
        for(int v=0;v<n;++v) overloaded[v]=v/(n/k);
        const auto capacity=gpart::partition_capacity(n,k,1.03);
        for(int v=0;v<static_cast<int>(capacity-n/k)+3;++v) overloaded[v]=1;
        thrust::device_vector<V> repair_labels(overloaded);
        auto repair_options=options;repair_options.max_rounds=0;
        repair_options.allow_initial_imbalance=true;
        const auto repaired=gpart::refine_hierarchy_device(repair_hierarchy,std::move(repair_labels),repair_options);
        thrust::copy(repaired.device_partition.begin(),repaired.device_partition.end(),checked.begin());
        require(repaired.final_cut==gpart::host_cut(graph,checked) &&
                *std::max_element(repaired.final_part_weights.begin(),repaired.final_part_weights.end())<=capacity,
                "compacted donors failed strict large-layer repair");
    }
}

void check_heavy_edge_contraction() {
    using W = gpart::GraphTypes::WeightT;
    constexpr int active = 131072, n = active + 8;
    const W edge_scale = sizeof(W) == 8 ? W{1} << 40 : W{1};
    const W point_scale = sizeof(W) == 8 ? W{1} << 35 : W{1};
    gpart::WeightedGraph input;
    input.vertex_weights.assign(n, point_scale); input.offsets.push_back(0);
    for (int v = 0; v < n; ++v) {
        std::vector<std::pair<int, W>> row;
        if (v < active) for (int delta : {-3, -1, 1, 3})
            row.emplace_back((v + active + delta) % active, edge_scale * (std::abs(delta) == 1 ? 7 : 3));
        std::sort(row.begin(), row.end());
        for (auto [u, w] : row) { input.neighbors.push_back(u); input.edge_weights.push_back(w); }
        input.offsets.push_back(input.neighbors.size());
    }
    gpart::CoarsenOptions options;
    options.max_levels = 1; options.strict_verify = true; options.detailed_timings = false;
    // Capacity two isolates seed matching from subsequent singleton expansion.
    options.cluster_size_factor = n / 8;
    options.seed_matching = true;
    auto hierarchy = gpart::coarsen(gpart::make_device_weighted(input), options);
    require(hierarchy.levels.size() == 2, "seeded regret fixture failed to contract");
    const auto first = gpart::copy_device_weighted(hierarchy.levels[1]);
    require(*std::max_element(first.vertex_weights.begin(), first.vertex_weights.end()) <= 2 * point_scale,
            "heavy-edge path merged more than a pair");
    std::vector<std::int32_t> map(n);
    thrust::copy(hierarchy.fine_to_coarse[0].begin(), hierarchy.fine_to_coarse[0].end(), map.begin());
    std::vector<std::vector<int>> members(first.vertices());
    for (int v = 0; v < n; ++v) members[map[v]].push_back(v);
    for (const auto& group : members) {
        require(!group.empty() && group.size() <= 2, "heavy-edge map has an invalid pair size");
        // Remaining singletons may pair through a common favorite (two-hop).
    }
    // A degree-34 ring exercises the warp-per-row path, with weighted
    // matching and exact local/global CSR contraction checked independently.
    gpart::WeightedGraph medium;
    medium.vertex_weights.assign(n, point_scale); medium.offsets.push_back(0);
    for (int v = 0; v < n; ++v) {
        std::vector<std::pair<int, W>> row;
        if (v < active) for (int d = -17; d <= 17; ++d) if (d)
            row.emplace_back((v + active + d) % active,
                edge_scale * (std::abs(d) == 1 ? 7 : 1));
        std::sort(row.begin(), row.end());
        for (auto [u, w] : row) { medium.neighbors.push_back(u); medium.edge_weights.push_back(w); }
        medium.offsets.push_back(medium.neighbors.size());
    }
    options.max_levels = 1; options.heavy_edge_degree_limit = 64;
    options.row_local_contraction = false;
    auto global = gpart::coarsen(gpart::make_device_weighted(medium), options);
    options.row_local_contraction = true;
    auto local = gpart::coarsen(gpart::make_device_weighted(medium), options);
    require(global.levels.size() == 2 && local.levels.size() == 2,
            "warp matching failed to contract medium-degree graph");
    const auto gm = gpart::copy_device_weighted(global.levels[1]);
    const auto lm = gpart::copy_device_weighted(local.levels[1]);
    require(*std::max_element(gm.vertex_weights.begin(), gm.vertex_weights.end()) <= 2 * point_scale,
            "warp matching merged more than a pair");
    require(gm.offsets == lm.offsets && gm.neighbors == lm.neighbors &&
        gm.edge_weights == lm.edge_weights && gm.vertex_weights == lm.vertex_weights,
        "warp matching local/global contraction mismatch");
    std::vector<std::int32_t> medium_map(n), global_map(n);
    thrust::copy(local.fine_to_coarse[0].begin(), local.fine_to_coarse[0].end(), medium_map.begin());
    thrust::copy(global.fine_to_coarse[0].begin(), global.fine_to_coarse[0].end(), global_map.begin());
    require(medium_map == global_map, "warp matching is not deterministic");
    // A sparse star's hub must skip seeding and retain regret aggregation.
    constexpr int star_n = 65544;
    gpart::WeightedGraph star;
    star.vertex_weights.assign(star_n, W{1}); star.offsets.push_back(0);
    for (int v = 0; v < star_n; ++v) {
        if (!v) for (int u = 1; u < star_n; ++u) { star.neighbors.push_back(u); star.edge_weights.push_back(1); }
        else { star.neighbors.push_back(0); star.edge_weights.push_back(1); }
        star.offsets.push_back(star.neighbors.size());
    }
    options.max_levels = 1;
    auto fallback = gpart::coarsen(gpart::make_device_weighted(star), options);
    options.seed_matching = false;
    auto reference = gpart::coarsen(gpart::make_device_weighted(star), options);
    require(fallback.levels.size() == reference.levels.size() &&
            fallback.stop_reason == reference.stop_reason, "seed eligibility changed regret stopping");
    gpart::WeightedGraph isolated;
    isolated.offsets.assign(star_n + 1, 0); isolated.vertex_weights.assign(star_n, W{1});
    options.seed_matching = true;
    auto rejected = gpart::coarsen(gpart::make_device_weighted(isolated), options);
    options.seed_matching = false;
    auto isolated_reference = gpart::coarsen(gpart::make_device_weighted(isolated), options);
    require(rejected.levels.size() == isolated_reference.levels.size() &&
            rejected.stop_reason == isolated_reference.stop_reason,
            "empty seed pass changed regret stopping");
}

void check_short_row_sort() {
    using O = gpart::GraphTypes::OffsetT;
    using W = gpart::GraphTypes::WeightT;
    std::vector<O> offsets{0};
    std::vector<std::int32_t> neighbors;
    std::vector<W> weights;
    std::vector<std::map<std::int32_t, std::uint64_t>> expected;
    for (int degree : {0, 1, 7, 31, 32, 33, 63, 64, 126, 127, 128, 129, 255, 256, 257, 511, 512, 3}) {
        expected.emplace_back();
        for (int i = 0; i < degree; ++i) {
            const int target = degree == 126 ? 13 :
                (i % 5 == 0 ? INT32_MAX : ((degree - i) * 13) % 19);
            const W weight = sizeof(W) == 8 ? (W{1} << 40) + i : W{1} + i;
            neighbors.push_back(target); weights.push_back(weight);
            if (target != INT32_MAX) expected.back()[target] += weight;
        }
        offsets.push_back(neighbors.size());
    }
    gpart::detail::ScratchVector<O> d_offsets(offsets), counts(expected.size());
    gpart::detail::ScratchVector<std::int32_t> d_neighbors(neighbors);
    gpart::detail::ScratchVector<W> d_weights(weights);
    gpart::contraction_sort_rows<<<3, 256>>>(expected.size(),
        thrust::raw_pointer_cast(d_offsets.data()), thrust::raw_pointer_cast(d_neighbors.data()),
        thrust::raw_pointer_cast(d_weights.data()), thrust::raw_pointer_cast(counts.data()));
    gpart::contraction_sort_rows<true><<<3, 256>>>(expected.size(),
        thrust::raw_pointer_cast(d_offsets.data()), thrust::raw_pointer_cast(d_neighbors.data()),
        thrust::raw_pointer_cast(d_weights.data()), thrust::raw_pointer_cast(counts.data()));
    CUDA_CHECK(cudaGetLastError()); CUDA_CHECK(cudaDeviceSynchronize());
    std::vector<O> actual_counts(expected.size());
    thrust::copy(counts.begin(), counts.end(), actual_counts.begin());
    thrust::copy(d_neighbors.begin(), d_neighbors.end(), neighbors.begin());
    thrust::copy(d_weights.begin(), d_weights.end(), weights.begin());
    for (std::size_t row = 0; row < expected.size(); ++row) {
        require(actual_counts[row] == expected[row].size(), "short-row unique degree mismatch");
        auto e = offsets[row];
        for (auto [target, weight] : expected[row]) {
            require(neighbors[e] == target && weights[e] == weight,
                    "short-row sorting/reduction differs from independent CPU map");
            ++e;
        }
    }
}

void check_row_local_contraction(bool long_rows = false) {
    using W = gpart::GraphTypes::WeightT;
    constexpr int active = 131072, n = active + 3;
    gpart::WeightedGraph input;
    input.vertex_weights.assign(n, 1); input.offsets.push_back(0);
    for (int v = 0; v < n; ++v) {
        std::vector<int> row;
        if (v < active) {
            if (long_rows) {
                for (int delta = -65; delta <= 65; ++delta)
                    if (delta) row.push_back((v + active + delta) % active);
            } else for (int delta : {-3, -1, 1, 3}) row.push_back((v + active + delta) % active);
            if (v < 2) { row.push_back(1-v); row.push_back(v); }
        }
        std::sort(row.begin(), row.end());
        for (auto u : row) { input.neighbors.push_back(u); input.edge_weights.push_back(W{1}); }
        input.offsets.push_back(input.neighbors.size());
    }
    gpart::CoarsenOptions options;
    options.max_levels = long_rows ? 1 : 2;
    if (long_rows) options.cluster_size_factor = n / 8; // capacity at most three for the padded fixture
    options.strict_verify = true; options.detailed_timings = false;
    options.row_local_contraction = false;
    auto reference = gpart::coarsen(gpart::make_device_weighted(input), options);
    options.row_local_contraction = true;
    auto actual = gpart::coarsen(gpart::make_device_weighted(input), options);
    require(actual.levels.size() == reference.levels.size() && actual.levels.size() == (long_rows ? 2 : 3),
            "short-row contraction changed hierarchy depth");
    for (std::size_t level = 0; level < actual.levels.size(); ++level) {
        auto a = gpart::copy_device_weighted(actual.levels[level]);
        auto b = gpart::copy_device_weighted(reference.levels[level]);
        require(a.offsets == b.offsets && a.neighbors == b.neighbors &&
                a.edge_weights == b.edge_weights && a.vertex_weights == b.vertex_weights,
                "short-row contraction changed complete CSR or weights");
        if (level < actual.fine_to_coarse.size()) {
            std::vector<std::int32_t> a_map(actual.fine_to_coarse[level].size()), b_map(a_map.size());
            thrust::copy(actual.fine_to_coarse[level].begin(), actual.fine_to_coarse[level].end(), a_map.begin());
            thrust::copy(reference.fine_to_coarse[level].begin(), reference.fine_to_coarse[level].end(), b_map.begin());
            require(a_map == b_map, "short-row contraction changed SCLP mapping");
        }
    }
}



void check_precombined_contraction() {
    using W=gpart::GraphTypes::WeightT;
    using V=gpart::GraphTypes::VertexT;
    constexpr int n=4099;
    const W weight=sizeof(W)==8 ? W{1}<<20 : W{7};
    gpart::WeightedGraph input;
    input.vertex_weights.assign(n,1);input.offsets.push_back(0);
    for (int v=0;v<n;++v) {
        // More than 2^20 entries select the compact path. Repeated targets
        // span chunk boundaries; the two extra reciprocal edges make partial
        // final chunks, and Big exercises the 64-bit group summation.
        for (int d : {-1,1}) for (int j=0;j<128;++j) {
            input.neighbors.push_back((v+n+d)%n);input.edge_weights.push_back(weight);
        }
        if (v<2) { input.neighbors.push_back(1-v);input.edge_weights.push_back(weight); }
        input.offsets.push_back(input.neighbors.size());
    }
    gpart::CoarsenOptions options;options.max_levels=1;options.strict_verify=true;
    auto hierarchy=gpart::coarsen(gpart::make_device_weighted(input),options);
    require(hierarchy.levels.size()==2,"precombined contraction fixture did not contract");
    const auto actual=gpart::copy_device_weighted(hierarchy.levels[1]);
    std::vector<V> map(n);
    thrust::copy(hierarchy.fine_to_coarse[0].begin(),hierarchy.fine_to_coarse[0].end(),map.begin());
    std::vector<std::map<V,std::uint64_t>> rows(actual.vertices());
    std::vector<std::uint64_t> masses(actual.vertices(),0);
    for (int v=0;v<n;++v) {
        ++masses[map[v]];
        for (auto e=input.offsets[v];e<input.offsets[v+1];++e)
            if (map[v]!=map[input.neighbors[e]]) rows[map[v]][map[input.neighbors[e]]]+=input.edge_weights[e];
    }
    for (int v=0;v<actual.vertices();++v) {
        auto e=actual.offsets[v];
        require(masses[v]==actual.vertex_weights[v],"precombined contraction changed mass");
        for (const auto& [u,w] : rows[v]) {
            require(e<actual.offsets[v+1] && actual.neighbors[e]==u && actual.edge_weights[e]==w,
                    "precombined contraction differs from complete CPU row reduction");
            ++e;
        }
        require(e==actual.offsets[v+1],"precombined contraction emitted extra edges");
    }
}

void check_gpu_lp_control() {
    using W=gpart::GraphTypes::WeightT;
    using V=gpart::GraphTypes::VertexT;
    W scale=1;

    gpart::WeightedGraph graph;
    constexpr int n=65536;
    graph.vertex_weights.assign(n,scale);
    graph.offsets.push_back(0);
    for (int v=0;v<n;++v) {
        graph.neighbors.push_back((v/4)*4+3-v%4);
        graph.edge_weights.push_back(scale*10);
        graph.offsets.push_back(graph.neighbors.size());
    }
    for (auto layout : {gpart::AffinityLayout::Dense,gpart::AffinityLayout::Sparse,gpart::AffinityLayout::OnDemand}) {
        gpart::RefineOptions options;
        options.parts=2;options.strict_verify=true;
        options.boundary_group_rounds=0;options.affinity_layout=layout;
        std::vector<V> host(n);
        for (int v=0;v<n;++v) host[v]=v%2;
        auto device=host;
        gpart::RefineStats a,b;
        options.gpu_lp_loop=false;
        gpart::refine_partition(graph,host,options,&a);
        options.gpu_lp_loop=true;
        gpart::refine_partition(graph,device,options,&b);
        require(host==device && b.final_cut==0 && b.final_cut==gpart::host_cut(graph,device),
                "GPU LP loop differs on deterministic reciprocal moves");
        require(a.rounds==b.rounds && a.accepted==b.accepted &&
                a.checkpoint_updates==b.checkpoint_updates && b.checkpoint_updates>0 &&
                a.lp_cut_gain==b.lp_cut_gain && a.lp_cut_loss==b.lp_cut_loss,
                "GPU LP checkpoint/empty-round control differs from host reference");
    }
}

int main(int argc,char** argv) {
    try {
        if(argc==2 && std::string(argv[1])=="--joint-only") {
            check_joint_refinement();
            std::cout << "joint_refinement_ok=1\n";
            return 0;
        }
        check_overwrite_growth_order();
        check_scratch_pool_lifetime();
        gpart::detail::ScratchPoolSession scratch_pool;
        check_scratch_pool_lifetime();
        check_heavy_edge_contraction();
        check_short_row_sort();
        check_row_local_contraction();
        check_row_local_contraction(true);
        check_gpu_lp_control();
        check_precombined_contraction();
        check_frontier_growth();
        { // Resident arrays must keep their allocating pool alive after its
          // session ends; refinement can then use a different allocation scope.
            gpart::WeightedGraph ring;
            ring.vertex_weights.assign(1024,1);ring.offsets.push_back(0);
            for (int v=0;v<1024;++v) {
                ring.neighbors.push_back((v+1023)%1024);
                ring.neighbors.push_back((v+1)%1024);
                ring.edge_weights.push_back(1);ring.edge_weights.push_back(1);
                ring.offsets.push_back(ring.neighbors.size());
            }
            gpart::DeviceHierarchy retained;
            {
                gpart::detail::ScratchPoolSession pool;
                gpart::CoarsenOptions o;o.parts=4;o.cluster_size_factor=8;o.strict_verify=true;
                retained=gpart::coarsen(gpart::make_device_weighted(ring),o);
                pool.finish();
            }
            require(retained.levels.size()>1,"pool lifetime test did not build coarse arrays");
            const auto saved=gpart::copy_device_weighted(retained.levels.back());
            require(saved.vertices()>0,"retained graph invalid after pool session");
            thrust::device_vector<gpart::GraphTypes::VertexT> labels(saved.vertices(),0);
            gpart::RefineOptions o;o.parts=4;o.allow_initial_imbalance=true;
            o.strict_verify=true;o.max_rounds=0;o.boundary_group_rounds=0;
            auto r=gpart::refine_hierarchy_device(retained,std::move(labels),o);
            require(*std::max_element(r.final_part_weights.begin(),r.final_part_weights.end())<=263,
                    "pool lifetime refinement exceeded capacity");
        }

        { // Coarse weight-two points cannot fit cap=3; finer units can.
            gpart::Hierarchy h;
            gpart::WeightedGraph fine,coarse;
            fine.offsets.assign(7,0);fine.vertex_weights.assign(6,1);
            coarse.offsets.assign(4,0);coarse.vertex_weights.assign(3,2);
            h.levels={fine,coarse};h.fine_to_coarse={{0,0,1,1,2,2}};
            gpart::RefineOptions o;o.parts=2;o.max_rounds=0;
            o.boundary_group_rounds=0;o.strict_verify=true;
            bool rejected=false;
            try { auto r=gpart::refine_hierarchy_device(h,std::vector<gpart::GraphTypes::VertexT>{0,0,1},o); }
            catch(const std::invalid_argument&) { rejected=true; }
            require(rejected,"strict entry accepted coarse imbalance");
            o.allow_initial_imbalance=true;
            auto r=gpart::refine_hierarchy_device(h,std::vector<gpart::GraphTypes::VertexT>{0,0,1},o);
            require(r.final_part_weights==std::vector<std::uint64_t>{3,3} && r.final_cut==0,
                    "deferred GPU repair failed to balance finer units");
            std::vector<gpart::GraphTypes::VertexT> labels{0,0,1};rejected=false;
            try { gpart::refine_partition(coarse,labels,o); }
            catch(const std::runtime_error&) { rejected=true; }
            require(rejected,"standalone repair returned infeasible output");
        }

        using VertexT = gpart::GraphTypes::VertexT;
        check_parallel_cut();
        check_refinement_gain_overflow();
        check_receiver_counterflow();
        check_cross_edge_contraction();
        check_sort_weight_width();
        check_isolated_packing();
        check_coarsening_frontier();
        check_connected_group_exchange();
        check_joint_refinement();
        check_heavy_refinement_rows();
        check_collective_group_target();
        check_collective_group_target_high_k();
        check_negative_group_prefix();
        check_affinity_counter_width();
        check_weight_compatible_groups();
        auto hierarchy = make_hierarchy();
        // Both CSR validation paths must retain all rejection conditions.
        for (int failure = 0; failure < 4; ++failure) {
            auto invalid = hierarchy.levels.front();
            if (failure == 0) invalid.neighbors[0] = -1;
            if (failure == 1) invalid.neighbors[0] = invalid.vertices();
            if (failure == 2) invalid.offsets[2] = 0;
            if (failure == 3) invalid.neighbors[0] = 0;
            bool rejected = false;
            try { gpart::validate_weighted_shape(invalid, failure != 3); }
            catch (const std::runtime_error&) { rejected = true; }
            require(rejected, "CSR safety validation was lost");
            if (failure == 3) gpart::validate_weighted_shape(invalid, true);
        }
        const std::vector<VertexT> coarse_partition{VertexT{0}, VertexT{1}};
        const auto& map = hierarchy.fine_to_coarse.front();
        std::vector<VertexT> projected(map.size());
        for (std::size_t v = 0; v < map.size(); ++v) {
            projected[v] = coarse_partition[map[v]];
        }
        require(
            projected == std::vector<VertexT>({0, 0, 1, 1}),
            "projection labels are wrong");
        require(
            gpart::host_cut(hierarchy.levels.back(), coarse_partition) == 5 &&
            gpart::host_cut(hierarchy.levels.front(), projected) == 5,
            "projection did not preserve cut");
        require(
            hierarchy.levels.back().vertex_weights[0] == 2 &&
            hierarchy.levels.back().vertex_weights[1] == 2,
            "coarse part weights are wrong");
        std::uint64_t projected_weight[2] = {0, 0};
        for (std::size_t v = 0; v < projected.size(); ++v) {
            projected_weight[projected[v]] +=
                hierarchy.levels.front().vertex_weights[v];
        }
        require(
            projected_weight[0] == 2 && projected_weight[1] == 2,
            "projection did not preserve part weights");

        gpart::RefineOptions options;
        options.parts = 2;
        options.imbalance_ratio = 1.10;
        options.max_rounds = 4;
        options.strict_verify = true;
        // alpha*4/2=2.2 permits only load two, including on entry to refine.
        std::vector<VertexT> overloaded{0, 0, 0, 1};
        bool overloaded_rejected = false;
        try { gpart::refine_partition(hierarchy.levels.front(), overloaded, options); }
        catch (const std::invalid_argument&) { overloaded_rejected = true; }
        require(overloaded_rejected, "ceil capacity admitted an imbalanced input");
        const auto final_partition = gpart::uncoarsen(
            hierarchy, coarse_partition, options);
        auto production_options = options;
        production_options.strict_verify = false;
        require(
            gpart::uncoarsen(hierarchy, coarse_partition, production_options) ==
                final_partition,
            "production and strict partitions differ");
        for (bool strict : {false, true}) {
            gpart::DeviceHierarchy device_hierarchy;
            for (const auto& level : hierarchy.levels)
                device_hierarchy.levels.push_back(gpart::make_device_weighted(level));
            for (const auto& mapping : hierarchy.fine_to_coarse)
                device_hierarchy.fine_to_coarse.emplace_back(mapping);
            thrust::device_vector<VertexT> device_labels = coarse_partition;
            auto resident_options = options;
            resident_options.strict_verify = strict;
            auto result = gpart::uncoarsen(device_hierarchy, std::move(device_labels), resident_options);
            std::vector<VertexT> labels(result.device_partition.size());
            thrust::copy(result.device_partition.begin(), result.device_partition.end(), labels.begin());
            require(labels == final_partition, "device hierarchy changed refinement");
            require(result.partition.empty(), "resident path downloaded partition");
            for (const auto& level : result.levels)
                require(level.timings.graph_h2d_seconds == 0, "resident level uploaded graph");
        }

        // Exact level/map comparison, including the no-contraction case.
        for (int n : {8, 4096}) {
            gpart::WeightedGraph input;
            input.vertex_weights.assign(n, 1);
            input.offsets.push_back(0);
            for (int v = 0; v < n; ++v) {
                input.neighbors.push_back(v ^ 1);
                input.edge_weights.push_back(1);
                input.offsets.push_back(v + 1);
            }
            gpart::CoarsenOptions co;
            co.strict_verify = true;
            auto host_levels = gpart::coarsen(input, co);
            for (bool strict : {false, true}) {
                co.strict_verify = strict;
                auto device_levels = gpart::coarsen(gpart::make_device_weighted(input), co);
                require(host_levels.levels.size() == device_levels.levels.size(), "resident level count differs");
                require(host_levels.stop_reason == device_levels.stop_reason, "resident stop reason differs");
                if (!strict) require(device_levels.snapshot_seconds == 0, "production copied snapshots");
                for (std::size_t l = 0; l < host_levels.levels.size(); ++l) {
                    auto actual = gpart::copy_device_weighted(device_levels.levels[l]);
                    const auto& expected = host_levels.levels[l];
                    require(actual.offsets == expected.offsets && actual.neighbors == expected.neighbors &&
                            actual.edge_weights == expected.edge_weights && actual.vertex_weights == expected.vertex_weights,
                            "resident hierarchy CSR differs");
                    if (l < host_levels.fine_to_coarse.size()) {
                        std::vector<VertexT> map(device_levels.fine_to_coarse[l].size());
                        thrust::copy(device_levels.fine_to_coarse[l].begin(), device_levels.fine_to_coarse[l].end(), map.begin());
                        require(map == host_levels.fine_to_coarse[l], "resident hierarchy map differs");
                    }
                }
            }
        }
        require(final_partition.size() == 4, "final partition length is wrong");
        for (const auto part : final_partition) {
            require(part >= 0 && part < 2, "final part id is invalid");
        }
        const auto final_cut = gpart::host_cut(
            hierarchy.levels.front(), final_partition);
        require(final_cut <= 5, "refinement increased cut");
        std::uint64_t final_weight[2] = {0, 0};
        for (std::size_t v = 0; v < final_partition.size(); ++v) {
            final_weight[final_partition[v]] +=
                hierarchy.levels.front().vertex_weights[v];
        }
        require(
            std::max(final_weight[0], final_weight[1]) <= 2,
            "refinement violated balance");

        // Both parts are full. Two improving moves form a balanced cycle;
        // vacancy-only admission rejects both; exploration can admit the cycle.
        gpart::WeightedGraph exchange;
        exchange.offsets = {0, 2, 5, 7, 10, 11, 12};
        exchange.neighbors = {1, 3, 0, 2, 4, 1, 3, 0, 2, 5, 1, 3};
        exchange.edge_weights = {1, 4, 1, 4, 100, 4, 1, 4, 1, 100, 100, 100};
        exchange.vertex_weights.assign(6, 1);
        std::vector<VertexT> exchange_labels{0, 0, 1, 1, 0, 1};
        gpart::RefineOptions exchange_options;
        exchange_options.parts = 2;
        exchange_options.imbalance_ratio = 1.03;
        gpart::RefineStats exchange_stats;
        exchange_options.strict_verify=true;
        exchange_options.max_rounds=32;
        gpart::refine_partition(exchange,exchange_labels,exchange_options,&exchange_stats);
        require(gpart::host_cut(exchange,exchange_labels)==2 &&
                std::count(exchange_labels.begin(),exchange_labels.end(),0)==3,
                "incremental exchange violated cut/balance");
        // An improving move temporarily overloads part 1. Rebalancing must
        // move an isolated vertex back, preserving the improvement exactly.
        gpart::WeightedGraph repair;
        repair.vertex_weights.assign(8,1);
        repair.offsets={0,2,4,5,5,7,8,8,8};
        repair.neighbors={1,4,0,2,1,0,5,4};
        repair.edge_weights={1,4,1,100,100,4,100,100};
        std::vector<VertexT> repair_labels{0,0,0,0,1,1,1,1};
        gpart::refine_partition(repair,repair_labels,exchange_options,&exchange_stats);
        require(gpart::host_cut(repair,repair_labels)==1 &&
                std::count(repair_labels.begin(),repair_labels.end(),0)==4 &&
                exchange_stats.admission_iterations>0,
                "incremental rebalancing lost quality or violated capacity");
        // Weighted vertices, unsorted duplicate adjacency and self loops.
        // Strict mode compares every incremental update to an independent CSR
        // rebuild; the CPU oracle also checks the restored best checkpoint.
        for (int k : {2,4,8,32}) {
            gpart::WeightedGraph stress;
            std::vector<std::vector<std::pair<int,gpart::GraphTypes::WeightT>>> rows(384);
            const auto add=[&](int a,int b,gpart::GraphTypes::WeightT w) {
                rows[a].push_back({b,w});rows[b].push_back({a,w});
            };
            gpart::GraphTypes::WeightT scale=1;

            std::vector<VertexT> labels(384);
            std::uint64_t total=0;
            for (int v=0;v<384;++v) {
                add(v,(v+1)%384,scale*3);add(v,(v+17)%384,scale*11);
                add(v,(v+17)%384,scale*7);add(v,v,scale*13);
                stress.vertex_weights.push_back(1+(v/k)%3);
                total+=stress.vertex_weights.back();labels[v]=v%k;
            }
            stress.offsets.push_back(0);
            for (auto& row:rows) {
                std::reverse(row.begin(),row.end());
                for (auto [u,w]:row) { stress.neighbors.push_back(u);stress.edge_weights.push_back(w); }
                stress.offsets.push_back(stress.neighbors.size());
            }
            const auto before=gpart::host_cut(stress,labels);
            exchange_options.parts=k;
            gpart::refine_partition(stress,labels,exchange_options,&exchange_stats);
            require(gpart::host_cut(stress,labels)<=before,"weighted incremental refinement increased cut");
            std::vector<std::uint64_t> loads(k,0);
            for (int v=0;v<384;++v) loads[labels[v]]+=stress.vertex_weights[v];
            require(*std::max_element(loads.begin(),loads.end())<=gpart::partition_capacity(total,k,1.03),
                    "weighted bucket refinement exceeded capacity");
        }
        std::cout << "uncoarsen_small_ok=1 graph_type="
                  << gpart::kActiveGraphName << " final_cut=" << final_cut
                  << '\n';
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "test_uncoarsen: " << error.what() << '\n';
        return 1;
    }
}
