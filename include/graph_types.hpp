#pragma once
#include <cstdint>
namespace gpart {
inline constexpr int kMaxParts=128;
// One production representation. Cut, gain and aggregate-load counters stay 64 bit.
struct GraphTypes {
    using VertexT = std::int32_t;
    using OffsetT = std::int32_t;
    using WeightT = std::uint32_t;
};
inline constexpr const char* kActiveGraphName = "standard";
} // namespace gpart
