# 实验结果表格索引

2026-10-19 **CPU新批次（运行中）**：按51图×k4/8/16/32/64×3次，先运行[Mt-METIS默认greedy](cpu-default-mtkahip-20261019/mtmetis-greedy/runs.csv)，再运行mt-KaHIP官方multitrysocialparallel，后者结果将在`cpu-default-mtkahip-20261019/mtkahip-mls/`产生。原HS数据保持；各批`coverage.csv`记录完成与失败，原始命令、日志、二进制、核验和队列状态保存在同名archive目录。

2026-10-19 **第三方 iG-kway 全图入口测试（完成）**：[逐配置结果](igkway-thirdparty-failed/results.csv)、[失败记录](igkway-thirdparty-failed/failed.csv)。测试原G-kway失败的59个配置：47个核验输出、12个粗化非法访存失败（com-LiveJournal/soc-LiveJournal1各6个k）。原源码未修改；诊断确认默认粗化停止条件会丢弃首层，ppa/soc-Pokec最终标签与原图BFS一致，不能作为完整多层G-kway成绩。[切边对照](igkway-thirdparty-failed/comparison.csv)使用既有Jet/CPU表。不属于作者官方baseline，不合并到data。


2026-10-18 **G-kway全选集排查（完成）**：[逐配置结果](gkway-paper/results.csv)、[失败清单](gkway-paper/failed.csv)、[九类覆盖](gkway-paper/categories.csv)。51图×k2/4/8/16/32/64，论文阈值，每配置一次，超载保留，OOM后排除该图后续配置。共306配置全部结束，247份有效输出（含114份超载），59次运行错误；41图全部k成功、ppa仅k2成功、9图全部失败。入口 `./run_gkway.sh` 支持续跑。

2026-10-18 **G-kway论文阈值对照（完成）**：[逐次结果](manual/gkway-paper-threshold-20261018/runs.csv)、[逐配置比较](manual/gkway-paper-threshold-20261018/comparison.csv)。四图×k8/32，新旧阈值、Acc-GP、Jet交错各三次，共96次。84份有效输出；soc-Pokec新旧阈值共12次失败，其他配置全部三次有效。[运行覆盖](manual/gkway-paper-threshold-20261018/coverage.csv)。超载保留，崩溃不计性能。

2026-10-18 **G-kway公开代码初筛已按用户要求停止**：[状态](manual/gkway-current-20261018/STATUS.csv)、[部分逐次结果](manual/gkway-current-20261018/runs.csv)、[部分比较表](manual/gkway-current-20261018/comparison.csv)。仅记录95/243槽位，不代表完整九类实验；k128共享内存越界已用Compute Sanitizer确认，soc-Pokec k8/32非法访问。原依赖恢复前的初测已撤回，不用于正式比较。

2026-10-18 **三方法基线统一汇总**：按用户要求集中到 [data/README.md](../data/README.md)，含全部306个配置的Markdown表及 [并列CSV](../data/baselines.csv)、[逐次CSV](../data/runs.csv)、[缺项](../data/missing.csv)、[来源](../data/sources.csv)。范围为当前51图×k4/8/16/32/64/128；KaMinPar和Jet各306配置三次齐全，Mt-METIS303配置有输出、293配置三次齐全。按已有输出分别取cut/时间中位数，保留超载标记；仅整理既有数据，原始记录未迁移或重测。

2026-10-18 **CPU最低覆盖追加重试**：[逐图/k最低覆盖](cpu-minimum-coverage-20261018/minimum-coverage.csv)、[本轮15次失败](cpu-minimum-coverage-20261018/native-retries.csv)。编译结束后恢复原HS/T32/seed0，kmer_U1a的k32/64/128各重试5次，全部SIGSEGV，零新增性能/切边数据。当前KaMinPar357/357配置有结果、Mt-METIS354/357；其余三个仍缺。已有结果未改，崩溃墙钟不计入加速比。此前中止的quality-only运行排除于正式统计。

2026-10-18 **Mt-METIS再次补跑已结束**：[逐配置补跑汇总](cpu-retry-20261018/summary.csv)、[本轮43次记录](cpu-retry-20261018/attempts.csv)。k64/128的30个缺项补出14份，旧k2–32的13个缺项补出5份；总共补出19份（4容量合格/15超载），24份仍退出-11。按用户要求保留超载cut；既有核验结果和KaMinPar1071份全部保持不变。剩余失败集中在soc-Pokec、com-LiveJournal、soc-LiveJournal1、kmer_V2a、kmer_U1a五图，具体k/repeat见汇总。全部新输出核验后删除标签，前后快照及审计存archive/experiments/cpu-retry-20261018。以下旧补跑统计为历史批次；当前高k/低k原目录的表格已刷新。

2026-10-18 **按用户要求忽略容量超限，仅比cut**：[逐图切边及实际重复数](manual/cpu-cut-comparison-20261018/comparison-ignore-balance.csv)、[九类汇总](manual/cpu-cut-comparison-20261018/categories-ignore-balance.csv)。当前17图k128：对KaMinPar 13/17更低，逐图比值均值0.966136；对Mt-METIS 11/16更低，均值0.947617（本轮重跑后）。Mt-METIS的kmer_U1a无输出不计；soc-Pokec和kmer_V2a各2次，kron20已补齐3次，按已有核验输出取中位数，其余各3次。保留超载cut，未把崩溃视作零cut；原严格容量比较表不覆盖。

2026-10-18 **当前版对CPU切边比较**：[17图k128逐图结果与容量状态](manual/cpu-cut-comparison-20261018/comparison.csv)、[九类汇总](manual/cpu-cut-comparison-20261018/categories.csv)。当前f35523a9 GPU记录（每图3/5次中位数）与已完成的CPU高k批次（三次中位数）对齐，不混入旧GPU版本。对KaMinPar：17图13低4高，逐图cut比算术平均0.966136（少3.3864%），道路road_usa多27.64%。对Mt-METIS：只有road_usa/grid三次都容量合格，我们分别多1.2458%/9.9579%；其余不计入同约束汇总，完整但超载的结果仅列诊断比值。类别图数分别1/1/4/1/3/1/4/1/1，不能外推全51图或其他k。来源哈希/核验范围存archive的cpu-cut-comparison-20261018/audit.json。

2026-10-18 **CPU旧实验补缺**：[完成/超载/缺项表](cpu-baselines-20261018/completed-k2-k32/coverage.csv)、[全部尝试记录](cpu-baselines-20261018/completed-k2-k32/attempts.csv)、[Mt-METIS中位数](cpu-baselines-20261018/completed-k2-k32/tables/mtmetis/median.csv)、[KaMinPar中位数](cpu-baselines-20261018/completed-k2-k32/tables/kaminpar/median.csv)。当前51图k2/4/8/16/32×三重复×两方法共1530槽位，复用1504份核验结果，仅对26个Mt-METIS崩溃缺项做两轮共43次补跑：补出13份（3份容量合格、10份超载），13份仍SIGSEGV。最终KaMinPar765份全部容量合格；Mt-METIS752份输出中452份合格、300份超载，剩余13份无结果。attempts保留所有失败；不是全套重新测量，不筛掉超载或挑最好的一次。

**CPU高k入口检查**：[fe_rotor k64/128](cpu-baselines-20261018/k64-k128-smoke/coverage.csv)。真实两方法各一次，共4份核验输出；KaMinPar合格，Mt-METIS最大负载比分别1.0453/1.0948，均超限。该条为入口检查时状态；随后读取用户全量运行结果，612次已全部尝试，KaMinPar306次均合格，Mt-METIS75合格/201超限/30崩溃，见[高k覆盖表](cpu-baselines/k64-k128/coverage.csv)。入口为`./run_cpu_baselines.sh`，默认输出`results/cpu-baselines/k64-k128/`，支持续跑。

