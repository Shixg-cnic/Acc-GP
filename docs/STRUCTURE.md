# 当前目录结构与文件职责

更新：2026-10-17。下表覆盖当前全部维护文件；结果目录每张表的用途见[结果索引](../results/INDEX.md)。构建生成文件不逐项维护。

```text
g_partition/
├── Acc-GP/
│   ├── app/       划分与粗化检查入口
│   ├── include/   公共接口/类型及detail辅助
│   ├── src/       当前唯一划分实现
│   ├── tests/     独立正确性与边界验证
│   ├── tools/     选集、核验和旧实验辅助工具
│   ├── docs/      历史、论文阅读与本结构说明
│   ├── results/   仅CSV和表格报告
│   └── build/ 本地CMake产物，Git忽略
├── graph-utils/   独立图生成/转换/对称化工具
├── Acc-GP-archive/ 历史原始记录、冻结版本及剖析
├── dataset_benchmark/ 共同输入与manifest
├── sotas/         外部基线与依赖
└── passage/       用户提供论文PDF
```

.cuh为所属.cu的私有实现，不是新的独立划分后端。没有保留未采用GPU初始化或失败提案kernel在当前源码中。算法修改见ALGORITHM，历史不得在多个README重复堆积。

| 文件 | 职责 |
| --- | --- |
| [.gitignore](../.gitignore) | 排除本地构建、输入数据、标签和新生成结果；已审核的历史表格快照显式提交。 |
| [AGENTS.md](../AGENTS.md) | 代码修改时的算法来源、对比和文档维护约定。 |
| [ALGORITHM.md](../ALGORITHM.md) | 当前唯一已实现算法、参数、容量和计时。 |
| [ALGORITHM_COMPARISON.md](../ALGORITHM_COMPARISON.md) | 当前机制与Jet、DAC G-kway、Hunyuan的区别和来源。 |
| [CMakeLists.txt](../CMakeLists.txt) | 单一standard图类型算法库、驱动、独立核验器与CTest构建。 |
| [CONTINUATION.md](../CONTINUATION.md) | 当前状态与未完成研究/实验，避免重复启动旧任务。 |
| [run.sh](../run.sh) | 用户一键运行：选择空闲GPU、冻结版本、逐图逐k比较、核验后清理标签；不编译。 |
| [analyze_cuts.sh](../analyze_cuts.sh) | 用户一键切边分析：独立核验待处理标签或读取已存核验值，输出三个CSV；不生成报告或图片。 |
| [README.md](../README.md) | 构建、运行、存储规则和文档导航。 |
| [app/coarsen_main.cu](../app/coarsen_main.cu) | 粗化检查CLI，导出层次并输出粗化统计。 |
| [app/partition_main.cu](../app/partition_main.cu) | 完整划分CLI，解析参数、调用粗化/METIS/细化并计时。 |
| [docs/EXPERIMENT_HISTORY.md](EXPERIMENT_HISTORY.md) | 统一两部分尝试历史：质量/算法与GPU加速，保留负结果。 |
| [docs/STRUCTURE.md](STRUCTURE.md) | 本文，当前全部维护文件及仓库外工具的职责。 |
| [docs/PAPER_REVIEW.md](PAPER_REVIEW.md) | 三篇论文阅读、页码、公式疑点与研究设计。 |
| [include/check.hpp](../include/check.hpp) | CUDA错误检查与公共检查辅助。 |
| [include/coarsen.hpp](../include/coarsen.hpp) | 粗化选项、聚合结果、工作区及统计接口。 |
| [include/detail/edge_weight.hpp](../include/detail/edge_weight.hpp) | 精确边权读取；空设备边权指针表示已证明全1。 |
| [include/detail/group_record.hpp](../include/detail/group_record.hpp) | 小组完整排序字段、有效位布局和编码。 |
| [include/detail/sclp_admission.hpp](../include/detail/sclp_admission.hpp) | SCLP容量准入键及完整tie编码。 |
| [include/detail/sclp_record.hpp](../include/detail/sclp_record.hpp) | 精确收缩记录编码、布局和权重归约。 |
| [include/detail/scratch_buffer.hpp](../include/detail/scratch_buffer.hpp) | 增长不保留旧内容的覆写临时缓冲。 |
| [include/detail/scratch_pool.hpp](../include/detail/scratch_pool.hpp) | 流序内存池、分配器、会话和清理。 |
| [include/graph.hpp](../include/graph.hpp) | 主机/设备加权CSR、加载、传输与验证接口。 |
| [include/graph_types.hpp](../include/graph_types.hpp) | 唯一standard图类型及最大分区数128；累计量保留64位。 |
| [include/hierarchy.hpp](../include/hierarchy.hpp) | 主机/设备层次、投影映射与层次数据结构。 |
| [include/initial_partition.hpp](../include/initial_partition.hpp) | METIS初始化与可行性选项接口。 |
| [include/partition_capacity.hpp](../include/partition_capacity.hpp) | 严格整数容量与范围检查。 |
| [include/refine.hpp](../include/refine.hpp) | 亲和力布局、细化选项、结果和统计接口。 |
| [include/uncoarsen.hpp](../include/uncoarsen.hpp) | 解粗化公共入口与结果接口。 |
| [results/INDEX.md](../results/INDEX.md) | 所有结果表格索引，注明历史/初筛范围。 |
| [src/README.md](../src/README.md) | 私有实现模块导航。 |
| [src/coarsen.cu](../src/coarsen.cu) | 粗化工作区与逐层编排、唯一regret主线和精确CSR收缩。 |
| [src/coarsen_matching.cuh](../src/coarsen_matching.cuh) | 互选HEM候选、配对和根映射kernel。 |
| [src/coarsen_residual.cuh](../src/coarsen_residual.cuh) | 残余单点角色冻结、种子簇重量及容量可行目标策略；供精确亲和力路径共享。 |
| [src/coarsen_rows.cuh](../src/coarsen_rows.cuh) | 短粗行局部排序、重复边精确归并和CSR构建。 |
| [src/coarsen_sclp.cuh](../src/coarsen_sclp.cuh) | SCLP亲和力、角色、容量准入、two-hop和孤立点实现。 |
| [src/graph.cpp](../src/graph.cpp) | CSR加载/验证、元数据和主机设备传输。 |
| [src/initial_partition_metis.cu](../src/initial_partition_metis.cu) | 下载粗图、精确范围转换、一次METIS、可选CPU修复和上传。 |
| [src/refine.cu](../src/refine.cu) | 细化工作区、亲和力构建、层次投影和选择。 |
| [src/refine_affinity.cuh](../src/refine_affinity.cuh) | Dense/Sparse/OnDemand精确亲和力读取与脏行维护。 |
| [src/refine_groups.cuh](../src/refine_groups.cuh) | 连通组生长、重量范围配对、事务准入与精确批收益。 |
| [src/refine_incremental.cuh](../src/refine_incremental.cuh) | LP提案/修正、增量cut/cache、源配额和小组搜索编排。 |
| [src/refine_joint.cuh](../src/refine_joint.cuh) | 候选双向连通组细化：净容量引导生长、分区对匹配、整组冲突剔除及精确前缀提交。 |
| [src/refine_lp_graph.cuh](../src/refine_lp_graph.cuh) | 大层GPU条件图LP循环、收敛和checkpoint。 |
| [src/refine_rebalance_graph.cuh](../src/refine_rebalance_graph.cuh) | GPU条件图平衡修复与接收端多目标重量票据。 |
| [src/uncoarsen.cu](../src/uncoarsen.cu) | 解粗化调用及结果日志。 |
| [tests/synthetic_suite.py](../tests/synthetic_suite.py) | 生成合成CSR并对standard完整划分做独立核验；成功后删标签。 |
| [tests/test_group_record.cpp](../tests/test_group_record.cpp) | 小组排序字段、完整比较语义和有效位测试。 |
| [tests/test_initial_partition_metis.cu](../tests/test_initial_partition_metis.cu) | METIS接口、权重归一化、容量和异常检查。 |
| [tests/test_joint_events.cu](../tests/test_joint_events.cu) | 用完整CPU切边逐前缀核验GPU边事件累计及最优可行前缀。 |
| [tests/test_residual_coarsen.cu](../tests/test_residual_coarsen.cu) | GPU粗化候选检查：种子保留、加权容量、诊断一致、CPU独立粗边归并和生产调度。 |
| [tests/test_manual_workflow.py](../tests/test_manual_workflow.py) | CPU模拟三方法实验流程；真实Python CSR核验、模式/阶段/比值、恢复和错误记录。 |
| [tests/test_result_storage.py](../tests/test_result_storage.py) | 主机回归：结果保留、路径迁移、表格发布与真实CSR核验后删除标签；模拟计时程序，不用GPU。 |
| [tests/test_partition_capacity.cpp](../tests/test_partition_capacity.cpp) | 整数容量、非法值和溢出边界测试。 |
| [tests/test_sclp_admission.cpp](../tests/test_sclp_admission.cpp) | 准入键位宽、收益/tie排序边界测试。 |
| [tests/test_sclp_record.cpp](../tests/test_sclp_record.cpp) | 收缩记录位宽、编码与求和边界测试。 |
| [tests/test_sclp_repeatability.py](../tests/test_sclp_repeatability.py) | 重复粗化，记录层次字节/日志差异，材料放仓库外。 |
| [tests/test_uncoarsen.cu](../tests/test_uncoarsen.cu) | 投影、亲和力布局、容量修复、小组和重量边界GPU正确性。 |
| [tests/test_verify_csr.py](../tests/test_verify_csr.py) | C++与Python独立CSR oracle交叉验证及反例。 |
| [tools/README.md](../tools/README.md) | 实验入口、严格核验、结果存储与报告说明。 |
| [tools/benchmark_selection.json](../tools/benchmark_selection.json) | 九类52名称、k配置、用户/显存排除与速度目标。 |
| [tools/check_gpu_categories.py](../tools/check_gpu_categories.py) | 两方法矩阵完整性、合法状态和冻结版本审计。 |
| [tools/check_gpu_optimization.py](../tools/check_gpu_optimization.py) | 完整三方法矩阵、版本、原始计时与已存核验审计。 |
| [tools/compare_jet.py](../tools/compare_jet.py) | 显式CSR/METIS输入的单图Jet/可选旧版对照。 |
| [tools/result_storage.py](../tools/result_storage.py) | 仓库外工作路径、核验后标签删除、逐次CSV与表格发布。 |
| [tools/run_cpu_baselines.py](../tools/run_cpu_baselines.py) | 官方CPU基线、固定物理线程/NUMA、独立核验及七列表。 |
| [tools/run_gpu_categories.py](../tools/run_gpu_categories.py) | 九类两方法批量计时、失败分类和独立核验。 |
| [tools/run_gpu_optimization.py](../tools/run_gpu_optimization.py) | 隔离GPU空闲窗口，三方法冻结版本/轮换计时/独立核验。 |
| [tools/verify_csr.cpp](../tools/verify_csr.cpp) | mmap/OpenMP C++独立cut/容量/对称性核验器。 |
| [tools/verify_partition.py](../tools/verify_partition.py) | 从原始CSR独立计算cut、标签范围和严格容量。 |

