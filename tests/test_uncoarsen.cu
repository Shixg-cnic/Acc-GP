#include "graph.hpp"
#include "graph_types.hpp"
#include "hierarchy.hpp"
#include "refine.hpp"
#include "uncoarsen.hpp"
#include "coarsen.hpp"
#include "detail/scratch_pool.hpp"
#include "partition_capacity.hpp"

#include <algorithm>
#include <thrust/sequence.h>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <map>
#include <stdexcept>
#include <vector>

namespace {

template <typename Types>
gpart::Hierarchy<Types> make_hierarchy() {
    using OffsetT = typename Types::OffsetT;
    using VertexT = typename Types::VertexT;
    using WeightT = typename Types::WeightT;
    gpart::WeightedGraph<Types> fine;
    fine.offsets = {OffsetT{0}, OffsetT{1}, OffsetT{3}, OffsetT{5}, OffsetT{6}};
    fine.neighbors = {
        VertexT{1}, VertexT{0}, VertexT{2},
        VertexT{1}, VertexT{3}, VertexT{2}};
    fine.edge_weights = {
        WeightT{1}, WeightT{1}, WeightT{5},
        WeightT{5}, WeightT{10}, WeightT{10}};
    fine.vertex_weights = {WeightT{1}, WeightT{1}, WeightT{1}, WeightT{1}};

    gpart::WeightedGraph<Types> coarse;
    coarse.offsets = {OffsetT{0}, OffsetT{1}, OffsetT{2}};
    coarse.neighbors = {VertexT{1}, VertexT{0}};
    coarse.edge_weights = {WeightT{5}, WeightT{5}};
    coarse.vertex_weights = {WeightT{2}, WeightT{2}};

    gpart::Hierarchy<Types> hierarchy;
    hierarchy.levels.push_back(std::move(fine));
    hierarchy.levels.push_back(std::move(coarse));
    hierarchy.fine_to_coarse.push_back(
        {VertexT{0}, VertexT{0}, VertexT{1}, VertexT{1}});
    return hierarchy;
}

void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}

template <typename Types>
void check_isolated_packing() {
    // Unequal weights include vertices crossing prefix-bin boundaries.
    gpart::WeightedGraph<Types> host;
    host.vertex_weights = {7,7,1,4,4,1,1,8,1,3,6,2};
    host.offsets = {0,1,2,2,2,2,2,2,2,2,2,2,2};
    host.neighbors = {1,0};
    host.edge_weights = {3,3};
    auto device = gpart::make_device_weighted(host);
    gpart::SclpWorkspace<Types> workspace;
    gpart::SclpStats before_stats, after_stats;
    auto before = gpart::aggregate(device, workspace, 2, 0, 0, before_stats, false, 2, false);
    auto after = gpart::aggregate(device, workspace, 2, 0, 0, after_stats, true, 2, true);
    require(after.coarse_vertices < before.coarse_vertices,
            "isolated packing failed to contract zero-degree vertices");
    require(after.maximum_weight <= after.capacity,
            "isolated packing exceeded cluster capacity");
    std::vector<typename Types::VertexT> mapping(after.map.size());
    thrust::copy(after.map.begin(), after.map.end(), mapping.begin());
    require(mapping[0] != mapping[1], "heavy connected vertices exceeded merge capacity");
    for (std::size_t v = 2; v < mapping.size(); ++v)
        require(mapping[v] != mapping[0] && mapping[v] != mapping[1],
                "isolated packing joined a connected cluster");
}

