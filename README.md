# Acc-GP

GPU 多层图划分研究代码。

当前唯一划分流程：**GPU SCLP 粗化 → GPU 递归加权谱二分初始化 → GPU 增量细化（含容量约束小组事务）**。
支持 `2 ≤ k ≤ 32`，默认最大负载比 `1.03`。主程序不链接 METIS、Jet 或 Kokkos。
CPU 按递归深度调度任务和算法阶段；同一深度的谱计算、排序和加权切分在 GPU 上批量完成。

## 代码入口

| 位置 | 内容 |
|---|---|
| `app/partition_main.cu` | 完整划分入口与阶段计时 |
| `src/coarsen.cu` | SCLP 聚合、容量准入、two-hop、CSR 收缩 |
| `src/initial_partition_gpu.cu` | 按深度批量执行 16 步谱预热 +48 步固定动量、GPU 加权递归二分 |
| `src/refine.cu` | 细化工作区、层次投影和执行调度 |
| `src/refine_incremental.cuh` | 迁移候选、优先级修正、增量更新、源端修复配额 |
| `src/refine_rebalance_graph.cuh` | GPU 再平衡条件循环、接收端多目标重量票据、warp 前缀/压缩 |
| `src/refine_groups.cuh` | 小组生长、反方向配对、净负载准入和整批收益检查 |
| `include/` | 图类型、GPU 层次、容量约束和接口 |
| `tests/` | CTest 及合成图正确性测试 |
| `tools/` | Python/C++ 独立 CSR 核验和 Jet 对照工具 |
| `graph_untils/` | 数据转换、对称化和划分分析工具 |

算法细节见 [ALGORITHM.md](ALGORITHM.md)，三个阶段与 Jet / DAC G-kway 的对比及
已记录的实验结果见 [ALGORITHM_COMPARISON.md](ALGORITHM_COMPARISON.md)。

## 获取源码

```bash
git clone https://github.com/Shixg-cnic/Acc-GP.git
cd Acc-GP
```

## 编译

需要 CMake ≥ 3.24、C++17 和 CUDA 13.x；当前 GPU 条件循环使用 CUDA 13 的设备接口。RTX 5090 示例：

```bash
cmake -S . -B build-5090 -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc \
  -DCMAKE_CUDA_ARCHITECTURES=120
cmake --build build-5090 -j6
CUDA_VISIBLE_DEVICES=0 ctest --test-dir build-5090 --output-on-failure
```

未指定架构时使用 `native`。算法库由同宽度的驱动和测试复用。
构建产物只留在本地，`build*/`、对象文件、静态/动态库、数据和结果目录均由
[.gitignore](.gitignore) 排除。

## 使用

```bash
CUDA_VISIBLE_DEVICES=0 build-5090/gpart_partition_standard \
  indptr.bin indices.bin 4 partition.part
python3 tools/verify_partition.py \
  --indptr indptr.bin --indices indices.bin --parts 4 --partition partition.part
```

参数：`indptr indices k output [imbalance_ratio=1.03] [seed=0] [--verify]`。
`--verify` 启用内部层次、投影、cut 和增量缓存校验；性能测试关闭该开关。

输入为无向对称的二进制 CSR，offsets 和邻点 ID 均为本机字节序 `int64`，
输入顶点和边权重均为一。输出为每顶点一个 `int32` 分区 ID。
`standard` 在 GPU 上使用 32 位 offsets/权重，`gpart_partition_big` 使用 64 位
offsets/权重；两者的顶点 ID 和输出格式一致。
容量为 `floor(imbalance_ratio * total_vertex_weight / k)`。
容量不可行或谱排序无法产生可行二分时，程序明确报错。

`algorithm_total_seconds` 包含粗化、初始化、投影细化及层次清理，排除加载、
输入准备/上传和最终下载/文件输出；`wall_total_seconds` 包含完整进程工作。

## 验证与分析

```bash
CUDA_VISIBLE_DEVICES=0 python3 tests/synthetic_suite.py --verify
CUDA_VISIBLE_DEVICES=0 python3 tests/test_sclp_small.py
cmake -S graph_untils -B graph_untils/build
cmake --build graph_untils/build -j6
```

合成套件默认测试三类图、`k=2,4,8,32`、standard/big、每配置两次，独立复算 cut
和负载。生成数据与日志写到被忽略的 `results/`。细化桶内原子排名可能造成同 seed
结果变化，重复测试检查正确性，不要求标签逐字节一致。

`gpart_coarsen_standard` / `gpart_coarsen_big` 仅用于粗化检查和层次导出；
它们不是另一套完整划分算法。参数为
`indptr indices k hierarchy [seed=0] [stop_ratio=0.90] [max_levels=24] [--verify]`。
数据工具说明见 [graph_untils/README.md](graph_untils/README.md)，真实图对照见
[tools/README.md](tools/README.md)。

## 数据与实验记录

仓库只发布当前源码、构建配置、必要测试和文档。数据集、CUDA 编译产物、基线源码和本地实验输出留在服务器，不纳入 Git。九类已处理输入在服务器同级 `../dataset_benchmark/`，每图含 METIS、CSR 及规模元信息；Products 保留。

算法对比文档中的实验明确标注版本与输入范围。2026-10-14 当前整合版本的全集对照仍在运行，旧版数据不代表本次源码的最新性能。主要借鉴方法及本项目改动见 [ALGORITHM_COMPARISON.md](ALGORITHM_COMPARISON.md)。

## 本次发布验证（2026-10-14）

在独立源码目录使用 CUDA 13.0.48、GCC 13.3 与 RTX 5090（SM 120）完成 standard/big 两个版本及全部图转换工具的干净构建。7 项 CTest 全部通过；三类合成图、k=2/4/8/16/32、两种宽度共 30 次完整划分开启内部严格校验，并由独立核验器复算切边与容量，全部通过。这些检查验证正确性，不作为与 Jet 的性能对照。