## 仓库外图工具

迁移位置：[graph-utils](../../graph-utils/README.md)。单独CMake构建，不是划分器依赖。

| 文件 | 职责 |
| --- | --- |
| [CMakeLists.txt](../../graph-utils/CMakeLists.txt) | 构建六个C++工具，边列表读取链接ZLIB。 |
| [README.md](../../graph-utils/README.md) | 输入格式、构建和转换/分析示例。 |
| [generate_graph.cpp](../../graph-utils/generate_graph.cpp) | 生成二进制CSR及可读COO。 |
| [edge_list_to_csr.cpp](../../graph-utils/edge_list_to_csr.cpp) | 读取文本/压缩边列表或矩阵格式，生成CSR。 |
| [csr_symmetrize.cpp](../../graph-utils/csr_symmetrize.cpp) | 对称化、排序、去重/自环处理。 |
| [check_csr_symmetry.py](../../graph-utils/check_csr_symmetry.py) | 独立检查CSR反向邻接对称性。 |
| [csr_to_metis.cpp](../../graph-utils/csr_to_metis.cpp) | CSR目录转METIS图。 |
| [symmetric_csr_to_metis.cpp](../../graph-utils/symmetric_csr_to_metis.cpp) | 对已对称CSR输出METIS格式。 |
| [analyze_partition.cpp](../../graph-utils/analyze_partition.cpp) | 计算标签对应cut、负载等分析指标。 |