2026-10-18 **当前完整覆盖f35523a9**：[17图逐配置速度和切边比](manual/weak3-arena-all-20261018/comparison.csv)、[九类汇总](manual/weak3-arena-all-20261018/categories.csv)、[九类原代表图](manual/weak3-arena-all-20261018/representatives.csv)、[171份逐次](manual/weak3-arena-all-20261018/runs.csv)。全为k128；重点三图五重复、另14图三重复，每图方法交错且同一卡。三类全部11张已选图10快1慢，对修改前1.08950×、cut均比1.00160；全部17图16快1慢，对修改前1.11149×、cut均比1.00210，对Jet1.59164×、cut均比1.03111。4配置仍不足Jet1.2×，stokes不足1.15×；最坏cut回退vas_stokes_2M+2.064%，不隐去负结果。所有171份独立cut/容量核验通过、标签删除，无新增OOM。六个其他类别仅一图，不是全选集。sources.csv给出原批次；合并表是只读汇总，非run.sh续跑目录。原[14图覆盖批](manual/weak3-arena-coverage-20261018/comparison.csv)可单独重分析。

[最终显存/API剖析](manual/weak3-gpu-profile-20261017/arena-memory.csv)：三弱图各before/arena一份，6份全核验。native分配API分别77.62→34.46、70.35→30.20、60.79→36.14ms。trace峰值stokes近似不变，nlpkkt200/kmer_V2a约增加1.1GiB（不含上下文/驱动开销）。这是诊断，不是原生加速比；[API细目](manual/weak3-gpu-profile-20261017/arena-allocation-api.csv)、[内核](manual/weak3-gpu-profile-20261017/arena-kernels.csv)。

2026-10-18 当前arena版f35523a9（三张弱图k128×5×3方法45份全核验）：[逐配置时间及cut](manual/weak3-arena-20261017/comparison.csv)、[逐次阶段](manual/weak3-arena-20261017/runs.csv)。相对本轮修改前4ba62d9e总体1.13227×，cut均比1.000415；对Jet1.17435×、cut均比1.02857，三图均仍未达到1.2×。覆盖补测另列，不把三张图外推为整个类别。

中间的有效隔离版本：[仅内核执行修改f69bc05e](manual/weak3-clean-final-20261017/comparison.csv)，总体1.01207×；[大小分流分配9c7759f8](manual/weak3-allocation-20261017/comparison.csv)，总体1.03134×。这两版已被统一arena替代；不是相互可叠加的收益。

**构建身份撤回：** `weak3-coarse-20261017`及`weak3-warp-final-20261017`恢复文件时保留旧时间戳，增量构建遗漏撤回源码；冻结二进制的cut/容量核验有效，但不能代表其源码快照，也不是当前版本成绩。各目录IDENTITY.csv保留说明；最终候选已改为clean-first全量重建后重新测量。

2026-10-17 三张弱图k128执行优化筛选（对照均为冻结的当前单主线4ba62d9e）：[线程组/亲和力负结果](manual/weak3-affinity-20261017/comparison.csv)、[接收重试枚举负结果](manual/weak3-retry-20261017/comparison.csv)、[粗化warp聚合负结果](manual/weak3-coarse-20261017/comparison.csv)。分别45/30/30份原生输出均独立核验，三版整体速度均未改善，相应路径已撤回；不是最终新版本成绩。其中coarse试验发现旧对象遗留，不作为单项归因证据。[内核剖析表](manual/weak3-gpu-profile-20261017/kernels.csv)是单条轨迹的Nsight Systems统计，不是原生加速比。Nsight Compute因GPU计数器权限不足未取得指标。

2026-10-17 此前唯一细化主线4ba62d9e（LP＋容量互补交换、单计划）：[九类k128逐配置速度及切边比](manual/capacity-exchange-final-20261017/comparison.csv)、[九类表](manual/capacity-exchange-final-20261017/categories.csv)、[逐次阶段](manual/capacity-exchange-final-20261017/runs.csv)。81份全核验，相对旧legacy1.03978×/cut比1.00069，8/9更快；相对Jet1.39697×/cut比1.04912。

[四图两k单计划对旧双计划](manual/capacity-exchange-single-plan-20261017/comparison.csv)：48份全核验，速度0.99575×、cut比0.99174；5/8更快且5/8切边降低，但整体速度未改善。两批均三次固定seed0，不是51图全集/多种子结果。所有下方legacy默认/候选开关描述属于历史版本。

2026-10-17 当前27e8d83f容量互补预算版（默认仍legacy）：[九类k128逐配置速度与cut比](manual/joint-complement-final-20261017/comparison.csv)、[九类汇总](manual/joint-complement-final-20261017/categories.csv)、[逐次/阶段](manual/joint-complement-final-20261017/runs.csv)。81份输出全部核验；对legacy速度1.03005×、cut比1.00288，对Jet1.37067×、cut比1.04514，三张弱图未达1.15×。不是八个社会图/51图全集。

[同binary四图两k互补开关消融](manual/joint-complement-ablation-20261017/comparison.csv)：48份核验，对旧joint速度0.98127×、cut比0.99626；质量小幅改善但额外耗时约1.91%，不能将九类整版对legacy的3%算作此机制贡献。

[Sparse 2–8键增量独立消融](manual/sparse-delta-bounded-20261017/comparison.csv)：18份核验，stokes/nlpkkt200/kmer_V2a速度1.06640/0.98951/1.01879×；仍默认关闭。[同版本stokes剖析](manual/sparse-delta-profile-20261017/profile.csv)显示重建减少但查键/原子更新与清理开销增加，三项维护核合计基本持平；不是原生时间。

2026-10-17 容量互补细化研究：[首版同LP检查点](manual/joint-complement-fixed-20261017/fixed_lp.csv)、[首版阶段计数](manual/joint-complement-fixed-20261017/stages.csv)、[四图原生负结果](manual/joint-complement-screen-20261017/comparison.csv)。首版八状态档案局部20/33单批改善，但原生平均慢约2.8%、cut基本持平，未提升默认。

四点预算修复版：[同LP检查点](manual/joint-complement-fixed-final-20261017/fixed_lp.csv)、[阶段计数](manual/joint-complement-fixed-final-20261017/stages.csv)。33检查点单批20好13同0差，两批21好10同2差。空档案分支修复前中止的[不完整记录](manual/joint-complement-bounded-20261017/comparison.csv)仅用于保留失败历史，不是性能证据。

Sparse增量维护的[首版独立初筛](manual/sparse-delta-screen-20261017/comparison.csv)：三图k128五重复，stokes基本持平、nlpkkt200/kmer_V2a变慢，默认关闭。原始版本、核验及日志在archive/experiments/joint-complement-20261017。

2026-10-17 GPU查询/缓存最终版c5c69063（legacy默认，九类各一图×k128×5次×3方法，135份全核验）：[逐配置速度与cut](manual/gpu-execution-final-20261017/comparison.csv)、[九类](manual/gpu-execution-final-20261017/categories.csv)、[逐次与阶段](manual/gpu-execution-final-20261017/runs.csv)。reference是同binary关闭repair enumeration和cut布局资格。相对reference1.06756×、平均cut比0.99824；相对Jet1.39811×、cut比1.04417；8快1慢，三张弱图仍不足Jet1.15×。社会网络仅soc-Pokec，本轮不是51图全集。

k8/64补充回归（相同c5c69063，三图×两k×3次×三方法，54份全核验）：[逐配置](manual/gpu-execution-k8k64-20261017/comparison.csv)、[分类](manual/gpu-execution-k8k64-20261017/categories.csv)、[逐次/阶段](manual/gpu-execution-k8k64-20261017/runs.csv)。对reference1.01284×、cut均比0.99946；3快3慢，最坏回退约0.69%，不与九类k128合并。

最终c5c69063的[stokes同binary Nsight对照](manual/gpu-execution-profile-20261017/profile.csv)：修复提案68.5→16.4ms，LP提案35.9→12.3ms，亲和力构建/重建15.9→48.1ms；调用数不同。单次剖析只用于定位，排序与池API仍有开销，不代替原生加速比。

本轮前置实验分别保留：[无CDF查询初筛](manual/repair-enumeration-screen-20261017/comparison.csv)、[查询＋CDF九类测试](manual/repair-enumeration-final-20261017/comparison.csv)、[Sparse资格单独初筛](manual/affinity-cut-bound-screen-20261017/comparison.csv)、[旧/查询CDF版本Nsight指标](manual/repair-enumeration-profile-20261017/profile.csv)。各自有独立冻结版本，不能把倍数相乘或作为最终版成绩；原始剖析在archive，profiling时间不代替native。

