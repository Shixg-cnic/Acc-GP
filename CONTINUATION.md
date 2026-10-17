# 当前状态与后续工作

更新：2026-10-17。本次提交在a773355外部审查之后，新增第一批受控筛选实现、测试与效果实验表格：GPART_JOINT_DEDUPLICATE默认0、GPART_JOINT_CONFLICT_ROUNDS默认1（可选1..4）、GPART_JOINT_DIAGNOSTICS默认0。legacy与joint默认行为均保持；显式开关才启用新筛选。定向正确性验证及随后真实图效果测试均已完成，没有后台实验。

首批范围是完全相同策略输出去重、失败认领重试、筛选计数及反例测试。未实现多净重量档案、精确shortlist、互补组合或GPU热点剖析。已补同一LP状态的三个筛选配置对照，但还没有逐一重放旧legacy接受移动的损失路径。下文162份实验与约4%提速均属于此前冻结版本，不能作为新筛选的成绩。

本轮验证：joint_events_gpu、uncoarsen_small_standard、manual_workflow_host三项定向CTest通过；完整细化测试覆盖joint/joint-polish、k4..128、Dense/Sparse/OnDemand及可选冲突恢复/去重。32组随机候选池×1..4轮与独立CPU冲突图判定一致，1轮与原筛选一致；H/X/Y反例完整CSR收益由10恢复至20且容量合格。20图精确事件oracle继续通过。新筛选核memcheck/racecheck为0错误/0 hazards；定向joint集成memcheck为0错误（该次运行早于补入joint-polish随机覆盖，后者已单独通过CTest，不声称其完成新一轮sanitizer）。4条诊断输出的生成/幸存/事务/顶点计数关系检查通过。此轮没有重跑全库11项；随后补测的真实图结果见下一节。日志位于../Acc-GP-archive/experiments/joint-filter-review-20261017/。

## 最新：筛选开关的真实效果（joint-filter-effects-20261017）

九类各一张代表图、k=8/128、每配置5次、固定seed0。四方法分别为：ours=只启用3轮冲突恢复；dedup=只启用同种子策略去重；reference=冻结原joint-polish（75c4b698）；jet=同批Jet。两种新配置使用当前6d19ba00二进制，生长批数均为2。360份原生输出全部独立cut/严格容量核验通过，0份标签保留。原生计时未开诊断。五图固定GPU0/CPU16–19，另四图固定GPU1/CPU24–27，同图四方法轮换；两组共享主机内存/IO，未发生同卡外来进程重叠重测。

- 去重：相对原候选几何平均0.99983472×，平均cut比0.99959135；k128速度0.98761953×。基本无整体提速，不能把微小cut差异称为算法收益。
- 冲突3轮：相对原候选0.99606982×（耗时增加约0.395%），平均cut比1.00132366；18配置7快11慢，k128速度0.98218652×、平均cut比1.00194498。没有达到优化目标。
- 相对同批Jet，去重/冲突分别为1.39611023×/1.39085315×，平均cut比1.06003596/1.06187632；这不是本次改动带来的新增加速。

同LP检查：road_usa/grid/products/af_shell10×k8/128，单次粗化/METIS后沿共同的纯LP投影轨迹，选择N<=65536且修复成功的55层检查点；从同一份标签分别跑原候选、去重、冲突恢复两批。165份结果全部CPU完整cut/负载核验。三个分支均丢弃，不改变后续共同LP轨迹；不将其用作端到端计时。去重55处最终标签完全相同，非空候选由20006降至10979（约45.1%），提交事务仍为2571。冲突恢复15处改善、34处相同、6处退步；af_shell10 k128 level8第一批幸存74→77，提交44→43，精确收益17701→17667，说明固定前缀选择会丢失原有好组合。

结论：继续legacy默认，去重默认关闭、冲突默认1轮。优先改容量互补候选与提交选择，不能把增加重试当成已经解决质量/速度；k128修复/CSR瓶颈仍需剖析。仅九类代表图两k，不是52图六k/多种子结果。原候选native对照使用此前冻结binary，固定LP对照使用同一当前库；不对个位百分点作强因果归因。

表格：results/manual/joint-filter-effects-20261017/{runs,comparison,categories,fixed_lp,fixed_lp_stages}.csv。comparison中ours表示retry3；dedup_*列给出去重对照。原始记录、版本、固定LP试验源码在../Acc-GP-archive/experiments/joint-filter-effects-20261017/。quality/speed两个子目录可各自用analyze_cuts.sh复核已存核验；总表为两组的合并与按18配置汇总。没有新增维护报告脚本。

## 当前源码与默认

big目标、BigTypes/ActiveTypes、图/层次/算法入口的Types模板、亲和力偏移/边权宽度分支及big自动运行路径均已删除。仅维护int32顶点ID/CSR偏移、uint32点/边权；切边、增益、负载及必要的亲和力累计保留64位。磁盘输入仍为int64 CSR；超出32位范围跳过或拒绝。build目录保留standard程序，旧big生成物已清除；历史归档不删除。

