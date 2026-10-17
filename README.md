# Acc-GP

GPU多层图划分：保留种子、残余单点扩展与备选损失准入粗化（regret研究主线） → 一次CPU METIS初始化 → GPU投影细化与容量修复。支持2–128份，正式实验关注k=4/8/16/32/64/128。

## 你自行编译

需要CMake>=3.24、CUDA 13、C++17和METIS。本机依赖路径示例：

```bash
# 本机根分区已满，nvcc临时文件改放有空间的/home分区。
mkdir -p ../Acc-GP-archive/build-tmp
export TMPDIR="$(cd ../Acc-GP-archive/build-tmp && pwd)"
# Conda会注入另一套编译器、CUDA头文件和链接参数。
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

以上是本机RTX 5090的配置，显式使用系统CUDA 13和GCC 13，避免激活Conda后选中环境内CUDA 12.8及另一套C++编译器。2026-10-16排查确认根分区100%、/tmp无法写入，导致nvcc的主机编译器预处理失败；改用上述TMPDIR后空输入预处理通过，未代用户编译项目。`--fresh`重置失败配置留下的CMake缓存；日常源码修改只需执行`cmake --build build -j4`，同一终端保留TMPDIR及清理后的编译环境。重新激活Conda后需重新设置。其他GPU应调整架构值。

构建目录统一为`build/`。脚本不会编译或修改你的构建。生成`gpart_partition_standard`和独立CPU核验器`gpart_verify_csr`。仅维护一种图类型：顶点ID/CSR偏移为int32，边/顶点重量为uint32；切边、增益、分区总重量保留64位。big目标及图类型模板已删除，超过32位CSR范围的图由运行脚本跳过，直接调用时明确报错。磁盘CSR仍读取int64格式。

## 当前粗化主线与检查

默认且唯一维护的粗化算法是regret：可选单轮HEM种子、单点向稳定簇扩展、按最佳/次佳可行连接差值处理容量竞争。旧legacy/SCLP/residual分支已归档移除。基础匹配和亲和力算子仍保留；新颖性与稳定收益需要继续验证，历史负结果不删除。

```bash
ctest --test-dir build --output-on-failure
```

`residual_coarsen_standard`是保留名称的当前regret测试，覆盖加权容量、种子不拆分、诊断/生产一致、CPU精确top-two和粗CSR归并。`GPART_COARSEN_MODE`可省略或设为regret，旧值会报错；`GPART_HEM_COARSEN=0`只关闭种子。`GPART_REGRET_FORCE_FULL=1`关闭容量证明快路径，保留完整regret计算用于消融。默认仅在能证明所有请求均能接纳时省去次强统计和排序/前缀扫描。

本轮新增细化候选，可显式运行：

```bash
GPART_REFINE_MODE=joint-polish ./run.sh
```

`joint-polish`保留原LP，用净容量引导双向连通组替换小层旧组阶段；`joint`为独立新细化实验路径，首轮完全替换试验质量不合格，不建议用于正式主结果。`legacy`为旧LP＋单侧组对照，当前可省略环境变量使用它。`GPART_JOINT_ROUNDS`控制新组阶段最多0..32批，默认2。新的结果与默认是否推广见[当前状态](CONTINUATION.md)，不能沿用旧版速度。

旧版对照使用归档binary，例如比较本次优化前regret：

```bash
REFERENCE_BIN="$PWD/../Acc-GP-archive/maintenance/before-regret-mainline-20261017/gpart_partition_standard" \
  REFERENCE_COARSEN_MODE=regret ./run.sh
