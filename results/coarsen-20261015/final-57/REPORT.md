# 57图GPU优化正式报告（2026-10-16）

本轮代码、完整复测、独立核验、实验审计及图表均已完成。当前standard `80145dbb`，Big `73c17283`。**整体完整耗时下降9.57%，相对Jet几何平均1.425×；改善明显集中在道路、人工网格及部分生物图，其他类别增幅仍有限。**此轮没有实现所有类别普遍大幅提速。

## 同批总体结果

57图 × k=4/8/16/32/64/128 × 三方法 × 三次 = **3078份**，全部成功并由CPU CSR核验cut与严格容量 `floor(103*N/(100*k))`；342个配置。相同配置的时间和cut分别取三次中位数；速度对配置等权取几何平均，cut百分比取算术平均。耗时下降定义为 `100*(1-1/G(旧时间/新时间))`，不是各图秒数之和的下降，也不是百分比的算术平均。

| 指标 | 同批旧版ac366852 | 新版80145dbb |
|:--|--:|--:|
| 相对Jet加速几何平均 | 1.28863× | 1.42503× |
| 快于Jet的配置 | 298/342 | 330/342 |
| 达到Jet 1.3×的配置 | 154/342 | 206/342 |

相对旧版：加速1.10586×，等价耗时−9.57%，cut−1.05%；287配置更快、55配置回退。相对Jet：平均cut+3.51%，仍有136配置达不到1.3×、其中12配置比Jet慢。1.425×表示Jet耗时/新版耗时，等价相对Jet耗时下降约29.83%；不能解读成下降42.5%。

主均值覆盖全部57个命名条目，有限元类别占19张。Long_Coup_dt0/dt6及Cube_Coup_dt0/dt6各一组CSR相同；去重55CSR结果为旧/新1.10951×、等价耗时−9.87%、Jet/新1.43591×，cut相对旧−1.09%、相对Jet+3.56%。九类等权的另一个敏感性口径为旧/新1.13474×、Jet/新1.42266×，不替换上述预定的342配置主均值。

## 九类全量结果

仅按用户要求剔除显存失败的 **kmer_P1a、kmer_A2a、kmer_V1r**；此前失败及Jet成功的初筛输出保留在 `../../categories-20261015/`。其余57张全部纳入，没有按速度删选。

| 类别 | 图数 | 新版耗时下降（对旧版） | 旧版/Jet | 新版/Jet | cut对旧版 | cut对Jet |
|:--|--:|--:|--:|--:|--:|--:|
| Web Crawl | 2 | +5.95% | 1.216× | 1.293× | +0.18% | -3.93% |
| Social Network | 9 | +2.94% | 1.605× | 1.654× | +0.03% | +1.32% |
| Semiconductor | 4 | +5.45% | 1.328× | 1.405× | -0.09% | +8.66% |
| Road Network | 2 | +35.10% | 1.061× | 1.636× | +1.42% | +22.04% |
| Optimization | 3 | +5.25% | 1.193× | 1.259× | -1.52% | +1.73% |
| Finite Element | 19 | +4.62% | 1.187× | 1.245× | -0.41% | +2.83% |
| Biology | 4 | +18.82% | 0.999× | 1.231× | -1.40% | +3.03% |
| Artificial Mesh | 10 | +20.39% | 1.410× | 1.771× | -4.49% | +4.72% |
| Artificial Complex | 4 | +2.01% | 1.394× | 1.422× | -0.03% | -0.15% |

![九类总览](../../../../Acc-GP-archive/experiments/coarsen-20261015/final-57/optimization-overview.png)

## 重点图和全部候选

