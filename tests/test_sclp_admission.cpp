#include "detail/sclp_admission.hpp"
#include <algorithm>
#include <cstdint>
#include <iostream>
#include <numeric>
#include <random>
#include <stdexcept>
#include <tuple>
#include <vector>

template <typename T> void check() {
    using Key=gpart::detail::SclpAdmissionKey<T>;
    struct Proposal { std::uint32_t target,tie; T gain; };
    std::mt19937_64 rng(1729);
    for (int bits=1;bits<=Key::word_bits;++bits) {
        const T mask=bits==Key::word_bits ? std::numeric_limits<T>::max() : (T{1}<<bits)-1;
        std::vector<Proposal> proposals;
        std::vector<Key> keys;
        for (int i=0;i<2048;++i) {
            Proposal p{static_cast<std::uint32_t>(rng()%2147483647),static_cast<std::uint32_t>(rng()),static_cast<T>(rng())&mask};
            if (i%7==0) p.gain=mask;
            if (i%11==0) p.gain=0;
            if (i%5==0 && i) p=proposals.back();
            proposals.push_back(p);
            auto key=Key::encode(p.target,p.gain,p.tie,i,bits);
            if (key.decode_target(bits)!=p.target) throw std::runtime_error("target roundtrip");
            if (bits==Key::word_bits && (key.target!=p.target || key.reverse_gain!=static_cast<T>(~p.gain) || key.reverse_tie!=~p.tie))
                throw std::runtime_error("full legacy layout changed");
            keys.push_back(key);
        }
        std::vector<int> reference(keys.size()),actual(keys.size());
        std::iota(reference.begin(),reference.end(),0);actual=reference;
        std::stable_sort(reference.begin(),reference.end(),[&](int a,int b) {
            const auto x=proposals[a],y=proposals[b];
            if(x.target!=y.target) return x.target<y.target;
            if(x.gain!=y.gain) return x.gain>y.gain;
            return x.tie>y.tie;
        });
        std::stable_sort(actual.begin(),actual.end(),[&](int a,int b) {
            return std::tie(keys[a].target,keys[a].reverse_gain,keys[a].reverse_tie)<
                std::tie(keys[b].target,keys[b].reverse_gain,keys[b].reverse_tie);
        });
        if(actual!=reference) throw std::runtime_error("complete priority or stable ties changed");
    }
}
int main() {
    try { check<std::uint32_t>();check<std::uint64_t>();std::cout<<"sclp_admission_ok=1 full_width=1 stable_ties=1\n"; }
    catch(const std::exception& e) { std::cerr<<e.what()<<'\n';return 1; }
}
