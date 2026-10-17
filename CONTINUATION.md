# 当前状态与后续工作

更新：2026-10-17。本轮代码实现、构建、测试、九类代表图重复测量及固定层次对比均已完成。没有后台待续实验。

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

## 本轮测量结论

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