template <typename Types>
void check_coarsening_frontier() {
    using W = typename Types::WeightT;
    using V = typename Types::VertexT;
    W scale = 1;
    if constexpr (sizeof(W) == 8) scale = W{1} << 35;
    for (bool parallel : {false, true}) {
        gpart::WeightedGraph<Types> host;
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
            gpart::SclpWorkspace<Types> fast_ws, full_ws;
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

template <typename Types>
void check_connected_group_exchange() {
    using W=typename Types::WeightT;
    using V=typename Types::VertexT;
    gpart::WeightedGraph<Types> graph;
    std::vector<std::vector<std::pair<int,W>>> rows(10);
    W scale=1;
    if constexpr (sizeof(W)==8) scale=W{1}<<35;
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

template <typename Types>
void check_heavy_refinement_rows() {
    using W=typename Types::WeightT;
    using V=typename Types::VertexT;
    constexpr int n=10000;
    W scale=3;
    if constexpr (sizeof(W)==8) scale=static_cast<W>(std::uint64_t{3}<<35);
    std::vector<std::vector<int>> rows(n);
    const auto add=[&](int a,int b) { rows[a].push_back(b);rows[b].push_back(a); };
    // Both hubs exceed the segmented-row threshold and migrate concurrently.
    // Their common edge must be owned once; nonunit weights test exact deltas.
    for (int v=1;v<=1000;++v) add(0,v);
    for (int v=5000;v<n;++v) add(0,v);
    for (int v=1;v<5000;++v) add(5000,v);
    for (int v=5001;v<=6000;++v) add(5000,v);
    gpart::WeightedGraph<Types> graph;
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
        gpart::DeviceHierarchy<Types> hierarchy;
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

template <typename Types>
void check_negative_group_prefix() {
    using V=typename Types::VertexT;
    using W=typename Types::WeightT;
    W scale=1;
    if constexpr (sizeof(W)==8) scale=W{1}<<35;
    gpart::WeightedGraph<Types> graph;
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

template <typename Types>
void check_collective_group_target() {
    using V=typename Types::VertexT;
    using W=typename Types::WeightT;
    W scale=1;
    if constexpr (sizeof(W)==8) scale=W{1}<<35;
    gpart::WeightedGraph<Types> graph;
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

template <typename Types>
void check_affinity_counter_width() {
    using V=typename Types::VertexT;
    using W=typename Types::WeightT;
    constexpr std::uint64_t scale=std::uint64_t{1}<<25;
    for (bool wide : {false,true}) {
        gpart::WeightedGraph<Types> graph;
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
        gpart::DeviceHierarchy<Types> hierarchy;
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

template <typename Types>
void check_weight_compatible_groups() {
    using V=typename Types::VertexT;
    using W=typename Types::WeightT;
    W scale=1;
    if constexpr (sizeof(W)==8) scale=W{1}<<35;
    const auto make=[&](bool solo) {
        gpart::WeightedGraph<Types> graph;
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

template <typename Types>
void check_parallel_cut() {
    using V = typename Types::VertexT;
    using W = typename Types::WeightT;
    constexpr int n = 259;
    std::vector<std::vector<V>> rows(n);
    const auto add = [&](int v, int u) { rows[v].push_back(u); rows[u].push_back(v); };
    for (int v = 1; v < n - 1; ++v) {
        add(0, v);
        add(0, v); // Repeated entries must each contribute their weight.
        if (v > 1) add(v - 1, v);
    }
    gpart::WeightedGraph<Types> graph;
    graph.offsets.push_back(0);
    graph.vertex_weights.assign(n, 1);
    W weight = 7;
    if constexpr (sizeof(W) == 8) weight = W{1} << 40;
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

template <typename Types>
void check_cross_edge_contraction() {
    using V = typename Types::VertexT;
    using W = typename Types::WeightT;
    using O = typename Types::OffsetT;
    // Non-warp-aligned row count, empty rows, duplicate entries, self loops,
    // all-internal edges, and repeated calls using the same scratch buffers.
    gpart::SclpWorkspace<Types> workspace;
    for (int groups : {7, 1, 7}) {
        constexpr int n = 35;
        gpart::WeightedGraph<Types> input, expected;
        std::vector<V> mapping(n);
        expected.vertex_weights.assign(groups, W{0});
        input.vertex_weights.assign(n, W{1});
        input.offsets.push_back(0);
        std::map<std::pair<V, V>, W> edges;
        W weight = W{3};
        if constexpr (sizeof(W) == 8) weight = W{1} << 40;
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
        gpart::DeviceAggregateResult<Types> aggregate;
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
        auto input = make_hierarchy<Types>().levels.front();
        if (empty) {
            input.neighbors.clear();
            input.edge_weights.clear();
            input.offsets.assign(input.vertices() + 1, 0);
        }
        std::vector<V> identity{0, 1, 2, 3};
        gpart::DeviceAggregateResult<Types> aggregate;
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

template <typename Types>
void check_sort_weight_width() {
    using V = typename Types::VertexT;
    using W = typename Types::WeightT;
    // Exercise the hub-sort path, duplicate edges, and the >UINT32_MAX
    // total-weight fallback. Compare every level to the original 64-bit path.
    std::vector<W> tested_weights{W{1}, W{1000000}};
    if constexpr (sizeof(W) == 8) tested_weights.push_back(W{1} << 40);
    for (W weight : tested_weights) {
        constexpr int n = 4096;
        std::vector<std::vector<V>> rows(n);
        const auto add = [&](int a, int b) { rows[a].push_back(b); rows[b].push_back(a); };
        for (int v = 0; v < n; ++v) add(v, (v + 1) % n);
        for (int v = 1; v <= 512; ++v) add(0, v);
        rows[0].push_back(0); // Hub sentinel must not collide with a packed key.
        gpart::WeightedGraph<Types> input;
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
        gpart::SclpWorkspace<Types> workspace; // Default standalone path is 64-bit.
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

template <typename Types>
void check_receiver_counterflow() {
    using W=typename Types::WeightT;
    using V=typename Types::VertexT;
    gpart::WeightedGraph<Types> graph;
    std::vector<std::vector<std::pair<int,W>>> rows(256);
    W scale=1;
    if constexpr(sizeof(W)==8) scale=W{1}<<35;
    const auto add=[&](int a,int b,int w) {
        rows[a].push_back({b,scale*w});rows[b].push_back({a,scale*w});
    };
    for(int v=0;v<20;++v) {add(v,20,1);add(v,64,10);}
    for(int v=21;v<64;++v) add(v,20,100);
    for(int v=65;v<128;++v) {add(v,64,4);add(v,128,1);}
    for(int v=129;v<192;++v) add(v,128,100);
    for(int v=193;v<256;++v) add(v,192,100);
    graph.vertex_weights.assign(256,1);graph.offsets.push_back(0);
    for(const auto& row:rows) {
        for(auto [u,w]:row) {graph.neighbors.push_back(u);graph.edge_weights.push_back(w);}
        graph.offsets.push_back(graph.neighbors.size());
    }
    std::vector<V> labels(256);
    for(int v=0;v<256;++v) labels[v]=v/64;
    const auto before=gpart::host_cut(graph,labels);
    gpart::RefineOptions options;
    options.parts=4;options.max_rounds=1;options.boundary_group_rounds=0;options.strict_verify=true;
    gpart::RefineStats stats;
    gpart::refine_partition(graph,labels,options,&stats);
    // Twenty improving LP moves overload part 1. Every repair donor prefers
    // part 2, whose room is only one; remaining donors must reach other parts
    // in this same batch. The old one-destination repair needs more batches.
    require(stats.admission_iterations==1 && stats.admission_fallbacks==0 &&
            stats.final_cut<before && stats.final_cut==gpart::host_cut(graph,labels),
            "receiver tickets failed to finish unit-weight counterflow in one batch");
    std::uint64_t loads[4]={0,0,0,0};
    for(const auto p:labels) ++loads[p];
    require(*std::max_element(loads,loads+4)<=65,"receiver tickets overfilled a destination");
}

template <typename Types>
void check_refinement_gain_overflow() {
    if constexpr (sizeof(typename Types::WeightT) == 8) {
        gpart::WeightedGraph<Types> graph;
        graph.offsets = {0, 1, 2};
        graph.neighbors = {1, 0};
        const auto weight = static_cast<typename Types::WeightT>(INT64_MAX / 2);
        graph.edge_weights = {weight, weight};
        graph.vertex_weights = {1, 1};
        std::vector<typename Types::VertexT> labels{0, 1};
        gpart::RefineOptions options;
        options.parts = 2;
        bool rejected = false;
        try { gpart::refine_partition(graph, labels, options); }
        catch (const std::overflow_error&) { rejected = true; }
        require(rejected, "refinement accepted an unsafe signed gain range");

        gpart::DeviceHierarchy<Types> hierarchy;
        hierarchy.levels.push_back(gpart::make_device_weighted(graph));
        thrust::device_vector<typename Types::VertexT> device_labels = labels;
        rejected = false;
        try { gpart::uncoarsen(hierarchy, std::move(device_labels), options); }
        catch (const std::overflow_error&) { rejected = true; }
        require(rejected, "coarsest refinement skipped signed gain validation");
    }
}

}  // namespace

int main() {
    try {
        check_scratch_pool_lifetime();
        gpart::detail::ScratchPoolSession scratch_pool;
        check_scratch_pool_lifetime();
        using Types = gpart::ActiveTypes;
        using VertexT = typename Types::VertexT;
        check_parallel_cut<Types>();
        check_refinement_gain_overflow<Types>();
        check_receiver_counterflow<Types>();
        check_cross_edge_contraction<Types>();
        check_sort_weight_width<Types>();
        check_isolated_packing<Types>();
        check_coarsening_frontier<Types>();
        check_connected_group_exchange<Types>();
        check_heavy_refinement_rows<Types>();
        check_collective_group_target<Types>();
        check_negative_group_prefix<Types>();
        check_affinity_counter_width<Types>();
        check_weight_compatible_groups<Types>();
        auto hierarchy = make_hierarchy<Types>();
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
            gpart::DeviceHierarchy<Types> device_hierarchy;
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
            gpart::WeightedGraph<Types> input;
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
        gpart::WeightedGraph<Types> exchange;
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
        gpart::WeightedGraph<Types> repair;
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
            gpart::WeightedGraph<Types> stress;
            std::vector<std::vector<std::pair<int,typename Types::WeightT>>> rows(384);
            const auto add=[&](int a,int b,typename Types::WeightT w) {
                rows[a].push_back({b,w});rows[b].push_back({a,w});
            };
            typename Types::WeightT scale=1;
            if constexpr (sizeof(typename Types::WeightT)==8) scale=static_cast<typename Types::WeightT>(std::uint64_t{1}<<35);
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
