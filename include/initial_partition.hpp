#pragma once
#include "graph.hpp"
namespace gpart {
// CPU METIS on a resident coarse graph. Strict mode repairs integer capacity.
// Production defers coarse imbalance to GPU repair during uncoarsening.
thrust::device_vector<gpart::GraphTypes::VertexT> initial_partition_metis(
    const DeviceWeightedGraph& graph, int parts, double imbalance_ratio,
    std::uint32_t seed = 0, bool require_feasible = true);
} // namespace gpart
