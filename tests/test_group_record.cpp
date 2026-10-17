#include "detail/group_record.hpp"
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <limits>
#include <numeric>
#include <random>
#include <stdexcept>
#include <tuple>
#include <vector>

using gpart::detail::GroupSortLayout;
using gpart::detail::GroupSortRecord;
struct Group {
    int pair;
    std::uint64_t weight;
    std::int64_t gain;
    std::array<std::int32_t, 4> vertices;
};
int main() {
    try {
        std::mt19937_64 random(83);
        for (int n : {1, 31, 256, 65536}) for (int k : {2, 4, 32, 128})
            for (bool wide : {false, true}) {
                std::vector<Group> groups(2048);
                std::uint64_t max_weight=0,max_gain=0;
                for (int i=0;i<static_cast<int>(groups.size());++i) {
                    auto& g=groups[i];g.pair=random()%(k*k);
                    g.weight=wide ? random() : random()%512;
                    const auto raw=random();
                    if (wide) std::memcpy(&g.gain,&raw,sizeof(raw));
                    else g.gain=static_cast<std::int64_t>(random()%2049)-1024;
                    if (wide && i==0) { g.gain=std::numeric_limits<std::int64_t>::min();g.weight=UINT64_MAX; }
                    if (wide && i==1) g.gain=std::numeric_limits<std::int64_t>::max();
                    const int size=1+random()%4;
                    for (int j=0;j<4;++j) g.vertices[j]=j<size ? random()%n : -1;
                    std::sort(g.vertices.begin(),g.vertices.begin()+size);
                    if (i && i%7==0) g=groups[i-1];
                    max_weight=std::max(max_weight,g.weight);
                    max_gain=std::max(max_gain,GroupSortLayout::magnitude(g.gain));
                }
                const auto layout=GroupSortLayout::bounded(n,k,max_weight,max_gain);
                const GroupSortLayout full{17,64,64,GroupSortLayout::bits(k*k-1)};
                std::vector<GroupSortRecord> keys;
                for (int i=0;i<static_cast<int>(groups.size());++i) {
                    const auto& g=groups[i];
                    keys.push_back(layout.encode(g.pair,g.weight,g.gain,g.vertices.data(),i));
                    const auto f=full.encode(g.pair,g.weight,g.gain,g.vertices.data(),i);
                    const auto v0=static_cast<std::uint64_t>(g.vertices[0]+1);
                    const auto v1=static_cast<std::uint64_t>(g.vertices[1]+1);
                    const auto v2=static_cast<std::uint64_t>(g.vertices[2]+1);
                    const auto v3=static_cast<std::uint64_t>(g.vertices[3]+1);
                    const auto reverse=~static_cast<std::uint64_t>(g.gain)^(1ULL<<63);
                    if (f.a!=((v0<<51)|(v1<<34)|(v2<<17)|v3) ||
                        f.b!=((reverse<<4)|(v0>>13)) || f.c!=((g.weight<<4)|(reverse>>60)) ||
                        f.d!=((static_cast<std::uint64_t>(g.pair)<<4)|(g.weight>>60)))
                        throw std::runtime_error("Full encoding differs from original bit layout");
                }
                std::vector<int> expected(groups.size()),actual(groups.size());
                std::iota(expected.begin(),expected.end(),0);actual=expected;
                std::sort(expected.begin(),expected.end(),[&](int a,int b) {
                    const auto& x=groups[a];const auto& y=groups[b];
                    if(x.pair!=y.pair)return x.pair<y.pair;
                    if(x.weight!=y.weight)return x.weight<y.weight;
                    if(x.gain!=y.gain)return x.gain>y.gain;
                    if(x.vertices!=y.vertices)return x.vertices<y.vertices;
                    return a<b;
                });
                std::stable_sort(actual.begin(),actual.end(),[&](int a,int b) {
                    const auto& x=keys[a];const auto& y=keys[b];
                    return std::tie(x.d,x.c,x.b,x.a)<std::tie(y.d,y.c,y.b,y.a);
                });
                if(actual!=expected)throw std::runtime_error("Packed key changed complete comparator order");
            }
        std::cout << "group_record_ok=1 full64=1 signed_extremes=1 stable_ties=1\n";
    } catch(const std::exception& e) { std::cerr<<e.what()<<'\n';return 1; }
}
