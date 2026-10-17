#pragma once

#include "graph_types.hpp"
#include "detail/scratch_pool.hpp"
#include "detail/edge_weight.hpp"

#include <cstdint>
#include <limits>
#include <string>
#include <vector>

#include <thrust/device_vector.h>

namespace gpart {

struct WeightedGraph {
    using VertexT = gpart::GraphTypes::VertexT;
    using OffsetT = gpart::GraphTypes::OffsetT;
    using WeightT = gpart::GraphTypes::WeightT;

    std::vector<OffsetT> offsets;
    std::vector<VertexT> neighbors;
    std::vector<WeightT> edge_weights;
    std::vector<WeightT> vertex_weights;

    std::int64_t vertices() const {
        return static_cast<std::int64_t>(vertex_weights.size());
    }
    std::int64_t edges() const {
        return static_cast<std::int64_t>(neighbors.size());
    }
};

struct DeviceWeightedGraph {
    using VertexT = gpart::GraphTypes::VertexT;
    using OffsetT = gpart::GraphTypes::OffsetT;
    using WeightT = gpart::GraphTypes::WeightT;

    detail::ScratchVector<OffsetT> offsets;
    detail::ScratchVector<VertexT> neighbors;
    detail::ScratchVector<WeightT> edge_weights;
    detail::ScratchVector<WeightT> vertex_weights;
    bool implicit_unit_weights=false;
    // Conservative maximum incident edge-weight sum, carried by coarsening.
    // Unknown graphs retain 64-bit affinity counters; no extra CSR scan is
    // needed to specialize counters when this existing bound is available.
    std::uint64_t maximum_degree=std::numeric_limits<std::uint64_t>::max();
    bool has_heavy_rows=true; // Unknown until the coarsener classifies actual row degrees.
    std::uint64_t incident_weight_bound=std::numeric_limits<std::uint64_t>::max();

    std::int64_t vertices() const {
        return static_cast<std::int64_t>(vertex_weights.size());
    }
    std::int64_t edges() const {
        return static_cast<std::int64_t>(neighbors.size());
    }
};

WeightedGraph load_weighted_graph(
    const std::string& indptr_path, const std::string& indices_path);

void validate_weighted_shape(
    const WeightedGraph& graph, bool allow_self_loops);

void validate_weighted_csr(
    const WeightedGraph& graph, bool allow_self_loops);

std::uint64_t host_cut(
    const WeightedGraph& graph,
    const std::vector<gpart::GraphTypes::VertexT>& labels);

DeviceWeightedGraph make_device_weighted(
    const WeightedGraph& graph, bool omit_unit_weights=true);

WeightedGraph copy_device_weighted(
    const DeviceWeightedGraph& graph);

}  // namespace gpart