| 图 | 耗时下降（对旧版） | 新版/Jet | cut对旧版 | cut对Jet |
|:--|--:|--:|--:|--:|
| grid | +21.75% | 1.729× | -0.94% | +5.94% |
| af_shell10 | +11.23% | 1.382× | -2.73% | +2.87% |
| road_usa | +27.58% | 1.756× | +2.22% | +30.05% |
| europe_osm | +41.84% | 1.524× | +0.62% | +14.03% |
| kmer_V2a | +31.22% | 1.219× | -0.96% | +3.45% |
| kmer_U1a | +31.37% | 1.228× | -2.66% | +6.15% |
| products | +4.54% | 1.314× | -0.51% | +1.41% |
| circuit5M | +2.31% | 2.989× | +0.19% | +23.52% |
| cage15 | +6.86% | 1.281× | -2.16% | -0.16% |
| kron_g500-logn20 | +0.54% | 1.398× | -0.01% | -0.35% |
| HV15R | +2.71% | 0.853× | +0.46% | +4.86% |
| Queen_4147 | +4.78% | 0.979× | -0.18% | +1.45% |

完整57图汇总见 [OPTIMIZATION.md](../../../../Acc-GP-archive/experiments/coarsen-20261015/final-57/OPTIMIZATION.md)，全部342个格子的时间、cut和中位数见 [配置CSV](optimization-cases.csv)；[九页PDF](../../../../Acc-GP-archive/experiments/coarsen-20261015/final-57/optimization-all-datasets.pdf)逐类展示每张候选的六个k。空白三类已全量比较，尚未替用户最终挑选数据集：

- **Finite Element（19名称/17CSR）**：af_shell1 1.589×、channel 1.518×、Geo_1438 1.412×、Hook_1498 1.357×；af_shell10 1.382×。质量对Jet分别+3.69%、+2.67%、+1.34%、+3.27%、+2.87%。HV15R仅0.853×、Queen_4147 0.979×，弱项完整保留。
- **Biology（4张）**：ppa 1.196×、cage15 1.281×、kmer_V2a 1.219×、kmer_U1a 1.228×；cut对Jet分别+2.68%、−0.16%、+3.45%、+6.15%。kmer两张比旧版耗时下降约31%，但对Jet的优势仍不到1.3×。
- **Artificial Mesh（10张）**：delaunay_n23/n24达到2.242×/2.007×、cut对Jet+4.23%/+4.04%；hugebubbles-00000为1.818×、cut+3.79%。其余grid、cube、rgg及其他hugebubbles全部在表/PDF中，未只保留好结果。

## 不同k与回退配置

| k | 耗时下降（对旧版） | 新版/Jet | cut对旧版 |
|--:|--:|--:|--:|
| 4 | +9.78% | 1.543× | -1.21% |
| 8 | +9.86% | 1.480× | -0.74% |
| 16 | +10.40% | 1.476× | -1.38% |
| 32 | +10.58% | 1.426× | -0.55% |
| 64 | +9.18% | 1.364× | -1.21% |
| 128 | +7.60% | 1.278× | -1.20% |

本轮增幅没有随k持续增长：k128下降7.60%，小于k32的10.58%；不再沿用早期“k越大提速越明显”的结论。k2只做功能检查，不计主均值；没有继续k512。

[55个旧版回退配置](regressions.csv)包含最弱的fe_rotor k8（耗时+31.22%）、Cube_Coup_dt6 k4（+17.97%）和Bump_2911 k8（+11.55%）。fe_rotor k8新版三次53.52/57.65/62.80ms，旧版42.87/43.97/43.94ms；新版细化19.41–26.20ms、旧版16.29–17.66ms，同时粗化存在波动。这是实际回退，不能简单以噪声忽略。只有三次重复，未声称差异均具统计显著性。

[12个慢于Jet的配置](jet-slower.csv)：HV15R全部六k；Queen_4147的k32/64/128；stokes的k64/128；vas_stokes_4M的k128。road_usa平均cut比Jet高30.05%，circuit5M平均+23.52%，其中k4为+141.10%；速度优势不代表质量目标已达成。

## 已保留的优化与未采用试验

当前核心机制、精确边界和来源以 [ALGORITHM.md](../../../ALGORITHM.md) 与 [对照说明](../../../ALGORITHM_COMPARISON.md)的2026-10-16节为准：有界HEM/SCLP、短粗行warp精确收缩、有效ID准入、元数据复用、消除重复清零、融合再平衡、流序池工作标签，以及小组排序有效位压缩。HEM改变粗化图；CSR与排序仍保持精确整数语义。它们是已有GPU/匹配方法的本项目工程组合，未声称独立新颖算法。

