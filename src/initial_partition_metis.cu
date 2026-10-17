#include "initial_partition.hpp"
#include "partition_capacity.hpp"
#include "check.hpp"

#include <metis.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <limits>
#include <numeric>
#include <stdexcept>
#include <vector>

namespace gpart {
namespace {
using U64 = std::uint64_t;

template <typename WeightT>
U64 checked_total(const std::vector<WeightT>& weights) {
    U64 total = 0;
    for (auto w : weights) {
        const auto weight = static_cast<U64>(w);
        if (weight > std::numeric_limits<U64>::max() - total)
            throw std::overflow_error("METIS initialization weight sum exceeds uint64");
        total += weight;
    }
    return total;
}

// METIS has a balance target, while our caller requires an integer capacity.
// Only repair an actual violation. All moves reduce overload and fit wholly
// in a receiver's remaining capacity; a failed repair is reported explicitly.
std::size_t repair_capacity(const WeightedGraph& graph,
    std::vector<gpart::GraphTypes::VertexT>& labels, std::vector<U64>& loads,
    U64 capacity) {
    if (*std::max_element(loads.begin(), loads.end()) <= capacity) return 0;
    const auto k = loads.size(), n = labels.size();
    if (n > std::vector<U64>().max_size() / k)
        throw std::overflow_error("METIS capacity repair workspace is too large");
    std::vector<U64> affinity(n * k, 0);
    for (std::size_t v = 0; v < n; ++v)
        for (auto e = graph.offsets[v]; e < graph.offsets[v + 1]; ++e) {
            const auto u = graph.neighbors[e];
            if (u != static_cast<gpart::GraphTypes::VertexT>(v))
                affinity[v * k + labels[u]] += graph.edge_weights[e];
        }
    std::size_t moved = 0;
    while (*std::max_element(loads.begin(), loads.end()) > capacity) {
        std::size_t chosen = n;
        int target = -1;
        long double best = -std::numeric_limits<long double>::infinity();
        for (std::size_t v = 0; v < n; ++v) {
            const auto source = labels[v];
            if (loads[source] <= capacity) continue;
            const U64 weight = graph.vertex_weights[v];
            for (std::size_t p = 0; p < k; ++p) {
                if (p == static_cast<std::size_t>(source) || loads[p] > capacity ||
                    weight > capacity - loads[p]) continue;
                const long double gain = static_cast<long double>(affinity[v * k + p]) -
                                         static_cast<long double>(affinity[v * k + source]);
                const auto removable = std::min(weight, loads[source] - capacity);
                const auto score = gain / removable;
                if (score > best) { best = score; chosen = v; target = static_cast<int>(p); }
            }
        }
        if (target < 0)
            throw std::runtime_error("METIS output cannot meet strict capacity by feasible single moves");
        const auto source = labels[chosen];
        loads[source] -= graph.vertex_weights[chosen];
        loads[target] += graph.vertex_weights[chosen];
        for (auto e = graph.offsets[chosen]; e < graph.offsets[chosen + 1]; ++e) {
            const auto u = graph.neighbors[e];
            if (u == static_cast<gpart::GraphTypes::VertexT>(chosen)) continue;
            affinity[static_cast<std::size_t>(u) * k + source] -= graph.edge_weights[e];
            affinity[static_cast<std::size_t>(u) * k + target] += graph.edge_weights[e];
        }
        labels[chosen] = static_cast<gpart::GraphTypes::VertexT>(target);
        ++moved;
    }
    return moved;
}
} // namespace

thrust::device_vector<gpart::GraphTypes::VertexT> initial_partition_metis(
    const DeviceWeightedGraph& device, int parts, double imbalance,
    std::uint32_t seed, bool require_feasible) {
    const auto start = std::chrono::steady_clock::now();
    const auto n64 = device.vertices();
    const U64 limit = static_cast<U64>(std::numeric_limits<idx_t>::max());
    if (n64 <= 0 || static_cast<U64>(n64) > limit || parts < 2 ||
        parts > kMaxParts || parts > n64 || !std::isfinite(imbalance) || imbalance < 1.0)
        throw std::invalid_argument("invalid METIS initialization options");

    // Use the installed library's idx_t/real_t, never assume their ABI widths.
    auto graph = copy_device_weighted(device);
    validate_weighted_shape(graph, true);
    const U64 total = checked_total(graph.vertex_weights);
    const U64 edge_total = checked_total(graph.edge_weights);
    const U64 capacity = partition_capacity(total, parts, imbalance);
    U64 vertex_gcd = 0, edge_gcd = 0;
    for (auto w : graph.vertex_weights) {
        if (!w) throw std::invalid_argument("METIS requires positive vertex weights");
        if (static_cast<U64>(w) > capacity)
            throw std::invalid_argument("a vertex exceeds partition capacity");
        vertex_gcd = std::gcd(vertex_gcd, static_cast<U64>(w));
    }
    for (auto w : graph.edge_weights) edge_gcd = std::gcd(edge_gcd, static_cast<U64>(w));
    if (!edge_gcd) edge_gcd = 1;
    // Exact common-factor normalization preserves the weighted objective and
    // capacities. Values that still exceed METIS's signed range are rejected;
    // there is no narrowing, clipping or approximate weight rescaling.
    const U64 scaled_total = total / vertex_gcd;
    if (scaled_total > limit || edge_total / edge_gcd > limit)
        throw std::overflow_error("weighted coarse graph exceeds METIS signed weight range");
    const auto minimum_load = scaled_total / parts + (scaled_total % parts != 0);
    if (require_feasible && capacity / vertex_gcd < minimum_load)
        throw std::runtime_error("indivisible weights cannot satisfy partition capacity");

    std::vector<idx_t> offsets(static_cast<std::size_t>(n64) + 1, 0);
    std::vector<idx_t> neighbors, edges, weights(static_cast<std::size_t>(n64));
    neighbors.reserve(graph.neighbors.size()); edges.reserve(graph.edge_weights.size());
    for (std::int64_t v = 0; v < n64; ++v) {
        weights[v] = static_cast<idx_t>(graph.vertex_weights[v] / vertex_gcd);
        for (auto e = graph.offsets[v]; e < graph.offsets[v + 1]; ++e) {
            if (graph.neighbors[e] == v || !graph.edge_weights[e]) continue;
            if (neighbors.size() >= limit)
                throw std::overflow_error("coarse adjacency exceeds METIS index range");
            neighbors.push_back(static_cast<idx_t>(graph.neighbors[e]));
            edges.push_back(static_cast<idx_t>(graph.edge_weights[e] / edge_gcd));
        }
        offsets[v + 1] = static_cast<idx_t>(neighbors.size());
    }
    idx_t n = static_cast<idx_t>(n64), constraints = 1, k = parts, objective = 0;
    std::vector<idx_t> output(static_cast<std::size_t>(n64));
    idx_t options[METIS_NOPTIONS];
    if (METIS_SetDefaultOptions(options) != METIS_OK)
        throw std::runtime_error("METIS_SetDefaultOptions failed");
    options[METIS_OPTION_SEED] = static_cast<idx_t>(seed & 0x7fffffffU);
    options[METIS_OPTION_NUMBERING] = 0;
    real_t upper = static_cast<real_t>(imbalance);
    // An exact balance request still needs a valid METIS tolerance. The
    // original integer capacity, checked below, remains the final contract.
    if (upper <= real_t{1})
        upper = std::nextafter(real_t{1}, std::numeric_limits<real_t>::infinity());
    const auto call_start = std::chrono::steady_clock::now();
    const int status = METIS_PartGraphKway(&n, &constraints, offsets.data(),
        neighbors.data(), weights.data(), nullptr, edges.data(), &k, nullptr,
        &upper, options, &objective, output.data());
    const double metis_seconds = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - call_start).count();
    if (status != METIS_OK)
        throw std::runtime_error("METIS_PartGraphKway failed: " + std::to_string(status));

