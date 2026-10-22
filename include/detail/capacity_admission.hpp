#pragma once
#include <cstdint>
#include <limits>

#ifdef __CUDACC__
#define GPART_ADMISSION_HD __host__ __device__
#else
#define GPART_ADMISSION_HD
#endif

namespace gpart::detail {
// Preserve the original record width and stable vertex payload. Pack the
// target immediately above the significant gain bits; tie remains full32.
template <typename GainT>
struct SclpAdmissionKey {
    GainT target, reverse_gain;
    std::uint32_t reverse_tie, vertex;
    static constexpr int word_bits = 8 * sizeof(GainT);
    GPART_ADMISSION_HD static SclpAdmissionKey encode(std::uint32_t target,
        GainT gain, std::uint32_t tie, std::uint32_t vertex, int gain_bits) {
        const auto reverse = static_cast<GainT>(~gain);
        if (gain_bits == word_bits) return {static_cast<GainT>(target), reverse, ~tie, vertex};
        const auto mask = static_cast<GainT>((GainT{1} << gain_bits) - 1);
        return {static_cast<GainT>(static_cast<GainT>(target) >> (word_bits-gain_bits)),
            static_cast<GainT>((static_cast<GainT>(target) << gain_bits) | (reverse & mask)),
            ~tie, vertex};
    }
    GPART_ADMISSION_HD std::uint32_t decode_target(int gain_bits) const {
        if (gain_bits == word_bits) return static_cast<std::uint32_t>(target);
        return static_cast<std::uint32_t>((target << (word_bits-gain_bits)) |
            (reverse_gain >> gain_bits));
    }
};
static_assert(sizeof(SclpAdmissionKey<std::uint32_t>) == 16);
static_assert(sizeof(SclpAdmissionKey<std::uint64_t>) == 24);
} // namespace gpart::detail
#undef GPART_ADMISSION_HD
