#include "coarsen.hpp"
#include "graph_types.hpp"
#include "check.hpp"

#include <thrust/copy.h>
#include <algorithm>
#include <cstdint>
#include <iostream>
#include <map>
#include <numeric>
#include <stdexcept>
#include <vector>
#include <tuple>

namespace {
using Graph = gpart::WeightedGraph;
using W = gpart::GraphTypes::WeightT;
using V = gpart::GraphTypes::VertexT;

void require(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}

Graph make_graph(int n, bool hubs, bool parallel, W scale) {
    std::vector<std::vector<std::pair<V, W>>> rows(n);
    const auto edge = [&](int a, int b, W weight) {
        rows[a].push_back({b, weight}); rows[b].push_back({a, weight});
    };
    for (int v = 0; v + 3 < n - 8; v += 4) {
        // Unique strongest mutual pairs must survive seeded aggregation.
        edge(v, v + 1, 100 * scale);
        edge(v + 1, v + 2, scale);
        edge(v + 1, v + 3, scale);
    }
    if (hubs) {
        for (int v = 4; v < 4500; ++v) edge(0, v, scale);
        for (int v = 4500; v < 4560; ++v) edge(2, v, 2 * scale);
    }
    if (parallel) {
        edge(4, 5, 7 * scale);
        rows[6].push_back({6, 2 * scale}); // even directed self-loop weight
    }
    Graph graph;
    graph.offsets.push_back(0);
    for (int v = 0; v < n; ++v) {
        std::sort(rows[v].begin(), rows[v].end());
        graph.vertex_weights.push_back((1 + v % 7) * scale);
        for (const auto& e : rows[v]) {
            graph.neighbors.push_back(e.first); graph.edge_weights.push_back(e.second);
        }
        graph.offsets.push_back(graph.neighbors.size());
    }
    return graph;
}

void check_case(const Graph& host, bool seeded, int parts = 4) {
    std::vector<V> previous;
    for (bool fast : {false, true}) for (bool diagnostics : {false, true}) {
        auto device = gpart::make_device_weighted(host);
        gpart::SclpWorkspace workspace;
        gpart::SclpStats stats;
        auto result = gpart::aggregate(device, workspace, parts, 17, 0, stats,
                                      diagnostics, 2, true, seeded, fast);
        std::vector<V> map(result.map.size());
        std::vector<W> weights(result.vertex_weights.size());
        thrust::copy(result.map.begin(), result.map.end(), map.begin());
        thrust::copy(result.vertex_weights.begin(), result.vertex_weights.end(), weights.begin());
        require(!weights.empty() && map.size() == host.vertex_weights.size(), "invalid dimensions");
        const auto total = std::accumulate(host.vertex_weights.begin(), host.vertex_weights.end(), std::uint64_t{0});
        const auto maximum = static_cast<std::uint64_t>(*std::max_element(host.vertex_weights.begin(), host.vertex_weights.end()));
        const auto denominator = static_cast<std::uint64_t>(2 * parts);
        require(result.capacity == std::max(maximum, total / denominator + (total % denominator != 0)), "wrong capacity");
        std::vector<std::uint64_t> reconstructed(weights.size(), 0);
        for (std::size_t v = 0; v < map.size(); ++v) {
            require(map[v] >= 0 && static_cast<std::size_t>(map[v]) < weights.size(), "invalid map ID");
            reconstructed[map[v]] += host.vertex_weights[v];
        }
        for (std::size_t c = 0; c < weights.size(); ++c) {
            require(reconstructed[c] != 0 && reconstructed[c] == static_cast<std::uint64_t>(weights[c]), "lost/duplicated vertex weight");
            require(reconstructed[c] <= result.capacity, "cluster capacity exceeded");
        }
        // These low-degree pairs have a uniquely strongest reciprocal edge,
        // even in the hub fixture. Root retention must not split them later.
        if (seeded)
            for (int v = 8; v + 3 < static_cast<int>(map.size()) - 8; v += 4) {
                if (static_cast<std::uint64_t>(host.vertex_weights[v]) + host.vertex_weights[v + 1] <= result.capacity)
                    require(map[v] == map[v + 1], "seed pair was split");
            }
        if (!previous.empty()) require(map == previous, "capacity shortcut or diagnostics changed regret decisions");
        previous = map;

        // Independent CPU edge aggregation, including duplicate edges,
        // non-unit weights and self-loops, checks the entire coarse CSR.
        std::map<std::pair<V, V>, std::uint64_t> expected;
        for (std::size_t v = 0; v < map.size(); ++v)
            for (auto e = host.offsets[v]; e < host.offsets[v + 1]; ++e)
                if (map[v] != map[host.neighbors[e]])
                    expected[{map[v], map[host.neighbors[e]]}] += host.edge_weights[e];
        gpart::ContractionTimings timings;
        auto coarse_device = gpart::contract(std::move(device), std::move(result), workspace, timings);
        auto coarse = gpart::copy_device_weighted(coarse_device);
        std::map<std::pair<V, V>, std::uint64_t> actual;
        for (V v = 0; v < coarse.vertices(); ++v)
            for (auto e = coarse.offsets[v]; e < coarse.offsets[v + 1]; ++e) {
                require(v != coarse.neighbors[e], "coarse self-loop");
                require(actual.emplace(std::make_pair(v, coarse.neighbors[e]), coarse.edge_weights[e]).second,
                        "duplicate coarse edge");
            }
        require(actual == expected, "coarse CSR differs from independent CPU aggregation");
    }
}
// Integration counterexample: a capacity-two receiver has one free slot.
// u prefers A:10/B:9; v prefers A:9/B:1. Regret must award A to v,
// whereas affinity-only awards A to u. Both choices remain capacity legal.
void check_competing_requests() {
    const auto mix=[](std::uint32_t x) {
        x ^= x >> 16; x *= 0x7feb352dU; x ^= x >> 15;
        x *= 0x846ca68bU; x ^= x >> 16; return x;
    };
    std::vector<int> donors, receivers;
    for(int v=0;v<16;++v)
        (mix(v ^ 17U ^ 0x27d4eb2dU)<0x80000000U ? donors : receivers).push_back(v);
    require(donors.size()>=2 && receivers.size()>=2,"fixture roles");
    const auto u=donors[0],v=donors[1],a=receivers[0],b=receivers[1];
    Graph graph;
    std::vector<std::vector<std::pair<V,W>>> rows(16);
    for (auto e : {std::make_tuple(u,a,10),std::make_tuple(u,b,9),
                   std::make_tuple(v,a,9),std::make_tuple(v,b,1)}) {
        const auto x=std::get<0>(e),y=std::get<1>(e),w=std::get<2>(e);
        rows[x].push_back({y,W(w)}); rows[y].push_back({x,W(w)});
    }
    graph.offsets.push_back(0);
    for(auto& row:rows) {
        std::sort(row.begin(),row.end()); graph.vertex_weights.push_back(1);
        for(auto e:row) {graph.neighbors.push_back(e.first);graph.edge_weights.push_back(e.second);}
        graph.offsets.push_back(graph.neighbors.size());
    }
    {
        auto device=gpart::make_device_weighted(graph);
        gpart::SclpWorkspace workspace;gpart::SclpStats stats;
        auto result=gpart::aggregate(device,workspace,4,17,0,stats,true,2,false,false);
        std::vector<V> map(result.map.size());
        thrust::copy(result.map.begin(),result.map.end(),map.begin());
        require(result.capacity==2,"fixture capacity");
        require(map[a]==map[v] && map[a]!=map[u],
                "capacity competition did not follow requested priority");
    }
}
} // namespace

