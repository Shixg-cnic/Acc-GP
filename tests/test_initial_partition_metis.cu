#include "initial_partition.hpp"
#include "partition_capacity.hpp"
#include <metis.h>
#include <thrust/copy.h>
#include <algorithm>
#include <cmath>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <vector>
using W = gpart::GraphTypes::WeightT;
void check(const gpart::WeightedGraph& graph, int parts, bool zero_cut) {
    auto device = gpart::make_device_weighted(graph);
    auto a = gpart::initial_partition_metis(device, parts, 1.03, 0);
    auto b = gpart::initial_partition_metis(device, parts, 1.03, 0);
    std::vector<int> labels(a.size()), again(b.size());
    thrust::copy(a.begin(), a.end(), labels.begin());
    thrust::copy(b.begin(), b.end(), again.begin());
    if (labels != again) throw std::runtime_error("METIS initialization is not repeatable");
    std::vector<std::uint64_t> weights(parts, 0);
    std::uint64_t total = 0;
    for (std::size_t v = 0; v < labels.size(); ++v) {
        if (labels[v] < 0 || labels[v] >= parts) throw std::runtime_error("invalid label");
        weights[labels[v]] += graph.vertex_weights[v];
        total += graph.vertex_weights[v];
    }
    auto capacity = gpart::partition_capacity(total, parts, 1.03);
    if (*std::max_element(weights.begin(), weights.end()) > capacity)
        throw std::runtime_error("capacity violation");
    if (zero_cut && gpart::host_cut(graph, labels) != 0)
        throw std::runtime_error("disconnected community quality regression");
}
int main() {
    gpart::WeightedGraph graph;
    graph.offsets.push_back(0);
    // Two weighted cliques: METIS should preserve disconnected components.
    for (int v = 0; v < 8; ++v) {
        for (int u = 0; u < 8; ++u) if (u != v && u / 4 == v / 4) {
            graph.neighbors.push_back(u); graph.edge_weights.push_back(W{3});
        }
        graph.offsets.push_back(graph.neighbors.size());
        graph.vertex_weights.push_back(W{2});
    }
    check(graph, 2, true);

    // Isolated vertices and a non-power-of-two partition count.
    graph.offsets.assign(13, 0); graph.neighbors.clear(); graph.edge_weights.clear();
    graph.vertex_weights.assign(12, W{1});
    check(graph, 3, true);
    // Partial blocks, hubs, duplicate edges and an isolated tail vertex.
    // Verify exact integer capacity, including any necessary METIS repair.
    graph.offsets.assign(1, 0);
    graph.vertex_weights.assign(259, W{1});
    for (int v = 0; v < 259; ++v) {
        std::vector<int> row;
        if (v == 0) for (int u = 1; u < 258; ++u) { row.push_back(u); row.push_back(u); }
        if (v > 0 && v < 258) { row.push_back(0); row.push_back(0); }
        if (v > 1 && v < 258) row.push_back(v - 1);
        if (v > 0 && v < 257) row.push_back(v + 1);
        std::sort(row.begin(), row.end());
        graph.neighbors.insert(graph.neighbors.end(), row.begin(), row.end());
        graph.edge_weights.insert(graph.edge_weights.end(), row.size(), W{7});
        graph.offsets.push_back(graph.neighbors.size());
    }
    for (int k : {2, 3, 4, 8}) check(graph, k, false);
    graph.offsets.assign(257, 0); graph.neighbors.clear(); graph.edge_weights.clear();
    graph.vertex_weights.assign(256, W{1});
    for(int k : {32,64,128}) check(graph,k,true);
    // Odd partition counts and the upper limit use the same METIS API.
    graph.offsets.assign(4097,0);graph.vertex_weights.assign(4096,W{1});
    for (int k : {5,7,17,31,63,65,127}) check(graph,k,true);

    graph.offsets.assign(257,0);graph.vertex_weights.assign(256,W{1});
    // No initializer can place this indivisible vertex under capacity.
    graph.vertex_weights[0] = W{1000};
    bool rejected = false;
    try { auto d = gpart::make_device_weighted(graph); gpart::initial_partition_metis(d, 3, 1.10); }
    catch (const std::invalid_argument&) { rejected = true; }
    if (!rejected) throw std::runtime_error("overweight vertex was not rejected");
    graph.offsets.assign(5, 0); graph.vertex_weights.assign(4, W{1});
    rejected = false;
    try { auto d = gpart::make_device_weighted(graph); gpart::initial_partition_metis(d, 3, 1.03); }
    catch (const std::invalid_argument&) { rejected = true; }
    if (!rejected) throw std::runtime_error("impossible integer capacity was not rejected");
    // No split of three indivisible weight-two vertices can fit capacity three.
    graph.offsets.assign(4, 0); graph.vertex_weights.assign(3, W{2});
    rejected = false;
    try { auto d = gpart::make_device_weighted(graph); gpart::initial_partition_metis(d, 2, 1.03); }
    catch (const std::runtime_error&) { rejected = true; }
    if (!rejected) throw std::runtime_error("infeasible weighted split was not rejected");
    { // Production can hand indivisible coarse imbalance to uncoarsening.
        auto d=gpart::make_device_weighted(graph);
        auto output=gpart::initial_partition_metis(d,2,1.03,0,false);
        if (output.size()!=3) throw std::runtime_error("raw METIS labels have wrong length");
    }

    // Reject non-normalizable weights instead of silently narrowing idx_t.
    if (static_cast<std::uint64_t>(std::numeric_limits<W>::max()) >=
        static_cast<std::uint64_t>(std::numeric_limits<idx_t>::max())) {
        const auto limit = static_cast<std::uint64_t>(std::numeric_limits<idx_t>::max());
        graph.offsets = {0, 0, 0}; graph.neighbors.clear(); graph.edge_weights.clear();
        graph.vertex_weights = {static_cast<W>(limit), static_cast<W>(limit - 1)};
        rejected = false;
        try { auto d = gpart::make_device_weighted(graph); gpart::initial_partition_metis(d, 2, 1.10); }
        catch (const std::overflow_error&) { rejected = true; }
        if (!rejected) throw std::runtime_error("METIS signed weight overflow was not rejected");
    }
    // On a graph needing no repair or normalization, the adapter must return
    // exactly the labels from Jet's default-options, seed-zero METIS API call.
    graph.offsets.assign(1, 0); graph.neighbors.clear(); graph.edge_weights.clear();
    graph.vertex_weights.assign(512, W{1});
    for (int v = 0; v < 512; ++v) {
        for (int u = 128 * (v / 128); u < 128 * (v / 128 + 1); ++u)
            if (u != v) { graph.neighbors.push_back(u); graph.edge_weights.push_back(W{1}); }
        graph.offsets.push_back(graph.neighbors.size());
    }
    auto d = gpart::make_device_weighted(graph);
    auto actual_device = gpart::initial_partition_metis(d, 4, 1.03, 0);
    std::vector<int> actual(512);
    thrust::copy(actual_device.begin(), actual_device.end(), actual.begin());
    std::vector<idx_t> offsets(graph.offsets.begin(), graph.offsets.end());
    std::vector<idx_t> neighbors(graph.neighbors.begin(), graph.neighbors.end());
    std::vector<idx_t> vw(512, 1), ew(neighbors.size(), 1), expected(512);
    idx_t n = 512, ncon = 1, parts = 4, cut = 0, options[METIS_NOPTIONS];
    METIS_SetDefaultOptions(options); options[METIS_OPTION_SEED] = 0;
    real_t imbalance = static_cast<real_t>(1.03);
    if (METIS_PartGraphKway(&n, &ncon, offsets.data(), neighbors.data(), vw.data(),
        nullptr, ew.data(), &parts, nullptr, &imbalance, options, &cut, expected.data()) != METIS_OK)
        throw std::runtime_error("direct reference METIS call failed");
    if (!std::equal(actual.begin(), actual.end(), expected.begin()) || cut != 0)
        throw std::runtime_error("adapter differs from the direct Jet-style METIS call");
    std::cout << "METIS initial correctness passed: " << gpart::kActiveGraphName << '\n';
}