2026-10-17 筛选开关效果补测（九类各一图×k8/128×5次×四方法，共360份全核验）：[逐配置](manual/joint-filter-effects-20261017/comparison.csv)、[九类速度与cut比](manual/joint-filter-effects-20261017/categories.csv)、[逐次/阶段](manual/joint-filter-effects-20261017/runs.csv)。ours=只开冲突3轮，dedup=只去重，reference=冻结原joint-polish 75c4b698，jet=同批Jet。去重/冲突速度0.99983×/0.99607×、cut比0.99959/1.00132，未提升默认。固定4图两k、55个共同LP状态的[165份核验结果](manual/joint-filter-effects-20261017/fixed_lp.csv)与[330批筛选计数](manual/joint-filter-effects-20261017/fixed_lp_stages.csv)：去重全部同标签；冲突15处好、34同、6差。原始材料在archive/experiments/joint-filter-effects-20261017；不是52图六k全集。

2026-10-17 新双向组候选（joint-polish，2批，九类各一图×k8/128×3次，162份输出全核验）：[逐配置](manual/joint-final-20261017/comparison.csv)、[九类速度和切边比](manual/joint-final-20261017/categories.csv)、[逐次及阶段](manual/joint-final-20261017/runs.csv)。对本轮前dd536dfc总体1.04118×、cut比1.00724；对Jet1.42366×、cut比1.06979。路网cut退步约5%，未替换默认。独立joint首版失败和32种子组合初筛分别见[独立失败记录](manual/joint-pilot-20261017/comparison.csv)、[组合初筛](manual/joint-polish-pilot-20261017/comparison.csv)，不混入最终表格。


2026-10-17 当前row512（九类各一图、k8/128，162份全核验）：[逐配置速度/cut](manual/row512-final-20261017/comparison.csv)、[九类](manual/row512-final-20261017/categories.csv)、[逐次/阶段](manual/row512-final-20261017/runs.csv)。对本轮前4cb8bb4d总体1.02313×、cut比0.99887；对Jet1.37390×、cut比1.06259，5/18仍不足1.15×。测量standard=f316f4c7。8/32搬运候选未获完整收益、已撤回：[五重复负结果](manual/row512-width-screen-20261017/comparison.csv)。

2026-10-17 此前regret容量证明版本（九类各一图，仅k128，81份全核验）：[逐图速度/cut比](manual/regret-capacity-proof-20261017/comparison.csv)、[九类](manual/regret-capacity-proof-20261017/categories.csv)、[逐次/阶段](manual/regret-capacity-proof-20261017/runs.csv)。相对冻结regret总体0.99513×、cut比0.99783，尚无整体提速；相对Jet1.29500×、cut比1.04085，3/9低于1.15×。当前standard SHA256前缀4cb8bb4d。

此前仅缓冲复用/two-hop步骤的同规模81条结果：[逐图](manual/regret-mainline-20261017/comparison.csv)、[九类](manual/regret-mainline-20261017/categories.csv)、[逐次](manual/regret-mainline-20261017/runs.csv)。相对冻结regret0.97990×，负结果保留，不混入当前版。

2026-10-17 regret-v1九类代表图筛选（9图×6k×3方法×3次，非52图全集）：[逐图逐k](manual/regret-20261017/comparison.csv)、[九类切边与速度](manual/regret-20261017/categories.csv)、[逐次与阶段](manual/regret-20261017/runs.csv)。全部486份独立核验通过；相对residual总体0.9922×、平均cut比0.99545，当时未推广默认；随后按用户决定作为研究主线，不改变该负结果。

## 用户运行：residual-v1，20261016-211749

2026-10-17核对完成：52图×6k×3方法×3次，2808份输出全部独立核验通过。ours/legacy为同一standard二进制的新旧粗化模式，Jet单独基线。相对legacy总体仅1.012×且157配置变慢；不要把1.521×相对Jet全归因于本次粗化。

- [逐配置加速比与切边比](manual/20261016-211749/comparison.csv)
- [九类汇总](manual/20261016-211749/categories.csv)
- [逐次核验及阶段耗时](manual/20261016-211749/runs.csv)

本目录只保留CSV与表格报告。逐图逐k的速度和cut见各批次表；局部初筛、历史正式与筛选视图不能混算。原始指标、核验和版本材料位于[仓库外归档](../../Acc-GP-archive/README.md)，标签已删除。

其他历史批次：

- [unit局部速度表](refactor-speed-20261016/unit-screen/SPEEDUP.md) / [切边比值](refactor-speed-20261016/unit-screen/CUT_RATIOS.md)：6图×k8/32/128局部初筛，不是52图完整矩阵。
- [旧57图正式结果](coarsen-20261015/final-57/REPORT.md)：旧80145dbb版本。
- [52图旧记录筛选视图](refactor-speed-20261016/baseline-52/SPEEDUP.md)：不是新测量。
- [CPU全集七列表](cpu-baselines-20261014/full-suite/REPORT.md)：历史1950次对照。

下表历史批次的runs.csv为补导出的逐次测量，保留失败/未核验状态；空白数值表示记录中没有该指标。原有summary/case表的口径保持，不从runs.csv重新挑选成绩。

