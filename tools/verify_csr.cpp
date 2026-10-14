// Independent, CPU-only oracle for unweighted symmetric int64 disk CSR.
#include <algorithm>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

template<class T> class Mapping {
    int fd_=-1;
    std::size_t bytes_=0;
    const T* data_=nullptr;
public:
    explicit Mapping(const char* path) {
        fd_=open(path,O_RDONLY);
        struct stat st{};
        if (fd_<0 || fstat(fd_,&st) || st.st_size<0 || st.st_size%sizeof(T))
            throw std::runtime_error("invalid input file");
        bytes_=static_cast<std::size_t>(st.st_size);
        if (bytes_) {
            auto* p=mmap(nullptr,bytes_,PROT_READ,MAP_PRIVATE,fd_,0);
            if (p==MAP_FAILED) throw std::runtime_error("cannot map input");
            data_=static_cast<const T*>(p);
        }
    }
    ~Mapping() { if (bytes_ && data_) munmap(const_cast<T*>(data_),bytes_);if(fd_>=0)close(fd_); }
    const T* data() const { return data_; }
    std::size_t size() const { return bytes_/sizeof(T); }
    const T& operator[](std::size_t i) const { return data_[i]; }
};

int main(int argc,char** argv) {
    try {
        if (argc<6 || argc>7) throw std::runtime_error("usage: indptr indices k partition binary|text [--symmetric]");
        const int k=std::stoi(argv[3]);
        if (k<2 || k>32) throw std::runtime_error("invalid k");
        const bool symmetry=argc==7;
        if (symmetry && std::string(argv[6])!="--symmetric") throw std::runtime_error("invalid flag");
        Mapping<std::int64_t> offsets(argv[1]),indices(argv[2]);
        if (!offsets.size() || offsets[0]!=0 || offsets[offsets.size()-1]!=static_cast<std::int64_t>(indices.size()))
            throw std::runtime_error("invalid CSR endpoints");
        const auto n=static_cast<std::int64_t>(offsets.size()-1);
        for (std::int64_t v=0;v<n;++v)
            if (offsets[v]<0 || offsets[v]>offsets[v+1]) throw std::runtime_error("nonmonotone offsets");
        std::vector<std::int32_t> labels;
        labels.reserve(n);
        if (std::string(argv[5])=="binary") {
            Mapping<std::int32_t> part(argv[4]);
            if (part.size()!=static_cast<std::size_t>(n)) throw std::runtime_error("partition length mismatch");
            if (n) labels.assign(part.data(),part.data()+n);
        } else if (std::string(argv[5])=="text") {
            std::ifstream in(argv[4]);std::int64_t label;
            if (!in) throw std::runtime_error("cannot read partition");
            while (in>>label) {
                if(label<0 || label>=k) throw std::runtime_error("invalid label");
                labels.push_back(static_cast<std::int32_t>(label));
            }
            if (!in.eof() || labels.size()!=static_cast<std::size_t>(n)) throw std::runtime_error("invalid text partition");
        } else throw std::runtime_error("invalid partition format");
        std::vector<std::uint64_t> loads(k,0);
        for (auto label:labels) {
            if(label<0 || label>=k) throw std::runtime_error("invalid label");
            ++loads[label];
        }
        std::uint64_t cut=0,nonloop=0;int invalid=0,unsorted=0;
        #pragma omp parallel for reduction(+:cut,nonloop) reduction(|:invalid,unsorted) schedule(dynamic,256)
        for (std::int64_t v=0;v<n;++v) {
            for(auto e=offsets[v];e<offsets[v+1];++e) {
                const auto u=indices[e];
                if (u<0 || u>=n) { invalid=1;continue; }
                nonloop+=u!=v;cut+=labels[v]!=labels[u];
                if (e>offsets[v] && indices[e-1]>u) unsorted=1;
            }
        }
        if(invalid) throw std::runtime_error("invalid neighbor id");
        if(symmetry) {
            if(unsorted) throw std::runtime_error("symmetry check requires sorted rows");
            #pragma omp parallel for reduction(|:invalid) schedule(dynamic,64)
            for(std::int64_t v=0;v<n;++v) {
                for(auto e=offsets[v];e<offsets[v+1];) {
                    auto u=indices[e];auto end=e+1;
                    while(end<offsets[v+1] && indices[end]==u) ++end;
                    if(u!=v) {
                        const auto reverse=std::equal_range(indices.data()+offsets[u],indices.data()+offsets[u+1],v);
                        if(reverse.second-reverse.first!=end-e)invalid=1;
                    }
                    e=end;
                }
            }
            if(invalid) throw std::runtime_error("asymmetric edge multiplicity");
        }
        if(cut%2 || nonloop%2) throw std::runtime_error("odd undirected edge/cut count");
        cut/=2;nonloop/=2;
        const auto capacity=static_cast<std::uint64_t>(n)*103/(100*k);
        const auto maximum=*std::max_element(loads.begin(),loads.end());
        std::cout.precision(17);
        std::cout<<"{\"vertices\":"<<n<<",\"undirected_edges\":"<<nonloop<<",\"cut\":"<<cut
                 <<",\"cut_ratio\":"<<(nonloop ? static_cast<double>(cut)/nonloop : 0)
                 <<",\"loads\":[";
        for(int p=0;p<k;++p)std::cout<<(p ? "," : "")<<loads[p];
        std::cout<<"],\"max_load\":"<<maximum<<",\"max_load_ratio\":"<<(n ? static_cast<double>(maximum)*k/n : 0)
                 <<",\"capacity\":"<<capacity<<",\"capacity_ok\":"<<(maximum<=capacity ? "true" : "false")<<"}\n";
        return maximum<=capacity ? 0 : 1;
    } catch(const std::exception& e) { std::cerr<<e.what()<<'\n';return 2; }
}