初筛全部保留：admission-screen（transform iterator直接编码）旧/新0.9869×，否决；rows-screen 1.067×；pool-screen 1.094×；HEM8只有68份部分输出，不能当全集成绩；HEM64 quick的stokes发生速度/质量回退，最终增加max度保护；warp-screen的10图/3k/两次180份结果1.206×属于前一候选，不能冒称当前57图正式成绩。冻结版本和经过见 [STATE.md](../../../../Acc-GP-archive/experiments/coarsen-20261015/STATE.md)及 [TUNING.md](../../../../Acc-GP-archive/experiments/coarsen-20261015/TUNING.md)。

## 当前瓶颈证据

下面每格是该图六k×三次的阶段**算术均值毫秒**，用于定位时间组成，不能用其比值替代主表几何平均。C=粗化、I=初始化、R=投影细化、其余=完整native−C−I−R（含清理和阶段边界）。

| 图/版本 | C | I | R | 其余 | 完整 |
|:--|--:|--:|--:|--:|--:|
| af_shell10/旧 | 39.57 | 6.31 | 30.23 | 5.15 | 81.26 |
| af_shell10/新 | 34.93 | 6.26 | 28.90 | 3.08 | 73.17 |
| grid/旧 | 47.89 | 5.16 | 46.31 | 10.82 | 110.19 |
| grid/新 | 34.57 | 4.87 | 43.37 | 5.21 | 88.01 |
| products/旧 | 83.38 | 23.56 | 61.87 | 14.04 | 182.85 |
| products/新 | 80.33 | 22.79 | 58.40 | 13.02 | 174.55 |
| HV15R/旧 | 98.36 | 9.43 | 59.03 | 36.75 | 203.57 |
| HV15R/新 | 102.37 | 9.15 | 51.79 | 29.04 | 192.35 |
| circuit5M/旧 | 295.19 | 12.42 | 207.63 | 12.13 | 527.36 |
| circuit5M/新 | 291.86 | 12.51 | 202.93 | 11.61 | 518.91 |
| kron_g500-logn20/旧 | 193.86 | 28.28 | 138.64 | 16.68 | 377.46 |
| kron_g500-logn20/新 | 195.37 | 28.31 | 135.40 | 18.31 | 377.39 |
| europe_osm/旧 | 178.89 | 4.66 | 43.36 | 51.98 | 278.89 |
| europe_osm/新 | 97.52 | 4.82 | 43.25 | 19.22 | 164.81 |

主要限制：

1. **中高平均度/长行图的粗化与全局排序**。HV15R新版粗化102.37ms（53.2%），Jet为73.80ms；Queen_4147为98.47ms，Jet84.14ms。当前精确局部CSR只覆盖原始记录≤128的短粗行，未解决所有不规则大行。circuit5M粗化291.86ms（56.2%），相对旧版295.19ms几乎没降；kron20粗化195.37ms对旧193.86ms，下一步需要针对大行的精确收缩/分段排序，而不能只继续扩大短行阈值。
2. **细化与工作量变化**。af_shell10新C/R约占47.7%/39.5%；products新C/R约46.0%/33.5%，本轮总体仅降低4.54%。投影、缓存建立、LP和小组候选仍有成本；桶内原子顺序和粗化图变化还会改变搜索轨迹。细化不是单独固定工作负载，不能把局部微内核收益直接加成整体加速。
3. **CUDA调度/同步成本仍多**。所有正式native结束后，空闲GPU0对当前80145dbb的af_shell10 k32做独立Nsight诊断：2119次cudaLaunchKernel、738次cudaMallocFromPoolAsync、628次cudaStreamSynchronize，全部GPU kernel时长之和14.66ms；profile中的完整native为85.56ms。整个trace还包括输入准备，kernel和API时长可能重叠，**不得把差值或API时长当作native精确占比**。这些调用数支持后续减少小阶段主机往返/分配调用的方向，尚未实现新的缓存分配器或更多条件图。
4. **有效位压缩有边界**。同一诊断中四个大组批次的排序键为90–93位，原206位；四个小批仍206位。GroupSortRecord仍40B，仍有152次该组记录的Onesweep内核。早期HEM64候选为208次，但两候选的候选集合和CSR路径也不同，此差异不能当作排序压缩独立消融收益。当前HEM选择24次共3.35ms，局部CSR排序6次共2.13ms，是值得进一步分析的kernel。

