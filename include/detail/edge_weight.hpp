#pragma once
#include <cstdint>

namespace gpart::detail {
// A null edge array represents exactly unit edge weights. Only graphs whose
// complete host weight array was proved unit may omit that device allocation.
// Coarse graphs continue to store their full integer weights.
template <typename W, typename I>
__host__ __device__ inline W edge_weight(const W* weights, I edge) {
    return weights ? weights[edge] : W{1};
}
} // namespace gpart::detail