2026-10-17：未新增维护文件。`coarsen_residual.cuh`策略增加可选top-two/priority缓冲，`coarsen_sclp.cuh`融合次佳可行簇统计；`test_residual_coarsen.cu`覆盖regret竞争反例及CPU精确top-two核验。`run.sh`支持非默认regret与显式REFERENCE_COARSEN_MODE，`analyze_cuts.sh`补充相对reference的cut比及分类汇总，CPU流程测试验证模式隔离。实验源/日志在仓库外regret-20261017，results仅保存CSV。

2026-10-17主线清理：旧`aggregate_heavy_edges`及legacy/residual/SCLP分支删除；`tests/test_sclp_small.py`模拟已删除旧算法，迁入维护快照，不再作为当前oracle。其并行边、自环、孤立点正确性由当前GPU测试的独立CPU粗CSR核验覆盖。`coarsen_matching.cuh`只承担单轮种子，`coarsen_sclp.cuh`名称保留用于共享亲和力/准入/two-hop，不表示旧SCLP后端仍存在。次强值与优先级共用一缓冲，two-hop不求次强。run.sh默认两方法，analyze_cuts.sh继续读取历史legacy列。源码与binary快照：`../../Acc-GP-archive/maintenance/before-regret-mainline-20261017/`。

同日容量证明快路径：`coarsen.cu`维护逐轮簇重量上界并证明全接纳，`coarsen_residual.cuh`新增该证明下的直接提交kernel；不维护第二套算法。`test_residual_coarsen.cu`比较快路径开关和诊断开关的映射，以及完整生产层次。CLI的GPART_REGRET_FORCE_FULL用于强制完整准入消融。

