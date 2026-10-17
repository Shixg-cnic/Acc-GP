#pragma once

#include "hierarchy.hpp"
#include "refine.hpp"

#include <vector>

namespace gpart {

std::vector<gpart::GraphTypes::VertexT> uncoarsen(
    const Hierarchy& hierarchy,
    const std::vector<gpart::GraphTypes::VertexT>& coarsest_partition,
    const RefineOptions& options);

// Consumes device levels/maps and labels; the result keeps the final partition
// on device so output download can be timed separately from partitioning.
DeviceUncoarsenResult uncoarsen(
    DeviceHierarchy& hierarchy,
    thrust::device_vector<gpart::GraphTypes::VertexT>&& coarsest_partition,
    const RefineOptions& options);

}  // namespace gpart