原始诊断：[Nsight trace](../../../../Acc-GP-archive/experiments/coarsen-20261015/profile-final-af.nsys-rep)、[SQLite](../../../../Acc-GP-archive/experiments/coarsen-20261015/profile-final-af.sqlite)、[kernel/API汇总](../../../../Acc-GP-archive/experiments/coarsen-20261015/profile-final-af-summary.json)、[日志](../../../../Acc-GP-archive/experiments/coarsen-20261015/profile-final-af.log)。它与3078份正式数据分离，未混入性能均值。其后两卡又有其他Python任务，未在共享GPU上追加性能样本；没有终止外部任务。

## 实验与正确性边界

- 两张同型号RTX5090（32607MiB），自动等待空闲；**每次仅使用单张GPU**，按图固定卡，图内三方法、全部k与重复始终同卡，整体串行。设备清单和分配保存在metadata/gpu-assignments；OMP=4、seed=0。重复方法顺序轮换，20份检测到GPU重叠的尝试已丢弃重测，单独保留污染日志。未宣称CPU时钟/调度完全恒定。
- Jet SHA `ca8fc1f9`、旧版SHA `ac366852`、新版SHA `80145dbb`，均冻结到本目录；`before`=Jet、`reference`=旧版、`after`=新版，不要仅凭字段名误读。旧版同批1.28863×不能与上一批九代表图1.41078×拼接比较。
- 时间为device输入至device划分的完整native，包含内部粗图D2H、一次METIS、标签H2D、严格容量修复、临时/层次/输入CSR释放和pool trim。排除原输入加载/上传、最终输出D2H/写盘、独立CPU核验；进程墙钟另外保留。细粒度GPU event默认关闭，不以0字段冒充真实阶段GPU耗时。
- 与Jet使用同一METIS库/API/default options；粗图不同使METIS耗时也不同，不能将全部收益算成纯GPU kernel提速。
- 独立CPU程序逐份扫描CSR复算cut/负载，3078份全通过；实验审计核对矩阵、二进制/驱动/manifest SHA、日志/时间、输出尺寸、轮换顺序、GPU分配和CSV中位数。当前38份编译相关源与冻结快照逐项一致，build二进制SHA一致。输入身份与重复图哈希继承前轮已核验记录，本轮审计未重新流读全部输入计算哈希。
- standard用于全部57图正式性能，Big用于64位正确性；无Big全图性能结论。8CTest、host ASAN/UBSAN、14份GPU sanitizer（含无--verify生产路径）、42小图/12大图严格划分、2份显式SCLP严格对照全通过。局部CSR含跨32项重复run、127/128项、wide点/边权对照；排序包括有符号极值、64位完整布局和stable tie。

[实验审计](../../../../Acc-GP-archive/experiments/coarsen-20261015/final-57/checks.json) · [验证清单](../../../../Acc-GP-archive/experiments/coarsen-20261015/final-57/validation.json) · [最终源与产物检查](../../../../Acc-GP-archive/experiments/coarsen-20261015/final-57/final-checks.json) · [逐次记录](../../../../Acc-GP-archive/experiments/coarsen-20261015/final-57/runs.json) · [逐图CSV](optimization-graphs.csv) · [九类CSV](optimization-categories.csv) · [阶段CSV](optimization-stages.csv)

复建汇总/审计/图表（不重跑GPU或CSR）：

```bash
python3 tools/report_gpu_optimization.py results/coarsen-20261015/final-57
python3 tools/check_gpu_optimization.py results/coarsen-20261015/final-57
/tmp/g_partition_plot_env/bin/python tools/plot_gpu_optimization.py results/coarsen-20261015/final-57
```

没有提交、推送或上传数据/二进制。CPU baseline旧任务已结束；旧接续记录中的暂停/恢复PID仅属历史，不能再发信号或启动重复任务。