2026-10-17 row512：未新增维护脚本。`coarsen_rows.cuh`提供32/64/128与256/512项行内排序，长短行kernel分离；`coarsen.cu`选择局部或全局精确CSR。`test_uncoarsen.cu`覆盖129/255/256/257/511/512边界及完整长行粗图/map与全局路径对照。临时8/32线程搬运候选已撤回，源码/失败计时存于仓库外，results保留CSV。

2026-10-17 细化实现：删除big构建目标、图宽度模板和自动选择big路径；`graph_types.hpp`仅提供固定GraphTypes。新增`src/refine_joint.cuh`（净容量引导双向连通组、分区对匹配、整组冲突剔除和精确前缀）与`tests/test_joint_events.cu`（逐前缀CPU完整切边oracle）。`test_uncoarsen.cu`增加负收益起步与所有k的加权随机核验。

2026-10-17 外部审查后的筛选实验：未新增维护文件。`refine_joint.cuh`新增双策略完全相同移动去重、有界冲突恢复及诊断前缀谓词；`refine_incremental.cuh`编排可选路径并输出筛选计数；`refine.hpp`/CLI新增独立开关。`test_joint_events.cu`增加CPU冲突图oracle、H/X/Y完整CSR检查与前缀局限反例；`test_uncoarsen.cu`覆盖开关、所有亲和力布局和正式k范围；`test_manual_workflow.py`检查计时入口移除额外诊断。

2026-10-17效果补测：没有新增维护源码或报告脚本。results/manual/joint-filter-effects-20261017的runs/comparison/categories为两组共360次原生结果合并；fixed_lp.csv是同LP状态的165份完整CPU核验结果，fixed_lp_stages.csv是330批筛选计数。临时四方法runner、固定LP C++驱动、冻结版本与日志均在同级archive，不进入生产构建。