    std::vector<U64> loads(parts, 0);
    std::vector<gpart::GraphTypes::VertexT> host_labels(output.size());
    for (std::size_t v = 0; v < output.size(); ++v) {
        if (output[v] < 0 || output[v] >= parts)
            throw std::runtime_error("METIS returned an invalid partition label");
        host_labels[v] = static_cast<gpart::GraphTypes::VertexT>(output[v]);
        loads[output[v]] += graph.vertex_weights[v];
    }
    const auto initial_max = *std::max_element(loads.begin(), loads.end());
    const auto repaired = require_feasible ? repair_capacity(graph, host_labels, loads, capacity) : 0;
    const auto exact_cut = host_cut(graph, host_labels);
    thrust::device_vector<gpart::GraphTypes::VertexT> labels(host_labels.begin(), host_labels.end());
    CUDA_CHECK(cudaDeviceSynchronize());
    std::cout << "initial_partition_backend=metis\n"
              << "initial_partition_metis_version=" << METIS_VER_MAJOR << '.'
              << METIS_VER_MINOR << '.' << METIS_VER_SUBMINOR << '\n'
              << "initial_partition_metis_index_bits=" << sizeof(idx_t) * 8 << '\n'
              << "coarsest_vertices=" << n64 << '\n'
              << "coarsest_edge_entries=" << graph.edges() << '\n'
              << "initial_partition_parts=" << parts << '\n'
              << "initial_partition_edgecut=" << exact_cut << '\n'
              << "initial_partition_metis_max_load=" << initial_max << '\n'
              << "initial_partition_repaired_vertices=" << repaired << '\n'
              << "initial_partition_metis_call_seconds=" << metis_seconds << '\n'
              << "initial_partition_seconds=" << std::chrono::duration<double>(
                    std::chrono::steady_clock::now() - start).count() << '\n';
    return labels;
}


} // namespace gpart
