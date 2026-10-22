# Acc-GPart

GPU多层图划分器，仓库目录名为`Acc-GP`。当前流程为稳定接收簇聚合、一次METIS初始化、GPU投影与容量互补交换细化。

- [当前算法与论文主线](ALGORITHM.md)：两个方法贡献、完整流程、容量与收益公式、GPU实现。
- [源码文件树与调用关系](docs/STRUCTURE.md)：模块边界及各文件职责。
- [已有基础与机制区别](ALGORITHM_COMPARISON.md)：与Jet、DAC G-kway的对应关系。
- [GPU执行与完整算法拆解](docs/GPU_ARCHITECTURE_ANALYSIS.md)：三方流程、依赖与访存开销、现行改进及公式。
- [实验历史](docs/EXPERIMENT_HISTORY.md)与[结果索引](results/INDEX.md)：测量版本和成功/失败记录。
- [当前任务](CONTINUATION.md)：源码验证状态、已完成实验及写作入口。

2026-10-22新增交换收益事件的warp内归约；CPU等价核对通过，尚未CUDA编译或GPU计时。已有实验表对应各自冻结版本，不包含这项新改动。

## 源码架构

```text
app/partition_main.cu             参数、主流程、原生计时
       │
       ├── src/graph.cpp          CSR读入与GPU表示
       ├── src/coarsen.cu         逐层聚合与收缩
       │     └── coarsening/     种子、单点扩展、准入、粗CSR
       ├── src/initial_partition_metis.cu
       └── src/uncoarsen.cu → src/refine.cu
                             └── refinement/
                                 LP、容量修复、互补交换、精确更新
```

`include/`保留公共数据结构和接口，`src/`承载生产实现，`tools/`保留当前实验入口所需的驱动和独立核验器。测试目录、粗化单独检查程序、旧GPU实验控制器已从主仓库移除。清理前快照保存在同级`Acc-GP-archive/maintenance/source-cleanup-20261019/`。

## 编译

依赖CMake≥3.24、CUDA、C++17和METIS。由用户编译，目录统一为`build/`。本机RTX5090示例：

```bash
mkdir -p ../Acc-GP-archive/build-tmp
export TMPDIR="$(cd ../Acc-GP-archive/build-tmp && pwd)"
unset NVCC_PREPEND_FLAGS NVCC_APPEND_FLAGS NVCC_CCBIN
unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS CUDAFLAGS
cmake --fresh -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CUDA_COMPILER=/usr/local/cuda-13.0/bin/nvcc \
  -DCMAKE_CUDA_HOST_COMPILER=/usr/bin/g++-13 \
  -DCMAKE_CXX_COMPILER=/usr/bin/g++-13 \
  -DCUDAToolkit_ROOT=/usr/local/cuda-13.0 \
  -DCMAKE_CUDA_ARCHITECTURES=120 \
  -DMETIS_ROOT=../sotas/.build-deps/jet-5090/install/metis
cmake --build build -j4
```

显式编译器路径用于避免Conda覆盖CUDA/主机编译器；其他机器按安装位置和GPU架构调整。临时文件放在有空间的分区。构建仅生成两个可执行入口：

| 可执行文件 | 用途 |
| --- | --- |
| `build/gpart_partition_standard` | 完整GPU划分器 |
| `build/gpart_verify_csr` | 独立CPU切边与负载核验 |

静态库仍按图表示、粗化、初始化、细化划分；生产编译选项、库边界和目标名保持原样。当前只有一种图类型：int32顶点/偏移、uint32点/边权、64位累计值，支持2–128份。磁盘int64 CSR超过表示范围时明确拒绝。

## 单图与批量运行

```bash
./build/gpart_partition_standard graph_indptr.bin graph_indices.bin 64 labels.part 1.03 0
# 可选：末尾加 --verify 启用内部严格核验。
```

只测当前划分器：

```bash
COMPARE_JET=0 PARTS="4 8 16 32 64" ./run.sh
```

已有`run.sh`默认仍为51图、k=4/8/16/32/64/128、每配置3次，并比较Jet；清理未修改脚本行为。可用`GPU`、`GRAPHS`、`PARTS`、`REPEATS`、`COMPARE_JET`、`JET_BIN`覆盖，详见`./run.sh --help`。旧算法比较通过`REFERENCE_BIN`指定归档程序。

```bash
COMPARE_JET=0 GRAPHS="grid soc-Pokec" PARTS="8 64" GPU=1 ./run.sh
./analyze_cuts.sh /path/to/experiment-workspace
```

批量入口保存原生时间和独立核验的cut/负载，随后删除标签；原始记录在同级archive，CSV在`results/`。分析产生逐次、逐配置和九类汇总CSV，运行中的实验不要另启分析，以免删除仍在写入的标签。

## CPU 与 G-kway 基线

CPU驱动保留当前任务所需的Mt-METIS、KaMinPar、mt-KaHIP，统一绑核、保存程序身份并独立核验。不同算法配置使用不同结果目录：

```bash
METHODS=mtmetis MTMETIS_REFINEMENT=greedy PARTS="4 8 16 32 64" \
  PARTITION_DIR=/dev/shm/accgp-cpu-labels \
  ./run_cpu_baselines.sh results/cpu-baselines/mtmetis-greedy
METHODS=mtkahip MTKAHIP_PRESET=multitrysocialparallel PARTS="4 8 16 32 64" \
  PARTITION_DIR=/dev/shm/accgp-cpu-labels \
  ./run_cpu_baselines.sh results/cpu-baselines/mtkahip-mls
```

上述为后续自行运行示例；2026-10-19已启动的正式队列由[当前任务](CONTINUATION.md)记录，不重复启动。默认CPU入口仍是Mt-METIS HS与KaMinPar、k64/128、32物理核、seed0、3次。`PARTITION_DIR`只改变临时标签位置，避开共享文件系统逐行写入；核验后删除。`REPORT_ONLY=1`从保存记录重建原表，`REUSE_RESULTS`只导入身份一致的结果。

`./run_gkway.sh`保留既有G-kway实验入口和断点续跑，参数见`--help`。G-kway、CPU及Jet的现有表格和归档不因源码整理改变。

## 数据与记录

`data/`是已汇总基线数据，`results/`是逐批CSV和表格；它们不参与编译。输入在同级`dataset_benchmark/`，图工具在`graph-utils/`，外部程序在`sotas/`，论文在`paper/`。当前清单为九类51个数据集，见`tools/benchmark_selection.json`。

本次没有重新编译划分器或重新测量GPU性能。32份生产C++/CUDA文件在还原include路径后逐字节一致，公共接口、参数及算法调用不变；正在运行的CPU脚本、清单、核验器源码和现有二进制保持原样。后续编译请沿用相同工具链和选项。
