#include "coarsen.hpp"
#include "graph.hpp"
#include "graph_types.hpp"
#include "initial_partition.hpp"
#include "partition_capacity.hpp"
#include "uncoarsen.hpp"
#include "check.hpp"
#include "detail/scratch_pool.hpp"
#include <thrust/copy.h>

#include <cstdint>
#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <stdexcept>
#include <string>

int main(int argc, char** argv) {
    try {
        const auto wall_start = std::chrono::steady_clock::now();
        bool verify = false;
        int positional_argc = argc;
        while (positional_argc > 1) {
            const std::string flag(argv[positional_argc - 1]);
            if (flag == "--verify") verify = true;
            else break;
            --positional_argc;
        }
        if (positional_argc < 5 || positional_argc > 7) {
            std::cerr << "Usage: " << argv[0]
                      << " <indptr.bin> <indices.bin> <parts> <partition.out>"
                      << " [imbalance_ratio=1.03] [seed] [--verify]\n";
            return 2;
        }
        const int parts = std::stoi(argv[3]);
        const double imbalance = positional_argc >= 6 ? std::stod(argv[5]) : 1.03;
        const auto seed = positional_argc >= 7
            ? static_cast<std::uint32_t>(std::stoul(argv[6])) : 0U;
        const auto load_start = std::chrono::steady_clock::now();
        auto graph = gpart::load_weighted_graph(argv[1], argv[2]);
        gpart::partition_capacity(static_cast<std::uint64_t>(graph.vertices()), parts, imbalance);
        const auto load_end = std::chrono::steady_clock::now();
        std::cout << "verify=" << (verify ? 1 : 0) << '\n';
        gpart::CoarsenOptions coarsen_options;
        coarsen_options.parts = parts;
        coarsen_options.seed = seed;
        coarsen_options.strict_verify = verify;
        coarsen_options.detailed_timings = std::getenv("GPART_GPU_TIMINGS") != nullptr;
        const char* matching = std::getenv("GPART_HEM_COARSEN");
        coarsen_options.seed_matching = !matching || std::string(matching) != "0";
        const char* force_regret = std::getenv("GPART_REGRET_FORCE_FULL");
        coarsen_options.capacity_safe_fast_path = !force_regret || std::string(force_regret) == "0";
        const char* requested_mode = std::getenv("GPART_COARSEN_MODE");
        const std::string coarsen_mode = requested_mode ? requested_mode : "regret";
        if (coarsen_mode != "regret")
            throw std::runtime_error("Only regret coarsening is maintained; use an archived binary for legacy/residual/sclp comparisons");
        coarsen_options.heavy_edge_degree_limit = 64;
        if (const char* limit = std::getenv("GPART_HEM_DEGREE_LIMIT")) {
            coarsen_options.heavy_edge_degree_limit = std::stoi(limit);
            if (coarsen_options.heavy_edge_degree_limit < 2 || coarsen_options.heavy_edge_degree_limit > 256)
                throw std::runtime_error("GPART_HEM_DEGREE_LIMIT must be between 2 and 256");
        }
        {
            // Preserve small-k SCLP cluster bounds. For k>=16, target 2*k
            // coarse vertices; GPU repair can defer indivisible coarse
            // imbalance until projection exposes finer vertices.
            coarsen_options.cluster_size_factor=(parts <= 8 ? std::max(64,(512+parts-1)/parts) : std::max(2,(32+parts-1)/parts));
            coarsen_options.pack_isolated=true;
            coarsen_options.progressive_cluster_capacity=parts>=16;
        }
        if(const char* factor=std::getenv("GPART_FINE_FACTOR"))
            coarsen_options.progressive_fine_factor=std::stoi(factor);
        if(const char* growth=std::getenv("GPART_CAPACITY_GROWTH"))
            coarsen_options.progressive_capacity_growth=std::stoi(growth);
        if (const char* beta=std::getenv("GPART_COARSE_BETA")) {
            coarsen_options.cluster_size_factor=std::stoi(beta);
            if(coarsen_options.cluster_size_factor<2 || coarsen_options.cluster_size_factor>256)
                throw std::runtime_error("GPART_COARSE_BETA must be between 2 and 256");
        }
        std::cout << "pipeline_mode=" << "incremental_bucket"
                  << " cluster_size_factor=" << coarsen_options.cluster_size_factor
                  << " progressive_cluster_capacity=" << coarsen_options.progressive_cluster_capacity
                  << " progressive_fine_factor=" << coarsen_options.progressive_fine_factor
                  << " progressive_capacity_growth=" << coarsen_options.progressive_capacity_growth
                  << " pack_isolated=" << coarsen_options.pack_isolated << '\n';
        std::cout << "seed_matching=" << coarsen_options.seed_matching
                  << " heavy_edge_degree_limit=" << coarsen_options.heavy_edge_degree_limit
                  << " coarsen_mode=" << coarsen_mode << '\n';
        // Jet-aligned boundary: initialized execution space and uploaded input.
        // Retain the full wall clock separately; do not hide preparation costs.
        const auto prepare_start = std::chrono::steady_clock::now();
        if (verify) gpart::validate_weighted_csr(graph, true);
        else gpart::validate_weighted_shape(graph, true);
        auto device_graph = gpart::make_device_weighted(graph);
        std::cout << "input_implicit_unit_weights=" << device_graph.implicit_unit_weights
                  << " stored_edge_weight_entries=" << device_graph.edge_weights.size() << '\n';
        CUDA_CHECK(cudaDeviceSynchronize());
        const auto coarsen_start = std::chrono::steady_clock::now();
        gpart::detail::ScratchPoolSession scratch_pool;
        auto hierarchy = gpart::coarsen(std::move(device_graph), coarsen_options);
        CUDA_CHECK(cudaDeviceSynchronize());
        const auto coarsen_end = std::chrono::steady_clock::now();
        const auto initial_start = std::chrono::steady_clock::now();
        auto coarse_partition = gpart::initial_partition_metis(
            hierarchy.levels.back(), parts, imbalance, seed, false);
        CUDA_CHECK(cudaDeviceSynchronize());
        const auto initial_end = std::chrono::steady_clock::now();
        gpart::RefineOptions refine_options;
        const char* requested_refine = std::getenv("GPART_REFINE_MODE");
        const std::string refine_mode = requested_refine ? requested_refine : "legacy";
        if (refine_mode=="joint") refine_options.mode=gpart::RefinementMode::Joint;
        else if (refine_mode=="joint-polish") refine_options.mode=gpart::RefinementMode::JointPolish;
        else if (refine_mode!="legacy") throw std::invalid_argument("GPART_REFINE_MODE must be legacy, joint, or joint-polish");
        if (const char* count=std::getenv("GPART_JOINT_ROUNDS")) refine_options.joint_rounds=std::stoi(count);
        if (const char* count=std::getenv("GPART_JOINT_CONFLICT_ROUNDS")) {
            std::size_t used=0;
            refine_options.joint_conflict_rounds=std::stoi(count,&used);
            if (count[used] || refine_options.joint_conflict_rounds<1 || refine_options.joint_conflict_rounds>4)
                throw std::invalid_argument("GPART_JOINT_CONFLICT_ROUNDS must be 1..4");
        }
        auto joint_flag=[](const char* name) {
            const char* value=std::getenv(name);
            if (!value) return false;
            if (std::string(value)=="1") return true;
            if (std::string(value)=="0") return false;
            throw std::invalid_argument(std::string(name)+" must be 0 or 1");
        };
        refine_options.joint_deduplicate=joint_flag("GPART_JOINT_DEDUPLICATE");
        refine_options.joint_diagnostics=joint_flag("GPART_JOINT_DIAGNOSTICS");
        std::cout << "refine_mode=" << refine_mode << " joint_rounds=" << refine_options.joint_rounds
                  << " joint_conflict_rounds=" << refine_options.joint_conflict_rounds
                  << " joint_deduplicate=" << refine_options.joint_deduplicate
                  << " joint_diagnostics=" << refine_options.joint_diagnostics << '\n';
        refine_options.parts = parts;
        refine_options.allow_initial_imbalance = true;
        refine_options.imbalance_ratio = imbalance;
        refine_options.max_rounds = 32;
        refine_options.strict_verify = verify;
        refine_options.refinement_growth_ratio=2.0;
        const auto uncoarsen_start = std::chrono::steady_clock::now();
        auto result = gpart::uncoarsen(
            hierarchy, std::move(coarse_partition), refine_options);
        CUDA_CHECK(cudaDeviceSynchronize());
        const auto uncoarsen_end = std::chrono::steady_clock::now();

        hierarchy.levels.clear();
        hierarchy.fine_to_coarse.clear();
        scratch_pool.finish();
        CUDA_CHECK(cudaDeviceSynchronize());
        const auto free_end = std::chrono::steady_clock::now();
        std::vector<gpart::GraphTypes::VertexT> partition(result.device_partition.size());
        thrust::copy(result.device_partition.begin(), result.device_partition.end(), partition.begin());
        const auto final_d2h_end = std::chrono::steady_clock::now();

        const auto output_start = std::chrono::steady_clock::now();
        std::ofstream output(argv[4], std::ios::binary | std::ios::trunc);
        if (!output) throw std::runtime_error("cannot open partition output");
        output.write(
            reinterpret_cast<const char*>(partition.data()),
            static_cast<std::streamsize>(
                partition.size() * sizeof(gpart::GraphTypes::VertexT)));
        output.close();
        if (!output) throw std::runtime_error("cannot write partition output");
        const auto output_end = std::chrono::steady_clock::now();
        const double input_seconds = std::chrono::duration<double>(
            load_end - load_start).count();
        const double coarsen_seconds = std::chrono::duration<double>(
            coarsen_end - coarsen_start).count();
        const double initial_seconds = std::chrono::duration<double>(
            initial_end - initial_start).count();
        const double uncoarsen_seconds = std::chrono::duration<double>(
            uncoarsen_end - uncoarsen_start).count();
        const double output_seconds = std::chrono::duration<double>(
            output_end - output_start).count();
        const double algorithm_seconds =
            std::chrono::duration<double>(free_end - coarsen_start).count();
        // Jet-aligned total includes stage logging and hierarchy cleanup, but
        // excludes input preparation, final partition download and file I/O.
        std::cout << std::setprecision(10)
                  << "partition_timing input_load_seconds=" << input_seconds
                  << " coarsen_seconds=" << coarsen_seconds
                  << " initial_partition_seconds=" << initial_seconds
                  << " uncoarsen_seconds=" << uncoarsen_seconds
                  << " input_prepare_seconds=" << std::chrono::duration<double>(coarsen_start - prepare_start).count()
                  << " hierarchy_free_seconds=" << std::chrono::duration<double>(free_end - uncoarsen_end).count()
                  << " final_partition_d2h_seconds=" << std::chrono::duration<double>(final_d2h_end - free_end).count()
                  << " timing_scope=jet_device_input_to_device_partition"
                  << " partition_output_seconds=" << output_seconds
                  << " partition_total_seconds=" << algorithm_seconds
                  << " algorithm_total_seconds=" << algorithm_seconds
                  << " wall_total_seconds="
                  << std::chrono::duration<double>(output_end - wall_start).count()
                  << '\n';
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "gpart_partition: " << error.what() << '\n';
        return 1;
    }
}