int main() {
    try {
        check_competing_requests();
        W scale = 1;

        for (bool seeded : {false, true}) {
            check_case(make_graph(512, false, false, scale), seeded, 4);
            check_case(make_graph(512, false, false, scale), seeded, 128);
            check_case(make_graph(6000, true, false, scale), seeded, 4);
            check_case(make_graph(6000, true, true, scale), seeded, 4);
        }
        // Exercise the production dispatcher, singleton fast path, packed
        // records, implicit unit edges, and the >=65536 matching gate.
        for (int n : {512, 6000, 65536}) {
            auto graph = make_graph(n, n == 6000, false, 1);
            std::fill(graph.vertex_weights.begin(), graph.vertex_weights.end(), W{1});
            std::fill(graph.edge_weights.begin(), graph.edge_weights.end(), W{1});
            for (bool seeded : {false, true}) {
                std::vector<std::vector<V>> expected_maps;
                for (bool fast : {false, true}) {
                    gpart::CoarsenOptions options;
                    options.parts = 4; options.cluster_size_factor = 2;
                    options.max_levels = 3; options.strict_verify = true;
                    options.seed_matching = seeded;
                    options.capacity_safe_fast_path = fast;
                    options.pack_isolated = true;
                    auto hierarchy = gpart::coarsen(graph, options);
                    require(hierarchy.layer_count() > 1, "production regret dispatch did not contract");
                    if (!fast) expected_maps = hierarchy.fine_to_coarse;
                    else require(hierarchy.fine_to_coarse == expected_maps,
                                 "capacity shortcut changed production hierarchy maps");
                }
            }
        }
        CUDA_CHECK(cudaDeviceSynchronize());
        std::cout << "residual aggregation checks passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