```

比较旧residual可将REFERENCE_COARSEN_MODE改为residual（上述归档binary仍支持）。每次模式/源码改变都使用新工作目录；归档历史实验不得用新binary续跑。CSV同时输出相对reference的速度和cut比。

## 一键运行

```bash
./run.sh
```

默认使用当前保留的52个数据集，k=4/8/16/32/64/128，每配置3次，同批比较当前regret Acc-GP（ours）和Jet，共1872份计时输出。5张用户指定有限元图和3张OOM图继续排除。每图所有方法、k及重复固定同一张GPU，自动等待空闲；方法顺序轮换，检测到其他进程重叠就重测。可以指定卡：

```bash
GPU=1 ./run.sh
```

配置可以直接用环境变量；例如只跑两图做检查：

```bash
GRAPHS="grid products" PARTS="4 32 128" REPEATS=3 GPU=1 ./run.sh
```

每图完成全部计时后，自动从原始CSR独立核验cut和严格容量，先保存核验结果再删除临时标签。失败/超载保留记录，OOM后跳过该图余下配置。不会长期保存每个数据集的划分文件。

原始工作目录写到同级`../Acc-GP-archive/manual/<时间>/`，CSV写到`results/manual/<时间>/`，启动时会打印两个路径。中断后用原工作目录恢复，配置或二进制改变时应新建一次实验：

```bash
./run.sh ../Acc-GP-archive/manual/原工作目录名
```

默认Jet从已有本地安装位置查找。若装在其他位置：

```bash
JET_BIN=/path/to/jet GPU=1 ./run.sh
```

其他可选配置：`BUILD_DIR`、`DATA_DIR`、`TIMEOUT`、`COMPARE_JET=0`（不跑Jet）、`REFERENCE_BIN=/path/to/old_binary`（增加旧版对照，限standard输入）。完整用法见`./run.sh --help`。

## 一键分析切边

```bash
./analyze_cuts.sh
```

默认分析最近一次`run.sh`实验，也可指定工作目录。尚未核验的标签从CSR独立复算；标签已清理的运行使用保存的exact核验值，不重新宣称做了一次CSR复算。分析脚本不需要GPU；运行仍在进行时禁止另起手动分析，防止删除正在写入的标签。

结果只输出CSV，不生成Markdown报告或图表：

| 文件 | 内容 |
| --- | --- |
| `runs.csv` | 每次运行的总时间与粗化/初始化/细化/其余阶段耗时、独立cut、负载、模式、失败状态及版本哈希 |
| `comparison.csv` | 每数据集每k的中位数、Jet/ours加速比、ours/Jet切边比；可选reference比值 |
| `categories.csv` | 九类汇总：有效配置数、相对Jet与可选reference的几何平均加速比、平均cut比值和切边占比 |

时间取完整原生算法时间，包含内部传输、修复、同步和清理，排除输入加载/上传及最终标签写出。加速比=Jet时间/Acc-GP时间；cut比值=Acc-GP cut/Jet cut。失败或重复不足的配置明确标记，不混入有效加速统计。cut/M与cut比值按配置算术平均，加速比按配置几何平均；汇总同时显示计划/有效配置数。

跑完将这三个CSV发来即可继续分析。脚本内部用Python3读取清单和CSV，独立cut核验用你编译出的C++ oracle；不依赖绘图库或额外报告程序。

## 代码与研究记录

代码审查建议先读[当前状态](CONTINUATION.md)，再对照算法说明、实现和`results/manual/joint-final-20261017/`的实测表格。仓库包含已审核的历史CSV/表格快照（包括负结果）；新生成结果默认仍被Git忽略。数据集、外部基线、论文PDF、原始日志、核验记录及冻结二进制位于本机同级目录，不随本仓库上传。远程读者可以审查代码和汇总证据；完整复跑需要按下述入口另备输入与依赖，不能假定本机归档路径在克隆后存在。

| 入口 | 内容 |
| --- | --- |
| [目录与文件说明](docs/STRUCTURE.md) | 每个维护文件的职责 |
| [当前算法](ALGORITHM.md) | 已实现机制、默认参数与容量 |
| [算法对比](ALGORITHM_COMPARISON.md) | 与Jet、DAC G-kway、Hunyuan的区别和来源 |
| [尝试历史](docs/EXPERIMENT_HISTORY.md) | 划分质量/算法与GPU加速两部分，包含失败记录 |
| [论文阅读](docs/PAPER_REVIEW.md) | 三篇论文与研究方向 |
| [历史结果索引](results/INDEX.md) | 此前实验表格，不能当作你新跑的成绩 |
| [接续状态](CONTINUATION.md) | 当前状态和未完成事项 |

图工具在同级[graph-utils](../graph-utils/README.md)，输入在`../dataset_benchmark/`，对照与依赖在`../sotas/`。旧报告/绘图Python脚本和旧构建缓存已迁到`../Acc-GP-archive/`；当前不自动启动正式实验。旧residual-v1的用户52图结果位于`results/manual/20261016-211749/`，正负结论见尝试历史。
