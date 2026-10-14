#include "initial_partition.hpp"
#include "check.hpp"
#include "partition_capacity.hpp"

#include <thrust/extrema.h>
#include <thrust/gather.h>
#include <thrust/reduce.h>
#include <thrust/scan.h>
#include <thrust/sequence.h>
#include <thrust/sort.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <vector>

namespace gpart {
namespace {
using U64 = unsigned long long;
template <typename T> T* ptr(thrust::device_vector<T>& v) {
    return thrust::raw_pointer_cast(v.data());
}
template <typename T> const T* ptr(const thrust::device_vector<T>& v) {
    return thrust::raw_pointer_cast(v.data());
}

struct CheckedSum {
    __host__ __device__ U64 operator()(U64 a, U64 b) const {
        return ~U64{0} - a < b ? ~U64{0} : a + b;
    }
};
__device__ unsigned hash(unsigned x) {
    x ^= x >> 16; x *= 0x7feb352dU;
    x ^= x >> 15; x *= 0x846ca68bU; return x ^ (x >> 16);
}

struct Moments { double mass, sum, squares, cross; };
struct Normalization { double mean, scale, previous_mean, previous_scale, momentum; };
struct SplitTask {
    int begin=0,count=0,first_part=0,parts=0,block_begin=0,block_count=0;
    U64 weight=0;
};
struct SpectralBlock { int group, local_block; };

__device__ Moments warp_sum(Moments m) {
    for (int s = 16; s; s /= 2) {
        m.mass += __shfl_down_sync(0xffffffffU, m.mass, s);
        m.sum += __shfl_down_sync(0xffffffffU, m.sum, s);
        m.squares += __shfl_down_sync(0xffffffffU, m.squares, s);
        m.cross += __shfl_down_sync(0xffffffffU, m.cross, s);
    }
    return m;
}

// All 256 threads participate, including the padding in the last block.
// A fixed reduction tree makes repeated runs independent of scheduling.
__device__ Moments block_sum(Moments m, Moments* shared) {
    int lane = threadIdx.x & 31, warp = threadIdx.x / 32;
    m = warp_sum(m);
    if (!lane) shared[warp] = m;
    __syncthreads();
    m = threadIdx.x < 8 ? shared[lane] : Moments{0, 0, 0};
    if (!warp) m = warp_sum(m);
    return m;
}

// Each group retains the same per-block and final reduction tree as a single
// recursive task. Siblings share launches but never share numeric reductions.
__global__ void finish_moments(const SplitTask* tasks,const Moments* partials,
    Normalization* norm,int iteration) {
    const auto task=tasks[blockIdx.x];
    if (task.parts<=1) return;
    __shared__ Moments shared[8];
    Moments m{0,0,0};
    for (int i=threadIdx.x;i<task.block_count;i+=blockDim.x) {
        const auto value=partials[task.block_begin+i];
        m.mass+=value.mass;m.sum+=value.sum;m.squares+=value.squares;m.cross+=value.cross;
    }
    m=block_sum(m,shared);
    if (!threadIdx.x) {
        const double mean=m.sum/m.mass;
        const double variance=fmax(0.0,m.squares/m.mass-mean*mean);
        const auto previous=norm[blockIdx.x];
        const double rayleigh=fmax(0.0,fmin(1.0,m.cross/m.mass));
        // Estimate and freeze the polynomial filter strength after the same
        // warmup in each child; this is delayed momentum power iteration.
        const double momentum=iteration<0 ? 0.0 :
            (iteration==15 ? 0.25*rayleigh*rayleigh : previous.momentum);
        norm[blockIdx.x]={mean,variance>1e-30 ? 1.0/sqrt(variance) : 1.0,
            previous.mean,previous.scale,momentum};
    }
}

template <typename O,typename W>
__global__ void spectral_start(const SplitTask* tasks,const SpectralBlock* blocks,
    const int* order,const int* labels,const O* offsets,const int* neighbors,
    const W* weights,double* degree,double* x,unsigned seed,Moments* partials) {
    __shared__ Moments shared[8];
    const auto work=blocks[blockIdx.x];
    const auto task=tasks[work.group];
    const int lane=threadIdx.x&31,i=work.local_block*8+threadIdx.x/32;
    double d=0;
    if (i<task.count) {
        const int v=order[task.begin+i];
        for (std::int64_t e=static_cast<std::int64_t>(offsets[v])+lane;e<offsets[v+1];e+=32)
            if (labels[neighbors[e]]==work.group) d+=static_cast<double>(weights[e]);
    }
    for (int shift=16;shift;shift/=2) d+=__shfl_down_sync(0xffffffffU,d,shift);
    Moments m{0,0,0};
    if (!lane && i<task.count) {
        const int v=order[task.begin+i];
        const double a=static_cast<double>(hash(v^(seed^static_cast<unsigned>(work.group))))/4294967296.0-0.5;
        degree[v]=d;x[v]=a;
        const double mass=d>0 ? d : 1.0;
        m={mass,mass*a,mass*a*a};
    }
    m=block_sum(m,shared);
    if (!threadIdx.x) partials[blockIdx.x]=m;
}

template <typename O,typename W>
__global__ void spectral_step(const SplitTask* tasks,const SpectralBlock* blocks,
    const int* order,const int* labels,const O* offsets,const int* neighbors,
    const W* weights,const double* degree,const double* x,double* y,
    const Normalization* norm,Moments* partials) {
    __shared__ Moments shared[8];
    const auto work=blocks[blockIdx.x];
    const auto task=tasks[work.group];
    const auto normalization=norm[work.group];
    const int lane=threadIdx.x&31,i=work.local_block*8+threadIdx.x/32;
    double sum=0;
    if (i<task.count) {
        const int v=order[task.begin+i];
        for (std::int64_t e=static_cast<std::int64_t>(offsets[v])+lane;e<offsets[v+1];e+=32) {
            const int u=neighbors[e];
            if (labels[u]==work.group) {
                const double value=(x[u]-normalization.mean)*normalization.scale;
                sum+=static_cast<double>(weights[e])*value;
            }
        }
    }
    for (int shift=16;shift;shift/=2) sum+=__shfl_down_sync(0xffffffffU,sum,shift);
    Moments m{0,0,0};
    if (!lane && i<task.count) {
        const int v=order[task.begin+i];
        const double current=(x[v]-normalization.mean)*normalization.scale;
        const double d=degree[v],diffused=d>0 ? 0.5*(current+sum/d) : current;
        const double previous=(y[v]-normalization.previous_mean)*normalization.previous_scale;
        const double a=diffused-normalization.momentum*normalization.scale*previous;
        y[v]=a;
        const double mass=d>0 ? d : 1.0;
        m={mass,mass*a,mass*a*a,mass*current*diffused};
    }
    m=block_sum(m,shared);
    if (!threadIdx.x) partials[blockIdx.x]=m;
}

__global__ void normalize_final(int n,const int* labels,const SplitTask* tasks,
    double* x,const Normalization* norm) {
    const int v=blockIdx.x*blockDim.x+threadIdx.x;
    if (v<n && tasks[labels[v]].parts>1) {
        const auto value=norm[labels[v]];
        x[v]=(x[v]-value.mean)*value.scale;
    }
}
struct SpectralOrder {
    const int* labels;
    const double* x;
    __device__ bool operator()(int a,int b) const {
        if (labels[a]!=labels[b]) return labels[a]<labels[b];
        return x[a]<x[b] || (x[a]==x[b] && a<b);
    }
};

// Global weight prefixes are rebased per group. GPU search uses exact integer
// ratios, including odd k, and preserves the previous nearest-weight boundary.
__global__ void split_tasks(const SplitTask* tasks,SplitTask* next,
    const int* order,const U64* prefix,U64 capacity,int* labels,int* error) {
    const auto task=tasks[blockIdx.x];
    if (task.parts<=1) return;
    __shared__ int boundary;
    if (!threadIdx.x) {
        const int left_parts=task.parts/2,right_parts=task.parts-left_parts;
        const U64 target=(task.weight/task.parts)*left_parts+
            ((task.weight%task.parts)*left_parts)/task.parts;
        const U64 base=task.begin ? prefix[task.begin-1] : 0;
        int low=0,high=task.count;
        while (low<high) {
            const int middle=low+(high-low)/2;
            if (prefix[task.begin+middle]-base<target) low=middle+1;
            else high=middle;
        }
        boundary=max(left_parts,min(task.count-right_parts,low+1));
        U64 left_weight=prefix[task.begin+boundary-1]-base;
        const U64 left_limit=capacity>task.weight/left_parts ? task.weight : capacity*left_parts;
        const U64 right_limit=capacity>task.weight/right_parts ? task.weight : capacity*right_parts;
        const U64 min_left=task.weight>right_limit ? task.weight-right_limit : 0;
        if (left_weight>left_limit && boundary>left_parts) --boundary;
        left_weight=prefix[task.begin+boundary-1]-base;
        if (left_weight<min_left && boundary<task.count-right_parts) ++boundary;
        left_weight=prefix[task.begin+boundary-1]-base;
        if (left_weight>left_limit || left_weight<min_left) {
            atomicExch(error,1);boundary=-1;
        } else {
            next[task.first_part]={task.begin,boundary,task.first_part,left_parts,0,0,left_weight};
            next[task.first_part+left_parts]={task.begin+boundary,task.count-boundary,
                task.first_part+left_parts,right_parts,0,0,task.weight-left_weight};
        }
    }
    __syncthreads();
    if (boundary<0) return;
    for (int i=threadIdx.x;i<task.count;i+=blockDim.x)
        labels[order[task.begin+i]]=task.first_part+(i<boundary ? 0 : task.parts/2);
}
template <typename O, typename W>
__global__ void cut_terms(int n, const O* offsets, const int* neighbors,
    const W* weights, const int* labels, U64* terms) {
    int v = blockIdx.x * blockDim.x + threadIdx.x;
    if (v >= n) return;
    U64 sum = 0;
    for (O e = offsets[v]; e < offsets[v + 1]; ++e)
        if (labels[v] != labels[neighbors[e]]) sum += weights[e];
    terms[v] = sum;
}
__global__ void part_weights(int n, const int* labels, const U64* weights, U64* loads) {
    int v = blockIdx.x * blockDim.x + threadIdx.x;
    if (v < n) atomicAdd(loads + labels[v], weights[v]);
}
} // namespace

template <typename Types>
thrust::device_vector<typename Types::VertexT> initial_partition_gpu(
    const DeviceWeightedGraph<Types>& graph, int parts, double imbalance,
    std::uint32_t seed) {
    const auto start = std::chrono::steady_clock::now();
    const auto n64 = graph.vertices();
    if (n64 <= 0 || n64 > std::numeric_limits<int>::max() - 255 || parts < 2 ||
        parts > n64 || parts > 32 ||
        !std::isfinite(imbalance) || imbalance < 1.0)
        throw std::invalid_argument("invalid GPU initial partition input");
    int n = static_cast<int>(n64);
    const U64 total = thrust::reduce(graph.vertex_weights.begin(),
        graph.vertex_weights.end(), U64{0}, CheckedSum{});
    const U64 edge_total = thrust::reduce(graph.edge_weights.begin(),
        graph.edge_weights.end(), U64{0}, CheckedSum{});
    if (!total || total == ~U64{0} || edge_total == ~U64{0})
        throw std::overflow_error("GPU initializer weight accumulation overflow");
    const U64 capacity = partition_capacity(total, parts, imbalance);
    auto max_weight = *thrust::max_element(graph.vertex_weights.begin(), graph.vertex_weights.end());
    if (static_cast<U64>(max_weight) > capacity)
        throw std::invalid_argument("a vertex exceeds partition capacity");

    thrust::device_vector<int> labels(n, 0), order(n);
    thrust::sequence(order.begin(), order.end());
    thrust::device_vector<double> degree(n), x(n), y(n);
    thrust::device_vector<Moments> partials((n+7)/8+parts);
    thrust::device_vector<Normalization> norm(parts);
    thrust::device_vector<U64> ordered_weights(n),prefix(n),vertex_weights(graph.vertex_weights);
    thrust::device_vector<SplitTask> tasks(parts),next_tasks(parts);
    thrust::device_vector<SpectralBlock> blocks((n+7)/8+parts);
    thrust::device_vector<int> error(1,0);
    std::vector<SplitTask> host_tasks(parts);
    host_tasks[0]={0,n,0,parts,0,0,total};
    int depth=0;
    for (;;) {
        std::vector<SpectralBlock> host_blocks;
        for (auto& task:host_tasks) {
            if (task.parts<=1) continue;
            task.block_begin=static_cast<int>(host_blocks.size());
            task.block_count=(task.count+7)/8;
            for (int block=0;block<task.block_count;++block)
                host_blocks.push_back({task.first_part,block});
        }
        if (host_blocks.empty()) break;
        CUDA_CHECK(cudaMemcpy(ptr(tasks),host_tasks.data(),parts*sizeof(SplitTask),cudaMemcpyHostToDevice));
        CUDA_CHECK(cudaMemcpy(ptr(blocks),host_blocks.data(),host_blocks.size()*sizeof(SpectralBlock),cudaMemcpyHostToDevice));
        const int work_blocks=static_cast<int>(host_blocks.size());
        spectral_start<<<work_blocks,256>>>(ptr(tasks),ptr(blocks),ptr(order),ptr(labels),
            ptr(graph.offsets),ptr(graph.neighbors),ptr(graph.edge_weights),ptr(degree),ptr(x),seed,ptr(partials));
        CUDA_CHECK(cudaGetLastError());
        finish_moments<<<parts,256>>>(ptr(tasks),ptr(partials),ptr(norm),-1);
        CUDA_CHECK(cudaGetLastError());
        // Sibling tasks share 64 rounds: 16 lazy diffusion steps estimate the
        // Rayleigh quotient, then 48 use a fixed momentum coefficient.
        // Normalization and the previous-vector scaling stay in this read.
        for (int iteration=0;iteration<64;++iteration) {
            spectral_step<<<work_blocks,256>>>(ptr(tasks),ptr(blocks),ptr(order),ptr(labels),
                ptr(graph.offsets),ptr(graph.neighbors),ptr(graph.edge_weights),ptr(degree),
                ptr(x),ptr(y),ptr(norm),ptr(partials));
            CUDA_CHECK(cudaGetLastError());
            finish_moments<<<parts,256>>>(ptr(tasks),ptr(partials),ptr(norm),iteration);
            CUDA_CHECK(cudaGetLastError());
            x.swap(y);
        }
        normalize_final<<<(n+255)/256,256>>>(n,ptr(labels),ptr(tasks),ptr(x),ptr(norm));
        CUDA_CHECK(cudaGetLastError());
        thrust::sort(order.begin(),order.end(),SpectralOrder{ptr(labels),ptr(x)});
        thrust::gather(order.begin(),order.end(),vertex_weights.begin(),ordered_weights.begin());
        thrust::inclusive_scan(ordered_weights.begin(),ordered_weights.end(),prefix.begin());
        CUDA_CHECK(cudaMemcpy(ptr(next_tasks),ptr(tasks),parts*sizeof(SplitTask),cudaMemcpyDeviceToDevice));
        split_tasks<<<parts,256>>>(ptr(tasks),ptr(next_tasks),ptr(order),ptr(prefix),capacity,ptr(labels),ptr(error));
        CUDA_CHECK(cudaGetLastError());
        CUDA_CHECK(cudaMemcpy(host_tasks.data(),ptr(next_tasks),parts*sizeof(SplitTask),cudaMemcpyDeviceToHost));
        int failed=0;
        CUDA_CHECK(cudaMemcpy(&failed,ptr(error),sizeof(failed),cudaMemcpyDeviceToHost));
        if (failed) throw std::runtime_error("GPU spectral split cannot satisfy capacity");
        ++depth;
    }
    thrust::device_vector<U64> loads(parts, 0);
    part_weights<<<(n + 255) / 256, 256>>>(n, ptr(labels), ptr(vertex_weights), ptr(loads));
    CUDA_CHECK(cudaGetLastError());
    std::vector<U64> host_loads(parts);
    CUDA_CHECK(cudaMemcpy(host_loads.data(), ptr(loads), parts * sizeof(U64), cudaMemcpyDeviceToHost));
    if (*std::max_element(host_loads.begin(), host_loads.end()) > capacity)
        throw std::runtime_error("GPU initializer balance validation failed");
    cut_terms<<<(n + 255) / 256, 256>>>(n, ptr(graph.offsets), ptr(graph.neighbors),
        ptr(graph.edge_weights), ptr(labels), ptr(prefix));
    CUDA_CHECK(cudaGetLastError());
    U64 cut = thrust::reduce(prefix.begin(), prefix.end(), U64{0}) / 2;
    CUDA_CHECK(cudaDeviceSynchronize());
    std::cout << "initial_partition_backend=gpu_spectral_momentum\n"
        << "coarsest_vertices=" << n << '\n'
        << "coarsest_edge_entries=" << graph.edges() << '\n'
        << "initial_partition_parts=" << parts << '\n'
        << "initial_partition_depths=" << depth << '\n'
        << "initial_partition_edgecut=" << cut << '\n'
        << "initial_partition_seconds=" << std::chrono::duration<double>(
            std::chrono::steady_clock::now() - start).count() << '\n';
    return labels;
}

template thrust::device_vector<ActiveTypes::VertexT> initial_partition_gpu<ActiveTypes>(
    const DeviceWeightedGraph<ActiveTypes>&, int, double, std::uint32_t);
} // namespace gpart
