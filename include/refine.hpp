#pragma once

#include "graph.hpp"
#include "hierarchy.hpp"

#include <cstdint>
#include <vector>

namespace gpart {

enum class AffinityLayout { Automatic, Dense, Sparse, OnDemand };

struct RefineOptions {
    int parts = 4;
    double imbalance_ratio = 1.03;
    int max_rounds = 32;
    bool strict_verify = false;
    bool allow_initial_imbalance = false;
    int stale_rounds = 3;
    double refinement_growth_ratio = 2.0;
    int exchange_rounds = 2; // Library test budget; production uses two batches.
    AffinityLayout affinity_layout = AffinityLayout::Automatic;
    bool gpu_lp_loop = true; // false keeps the host-controlled reference loop.
    bool repair_enumeration = true; // Exact interior shortcut / sparse destination enumeration.
    bool sparse_cut_bound = true; // Additional conservative layout eligibility from projected cut.
};

struct RefineStats {
    bool initial_repair_failed = false;
    int rounds = 0;
    std::uint64_t proposals = 0;
    std::uint64_t accepted = 0;
    std::uint64_t initial_cut = 0;
    std::uint64_t final_cut = 0;
    std::uint64_t final_max_part_weight = 0;
    double seconds = 0.0;
    int admission_iterations = 0;
    int admission_fallbacks = 0;
    int affinity_counter_bits = 0;
    bool sparse_affinity = false;
    bool on_demand_affinity = false;
    std::uint64_t frontier_vertices_initial = 0;
    std::uint64_t affinity_bytes = 0;
    // Exact affected-edge deltas, accumulated without additional CSR scans.
    std::uint64_t lp_cut_gain = 0;
    std::uint64_t lp_cut_loss = 0;
    std::uint64_t rebalance_cut_gain = 0;
    std::uint64_t rebalance_cut_loss = 0;
    std::uint64_t checkpoint_discarded_cut = 0;
    int checkpoint_updates = 0;
    std::uint64_t group_cut_gain = 0;
    std::uint64_t group_accepted = 0;
};

struct RefineLevelTimings {
    double workspace_resize_seconds = 0.0;
    double graph_h2d_seconds = 0.0;
    double projection_gpu_seconds = 0.0;
    double refinement_seconds = 0.0;
    double verification_seconds = 0.0;
};

struct RefineLevelResult {
    std::size_t level = 0;
    std::int64_t vertices = 0;
    std::int64_t edge_entries = 0;
    std::uint64_t projection_cut = 0;
    std::uint64_t projection_max_part_weight = 0;
    double projection_imbalance = 0.0;
    RefineStats refinement;
    RefineLevelTimings timings;
};

struct DeviceUncoarsenResult {
    std::vector<gpart::GraphTypes::VertexT> partition;
    thrust::device_vector<gpart::GraphTypes::VertexT> device_partition;
    std::vector<RefineLevelResult> levels;
    std::vector<std::uint64_t> final_part_weights;
    std::uint64_t final_cut = 0;
    std::uint64_t total_edge_weight = 0;
    double final_d2h_seconds = 0.0;
};

void refine_partition(
    const WeightedGraph& graph,
    std::vector<gpart::GraphTypes::VertexT>& partition,
    const RefineOptions& options,
    RefineStats* stats = nullptr);

DeviceUncoarsenResult refine_hierarchy_device(
    const Hierarchy& hierarchy,
    const std::vector<gpart::GraphTypes::VertexT>& coarsest_partition,
    const RefineOptions& options);

DeviceUncoarsenResult refine_hierarchy_device(
    DeviceHierarchy& hierarchy,
    thrust::device_vector<gpart::GraphTypes::VertexT>&& coarsest_partition,
    const RefineOptions& options);

}  // namespace gpart
