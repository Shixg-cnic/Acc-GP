#pragma once
// Exact destination selection on frozen loads. Included after AffinityView.
// This changes query work, not destination priorities or zero-affinity routing.
struct RepairDestination {
    int part=-1;
    std::uint64_t connection=0,current=0;
};
template<class C>
__device__ RepairDestination enumerate_repair_destination(
    std::int64_t v,int source,std::uint64_t weight,int k,
    const unsigned long long* loads,std::uint64_t capacity,
    AffinityView<C> cache,std::uint32_t hash) {
    RepairDestination result;
    result.current=cache.get(v,source);
    std::uint64_t best_slack=0;
    // Nonnegative edge weights: equality proves every external affinity is zero.
    if (!cache.row_totals || result.current!=cache.row_totals[v]) {
        if(!cache.sparse() && !cache.direct()) {
            // Preserve the simple ascending-ID dense scan for boundary rows.
            // No per-entry key lookup or extra arbitrary-order tie comparison.
            for(int p=0;p<k;++p) {
                if(p==source || loads[p]>=capacity || weight>capacity-loads[p]) continue;
                const std::uint64_t value=cache.values[v*k+p],slack=capacity-loads[p];
                if(result.part<0 || value>result.connection ||
                   (value==result.connection && slack>best_slack)) {
                    result.part=p;result.connection=value;best_slack=slack;
                }
            }
            if(result.connection) return result;
            result.part=-1; // Zero-affinity ties use the hash rule below.
        } else {
        const int count=cache.entries(v);
        for (int i=0;i<count;++i) {
            const int p=cache.part(v,i);
            if(p==source || loads[p]>=capacity || weight>capacity-loads[p]) continue;
            const std::uint64_t value=cache.value(v,i),slack=capacity-loads[p];
            if(value && (result.part<0 || value>result.connection ||
                (value==result.connection && (slack>best_slack ||
                 (slack==best_slack && p<result.part))))) {
                result.part=p;result.connection=value;best_slack=slack;
            }
        }
        }
    }
    if(result.part>=0) return result;
    // A frozen per-batch CDF is exact when every nonempty receiver can hold
    // this vertex. Overloaded sources contribute no room to that CDF.
    if(cache.repair_slack_cdf && loads[source]>=capacity && weight<=cache.repair_slack_cdf[k]) {
        const auto total=cache.repair_slack_cdf[k-1];
        if(!total) return result;
        const auto ticket=static_cast<std::uint64_t>(hash)%total;
        int lo=0,hi=k;
        while(lo<hi) {
            const int mid=(lo+hi)/2;
            if(cache.repair_slack_cdf[mid]<=ticket) lo=mid+1;
            else hi=mid;
        }
        result.part=lo;
        return result;
    }
    // Exactly the original slack-weighted hash routing, in partition-ID order.
    std::uint64_t total=0;
    for(int p=0;p<k;++p) if(p!=source && loads[p]<capacity && weight<=capacity-loads[p]) {
        const auto slack=capacity-loads[p];
        total=UINT64_MAX-total<slack ? UINT64_MAX : total+slack;
    }
    if(!total) return result;
    auto ticket=static_cast<std::uint64_t>(hash)%total;
    for(int p=0;p<k;++p) if(p!=source && loads[p]<capacity && weight<=capacity-loads[p]) {
        const auto slack=capacity-loads[p];
        if(ticket<slack) {result.part=p;break;}
        ticket-=slack;
    }
    return result;
}

// Called with exactly one warp. Build the inclusive saturating slack CDF
// directly from loads; no cross-thread reads of a partially written array.
__global__ void initialize_receiver_slack(int k,const unsigned long long* loads,
    std::uint64_t capacity,unsigned long long* slack,unsigned long long* requests,
    unsigned long long* cdf=nullptr) {
    const int lane=threadIdx.x;
    if(!cdf) {
        for(int p=lane;p<k;p+=32) {slack[p]=loads[p]<capacity ? capacity-loads[p] : 0;requests[p]=0;}
        return;
    }
    unsigned long long carry=0,minimum=UINT64_MAX;
    for(int base=0;base<k;base+=32) {
        const int p=base+lane;
        const auto room=p<k && loads[p]<capacity ? capacity-loads[p] : 0ULL;
        if(p<k) {slack[p]=room;requests[p]=0;}
        if(room) minimum=min(minimum,room);
        unsigned long long value=room;
        for(int d=1;d<32;d*=2) {
            const auto previous=__shfl_up_sync(0xffffffffU,value,d);
            if(lane>=d) value=UINT64_MAX-value<previous ? UINT64_MAX : value+previous;
        }
        value=UINT64_MAX-carry<value ? UINT64_MAX : carry+value;
        if(p<k) cdf[p]=value;
        carry=__shfl_sync(0xffffffffU,value,31);
    }
    for(int d=16;d;d/=2) minimum=min(minimum,__shfl_down_sync(0xffffffffU,minimum,d));
    if(!lane) cdf[k]=minimum;
}
