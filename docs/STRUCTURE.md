# 源码文件树与架构

更新：2026-10-22。主仓库保留生产划分源码、运行/核验入口和研究数据。完整算法见[ALGORITHM.md](../ALGORITHM.md)。

## 文件树

```text
Acc-GP/
├── CMakeLists.txt
├── app/
│   └── partition_main.cu
├── include/
│   ├── graph_types.hpp          固定图类型与范围
│   ├── graph.hpp                主机/设备CSR
│   ├── hierarchy.hpp            多层图与投影映射
│   ├── coarsen.hpp              粗化接口、参数和统计
│   ├── initial_partition.hpp    METIS初始化接口
│   ├── refine.hpp               细化接口、参数和统计
│   ├── uncoarsen.hpp            解粗化入口
│   ├── partition_capacity.hpp   整数容量计算
│   ├── check.hpp                CUDA错误处理
│   └── detail/
│       ├── capacity_admission.hpp  容量准入排序键
│       ├── contraction_record.hpp  粗边记录编码
│       ├── edge_weight.hpp         显式/单位边权读取
│       ├── scratch_buffer.hpp      覆写型临时缓冲
│       └── scratch_pool.hpp        默认流有序显存arena
├── src/
│   ├── graph.cpp
│   ├── coarsen.cu
│   ├── initial_partition_metis.cu
│   ├── uncoarsen.cu
│   ├── refine.cu
│   ├── coarsening/
│   │   ├── seed_matching.cuh
│   │   ├── singleton_growth.cuh
│   │   ├── aggregation.cuh
│   │   └── contraction_rows.cuh
│   ├── refinement/
│   │   ├── affinity.cuh
│   │   ├── incremental.cuh
│   │   ├── lp_graph.cuh
│   │   ├── rebalance_graph.cuh
│   │   ├── rebalance_select.cuh
│   │   ├── exchange.cuh
│   │   └── complementary_moves.cuh
│   └── README.md
├── tools/
│   ├── benchmark_selection.json
│   ├── run_cpu_baselines.py
│   ├── run_gkway.py
│   ├── result_storage.py
│   ├── verify_csr.cpp
│   └── README.md
├── run.sh
├── analyze_cuts.sh
├── run_cpu_baselines.sh
├── run_gkway.sh
├── README.md
├── ALGORITHM.md
├── ALGORITHM_COMPARISON.md
├── CONTINUATION.md
├── AGENTS.md
├── docs/
│   ├── STRUCTURE.md
│   ├── EXPERIMENT_HISTORY.md
│   ├── GPU_ARCHITECTURE_ANALYSIS.md
│   └── PAPER_REVIEW.md
├── data/                       已汇总数据与说明
├── results/                    逐批CSV和表格
└── build/                      本地构建产物，Git忽略
```

## 编译与模块边界

| 翻译单元 | 构建目标 | 职责 |
| --- | --- | --- |
| `src/graph.cpp` | `gpart_graph_standard` | CSR加载、范围检查、上传/下载、单位边权表示；沿用CUDA语言编译 |
| `src/coarsen.cu` | `gpart_coarsening_standard` | 每层容量、工作区、种子选择、聚合准入、精确收缩与层次保存 |
| `src/initial_partition_metis.cu` | `gpart_initial_metis_standard` | 最粗图与METIS之间的数据/类型转换和一次初始化 |
| `src/refine.cu`、`src/uncoarsen.cu` | `gpart_refinement_standard` | 投影、细化层选择、工作区及结果返回 |
| `app/partition_main.cu` | `gpart_partition_standard` | 参数、完整调用链与原生计时 |
| `tools/verify_csr.cpp` | `gpart_verify_csr` | 独立读取原图CSR与标签，复算切边和负载 |

`.cuh`是所属`.cu`的私有文本实现，保持原有include顺序和命名空间；不创建额外翻译单元，不改变设备链接或kernel编译边界。公开函数、结构和旧`SclpWorkspace`标识保留，避免API变化。

## 粗化私有实现

| 文件 | 职责 |
| --- | --- |
| `seed_matching.cuh` | 一轮容量合法互选重边种子 |
| `singleton_growth.cuh` | 单点/多点簇判别、冻结角色、稳定接收目标、全接纳直接提交 |
| `aggregation.cuh` | 精确簇亲和力、最佳/次佳连接、备选损失准入、two-hop及簇压缩 |
| `contraction_rows.cuh` | 有界短行排序、重复粗边归并；与全局radix路径保持相同CSR含义 |

## 细化私有实现

| 文件 | 职责 |
| --- | --- |
| `affinity.cuh` | Dense/Sparse/OnDemand精确邻接分区连接权重视图 |
| `incremental.cuh` | 提案、迁移、精确cut/cache维护、LP与交换阶段编排 |
| `lp_graph.cuh` | 大层GPU条件图LP、停止条件与最佳状态控制 |
| `rebalance_graph.cuh` | 容量修复的源桶、接收票据、迭代控制 |
| `rebalance_select.cuh` | 稀疏目标枚举、内部点判别、余量CDF及哈希后备目标 |
| `exchange.cuh` | 商图匹配、种子、双向生长、片段记录、冲突筛选、warp归约的精确边事件与前缀 |
| `complementary_moves.cuh` | 精确净重量区间检索、不重叠片段组合、跨片段边修正 |

## 运行工具与研究材料

`results/mtmetis-smt-wb-edu-k8-20261020/`保留单图32/64线程探索试验的CSV；完整启动身份、日志和核验位于`../../Acc-GP-archive/experiments/mtmetis-smt-wb-edu-k8-20261020/`。该试验不并入正式基线表。

`run.sh`和`analyze_cuts.sh`是当前GPU测量/分析入口；CPU与G-kway入口使用`tools/`驱动，`result_storage.py`管理CSV发布、原始记录路径与标签清理。`benchmark_selection.json`是当前51图选择，CPU队列在测量时检查它的哈希；10月19日启动的两个CPU批次现已结束。

`ALGORITHM.md`维护当前方法；`ALGORITHM_COMPARISON.md`维护来源与贡献；`EXPERIMENT_HISTORY.md`保留成功和失败；`PAPER_REVIEW.md`保留阅读时的历史语境；`CONTINUATION.md`记录活跃工作。历史文件中出现的旧路径，以对应源码快照为准。

`GPU_ARCHITECTURE_ANALYSIS.md`记录对Acc-GPart、Jet与DAC G-kway的主执行路径核对。第3、4节用三列粗化／细化流程，将匹配重试、组标识传播、候选过滤、受限批次、重复访问及主机控制对应到具体步骤；第7、8节以公式、例子和伪代码展开现行算法；第10.5节给出挑战与贡献的表述。10月22日同时记录事件warp归约的代码改动、操作量及CPU核对，区分待测改动与历史GPU成绩。论文正文未改。

## 本次清理范围

从主仓库移除15个测试源文件、`app/coarsen_main.cu`及6个旧实验/核验脚本，删除CMake中的测试目标和独立粗化目标；13个私有实现/辅助头文件按职责迁移命名。移除文件、原文档及清理前未提交改动快照位于`../../Acc-GP-archive/maintenance/source-cleanup-20261019/`。

没有删除实验CSV、历史证据、当前测量脚本、独立CSR核验器或本地构建产物。原`build/`可能仍有此前生成的测试二进制；它们已不属于新CMake源码目标。用户下次重新配置后，正式构建仅保留划分器和核验器两个可执行入口。
