#pragma once

#include "check.hpp"
#include <cuda_runtime_api.h>
#include <thrust/device_allocator.h>
#include <thrust/device_vector.h>
#include <thrust/system/cuda/execution_policy.h>
#include <cstdint>
#include <limits>
#include <memory>
#include <map>
#include <mutex>
#include <vector>
#include <type_traits>
#include <utility>

namespace gpart::detail {

// Default-stream arena. Returning a range only changes host metadata; its
// next user is enqueued after its previous user. Non-default graph streams
// explicitly wait for the default stream and join before returning.
struct ScratchPoolState {
    static constexpr std::size_t alignment = 256;
    static constexpr std::size_t chunk_granularity = 2ULL << 20;
    struct Chunk {
        void* base = nullptr;
        std::size_t bytes = 0, live = 0;
        std::map<std::size_t,std::size_t> free; // offset -> length
    };
    std::vector<std::unique_ptr<Chunk>> chunks;
    std::mutex mutex;
    static std::size_t round_up(std::size_t bytes, std::size_t unit) {
        if (bytes > std::numeric_limits<std::size_t>::max()-(unit-1))
            throw std::bad_array_new_length();
        return (bytes+unit-1)/unit*unit;
    }
    void* allocate(std::size_t bytes) {
        if (!bytes) return nullptr;
        bytes=round_up(bytes,alignment);
        std::lock_guard<std::mutex> lock(mutex);
        Chunk* best=nullptr;
        std::size_t offset=0, available=std::numeric_limits<std::size_t>::max();
        for (auto& chunk:chunks) for (auto [start,length]:chunk->free)
            if (length>=bytes && length<available) {
                best=chunk.get();offset=start;available=length;
            }
        if (!best) {
            auto chunk=std::make_unique<Chunk>();
            chunk->bytes=round_up(bytes,chunk_granularity);
            chunk->free.emplace(0,chunk->bytes);
            // Reserve host metadata before acquiring device memory.
            chunks.reserve(chunks.size()+1);
            CUDA_CHECK(cudaMalloc(&chunk->base,chunk->bytes));
            best=chunk.get();available=chunk->bytes;
            chunks.push_back(std::move(chunk));
        }
        // Reuse the map node to avoid a host allocation when splitting.
        auto range=best->free.extract(offset);
        if (available>bytes) {
            range.key()=offset+bytes;range.mapped()=available-bytes;
            best->free.insert(std::move(range));
        }
        best->live+=bytes;
        return static_cast<std::uint8_t*>(best->base)+offset;
    }
    void deallocate(void* allocation, std::size_t bytes) {
        if (!allocation) return;
        bytes=round_up(bytes,alignment);
        std::lock_guard<std::mutex> lock(mutex);
        const auto address=reinterpret_cast<std::uintptr_t>(allocation);
        for (auto& chunk:chunks) {
            const auto base=reinterpret_cast<std::uintptr_t>(chunk->base);
            if (address<base || address-base>=chunk->bytes) continue;
            const auto offset=static_cast<std::size_t>(address-base);
            if (bytes>chunk->bytes-offset || bytes>chunk->live)
                throw std::logic_error("invalid scratch arena range");
            auto next=chunk->free.lower_bound(offset);
            if ((next!=chunk->free.end() && offset+bytes>next->first) ||
                (next!=chunk->free.begin() && std::prev(next)->first+std::prev(next)->second>offset))
                throw std::logic_error("overlapping scratch arena free");
            auto current=chunk->free.emplace_hint(next,offset,bytes);
            if (next!=chunk->free.end() && current->first+current->second==next->first) {
                current->second+=next->second;chunk->free.erase(next);
            }
            if (current!=chunk->free.begin()) {
                auto previous=std::prev(current);
                if (previous->first+previous->second==current->first) {
                    previous->second+=current->second;chunk->free.erase(current);
                }
            }
            chunk->live-=bytes;
            return;
        }
        throw std::logic_error("scratch allocation belongs to another arena");
    }
    // Called after synchronization; retained vectors keep live chunks valid.
    void release_unused() {
        std::lock_guard<std::mutex> lock(mutex);
        for (auto it=chunks.begin();it!=chunks.end();) {
            if ((*it)->live) {++it;continue;}
            CUDA_CHECK(cudaFree((*it)->base));
            it=chunks.erase(it);
        }
    }
    ~ScratchPoolState() {
        // cudaFree also waits for pending uses when a session unwinds early.
        for (auto& chunk:chunks) cudaFree(chunk->base);
    }
};

inline thread_local std::shared_ptr<ScratchPoolState> active_scratch_pool;

// Explicit pipeline lifetime; never preallocate or warm memory before timing.
// Allocators keep the pool alive if a scratch vector outlives the session.
class ScratchPoolSession {
    std::shared_ptr<ScratchPoolState> previous_ = active_scratch_pool;
    std::shared_ptr<ScratchPoolState> state_ = std::make_shared<ScratchPoolState>();
public:
    ScratchPoolSession() { active_scratch_pool = state_; }
    ScratchPoolSession(const ScratchPoolSession&) = delete;
    ScratchPoolSession& operator=(const ScratchPoolSession&) = delete;
    ~ScratchPoolSession() { if (state_) active_scratch_pool = previous_; }
    void finish() {
        if (!state_) return;
        CUDA_CHECK(cudaDeviceSynchronize());
        state_->release_unused();
        active_scratch_pool = previous_;
        state_.reset();
    }
};

template <typename T>
class ScratchAllocator : public thrust::device_allocator<T> {
    template <typename> friend class ScratchAllocator;
    std::shared_ptr<ScratchPoolState> state_ = active_scratch_pool;
public:
    using Base = thrust::device_allocator<T>;
    using pointer = typename Base::pointer;
    using is_always_equal = std::false_type;
    using propagate_on_container_move_assignment = std::true_type;
    using propagate_on_container_swap = std::true_type;
    template <typename U> struct rebind { using other = ScratchAllocator<U>; };
    __host__ ScratchAllocator() {}
    __host__ ScratchAllocator(const ScratchAllocator& other) : Base(other), state_(other.state_) {}
    __host__ ScratchAllocator(ScratchAllocator&& other) noexcept
        : Base(other), state_(std::move(other.state_)) {}
    __host__ ScratchAllocator& operator=(const ScratchAllocator& other) {
        state_ = other.state_; return *this;
    }
    __host__ ScratchAllocator& operator=(ScratchAllocator&& other) noexcept {
        state_ = std::move(other.state_); return *this;
    }
    __host__ ~ScratchAllocator() {}
    template <typename U>
    __host__ ScratchAllocator(const ScratchAllocator<U>& other) : state_(other.state_) {}
    pointer allocate(std::size_t count) {
        if (count > std::numeric_limits<std::size_t>::max() / sizeof(T))
            throw std::bad_array_new_length();
        if (!state_) return Base::allocate(count);
        return pointer(static_cast<T*>(state_->allocate(count*sizeof(T))));
    }
    void deallocate(pointer allocation, std::size_t count) {
        if (!state_) { Base::deallocate(allocation,count);return; }
        state_->deallocate(thrust::raw_pointer_cast(allocation),count*sizeof(T));
    }
    template <typename U> bool operator==(const ScratchAllocator<U>& other) const {
        return state_ == other.state_;
    }
    template <typename U> bool operator!=(const ScratchAllocator<U>& other) const {
        return !(*this == other);
    }
};

template <typename T>
using ScratchVector = thrust::device_vector<T, ScratchAllocator<T>>;

// Thrust's internal sort/scan/reduction buffers share the pipeline pool too.
// The policy owns its allocator, so it remains valid for the whole call.
inline auto scratch_policy() {
    // Algorithms returning host values still perform their required sync;
    // device-only sorts/scans can feed the next default-stream kernel directly.
    return thrust::cuda::par_nosync(ScratchAllocator<std::uint8_t>{});
}

} // namespace gpart::detail