| 表格 | 数据行数 | 说明 |
| --- | ---: | --- |
| [categories-20261015/REPORT.md](categories-20261015/REPORT.md) | — | 表格报告 |
| [categories-20261015/cases.csv](categories-20261015/cases.csv) | 342 | 结果/汇总 |
| [categories-20261015/categories.csv](categories-20261015/categories.csv) | 9 | 结果/汇总 |
| [categories-20261015/graphs.csv](categories-20261015/graphs.csv) | 60 | 结果/汇总 |
| [categories-20261015/runs.csv](categories-20261015/runs.csv) | 2070 | 逐次记录 |
| [categories-20261015/screen/REPORT.md](categories-20261015/screen/REPORT.md) | — | 表格报告 |
| [categories-20261015/screen/cases.csv](categories-20261015/screen/cases.csv) | 171 | 结果/汇总 |
| [categories-20261015/screen/categories.csv](categories-20261015/screen/categories.csv) | 9 | 结果/汇总 |
| [categories-20261015/screen/graphs.csv](categories-20261015/screen/graphs.csv) | 60 | 结果/汇总 |
| [categories-20261015/screen/runs.csv](categories-20261015/screen/runs.csv) | 360 | 逐次记录 |
| [categories-20261015/screen/stages.csv](categories-20261015/screen/stages.csv) | 116 | 结果/汇总 |
| [categories-20261015/stages.csv](categories-20261015/stages.csv) | 116 | 结果/汇总 |
| [categories-20261015/superseded-screen/runs.csv](categories-20261015/superseded-screen/runs.csv) | 6 | 逐次记录 |
| [coarsen-20261015/admission-screen/runs.csv](coarsen-20261015/admission-screen/runs.csv) | 180 | 逐次记录 |
| [coarsen-20261015/baseline-57/REPORT.md](coarsen-20261015/baseline-57/REPORT.md) | — | 表格报告 |
| [coarsen-20261015/baseline-57/cases.csv](coarsen-20261015/baseline-57/cases.csv) | 342 | 结果/汇总 |
| [coarsen-20261015/baseline-57/categories.csv](coarsen-20261015/baseline-57/categories.csv) | 9 | 结果/汇总 |
| [coarsen-20261015/baseline-57/graphs.csv](coarsen-20261015/baseline-57/graphs.csv) | 57 | 结果/汇总 |
| [coarsen-20261015/baseline-57/runs.csv](coarsen-20261015/baseline-57/runs.csv) | 2052 | 逐次记录 |
| [coarsen-20261015/baseline-57/stages.csv](coarsen-20261015/baseline-57/stages.csv) | 114 | 结果/汇总 |
| [coarsen-20261015/final-57/REPORT.md](coarsen-20261015/final-57/REPORT.md) | — | 表格报告 |
| [coarsen-20261015/final-57/jet-slower.csv](coarsen-20261015/final-57/jet-slower.csv) | 12 | 结果/汇总 |
| [coarsen-20261015/final-57/optimization-cases.csv](coarsen-20261015/final-57/optimization-cases.csv) | 342 | 结果/汇总 |
| [coarsen-20261015/final-57/optimization-categories.csv](coarsen-20261015/final-57/optimization-categories.csv) | 9 | 结果/汇总 |
| [coarsen-20261015/final-57/optimization-graphs.csv](coarsen-20261015/final-57/optimization-graphs.csv) | 57 | 结果/汇总 |
| [coarsen-20261015/final-57/optimization-stages.csv](coarsen-20261015/final-57/optimization-stages.csv) | 171 | 结果/汇总 |
| [coarsen-20261015/final-57/regressions.csv](coarsen-20261015/final-57/regressions.csv) | 55 | 结果/汇总 |
| [coarsen-20261015/final-57/runs.csv](coarsen-20261015/final-57/runs.csv) | 3078 | 逐次记录 |
| [coarsen-20261015/hem-screen/optimization-cases.csv](coarsen-20261015/hem-screen/optimization-cases.csv) | 11 | 结果/汇总 |
| [coarsen-20261015/hem-screen/optimization-categories.csv](coarsen-20261015/hem-screen/optimization-categories.csv) | 4 | 结果/汇总 |
| [coarsen-20261015/hem-screen/optimization-graphs.csv](coarsen-20261015/hem-screen/optimization-graphs.csv) | 4 | 结果/汇总 |
| [coarsen-20261015/hem-screen/runs.csv](coarsen-20261015/hem-screen/runs.csv) | 68 | 逐次记录 |
| [coarsen-20261015/hem64-quick/optimization-cases.csv](coarsen-20261015/hem64-quick/optimization-cases.csv) | 4 | 结果/汇总 |
| [coarsen-20261015/hem64-quick/optimization-categories.csv](coarsen-20261015/hem64-quick/optimization-categories.csv) | 4 | 结果/汇总 |
| [coarsen-20261015/hem64-quick/optimization-graphs.csv](coarsen-20261015/hem64-quick/optimization-graphs.csv) | 4 | 结果/汇总 |
| [coarsen-20261015/hem64-quick/runs.csv](coarsen-20261015/hem64-quick/runs.csv) | 12 | 逐次记录 |
| [coarsen-20261015/pool-screen/optimization-cases.csv](coarsen-20261015/pool-screen/optimization-cases.csv) | 30 | 结果/汇总 |
| [coarsen-20261015/pool-screen/optimization-categories.csv](coarsen-20261015/pool-screen/optimization-categories.csv) | 6 | 结果/汇总 |
| [coarsen-20261015/pool-screen/optimization-graphs.csv](coarsen-20261015/pool-screen/optimization-graphs.csv) | 10 | 结果/汇总 |
| [coarsen-20261015/pool-screen/runs.csv](coarsen-20261015/pool-screen/runs.csv) | 180 | 逐次记录 |
| [coarsen-20261015/rows-screen/runs.csv](coarsen-20261015/rows-screen/runs.csv) | 180 | 逐次记录 |
| [coarsen-20261015/warp-screen/optimization-cases.csv](coarsen-20261015/warp-screen/optimization-cases.csv) | 30 | 结果/汇总 |
| [coarsen-20261015/warp-screen/optimization-categories.csv](coarsen-20261015/warp-screen/optimization-categories.csv) | 7 | 结果/汇总 |
| [coarsen-20261015/warp-screen/optimization-graphs.csv](coarsen-20261015/warp-screen/optimization-graphs.csv) | 10 | 结果/汇总 |
| [coarsen-20261015/warp-screen/optimization-stages.csv](coarsen-20261015/warp-screen/optimization-stages.csv) | 30 | 结果/汇总 |
| [coarsen-20261015/warp-screen/runs.csv](coarsen-20261015/warp-screen/runs.csv) | 180 | 逐次记录 |
| [cpu-baselines-20261014/full-suite/REPORT.md](cpu-baselines-20261014/full-suite/REPORT.md) | — | 表格报告 |
| [cpu-baselines-20261014/full-suite/runs.csv](cpu-baselines-20261014/full-suite/runs.csv) | 1950 | 逐次记录 |
| [cpu-baselines-20261014/full-suite/tables/README.md](cpu-baselines-20261014/full-suite/tables/README.md) | — | 表格报告 |
| [cpu-baselines-20261014/full-suite/tables/kaminpar/median.csv](cpu-baselines-20261014/full-suite/tables/kaminpar/median.csv) | 325 | 结果/汇总 |
| [cpu-baselines-20261014/full-suite/tables/kaminpar/median.md](cpu-baselines-20261014/full-suite/tables/kaminpar/median.md) | — | 表格报告 |
| [cpu-baselines-20261014/full-suite/tables/kaminpar/run1.csv](cpu-baselines-20261014/full-suite/tables/kaminpar/run1.csv) | 325 | 结果/汇总 |
| [cpu-baselines-20261014/full-suite/tables/kaminpar/run1.md](cpu-baselines-20261014/full-suite/tables/kaminpar/run1.md) | — | 表格报告 |
| [cpu-baselines-20261014/full-suite/tables/kaminpar/run2.csv](cpu-baselines-20261014/full-suite/tables/kaminpar/run2.csv) | 325 | 结果/汇总 |
| [cpu-baselines-20261014/full-suite/tables/kaminpar/run2.md](cpu-baselines-20261014/full-suite/tables/kaminpar/run2.md) | — | 表格报告 |
| [cpu-baselines-20261014/full-suite/tables/kaminpar/run3.csv](cpu-baselines-20261014/full-suite/tables/kaminpar/run3.csv) | 325 | 结果/汇总 |
| [cpu-baselines-20261014/full-suite/tables/kaminpar/run3.md](cpu-baselines-20261014/full-suite/tables/kaminpar/run3.md) | — | 表格报告 |
| [cpu-baselines-20261014/full-suite/tables/mtmetis/median.csv](cpu-baselines-20261014/full-suite/tables/mtmetis/median.csv) | 325 | 结果/汇总 |
| [cpu-baselines-20261014/full-suite/tables/mtmetis/median.md](cpu-baselines-20261014/full-suite/tables/mtmetis/median.md) | — | 表格报告 |
| [cpu-baselines-20261014/full-suite/tables/mtmetis/run1.csv](cpu-baselines-20261014/full-suite/tables/mtmetis/run1.csv) | 325 | 结果/汇总 |
| [cpu-baselines-20261014/full-suite/tables/mtmetis/run1.md](cpu-baselines-20261014/full-suite/tables/mtmetis/run1.md) | — | 表格报告 |
| [cpu-baselines-20261014/full-suite/tables/mtmetis/run2.csv](cpu-baselines-20261014/full-suite/tables/mtmetis/run2.csv) | 325 | 结果/汇总 |
| [cpu-baselines-20261014/full-suite/tables/mtmetis/run2.md](cpu-baselines-20261014/full-suite/tables/mtmetis/run2.md) | — | 表格报告 |
| [cpu-baselines-20261014/full-suite/tables/mtmetis/run3.csv](cpu-baselines-20261014/full-suite/tables/mtmetis/run3.csv) | 325 | 结果/汇总 |
| [cpu-baselines-20261014/full-suite/tables/mtmetis/run3.md](cpu-baselines-20261014/full-suite/tables/mtmetis/run3.md) | — | 表格报告 |
| [cpu-baselines-20261014/products/REPORT.md](cpu-baselines-20261014/products/REPORT.md) | — | 表格报告 |
| [cpu-baselines-20261014/products/runs.csv](cpu-baselines-20261014/products/runs.csv) | 30 | 逐次记录 |
| [cpu-baselines-20261014/products/tables/README.md](cpu-baselines-20261014/products/tables/README.md) | — | 表格报告 |
| [cpu-baselines-20261014/products/tables/kaminpar/median.csv](cpu-baselines-20261014/products/tables/kaminpar/median.csv) | 5 | 结果/汇总 |
| [cpu-baselines-20261014/products/tables/kaminpar/median.md](cpu-baselines-20261014/products/tables/kaminpar/median.md) | — | 表格报告 |
| [cpu-baselines-20261014/products/tables/kaminpar/run1.csv](cpu-baselines-20261014/products/tables/kaminpar/run1.csv) | 5 | 结果/汇总 |
| [cpu-baselines-20261014/products/tables/kaminpar/run1.md](cpu-baselines-20261014/products/tables/kaminpar/run1.md) | — | 表格报告 |
| [cpu-baselines-20261014/products/tables/kaminpar/run2.csv](cpu-baselines-20261014/products/tables/kaminpar/run2.csv) | 5 | 结果/汇总 |
| [cpu-baselines-20261014/products/tables/kaminpar/run2.md](cpu-baselines-20261014/products/tables/kaminpar/run2.md) | — | 表格报告 |
| [cpu-baselines-20261014/products/tables/kaminpar/run3.csv](cpu-baselines-20261014/products/tables/kaminpar/run3.csv) | 5 | 结果/汇总 |
| [cpu-baselines-20261014/products/tables/kaminpar/run3.md](cpu-baselines-20261014/products/tables/kaminpar/run3.md) | — | 表格报告 |
| [cpu-baselines-20261014/products/tables/mtmetis/median.csv](cpu-baselines-20261014/products/tables/mtmetis/median.csv) | 5 | 结果/汇总 |
| [cpu-baselines-20261014/products/tables/mtmetis/median.md](cpu-baselines-20261014/products/tables/mtmetis/median.md) | — | 表格报告 |
| [cpu-baselines-20261014/products/tables/mtmetis/run1.csv](cpu-baselines-20261014/products/tables/mtmetis/run1.csv) | 5 | 结果/汇总 |
| [cpu-baselines-20261014/products/tables/mtmetis/run1.md](cpu-baselines-20261014/products/tables/mtmetis/run1.md) | — | 表格报告 |
| [cpu-baselines-20261014/products/tables/mtmetis/run2.csv](cpu-baselines-20261014/products/tables/mtmetis/run2.csv) | 5 | 结果/汇总 |
| [cpu-baselines-20261014/products/tables/mtmetis/run2.md](cpu-baselines-20261014/products/tables/mtmetis/run2.md) | — | 表格报告 |
| [cpu-baselines-20261014/products/tables/mtmetis/run3.csv](cpu-baselines-20261014/products/tables/mtmetis/run3.csv) | 5 | 结果/汇总 |
| [cpu-baselines-20261014/products/tables/mtmetis/run3.md](cpu-baselines-20261014/products/tables/mtmetis/run3.md) | — | 表格报告 |
| [cpu-baselines-20261014/smoke-final/REPORT.md](cpu-baselines-20261014/smoke-final/REPORT.md) | — | 表格报告 |
| [cpu-baselines-20261014/smoke-final/runs.csv](cpu-baselines-20261014/smoke-final/runs.csv) | 10 | 逐次记录 |
| [cpu-baselines-20261014/smoke-runs/REPORT.md](cpu-baselines-20261014/smoke-runs/REPORT.md) | — | 表格报告 |
| [cpu-baselines-20261014/smoke-runs/runs.csv](cpu-baselines-20261014/smoke-runs/runs.csv) | 10 | 逐次记录 |
| [cpu-baselines-20261014/smoke-validated/REPORT.md](cpu-baselines-20261014/smoke-validated/REPORT.md) | — | 表格报告 |
| [cpu-baselines-20261014/smoke-validated/runs.csv](cpu-baselines-20261014/smoke-validated/runs.csv) | 10 | 逐次记录 |
| [gpu-optimization-20261014/boundary/runs.csv](gpu-optimization-20261014/boundary/runs.csv) | 72 | 逐次记录 |
| [gpu-optimization-20261014/metis/runs.csv](gpu-optimization-20261014/metis/runs.csv) | 28 | 逐次记录 |
| [gpu-optimization-20261014/metis16/runs.csv](gpu-optimization-20261014/metis16/runs.csv) | 40 | 逐次记录 |
| [gpu-optimization-20261014/persistent256/runs.csv](gpu-optimization-20261014/persistent256/runs.csv) | 28 | 逐次记录 |
| [gpu-optimization-20261014/profile-pool-stats_cuda_api_sum.csv](gpu-optimization-20261014/profile-pool-stats_cuda_api_sum.csv) | 35 | 历史剖析统计 |
| [gpu-optimization-20261014/profile-pool-stats_cuda_gpu_kern_sum.csv](gpu-optimization-20261014/profile-pool-stats_cuda_gpu_kern_sum.csv) | 146 | 历史剖析统计 |
| [gpu-optimization-20261014/profile-products-stats_cuda_api_sum.csv](gpu-optimization-20261014/profile-products-stats_cuda_api_sum.csv) | 35 | 历史剖析统计 |
| [gpu-optimization-20261014/profile-products-stats_cuda_gpu_kern_sum.csv](gpu-optimization-20261014/profile-products-stats_cuda_gpu_kern_sum.csv) | 146 | 历史剖析统计 |
| [gpu-optimization-20261014/region/runs.csv](gpu-optimization-20261014/region/runs.csv) | 11 | 逐次记录 |
| [gpu-optimization-20261014/resumed-jet-k2-128/REPORT.md](gpu-optimization-20261014/resumed-jet-k2-128/REPORT.md) | — | 表格报告 |
| [gpu-optimization-20261014/resumed-jet-k2-128/runs.csv](gpu-optimization-20261014/resumed-jet-k2-128/runs.csv) | 126 | 逐次记录 |
| [gpu-optimization-20261014/resumed-jet-k2-128/tables/jet/median.csv](gpu-optimization-20261014/resumed-jet-k2-128/tables/jet/median.csv) | 21 | 结果/汇总 |
| [gpu-optimization-20261014/resumed-jet-k2-128/tables/jet/median.md](gpu-optimization-20261014/resumed-jet-k2-128/tables/jet/median.md) | — | 表格报告 |
| [gpu-optimization-20261014/resumed-jet-k2-128/tables/jet/run1.csv](gpu-optimization-20261014/resumed-jet-k2-128/tables/jet/run1.csv) | 21 | 结果/汇总 |
| [gpu-optimization-20261014/resumed-jet-k2-128/tables/jet/run1.md](gpu-optimization-20261014/resumed-jet-k2-128/tables/jet/run1.md) | — | 表格报告 |
| [gpu-optimization-20261014/resumed-jet-k2-128/tables/jet/run2.csv](gpu-optimization-20261014/resumed-jet-k2-128/tables/jet/run2.csv) | 21 | 结果/汇总 |
| [gpu-optimization-20261014/resumed-jet-k2-128/tables/jet/run2.md](gpu-optimization-20261014/resumed-jet-k2-128/tables/jet/run2.md) | — | 表格报告 |
| [gpu-optimization-20261014/resumed-jet-k2-128/tables/jet/run3.csv](gpu-optimization-20261014/resumed-jet-k2-128/tables/jet/run3.csv) | 21 | 结果/汇总 |
| [gpu-optimization-20261014/resumed-jet-k2-128/tables/jet/run3.md](gpu-optimization-20261014/resumed-jet-k2-128/tables/jet/run3.md) | — | 表格报告 |
| [gpu-optimization-20261014/resumed-jet-k2-128/tables/ours/median.csv](gpu-optimization-20261014/resumed-jet-k2-128/tables/ours/median.csv) | 21 | 结果/汇总 |
| [gpu-optimization-20261014/resumed-jet-k2-128/tables/ours/median.md](gpu-optimization-20261014/resumed-jet-k2-128/tables/ours/median.md) | — | 表格报告 |
| [gpu-optimization-20261014/resumed-jet-k2-128/tables/ours/run1.csv](gpu-optimization-20261014/resumed-jet-k2-128/tables/ours/run1.csv) | 21 | 结果/汇总 |
| [gpu-optimization-20261014/resumed-jet-k2-128/tables/ours/run1.md](gpu-optimization-20261014/resumed-jet-k2-128/tables/ours/run1.md) | — | 表格报告 |
| [gpu-optimization-20261014/resumed-jet-k2-128/tables/ours/run2.csv](gpu-optimization-20261014/resumed-jet-k2-128/tables/ours/run2.csv) | 21 | 结果/汇总 |
| [gpu-optimization-20261014/resumed-jet-k2-128/tables/ours/run2.md](gpu-optimization-20261014/resumed-jet-k2-128/tables/ours/run2.md) | — | 表格报告 |
| [gpu-optimization-20261014/resumed-jet-k2-128/tables/ours/run3.csv](gpu-optimization-20261014/resumed-jet-k2-128/tables/ours/run3.csv) | 21 | 结果/汇总 |
| [gpu-optimization-20261014/resumed-jet-k2-128/tables/ours/run3.md](gpu-optimization-20261014/resumed-jet-k2-128/tables/ours/run3.md) | — | 表格报告 |
| [gpu-optimization-20261014/warp-ab/runs.csv](gpu-optimization-20261014/warp-ab/runs.csv) | 24 | 逐次记录 |
| [gpu-resident-20261015/byte-cache-screen/runs.csv](gpu-resident-20261015/byte-cache-screen/runs.csv) | 72 | 逐次记录 |
| [gpu-resident-20261015/direct-screen/runs.csv](gpu-resident-20261015/direct-screen/runs.csv) | 54 | 逐次记录 |
| [gpu-resident-20261015/k4-128-final/REPORT.md](gpu-resident-20261015/k4-128-final/REPORT.md) | — | 表格报告 |
| [gpu-resident-20261015/k4-128-final/case-medians.csv](gpu-resident-20261015/k4-128-final/case-medians.csv) | 54 | 结果/汇总 |
| [gpu-resident-20261015/k4-128-final/runs.csv](gpu-resident-20261015/k4-128-final/runs.csv) | 486 | 逐次记录 |
| [gpu-resident-20261015/k4-128-revised-final/REPORT.md](gpu-resident-20261015/k4-128-revised-final/REPORT.md) | — | 表格报告 |
| [gpu-resident-20261015/k4-128-revised-final/case-medians.csv](gpu-resident-20261015/k4-128-revised-final/case-medians.csv) | 54 | 结果/汇总 |
| [gpu-resident-20261015/k4-128-revised-final/runs.csv](gpu-resident-20261015/k4-128-revised-final/runs.csv) | 486 | 逐次记录 |
| [gpu-resident-20261015/lp-graph-screen/runs.csv](gpu-resident-20261015/lp-graph-screen/runs.csv) | 48 | 逐次记录 |
| [gpu-resident-20261015/precombine-screen/runs.csv](gpu-resident-20261015/precombine-screen/runs.csv) | 32 | 逐次记录 |
| [gpu-resident-20261015/radix-screen/runs.csv](gpu-resident-20261015/radix-screen/runs.csv) | 90 | 逐次记录 |
| [gpu-resident-20261015/subwarp-screen/runs.csv](gpu-resident-20261015/subwarp-screen/runs.csv) | 36 | 逐次记录 |
| [k512-optimization-20261015/adaptive-screen/runs.csv](k512-optimization-20261015/adaptive-screen/runs.csv) | 24 | 逐次记录 |
| [k512-optimization-20261015/bounded-pool-3repeat/runs.csv](k512-optimization-20261015/bounded-pool-3repeat/runs.csv) | 24 | 逐次记录 |
| [k512-optimization-20261015/bounded-pool-3repeat-valid/runs.csv](k512-optimization-20261015/bounded-pool-3repeat-valid/runs.csv) | 72 | 逐次记录 |
| [k512-optimization-20261015/bounded-pool-g8-screen/runs.csv](k512-optimization-20261015/bounded-pool-g8-screen/runs.csv) | 24 | 逐次记录 |
| [k512-optimization-20261015/capacity-g2-f64/runs.csv](k512-optimization-20261015/capacity-g2-f64/runs.csv) | 18 | 逐次记录 |
| [k512-optimization-20261015/capacity-g4-f16/runs.csv](k512-optimization-20261015/capacity-g4-f16/runs.csv) | 18 | 逐次记录 |
| [k512-optimization-20261015/capacity-g4-f64/runs.csv](k512-optimization-20261015/capacity-g4-f64/runs.csv) | 18 | 逐次记录 |
| [k512-optimization-20261015/capacity-g8-f64/runs.csv](k512-optimization-20261015/capacity-g8-f64/runs.csv) | 18 | 逐次记录 |
| [k512-optimization-20261015/donor-g8-screen/runs.csv](k512-optimization-20261015/donor-g8-screen/runs.csv) | 24 | 逐次记录 |
| [k512-optimization-20261015/driver-smoke-3repeat/runs.csv](k512-optimization-20261015/driver-smoke-3repeat/runs.csv) | 6 | 逐次记录 |
| [k512-optimization-20261015/frontier-512-screen/runs.csv](k512-optimization-20261015/frontier-512-screen/runs.csv) | 18 | 逐次记录 |
| [k512-optimization-20261015/frontier-screen/runs.csv](k512-optimization-20261015/frontier-screen/runs.csv) | 24 | 逐次记录 |
| [k512-optimization-20261015/k4-128-final/REPORT.md](k512-optimization-20261015/k4-128-final/REPORT.md) | — | 表格报告 |
| [k512-optimization-20261015/k4-128-final/case-medians.csv](k512-optimization-20261015/k4-128-final/case-medians.csv) | 54 | 结果/汇总 |
| [k512-optimization-20261015/k4-128-final/runs.csv](k512-optimization-20261015/k4-128-final/runs.csv) | 486 | 逐次记录 |
| [k512-optimization-20261015/pool-g8-screen/runs.csv](k512-optimization-20261015/pool-g8-screen/runs.csv) | 32 | 逐次记录 |
| [k512-optimization-20261015/queue-screen/runs.csv](k512-optimization-20261015/queue-screen/runs.csv) | 18 | 逐次记录 |
| [k512-optimization-20261015/raw-screen/runs.csv](k512-optimization-20261015/raw-screen/runs.csv) | 24 | 逐次记录 |
| [k512-optimization-20261015/small-k-g8-screen/runs.csv](k512-optimization-20261015/small-k-g8-screen/runs.csv) | 20 | 逐次记录 |
| [k512-optimization-20261015/small-k-pool-off/runs.csv](k512-optimization-20261015/small-k-pool-off/runs.csv) | 20 | 逐次记录 |
| [k512-optimization-20261015/small-k-pool-on/runs.csv](k512-optimization-20261015/small-k-pool-on/runs.csv) | 20 | 逐次记录 |
| [k512-optimization-20261015/sparse-screen/runs.csv](k512-optimization-20261015/sparse-screen/runs.csv) | 18 | 逐次记录 |
| [k512-optimization-20261015/wide-g8-screen/runs.csv](k512-optimization-20261015/wide-g8-screen/runs.csv) | 162 | 逐次记录 |
| [metis-production-20261014/REPORT.md](metis-production-20261014/REPORT.md) | — | 表格报告 |
| [metis-speed-20261014/baseline-profile-stats_cuda_api_sum.csv](metis-speed-20261014/baseline-profile-stats_cuda_api_sum.csv) | 35 | 历史剖析统计 |
| [metis-speed-20261014/baseline-profile-stats_cuda_gpu_kern_sum.csv](metis-speed-20261014/baseline-profile-stats_cuda_gpu_kern_sum.csv) | 117 | 历史剖析统计 |
| [metis-speed-20261014/baseline-screen/runs.csv](metis-speed-20261014/baseline-screen/runs.csv) | 54 | 逐次记录 |
| [metis-speed-20261014/budget8-screen/runs.csv](metis-speed-20261014/budget8-screen/runs.csv) | 5 | 逐次记录 |
| [metis-speed-20261014/candidate-screen/runs.csv](metis-speed-20261014/candidate-screen/runs.csv) | 54 | 逐次记录 |
| [metis-speed-20261014/deferred-profile-stats_cuda_api_sum.csv](metis-speed-20261014/deferred-profile-stats_cuda_api_sum.csv) | 37 | 历史剖析统计 |
| [metis-speed-20261014/deferred-profile-stats_cuda_gpu_kern_sum.csv](metis-speed-20261014/deferred-profile-stats_cuda_gpu_kern_sum.csv) | 120 | 历史剖析统计 |
| [metis-speed-20261014/deferred-screen/runs.csv](metis-speed-20261014/deferred-screen/runs.csv) | 54 | 逐次记录 |
| [metis-speed-20261014/execution-final/REPORT.md](metis-speed-20261014/execution-final/REPORT.md) | — | 表格报告 |
| [metis-speed-20261014/execution-final/case-medians.csv](metis-speed-20261014/execution-final/case-medians.csv) | 54 | 结果/汇总 |
| [metis-speed-20261014/execution-final/runs.csv](metis-speed-20261014/execution-final/runs.csv) | 486 | 逐次记录 |
| [metis-speed-20261014/execution-screen/runs.csv](metis-speed-20261014/execution-screen/runs.csv) | 36 | 逐次记录 |
| [metis-speed-20261014/final-profile-stats_cuda_api_sum.csv](metis-speed-20261014/final-profile-stats_cuda_api_sum.csv) | 35 | 历史剖析统计 |
| [metis-speed-20261014/final-profile-stats_cuda_gpu_kern_sum.csv](metis-speed-20261014/final-profile-stats_cuda_gpu_kern_sum.csv) | 120 | 历史剖析统计 |
| [metis-speed-20261014/memory-screen/runs.csv](metis-speed-20261014/memory-screen/runs.csv) | 54 | 逐次记录 |
| [metis-speed-20261014/progressive-final/REPORT.md](metis-speed-20261014/progressive-final/REPORT.md) | — | 表格报告 |
| [metis-speed-20261014/progressive-final/case-medians.csv](metis-speed-20261014/progressive-final/case-medians.csv) | 54 | 结果/汇总 |
| [metis-speed-20261014/progressive-final/runs.csv](metis-speed-20261014/progressive-final/runs.csv) | 486 | 逐次记录 |
| [metis-speed-20261014/progressive-profile-stats_cuda_api_sum.csv](metis-speed-20261014/progressive-profile-stats_cuda_api_sum.csv) | 37 | 历史剖析统计 |
| [metis-speed-20261014/progressive-profile-stats_cuda_gpu_kern_sum.csv](metis-speed-20261014/progressive-profile-stats_cuda_gpu_kern_sum.csv) | 120 | 历史剖析统计 |
| [metis-speed-20261014/progressive-screen/runs.csv](metis-speed-20261014/progressive-screen/runs.csv) | 54 | 逐次记录 |
| [refactor-speed-20261016/balance-screen/CUT_RATIOS.md](refactor-speed-20261016/balance-screen/CUT_RATIOS.md) | — | 表格报告 |
| [refactor-speed-20261016/balance-screen/SPEEDUP.md](refactor-speed-20261016/balance-screen/SPEEDUP.md) | — | 表格报告 |
| [refactor-speed-20261016/balance-screen/below-target.csv](refactor-speed-20261016/balance-screen/below-target.csv) | 8 | 结果/汇总 |
| [refactor-speed-20261016/balance-screen/optimization-cases.csv](refactor-speed-20261016/balance-screen/optimization-cases.csv) | 12 | 结果/汇总 |
| [refactor-speed-20261016/balance-screen/optimization-categories.csv](refactor-speed-20261016/balance-screen/optimization-categories.csv) | 5 | 结果/汇总 |
| [refactor-speed-20261016/balance-screen/optimization-graphs.csv](refactor-speed-20261016/balance-screen/optimization-graphs.csv) | 6 | 结果/汇总 |
| [refactor-speed-20261016/balance-screen/optimization-stages.csv](refactor-speed-20261016/balance-screen/optimization-stages.csv) | 18 | 结果/汇总 |
| [refactor-speed-20261016/balance-screen/runs.csv](refactor-speed-20261016/balance-screen/runs.csv) | 108 | 逐次记录 |
| [refactor-speed-20261016/baseline-52/CUT_RATIOS.md](refactor-speed-20261016/baseline-52/CUT_RATIOS.md) | — | 表格报告 |
| [refactor-speed-20261016/baseline-52/SPEEDUP.md](refactor-speed-20261016/baseline-52/SPEEDUP.md) | — | 表格报告 |
| [refactor-speed-20261016/baseline-52/below-target.csv](refactor-speed-20261016/baseline-52/below-target.csv) | 62 | 结果/汇总 |
| [refactor-speed-20261016/baseline-52/optimization-cases.csv](refactor-speed-20261016/baseline-52/optimization-cases.csv) | 312 | 结果/汇总 |
| [refactor-speed-20261016/baseline-52/optimization-categories.csv](refactor-speed-20261016/baseline-52/optimization-categories.csv) | 9 | 结果/汇总 |
| [refactor-speed-20261016/baseline-52/optimization-graphs.csv](refactor-speed-20261016/baseline-52/optimization-graphs.csv) | 52 | 结果/汇总 |
| [refactor-speed-20261016/baseline-52/optimization-stages.csv](refactor-speed-20261016/baseline-52/optimization-stages.csv) | 156 | 结果/汇总 |
| [refactor-speed-20261016/baseline-52/runs.csv](refactor-speed-20261016/baseline-52/runs.csv) | 2808 | 逐次记录 |
| [refactor-speed-20261016/beta32-screen/CUT_RATIOS.md](refactor-speed-20261016/beta32-screen/CUT_RATIOS.md) | — | 表格报告 |
| [refactor-speed-20261016/beta32-screen/SPEEDUP.md](refactor-speed-20261016/beta32-screen/SPEEDUP.md) | — | 表格报告 |
| [refactor-speed-20261016/beta32-screen/below-target.csv](refactor-speed-20261016/beta32-screen/below-target.csv) | 2 | 结果/汇总 |
| [refactor-speed-20261016/beta32-screen/optimization-cases.csv](refactor-speed-20261016/beta32-screen/optimization-cases.csv) | 3 | 结果/汇总 |
| [refactor-speed-20261016/beta32-screen/optimization-categories.csv](refactor-speed-20261016/beta32-screen/optimization-categories.csv) | 2 | 结果/汇总 |
| [refactor-speed-20261016/beta32-screen/optimization-graphs.csv](refactor-speed-20261016/beta32-screen/optimization-graphs.csv) | 3 | 结果/汇总 |
| [refactor-speed-20261016/beta32-screen/optimization-stages.csv](refactor-speed-20261016/beta32-screen/optimization-stages.csv) | 9 | 结果/汇总 |
| [refactor-speed-20261016/beta32-screen/runs.csv](refactor-speed-20261016/beta32-screen/runs.csv) | 27 | 逐次记录 |
| [refactor-speed-20261016/beta4-screen/CUT_RATIOS.md](refactor-speed-20261016/beta4-screen/CUT_RATIOS.md) | — | 表格报告 |
| [refactor-speed-20261016/beta4-screen/SPEEDUP.md](refactor-speed-20261016/beta4-screen/SPEEDUP.md) | — | 表格报告 |
| [refactor-speed-20261016/beta4-screen/below-target.csv](refactor-speed-20261016/beta4-screen/below-target.csv) | 7 | 结果/汇总 |
| [refactor-speed-20261016/beta4-screen/optimization-cases.csv](refactor-speed-20261016/beta4-screen/optimization-cases.csv) | 12 | 结果/汇总 |
| [refactor-speed-20261016/beta4-screen/optimization-categories.csv](refactor-speed-20261016/beta4-screen/optimization-categories.csv) | 4 | 结果/汇总 |
| [refactor-speed-20261016/beta4-screen/optimization-graphs.csv](refactor-speed-20261016/beta4-screen/optimization-graphs.csv) | 6 | 结果/汇总 |
| [refactor-speed-20261016/beta4-screen/optimization-stages.csv](refactor-speed-20261016/beta4-screen/optimization-stages.csv) | 18 | 结果/汇总 |
| [refactor-speed-20261016/beta4-screen/runs.csv](refactor-speed-20261016/beta4-screen/runs.csv) | 108 | 逐次记录 |
| [refactor-speed-20261016/heavy-default-screen/CUT_RATIOS.md](refactor-speed-20261016/heavy-default-screen/CUT_RATIOS.md) | — | 表格报告 |
| [refactor-speed-20261016/heavy-default-screen/SPEEDUP.md](refactor-speed-20261016/heavy-default-screen/SPEEDUP.md) | — | 表格报告 |
| [refactor-speed-20261016/heavy-default-screen/below-target.csv](refactor-speed-20261016/heavy-default-screen/below-target.csv) | 6 | 结果/汇总 |
| [refactor-speed-20261016/heavy-default-screen/optimization-cases.csv](refactor-speed-20261016/heavy-default-screen/optimization-cases.csv) | 8 | 结果/汇总 |
| [refactor-speed-20261016/heavy-default-screen/optimization-categories.csv](refactor-speed-20261016/heavy-default-screen/optimization-categories.csv) | 4 | 结果/汇总 |
| [refactor-speed-20261016/heavy-default-screen/optimization-graphs.csv](refactor-speed-20261016/heavy-default-screen/optimization-graphs.csv) | 4 | 结果/汇总 |
| [refactor-speed-20261016/heavy-default-screen/optimization-stages.csv](refactor-speed-20261016/heavy-default-screen/optimization-stages.csv) | 12 | 结果/汇总 |
| [refactor-speed-20261016/heavy-default-screen/runs.csv](refactor-speed-20261016/heavy-default-screen/runs.csv) | 72 | 逐次记录 |
| [refactor-speed-20261016/keys-screen/CUT_RATIOS.md](refactor-speed-20261016/keys-screen/CUT_RATIOS.md) | — | 表格报告 |
| [refactor-speed-20261016/keys-screen/SPEEDUP.md](refactor-speed-20261016/keys-screen/SPEEDUP.md) | — | 表格报告 |
| [refactor-speed-20261016/keys-screen/below-target.csv](refactor-speed-20261016/keys-screen/below-target.csv) | 12 | 结果/汇总 |
| [refactor-speed-20261016/keys-screen/optimization-cases.csv](refactor-speed-20261016/keys-screen/optimization-cases.csv) | 18 | 结果/汇总 |
| [refactor-speed-20261016/keys-screen/optimization-categories.csv](refactor-speed-20261016/keys-screen/optimization-categories.csv) | 5 | 结果/汇总 |
| [refactor-speed-20261016/keys-screen/optimization-graphs.csv](refactor-speed-20261016/keys-screen/optimization-graphs.csv) | 6 | 结果/汇总 |
| [refactor-speed-20261016/keys-screen/optimization-stages.csv](refactor-speed-20261016/keys-screen/optimization-stages.csv) | 18 | 结果/汇总 |
| [refactor-speed-20261016/keys-screen/runs.csv](refactor-speed-20261016/keys-screen/runs.csv) | 162 | 逐次记录 |
| [refactor-speed-20261016/mixed-screen/CUT_RATIOS.md](refactor-speed-20261016/mixed-screen/CUT_RATIOS.md) | — | 表格报告 |
| [refactor-speed-20261016/mixed-screen/SPEEDUP.md](refactor-speed-20261016/mixed-screen/SPEEDUP.md) | — | 表格报告 |
| [refactor-speed-20261016/mixed-screen/below-target.csv](refactor-speed-20261016/mixed-screen/below-target.csv) | 3 | 结果/汇总 |
| [refactor-speed-20261016/mixed-screen/optimization-cases.csv](refactor-speed-20261016/mixed-screen/optimization-cases.csv) | 3 | 结果/汇总 |
| [refactor-speed-20261016/mixed-screen/optimization-categories.csv](refactor-speed-20261016/mixed-screen/optimization-categories.csv) | 1 | 结果/汇总 |
| [refactor-speed-20261016/mixed-screen/optimization-graphs.csv](refactor-speed-20261016/mixed-screen/optimization-graphs.csv) | 1 | 结果/汇总 |
| [refactor-speed-20261016/mixed-screen/optimization-stages.csv](refactor-speed-20261016/mixed-screen/optimization-stages.csv) | 4 | 结果/汇总 |
| [refactor-speed-20261016/mixed-screen/runs.csv](refactor-speed-20261016/mixed-screen/runs.csv) | 19 | 逐次记录 |
| [refactor-speed-20261016/receiver-list-screen/CUT_RATIOS.md](refactor-speed-20261016/receiver-list-screen/CUT_RATIOS.md) | — | 表格报告 |
| [refactor-speed-20261016/receiver-list-screen/SPEEDUP.md](refactor-speed-20261016/receiver-list-screen/SPEEDUP.md) | — | 表格报告 |
| [refactor-speed-20261016/receiver-list-screen/below-target.csv](refactor-speed-20261016/receiver-list-screen/below-target.csv) | 7 | 结果/汇总 |
| [refactor-speed-20261016/receiver-list-screen/optimization-cases.csv](refactor-speed-20261016/receiver-list-screen/optimization-cases.csv) | 12 | 结果/汇总 |
| [refactor-speed-20261016/receiver-list-screen/optimization-categories.csv](refactor-speed-20261016/receiver-list-screen/optimization-categories.csv) | 5 | 结果/汇总 |
| [refactor-speed-20261016/receiver-list-screen/optimization-graphs.csv](refactor-speed-20261016/receiver-list-screen/optimization-graphs.csv) | 6 | 结果/汇总 |
| [refactor-speed-20261016/receiver-list-screen/optimization-stages.csv](refactor-speed-20261016/receiver-list-screen/optimization-stages.csv) | 18 | 结果/汇总 |
| [refactor-speed-20261016/receiver-list-screen/runs.csv](refactor-speed-20261016/receiver-list-screen/runs.csv) | 108 | 逐次记录 |
| [refactor-speed-20261016/unit-screen/CUT_RATIOS.md](refactor-speed-20261016/unit-screen/CUT_RATIOS.md) | — | 表格报告 |
| [refactor-speed-20261016/unit-screen/SPEEDUP.md](refactor-speed-20261016/unit-screen/SPEEDUP.md) | — | 表格报告 |
| [refactor-speed-20261016/unit-screen/below-target.csv](refactor-speed-20261016/unit-screen/below-target.csv) | 11 | 结果/汇总 |
| [refactor-speed-20261016/unit-screen/optimization-cases.csv](refactor-speed-20261016/unit-screen/optimization-cases.csv) | 18 | 结果/汇总 |
| [refactor-speed-20261016/unit-screen/optimization-categories.csv](refactor-speed-20261016/unit-screen/optimization-categories.csv) | 5 | 结果/汇总 |
| [refactor-speed-20261016/unit-screen/optimization-graphs.csv](refactor-speed-20261016/unit-screen/optimization-graphs.csv) | 6 | 结果/汇总 |
| [refactor-speed-20261016/unit-screen/optimization-stages.csv](refactor-speed-20261016/unit-screen/optimization-stages.csv) | 18 | 结果/汇总 |
| [refactor-speed-20261016/unit-screen/runs.csv](refactor-speed-20261016/unit-screen/runs.csv) | 162 | 逐次记录 |

2026-10-18 **G-kway失败诊断**：[11个代表配置的边数组容量证据](gkway-paper/diagnosis.csv)。soc-Pokec sanitizer确认粗图构建写越界；9张全失败图和ppa代表配置都触发实际粗边输出超出固定层次数组容量。仅诊断，非性能数据；未修复正式程序。

2026-10-18 **G-kway与Jet比较**：[逐配置](gkway-paper/vs-jet.csv)、[九类](gkway-paper/vs-jet-categories.csv)、[各k](gkway-paper/vs-jet-parts.csv)、[总体](gkway-paper/vs-jet-summary.csv)。41图×k4–64，205配置，含超载；Jet时间优势几何平均2.008×，G-kway切边比均值1.3557。对齐既有批次，非同轮重测。
