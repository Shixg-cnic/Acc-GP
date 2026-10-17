#pragma once
#include "detail/scratch_pool.hpp"
#include <thrust/copy.h>
#include <thrust/fill.h>
#include <iterator>

namespace gpart::detail {
// Overwrite-only CUDA workspace. Growing discards old contents; resize never
// initializes new entries. Callers must write every entry they subsequently
// read. Keep ordinary ScratchVector for graph storage and initialized state.
template <typename T>
class ScratchBuffer {
    static_assert(std::is_trivially_copyable_v<T> && std::is_trivially_destructible_v<T>);
    ScratchAllocator<T> allocator_;
    typename ScratchAllocator<T>::pointer pointer_{};
    std::size_t size_=0,capacity_=0;
    void release() {
        if(capacity_) allocator_.deallocate(pointer_,capacity_);
        pointer_={};size_=capacity_=0;
    }
public:
    using value_type=T;
    ScratchBuffer()=default;
    explicit ScratchBuffer(std::size_t n) { resize(n); }
    ScratchBuffer(std::size_t n,const T& value) { assign(n,value); }
    ScratchBuffer(const ScratchBuffer&)=delete;
    ScratchBuffer& operator=(const ScratchBuffer&)=delete;
    ~ScratchBuffer() { release(); }
    ScratchBuffer(ScratchBuffer&& other) noexcept { swap(other); }
    ScratchBuffer& operator=(ScratchBuffer&& other) noexcept {
        if(this!=&other) { release();swap(other); }return *this;
    }
    void swap(ScratchBuffer& other) noexcept {
        using std::swap;swap(allocator_,other.allocator_);swap(pointer_,other.pointer_);
        swap(size_,other.size_);swap(capacity_,other.capacity_);
    }
    void reserve(std::size_t n) {
        if(n<=capacity_) return;
        const auto logical_size=size_;
        // Growth discards contents. Free first on the same stream so CUDA
        // can reuse those pool pages for the larger overwrite-only buffer.
        // Keep an empty valid object if allocation subsequently throws.
        release();
        pointer_=allocator_.allocate(n);capacity_=n;size_=logical_size;
    }
    void resize(std::size_t n) { reserve(n);size_=n; }
    std::size_t size() const { return size_; }
    std::size_t capacity() const { return capacity_; }
    auto data() { return pointer_; }
    auto data() const { return thrust::device_ptr<const T>(pointer_); }
    auto begin() { return pointer_; }
    auto begin() const { return data(); }
    auto end() { return pointer_+size_; }
    auto end() const { return data()+size_; }
    auto operator[](std::size_t i) { return pointer_[i]; }
    auto operator[](std::size_t i) const { return data()[i]; }
    void assign(std::size_t n,const T& value) {
        resize(n);thrust::fill(scratch_policy(),begin(),end(),value);
    }
    template <typename It,typename=std::enable_if_t<!std::is_integral_v<It>>>
    void assign(It first,It last) {
        resize(static_cast<std::size_t>(thrust::distance(first,last)));
        thrust::copy(scratch_policy(),first,last,begin());
    }
};
} // namespace gpart::detail