粗化仍为唯一regret主线，METIS接口未改。新细化位于src/refine_joint.cuh：净容量缺口引导双向连通组生长、每种子两条贪心轨迹、每侧最多4点、每分区32..128种子、整组冲突剔除、精确边事件前缀、严格容量批提交。

**默认细化仍为legacy，候选未提升默认。** GPART_REFINE_MODE=joint-polish保留已有LP、以新机制替换N<=65536小层旧组，默认最多2批；joint为独立新机制实验路径，仅保留初始容量修复。二者都有代码，不是文档提案；独立替换的真实质量明显不合格，不能推荐作为主结果。GPART_JOINT_ROUNDS=0..32明确控制新阶段预算。

```bash
GPART_REFINE_MODE=joint-polish ./run.sh
# 添加本轮之前的对照：
GPART_REFINE_MODE=joint-polish \
REFERENCE_BIN="$PWD/../Acc-GP-archive/experiments/joint-refinement-20261017/before" ./run.sh
```

每次源码/参数改变使用新的工作目录。./analyze_cuts.sh仍重分析已有结果；没有新增报告/绘图生成脚本。

## 此前双向组初版测量（75c4b698）

九类各一图×k8/128×3重复×ours/reference/Jet，共162份原生输出，全部独立核验cut与floor(1.03*N/k)容量，临时标签已删除。测量候选75c4b698，显式joint-polish/2批；reference为本轮前dd536dfc。按每配置三次中位数：

- 相对旧版几何平均1.04117913×，耗时几何比下降3.95505%；平均cut比1.00723598，增加约0.724%。13/18配置较快、5/18较慢。
- k128九图相对旧版1.04252931×，平均cut比1.00303079；仍没有大幅高k加速。
- 相对Jet几何平均1.42366043×，平均cut比1.06978804；5/18未达到1.15×，其中stokes/nlpkkt200的k128慢于Jet。这些总体优势并非全由本次修改产生。
- road_usa k8/128对旧版cut增加5.18%/4.89%；af_shell10 k128 cut下降2.23%、速度1.03789×。因此不把平均约4%的省时当成稳定质量改进，不替换默认。

表格：results/manual/joint-final-20261017/{runs,comparison,categories}.csv。原始运行、162份核验和冻结binary在../Acc-GP-archive/experiments/joint-final-20261017/。测试和实现记录在../Acc-GP-archive/experiments/joint-refinement-20261017/。当前重新编译binary为8d9e3e71，与测量版源码只有两行注释和src/README文件说明差异，没有算法或默认变更；production-source-hashes.json、source-final和validation.json保留测量身份。

固定层次补充：grid/products/road_usa×k8/128，每配置只粗化一次、只调用METIS一次，用同一不可变层次和同一标签比较legacy、joint-polish 2/4/8批及joint，共30份内存结果，完整CPU切边/负载核验通过。表为results/manual/joint-final-20261017/fixed_hierarchy.csv。该组用于质量隔离，主机层次路径、固定顺序、单次测量，不能用其时间列替代上述原生计时。road_usa k8的2/4/8批cut相对旧版为1.05273/1.05550/1.04255；增加轮次没有稳定解决回退。当前joint独立模式在六配置cut比为1.28770..2.40650，仍明显不合格。

首版joint完全替换和32种子组合初筛负结果分别保留在results/manual/joint-pilot-20261017、joint-polish-pilot-20261017，不混入最终18配置结果。

## 验证与限制

单类型清理先通过10项CTest；加入新机制后11项通过。完整uncoarsen memcheck为0错误，新细化定向racecheck及20图精确前缀racecheck均0 hazards。全库racecheck在旧粗化测试中异常退出，不声称全库竞争检查通过。最终重编译后再次检查11项CTest及一键流程。

最终测量脚本在所有测量/核验完成后的shell收尾因运行中修改脚本而报EOF；已恢复与metadata匹配的原runner哈希并成功续跑收尾，没有替换任何测量。原始和恢复日志均保留。今后运行期间冻结入口脚本，修改完成后再启动。

此轮只覆盖九类代表图两种k、固定seed0三次，不是52图六k全集或多种子验证。9类全配置cut/速度均保留，没有删除表现差的图。5张用户指定有限元图、3张OOM图继续排除；最大k128。

后续应改进联合候选的目标覆盖、净重量多样性与生长选择，验证能够消除路网回退后再扩大层次范围；单纯增加批次已显示不足。现有新路径尚未解决大层LP/修复开销，不能据小层省时承诺所有配置达到1.15或1.2×Jet。具体方法来源和贡献边界见ALGORITHM_COMPARISON.md及docs/PAPER_REVIEW.md。
