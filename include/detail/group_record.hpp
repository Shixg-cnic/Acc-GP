#pragma once
#include <cstdint>

#ifdef __CUDACC__
#define GPART_GROUP_HD __host__ __device__
#else
#define GPART_GROUP_HD
#endif

namespace gpart::detail {
struct GroupSortRecord {
    std::uint64_t a, b, c, d;
    std::int32_t index;
    std::uint32_t reserved;
    GPART_GROUP_HD void append(std::uint64_t value, int bits) {
        if (bits == 64) { d = c; c = b; b = a; a = value; }
        else {
            d = (d << bits) | (c >> (64 - bits));
            c = (c << bits) | (b >> (64 - bits));
            b = (b << bits) | (a >> (64 - bits));
            a = (a << bits) | (value & ((std::uint64_t{1} << bits) - 1));
        }
    }
};
static_assert(sizeof(GroupSortRecord) == 40);
struct GroupSortLayout {
    int vertex_bits, weight_bits, gain_bits, pair_bits;
    GPART_GROUP_HD static int bits(std::uint64_t value) {
        int result = 0;
        while (value) { ++result; value >>= 1; }
        return result;
    }
    GPART_GROUP_HD static std::uint64_t magnitude(std::int64_t value) {
        const auto u = static_cast<std::uint64_t>(value);
        return value < 0 ? std::uint64_t{0} - u : u;
    }
    GPART_GROUP_HD static GroupSortLayout bounded(int n, int k,
        std::uint64_t maximum_weight, std::uint64_t maximum_gain_magnitude) {
        const auto wb = bits(maximum_weight);
        const auto gb = bits(maximum_gain_magnitude) + 1;
        return {bits(n), wb ? wb : 1, gb > 64 ? 64 : gb, bits(k * k - 1)};
    }
    GPART_GROUP_HD int end_bit() const {
        return 4 * vertex_bits + weight_bits + gain_bits + pair_bits;
    }
    GPART_GROUP_HD GroupSortRecord encode(int pair, std::uint64_t weight,
        std::int64_t gain, const std::int32_t* vertices, int index) const {
        GroupSortRecord key{0, 0, 0, 0, index, 0};
        key.append(pair, pair_bits);
        key.append(weight, weight_bits);
        const auto reverse = ~static_cast<std::uint64_t>(gain) ^
            (std::uint64_t{1} << (gain_bits - 1));
        key.append(reverse, gain_bits);
        for (int i = 0; i < 4; ++i)
            key.append(static_cast<std::uint64_t>(vertices[i] + 1), vertex_bits);
        return key;
    }
};
} // namespace gpart::detail
#undef GPART_GROUP_HD
