#pragma once

#include "graph.hpp"
#include "hierarchy.hpp"

#include <cstdint>
#include <memory>

#include <thrust/device_vector.h>

namespace gpart {

inline constexpr std::int64_t kBeta = 256;

struct CoarsenOptions {
    int parts = 4;
    std::uint32_t seed = 0;
    double stop_contraction_ratio = 0.90;
    int max_levels = 24;
    bool strict_verify = false;
    // Cluster capacity is ceil(total_weight / (cluster_size_factor * parts)).
    int cluster_size_factor = kBeta;
    bool pack_isolated = false;
    // Start with fine clusters, then relax the bound as graph size falls.
    // The final cutoff still uses cluster_size_factor.
    bool progressive_cluster_capacity = false;
    int progressive_fine_factor = 64;
    int progressive_capacity_growth = 8;
    // Optional GPU subphase telemetry; complete native wall time is always measured.
    bool detailed_timings = true;
    // Exact short-row CSR builder; false retains global radix contraction.
    bool row_local_contraction = true;
    // Optional one-pass HEM seed within regret aggregation. No trial/restart.
    bool seed_matching = true;
    // Skip regret statistics only when every request provably fits.
    bool capacity_safe_fast_path = true;
    int heavy_edge_degree_limit = 64;
};

struct DeviceAggregateResult {
    detail::ScratchVector<gpart::GraphTypes::VertexT> map;
    detail::ScratchVector<gpart::GraphTypes::WeightT> vertex_weights;
    gpart::GraphTypes::VertexT coarse_vertices = 0;
    std::uint64_t maximum_weight = 0;
    std::uint64_t capacity = 0;
};

class SclpWorkspace {
public:
    SclpWorkspace();
    ~SclpWorkspace();
    SclpWorkspace(SclpWorkspace&&) noexcept;
    SclpWorkspace& operator=(SclpWorkspace&&) noexcept;
    SclpWorkspace(const SclpWorkspace&) = delete;
    SclpWorkspace& operator=(const SclpWorkspace&) = delete;

    void reserve_contract_buffers(std::int64_t max_edges);

    struct Impl;
    std::unique_ptr<Impl> impl;
};

struct SclpStats {
    std::uint64_t maximum_degree=std::numeric_limits<std::uint64_t>::max();
    bool has_heavy_rows = true;
    std::uint64_t capacity = 0;
    std::uint64_t lp_accepted = 0;
    std::uint64_t capacity_rejected = 0;
    std::uint64_t two_hop_merged = 0;
    std::uint64_t singleton_count = 0;
    std::uint64_t proposal_count = 0;
    std::uint64_t positive_gain_vertices = 0;
    std::uint64_t role_blocked_vertices = 0;
    std::uint64_t role_blocked_gain = 0;
    std::uint64_t singleton_with_favorite = 0;
    std::uint64_t pairable_singletons = 0;
    int rounds = 0;
    double affinity_seconds = 0.0;
    double admission_seconds = 0.0;
    double two_hop_seconds = 0.0;
    double compact_seconds = 0.0;
    double aggregate_seconds = 0.0;
};

struct ContractionTimings {
    double total_seconds = 0.0;
    double compact_seconds = 0.0;
    double sort_seconds = 0.0;
    double reduce_seconds = 0.0;
    double csr_build_seconds = 0.0;
    double vertex_weight_seconds = 0.0;
};

DeviceAggregateResult aggregate(
    const DeviceWeightedGraph& graph, SclpWorkspace& workspace,
    int parts, std::uint32_t seed,
    int level, SclpStats& stats, bool diagnostics,
    int cluster_size_factor = kBeta, bool pack_isolated = false,
    bool seed_matching = false, bool capacity_safe_fast_path = true);

DeviceWeightedGraph contract(
    DeviceWeightedGraph fine,
    DeviceAggregateResult&& aggregate,
    SclpWorkspace& workspace, ContractionTimings& timings);

Hierarchy coarsen(
    const WeightedGraph& graph, const CoarsenOptions& options);

// Input is already validated/uploaded; allocation of coarsening workspace
// remains inside this call and therefore inside the partition timing.
DeviceHierarchy coarsen(
    DeviceWeightedGraph&& graph, const CoarsenOptions& options);

}  // namespace gpart
