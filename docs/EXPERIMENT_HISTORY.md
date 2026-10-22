# 算法与GPU加速尝试历史

2026-10-19 CPU基线扩展：用户授权51图×k4/8/16/32/64×3次，先Mt-METIS官方默认greedy，再mt-KaHIP官方multitrysocialparallel。保留历史HS数据，独立输出到`results/cpu-default-mtkahip-20261019/`。mt-KaHIP未修改源码，补TBB头文件路径完成Release构建；其逐行flush输出在NFS上很慢，首次小图验证已中断并留档，改用/dev/shm临时标签后fe_rotor的k4/64两方法全部cut核验完成。正式队列顺序运行，记录原生时间和进程墙钟，标签核验后删除。此项为基线测量，不改变Acc-GP算法，不预先宣称greedy更快。

2026-10-19 晚间按用户新指示调整测量：停止本轮Jet重测，复用`data/baselines.csv`中已有Jet结果；将尚未完成的Acc-GP配置切至空闲GPU1，只测51图的k4/8/16/32/64。迁移时保留400条Acc-GP原生记录及已保存的独立核验，原记录GPU UUID不改写；后续仍用冻结binary f35523a9…。旧41图/追加10图控制器已被`archive/experiments/cohort41-social-20261019/ours51_gpu1.py`替代，当前状态以同目录`pipeline-state.json`和`supplement-state.json`为准。Jet来源表已冻结，最终对比标明历史结果复用，不声称是同轮交错测量；逐k汇总保持不变。此项仅改变实验调度与对照来源，不改算法。

2026-10-19 20:40 扩展当前冻结版覆盖：用户要求测齐现有51图的k4/8/16/32/64，追加原41图之外的10图；与Jet配对，固定现有binary，不重新编译。现有41图队列含k128，继续按原身份完成；新10图仅补用户本次指定的五种k。合并表只纳入五种k，九类柱状图所用统计按k分别输出，不跨k平均。当前是已排队的实验，不表示51图已有完整结果；内存分配失败继续保留并报告。

2026-10-19 当前补测状态：按用户要求对原G-kway成功的41图补测当前冻结Acc-GP与Jet的k4/8/16/32/64/128，二进制分别为f35523a9…、ca8fc1f9…。批次在`results/manual/cohort41-20261019`，原始资料在同级archive的`experiments/cohort41-social-20261019/ours-jet`。本次不改算法，不将旧版本成绩当成当前成绩；完成后按实际覆盖汇总。uk-2002 k128当前Acc-GP发生cudaMalloc显存分配错误，k4–64已完成，失败不填时间或速度比。

同日Mt-METIS缺项补跑：官方0.7.2冻结binary、32物理线程、HS、seed0，对kmer_U1a的k32/64/128各再次运行五次，15次均SIGSEGV，没有有效标签；`data/baselines.csv`仍保留缺失，不混入改版、改线程或其他seed的成绩。覆盖和逐次失败记录见`results/cpu-baselines/cohort41-missing-20261019`。此前S_move_vertex的NULL_PID越界诊断仍是已有确认的源码证据，本轮未重新跑调试器。

同日社交候选筛查：沿用原论文阈值G-kway冻结binary5014ba48…，不恢复已撤回的层次存储修复。首批13个候选中wiki-Talk、com-DBLP、dblp-2010、hollywood-2009、ego-Facebook及商品共同购买图amazon-2008均通过k2–64；超载按用户要求保留，全部接受输出cut独立复算一致。其余候选的运行错误/内存分配失败和跳过均保留。输入来源、全部结果和小图规模限制见`data/SOCIAL_CANDIDATES.md`；另准备YouTube/Gowalla更大候选，尚未计入通过清单。没有按Acc-GP加速效果筛图，主选集未改变。

更新：2026-10-17。本文是维护中的统一历史入口，分为两部分；成功、失败、撤回和未验证都保留。状态“保留”表示进入当前源码，“历史采用”表示曾进入旧版本，“否决/撤回”表示不在当前主线，“待验证”不代表已实现或有成绩。每项倍数只对应注明的版本、输入和对照，整版结果不等于单项贡献。

当前主线为regret（2026-10-17按用户决定）；旧粗化分支已归档删除。该决定不改变此前九图筛选偏弱的结论，也不代表新颖性和速度目标已经达成。历史材料和失败结果继续保留，当前代码与运行方式见ALGORITHM/README。

## 一、划分质量与算法机制的创新/修改历史

2026-10-19 源码整理：按用户要求删除主仓库测试目录、独立粗化检查入口及6个过期实验脚本；13个私有实现/辅助头文件按粗化、细化与数据结构职责重排。32份生产C++/CUDA文件在还原include路径后逐字节一致，保留编译单元、kernel、默认参数与计时。当前算法和贡献文档重写，历史文档原文、测试和此前未提交差异保存在`../../Acc-GP-archive/maintenance/source-cleanup-20261019/`。本次不新增GPU性能结果；当前CPU队列所依赖的文件与二进制未改。

本部分包括影响合并映射、候选、迁移、容量或搜索预算的修改；通用机制与Jet等继承机制不当作已证明原创。

| 日期/版本 | 尝试与动机 | 结果、局限及决定 | 状态/证据 |
| --- | --- | --- | --- |
| 10-17，容量互补单主线整理 | 按用户“多数配置整体收益即可保留”标准，统一LP＋容量互补交换；删除legacy/独立joint后端、去重/重试开关和双计划保护 | 11项CTest/完整uncoarsen memcheck通过；九图k128三次81份：对legacy速度1.03978×、cut比1.00069，8/9更快；对Jet1.39697×、cut比1.04912。另四图两k48份对旧双计划速度0.99575×、cut比0.99174，5/8更快/5/8切边更低。全部独立核验，允许局部回退，容量/实际正收益保持 | 保留唯一研究主线；[九类结果](../results/manual/capacity-exchange-final-20261017/comparison.csv)、[单/双计划](../results/manual/capacity-exchange-single-plan-20261017/comparison.csv)。旧源码/测试/binary冻结在capacity-exchange-mainline-20261017 |
| 10-17，容量互补预算版27e8d83f | 四点/四状态档案保留不可行正收益片段，精确互补组合与原完整计划逐匹配对择优 | 33个同LP检查点132份核验：单批20好13同0差，两批21好10同2差。四图两k三重复48份开关消融，对旧joint0.98127310×、cut比0.99625976（质量约好0.374%，耗时约增1.91%）。局部单批保护不能推广为多批质量保证 | 保留研究开关、默认0；[同LP](../results/manual/joint-complement-fixed-final-20261017/fixed_lp.csv)、[单机制原生](../results/manual/joint-complement-ablation-20261017/comparison.csv) |
| 10-17，容量互补预算版九类 | 九类各一图k128×3次×候选/legacy/Jet，81份全部cut/严格容量核验 | 对legacy速度1.03005421×、cut均比1.00288479；对Jet1.37067119×、cut均比1.04513747。stokes/nlpkkt200/kmer_V2a仅0.90054/1.02497/1.13753×Jet；不可把整版对legacy差异归给本次complement。社会网络只测soc-Pokec，不是八图或51图全集 | legacy默认保持，未达逐配置1.15×；[逐配置及切边比](../results/manual/joint-complement-final-20261017/comparison.csv) |
| 10-17，容量互补前缀首版 | 原轨迹保存至多8个正收益状态，含单独不可行前缀；净重区间4代表配对、真实边修正；原/新完整计划逐匹配对择优 | 33个共同LP状态132份核验：单批20好13同0差，两批24好9同0差。四图k8/128×3次×两方法48份全核验；对旧joint0.97304×、cut均比1.00016，af_shell10 k128切边+1.72%，局部收益未稳定传到端到端 | 不提升默认；joint-complement-fixed-20261017、joint-complement-screen-20261017 |
| 10-17，四点档案预算回归 | 保留原八点候选，限制额外档案为至多四点片段，以降低扩池/排序/精确事件成本 | 初版空档案误跳过原六/八点可行候选，三角形测试cut27未改善而应为3；确认测试退出前误启计时，已中止，5份输出虽独立核验通过但不作性能结论。修复为空档案直接执行实际原计划，测试断言保持 | 失败源码/日志和中止批次joint-complement-bounded-20261017保留；修复后12项CTest、组memcheck、joint路径initcheck通过，重测见上两行 |

| 10-17，bbf6c81后复审与选集调整 | 用户排除products，社会网络保留原指定八图；核对路网零输出与af_shell10提交退步，停止单独调去重/冲突轮数 | road_usa k8的18批中10批零输出，32记录仅10事务且全部提交，重试无新增；af_shell10 k128保留真实收益17701→17667的反例。旧结果不改写 | 已更新51名称选集及入口；下一步为同LP生成诊断、原提交计划保护、按证据决定净重量备选组合；算法尚未实现，详见CONTINUATION |
| 10-17，筛选真实效果与同LP检查 | 9图×两k×5次×原候选/去重/冲突3轮/Jet，共360份；另4图两k的55个同LP检查点、165份局部结果 | 全部cut/容量核验。去重速度0.99983472×、cut比0.99959135；冲突0.99606982×、cut比1.00132366。同LP去重标签全相同，冲突15好34同6差；额外候选可能破坏原最佳前缀 | 未达到优化目标，两个开关均不推广；[逐配置](../results/manual/joint-filter-effects-20261017/comparison.csv)、[固定LP](../results/manual/joint-filter-effects-20261017/fixed_lp.csv) |

| 10-17，外部审查后的筛选实验 | 同种子双策略完全相同移动去重；成功事务固定、失败事务最多4轮重新竞争；生成/幸存/提交事务与顶点分开计数 | 新功能显式启用，默认保持原行为。H/X/Y冲突反例和收益10对可行子集18的前缀局限进入测试；当时仅正确性验证，随后补测见上行 | 3项定向CTest通过，新筛选核memcheck/racecheck通过；不推广默认，不称已修复路网质量回退 |

| 10-17，固定层次/批次检查 | grid/products/road_usa×k8/128，每配置一次粗化/METIS，比较旧细化、新组合2/4/8批和独立joint | 30份完整CPU核验。路网k8三档cut/旧为1.05273/1.05550/1.04255；独立joint六配置1.28770..2.40650。增加轮次不是稳定解法；该主机层次路径时间不混入原生计时 | 不推广默认，继续候选机制研究；[同初始条件结果](../results/manual/joint-final-20261017/fixed_hierarchy.csv) |

| 10-17，双向组2批重复测试 | 低k增至最多128种子/分区，最多4096种子；压缩有效事务后排序，修正匹配轮间共享进度同步 | 九类各一图×k8/128×3次×3方法162份全核验；对旧版1.04118×、cut比1.00724，对Jet1.42366×、cut比1.06979。路网两配置cut约+5%，5/18仍不足Jet1.15×；不能推广为稳定改进 | 保留显式joint-polish候选，默认legacy；[全配置表](../results/manual/joint-final-20261017/comparison.csv)与[九类](../results/manual/joint-final-20261017/categories.csv) |

| 10-17，双向组首版完全替换 | 实现净容量引导双向连通组、整组冲突剔除与精确事务前缀，初始每分区32种子、4批，在所有细化层替代LP | 4图×k8/128×两方法共16份输出，cut/严格容量全部独立核验；新/旧cut比1.363..2.623，速度比0.085..1.222，质量明显退步且高k串行匹配极慢 | 不推广独立替换；[失败表](../results/manual/joint-pilot-20261017/comparison.csv) |
| 10-17，双向组小层组合初筛 | 保留LP，仅替换N<=65536小层旧组，2批；并行互选匹配、低成本提名后精确warp边际 | 4图×2k共16份全核验，cut/旧0.988..1.042，速度/旧0.925..1.120；products k8约+4.2%cut，不能只报较快配置 | 增加低k种子覆盖并继续九类重复测量；[初筛表](../results/manual/joint-polish-pilot-20261017/comparison.csv) |

| 10-17，细化机制调研 | 对照Jet/G-kway/Hunyuan，扩展至Mt-KaHyPar带权交换、无约束FM、HyperG精确前缀、负环与流细化；提出净容量引导的双向连通组生长及批量选择 | 明确组交换、负收益探索、净容量与精确前缀均有先例；区别拟落在双向耦合候选生成及大层GPU工作量控制。当前原型仍是单侧生成后配对，仅小层；本次未改代码、未编译、未跑实验 | 调研完成/新机制未实现；[论文记录](PAPER_REVIEW.md)开头2026-10-17章节 |
| 10-17，regret主线整理 | 用户要求删除旧粗化，集中优化备选损失机制；移除4轮HEM整层回退、旧可拆簇SCLP、无备选损失residual入口 | CLI/库统一regret。保留新算法依赖的匹配种子、精确亲和力、完整重量准入和CSR算子。旧算法仅用归档binary对照，历史负结果不撤销；这是研究方向决定，不以改默认证明有效 | 已执行；maintenance/before-regret-mainline-20261017保留源码与086d9ad5划分binary；当前run.sh默认ours/Jet |
| 10-17，regret-v1 | 在residual-v1上只将容量竞争优先级改为最佳/次佳可行簇连接差值；额外top-two统计，不改轮数/种子/细化 | standard/big GPU测试及CPU精确top-two/粗CSR核验通过；standard memcheck零错误。九类各一代表图×6k×3方法×3次=486份输出全部核验通过；同binary对residual几何均值0.99221480×（约慢0.8%），平均cut比0.99545356（降0.45%）。31/54变慢、24/54 cut变差、9/54二者同时退步。对Jet1.40516820×、cut比1.04920256，18/54不足1.15×。保留非默认实验模式，不推广；不是52图全集 | 实验候选；归档experiments/regret-20261017，源码及日志冻结 |
| 10-17，residual-v1全集 | 用户运行20261016-211749，52名称×6k×3方法×3次=2808；ours/legacy同一standard二进制3b0997a4，Jet ca8fc1f9 | 全部cut/严格容量核验通过。312配置相对legacy几何均值1.01197195×，平均cut比1.00773947；157配置变慢，204配置cut变差，112配置速度/质量同时变差。相对Jet1.52082981×、cut比1.03870552；47低于1.15×、55低于1.2×。社会网络和人工复杂图有效，网格/优化类回退；不能作为普适改进推广 | 实验完成/混合结果；[逐配置](../results/manual/20261016-211749/comparison.csv)、[九类](../results/manual/20261016-211749/categories.csv)；未改回默认，候选保留供后续修改 |
| 10-16，residual-v1 | 1轮HEM仅作种子，保留映射；只让单点向稳定簇按精确连接权重聚合，先筛容量可行目标再做完整重量前缀准入；无HEM层同样使用残余路径 | 已写源码并设为CLI实验默认，保留legacy/sclp消融。早期合并锁定、收缩不足和cut退化风险待实验；固定最多4轮残余，尚无拟合成本模型。新增独立CPU归并oracle的GPU测试，按用户要求未编译/未运行GPU；没有加速或质量成绩 | 实现待验证；src/coarsen_residual.cuh、tests/test_residual_coarsen.cu；修改前源码在maintenance/before-residual-20261016 |
| 10-13，00f2/1fef | GPU谱初始化、固定步数预热/动量迭代 | 做过九类和Products/LiveJournal对照；结构化图cut仍偏高。后续按用户要求切为METIS，旧GPU初始化成绩不代表当前算法 | 已替换；归档gpu-optimization-20261014及旧文档 |
| 10-14 | boundary/region/persistent、不同粗图预算等初始化原型 | 目录和冻结材料保留，但未保留在当前主线；缺少充分独立成绩的原型不补造“成功”结论 | 归档/未采用；gpu-optimization-20261014/{boundary,region,persistent256,metis16} |
| 10-14，b15dc304 | 改用与Jet相同的CPU METIS API，范围检查和精确权重公约数归一化 | 生产一次调用；保留库CPU严格修复。7CTest、42严格合成和9真实输出核验；初始化不作为原创贡献 | 保留；[报告](../results/metis-production-20261014/REPORT.md) |
| 10-14，budget8/cpu-retry | 进一步缩小粗图、重复METIS候选 | 小粗图+重复调用仅约1.070×旧基线，未达到期望；重复CPU初始化未推广 | 否决；归档metis-speed-20261014/{budget8-screen,cpu-retry-prototype} |
| 10-14–15，progressive | 高k目标粗图beta2，前期细簇、后期放宽，粗层不可分超载投影后再修复 | 9图486份初版同批旧/新1.243×，cut旧-0.58%；这是整版结果。一次METIS/最终严格容量保持 | 保留；[初版表](../results/metis-speed-20261014/progressive-final/case-medians.csv) |
| 10-15，容量调度 | 比较fine因子与后期容量增长倍率，最终fine64/growth8；小k保持旧预算 | 选择进入0419a5f3；初筛无效开关和被覆盖重复单独标记，不能用无效测量支持选择 | 保留；归档k512-optimization-20261015容量试验及TUNING材料 |
| 10-14–15 | 源迁出配额＋接收多目标完整重量票据 | 减少接收冲突与修复循环；源评分归一化借鉴Jet strong。带权顶点可能留空隙，需要迭代/回退；独立贡献未从整版中完全隔离 | 保留；src/refine_rebalance_graph.cuh和原文档归档 |
| 10-14–15 | 小组事务：连通组、整组重选目标、负收益虚拟扩展、重量区间反向配对、净容量与整批收益保护 | 支持单点不能完成的联合迁移。仅N<=65536小层、最多4点、默认2轮；组交换等思想已有，新颖性与独立贡献待验证 | 保留；src/refine_groups.cuh及uncoarsen测试 |
| 10-14–15 | LP单位重量优先级、额外原图流搜索、八池/交换后额外LP等分支 | 当前已移除/未采用；缺少可隔离正式数据的分支不赋予量化收益。原LP优先级和搜索预算保留 | 否决/归档；旧ALGORITHM/COMPARISON快照 |
| 10-15，HEM初筛 | 引入受容量保护的互选HEM，与SCLP按层混合，平均度门槛逐步探索 | 最终平均度门槛64；4轮HEM收缩不充分时原层SCLP。能改变层次与cut，并非单纯硬件优化；存在失败重做成本 | 保留；[HEM初筛](../results/coarsen-20261015/hem-screen/optimization-cases.csv)、[57图正式](../results/coarsen-20261015/final-57/REPORT.md) |
| 10-16，beta4 | 高k粗化因子2->4，试图改善后端规模/质量权衡 | 6图k32/128，108份核验；同二进制旧/新0.95597×，耗时增加约4.61%，cut仅改善约0.41% | 否决默认；[表](../results/refactor-speed-20261016/beta4-screen/optimization-cases.csv) |
| 10-16，beta32 | 低k8粗化因子64->32，减少METIS粗图开销 | uk/ppa/kmer_U1a，27份核验；旧/新1.05911×，cut旧约+0.695%，仍有两个配置低于Jet1.15×；不足以推广统一默认 | 未推广；[表](../results/refactor-speed-20261016/beta32-screen/optimization-cases.csv) |
| 10-16，边界优先修复 | 尝试边界优先、再切完整修复的weak/strong类流程 | 仅不完整CPU编译，未GPU验证或计时；因收益未证实且与Jet机制接近撤回。不是禁止合理算法继承 | 撤回；归档refactor-speed-20261016/withdrawn-boundary-first |
| 10-16，粗化论文方向 | 分析HEM互选竞争/点对限制与SCLP多轮亲和力/容量竞争，研究轻量候选、容量/竞争准入、有效合并保留、残余活动域推进 | 当前仅设计假设；没有实现，不能将现有整层回退称为已完成的新方法。Hybrid/自适应是属性，贡献落在具体规则和独立收益 | 待实现/查新/消融；[论文阅读](PAPER_REVIEW.md) |
| 10-16，细化论文方向 | 深化带权联合迁移及净容量准入、精确交互收益，控制候选和大层开销 | 保留有效LP并注明Jet来源；固定层次和初始标签隔离细化；不要求推倒整个已有框架 | 待实现/查新/消融；[方法对比](../ALGORITHM_COMPARISON.md) |

历史完整版本的质量证据：80145dbb在57图六k中相对旧版平均cut-1.05%、相对Jet+3.51%，仍有明显质量差距；不能把整版质量收益全部归给HEM或组事务。剔除5张有限元图后，baseline-52只是旧记录的筛选视图，选集改变不算算法提速。用户5FE删除和3OOM排除继续生效，k512不再实验。

## 二、GPU加速与执行优化尝试历史

2026-10-20 CPU基线超线程单图试验：按用户要求，对wb-edu、k=8使用同一个官方Mt-METIS 0.7.2冻结binary（404620b3…）、默认greedy、seed0和3%容量，交错运行32/64线程各三次。32线程绑定CPU0–31，64线程绑定CPU0–63，均使用NUMA interleave=0,1、OMP_PROC_BIND=close、OMP_PLACES=cores。原生时间分别为32线程15.344/20.313/12.910秒、64线程18.997/18.078/17.087秒；中位数为15.344/18.078秒，64线程本轮耗时增加17.8%。六次切边独立复算一致且容量合格。运行窗口存在其他用户后台CUDA编译，32线程本轮明显高于历史4.544秒且有波动，因此仅记录为受干扰的探索性试验，不能认定为纯SMT收益，也不替换正式基线。逐次/汇总CSV在`results/mtmetis-smt-wb-edu-k8-20261020/`，命令、日志、核验与进程快照在同级archive的同名experiments目录；临时标签已删除。未修改生产代码或CPU运行脚本。

本部分优先记录保持给定算法含义的布局、调度、压缩、缓存与资源管理。GPU调度可改变原子平局到达顺序，因此cut可能波动；精确CSR、容量和独立核验仍必须成立。

| 日期/版本 | 尝试 | 实测或验证、失败原因/限制 | 决定/证据 |
| --- | --- | --- | --- |
| 10-22，交换收益事件warp归约 | 一个warp处理一个事务；本事务的边贡献由lane局部累加、五步shuffle归约后至多一次原子写回，远端事件保持原路径；无新开关 | CPU oracle seed=20261022，8个定向案例＋2500个随机图／候选池，33267个前缀的旧事件／新事件／独立cut三方一致。覆盖空／失败事务、跨匹配对、自环／零权、抵消、2050度长行及64位事件。模拟逐边处理的原子调用1006580→179146，仅为合成案例的操作计数；未CUDA编译或GPU测试 | 已实现、待GPU验证。候选、容量、冲突与前缀规则不变。实现见[exchange.cuh](../src/refinement/exchange.cuh) `joint_events`；操作量和归约语义见[技术拆解§8.8.5](GPU_ARCHITECTURE_ANALYSIS.md)。本次不引用历史速度作为提速结果 |
| 10-18，arena最终profile | 同卡before/arena各三弱图，Nsight Systems，输出逐份CPU核验 | native分配API 77.62→34.46、70.35→30.20、60.79→36.14ms；调用数1520→92、1480→80、2212→166。trace显存峰值stokes近似不变，nlpkkt200/kmer增加约1.1GiB，包含池保留量但不含上下文/驱动 | 6份全核验并清理标签；仅诊断，不代替原生速度。[表](../results/manual/weak3-gpu-profile-20261017/arena-memory.csv) |
| 10-18，统一arena | 普通CUDA底层块＋best-fit区间复用/合并，取代异步池；没有新增开关；仍含全部分配/释放计时 | 三弱图k128×5×3方法45份全核验；相对4ba62d9e速度1.17199/1.10895/1.11691，几何平均1.13227×，平均cut比1.000415；Jet1.17435×。stokes仍仅Jet1.14546，另外两图约1.19×，未全部达到1.2× | 保留f35523a9，11CTest及memcheck/synccheck通过；[重点表](../results/manual/weak3-arena-20261017/comparison.csv)。完整17图171份全核验，16快1慢，对修改前1.11149×、cut均比1.00210；三类11图1.08950×，无新增OOM。[覆盖表](../results/manual/weak3-arena-all-20261018/comparison.csv) |
| 10-17，clean-kernels | 全量重编译确认恢复原medium-row CSR；warp级cut累加、dirty原子预读、warp CDF、充分位宽下bounds原子加 | 三弱图k128×5×3方法45份全核验；对4ba62d9e速度stokes1.00128、nlpkkt2000.98431、kmer_V2a1.05184；未达到大幅改善 | 有效隔离版本f69bc05e；[表](../results/manual/weak3-clean-final-20261017/comparison.csv) |
| 10-17，allocation | 大于等于128MiB数组普通CUDA分配，小数组仍异步池 | 三图45份全核验；对4ba62d9e速度1.01494/1.02989/1.04949、cut比1.00698/1.00018/1.00010；释放变快但重复分配抵消部分收益 | 中间候选9c7759f8；[表](../results/manual/weak3-allocation-20261017/comparison.csv) |
| 10-17，release微测试 | 相同14GiB分配、写入、释放；普通分配与异步池；另比较trim/destroy/threshold释放 | 四轮中位数普通21.13ms、异步79.63ms；free前后显存一致。仅换池释放API均约44–50ms，无效 | 仅微测试，不等于数据集收益；[表](../results/manual/weak3-gpu-profile-20261017/pool-vs-direct.csv) |
| 10-17，warp-final混合对象构建撤回 | warp切边累计、标脏加载、并行CDF与有界粗化求和 | 45份冻结二进制输出全部cut/容量核验；但恢复coarsen_sclp旧时间戳后漏编，仍链接已撤回的短行寄存器聚合。源码快照与对象不一致，三图原生数字不得作为当前源码成绩。同步检查的块屏障版本也未进入正式候选，改为warp累计及warp CDF后CTest/memcheck/synccheck均通过 | 撤回版本归因，保留[原始表](../results/manual/weak3-warp-final-20261017/comparison.csv)及IDENTITY.csv；不叠加收益。后续clean-first重建并重新冻结/测量 |
| 10-17，粗化warp内聚合试验 | 9–32项邻接行用match/reduce代替共享哈希；同时测试有界簇重量atomicAdd | 三图k128各5次的冻结二进制负结果为速度0.97915×、cut比0.99759。但随后发现copy2恢复旧时间戳导致增量构建遗留retry细化对象，源码快照不能完整代表已链接二进制；不作为粗化单项归因证据。独立映射/容量检查仍通过 | 撤回；原始30份cut/容量核验有效，性能归因撤回；最终候选必须clean-first全量重建。[30份核验结果](../results/manual/weak3-coarse-20261017/comparison.csv)；coarse-source归档 |
| 10-17，三张弱图统一缩小线程组/寄存器亲和力 | Sparse/OnDemand提案宽8改1、更新宽32改8；短行4项排序、17–64度至多4键寄存器聚合 | 三图k128各5次，对当前4ba基线速度0.98428×、cut比0.99955；stokes/nlpkkt200/kmer分别0.97451/1.00551/0.97315×。11项CTest与完整uncoarsen memcheck通过，但总时间未改善。单次profile也显示kmer提案/更新变慢，不能凭线程利用率猜测提速 | 撤回全部生产改动，无开关；[45份全核验结果](../results/manual/weak3-affinity-20261017/comparison.csv)；冻结在weak3-gpu-20261017/affinity-source |
| 10-17，容量预约重试枚举 | 重试枚举非零亲和力，必要时扫描零亲和力最大余量；保留整点票据协议 | 三图k128各5次，对4ba速度0.99410×、cut比1.00215；分别1.02839/1.00315/0.95230×。345408次初始选择及345408次重试选择对CPU穷举通过，11项CTest通过；Biology明显退步，静态复杂度下降未转成总体收益 | 撤回；[30份全核验结果](../results/manual/weak3-retry-20261017/comparison.csv)；weak3-gpu-20261017/retry-source保留实现与oracle |
| 10-17，生产执行路径收敛 | 移除Sparse增量及相关字段/分支，固定采用已验证的修复查询枚举/CDF和cut布局资格 | Sparse增量重建节省被维护开销抵消，旧实验保留；不保留CLI切换，库oracle仍核对查询/布局。单计划减少重复排序/事件/全N标记，但四图两k对双计划速度仅0.99575×，未实现整体提速；不能把少执行步骤当成速度证据 | 生产移出失败路径，归档完整旧源码；不将删除代码量当作实测提速 |
| 10-17，Sparse增量2–8键预算版 | 限制查键成本，一键或超过8键行直接重建，其余精确原子增量/缺键重建 | 三图k128×3次×两方法18份全核验；stokes/nlpkkt200/kmer_V2a速度1.06640/0.98951/1.01879×，cut比1.00239/1.00316/1.00343。两快一慢，kmer反粗化中位反而增加约22.2ms，不能将总时间微降归为维护收益 | 保留开关、默认0；[独立消融](../results/manual/sparse-delta-bounded-20261017/comparison.csv) |
| 10-17，Sparse预算版Nsight | stokes k128同一27e8d83f开/关增量，另2份cut/容量核验后删除标签 | warp重建45.014→21.065ms，短行构建/压缩1.579→10.396ms，cache/cut更新13.646→29.118ms；合计60.240→60.579ms，新增维护代价抵消重建节省。repair预约10.161→14.925ms、98→122调用；onesweep约56.5ms、trim API约45ms | 单次轨迹诊断，不是固定输入或原生计时；[GPU/API分别列示](../results/manual/sparse-delta-profile-20261017/profile.csv)。需减少查键/原子/压缩代价后再验收 |
| 10-17，Sparse已有键增量首版 | 冻结Sparse键、原子更新现有源/目标槽；缺键行重建，其他行压缩零值，保持精确候选集合 | stokes/nlpkkt200/kmer_V2a k128×5次×两方法30份全核验；速度1.00195/0.98118/0.95474×，cut比0.99716/0.99751/0.99358，未见整体提速。键查询与原子更新成本抵消重建节省 | 默认关闭；sparse-delta-screen-20261017。后续只尝试2–8键行，其余直接重建；该预算独立量化见上行，不能沿用首版成绩 |

| 10-17，最终版Nsight核对 | c5c69063同二进制关闭/开启两优化，stokes k128，原生计时之外单独采集 | proposals68.508→16.374ms，warp LP35.886→12.330ms；构建/重建15.870→48.088ms（39→85次），显示Sparse维护新代价；全阶段onesweep仍约53.1ms，trim API44.6→45.1ms。调用数/轨迹有差异，不能当作固定输入单核消融，API与GPU时间不可相加；两份输出独立核验后删除标签 | 定位下一步重建与排序；gpu-execution-profile-20261017。未改动态接收重试、粗化和清理计时范围 |

| 10-17，查询＋布局最终c5c69063 | 查询内部点证明、Sparse枚举、余量CDF；Dense边界保留原顺序扫描；cut上界扩展Sparse资格 | 九类k128×5次×3方法，135份全核验；对同binary两项关闭几何平均1.06756×、cut均比0.99824，8快1慢；对Jet1.39811×、cut均比1.04417。stokes/nlpkkt200/kmer_V2a仍不足Jet1.15×，af_shell10对reference0.99041×。12项CTest通过，345408次目标oracle一致，selector/完整细化memcheck0错误 | 保留本轮执行优化，速度目标未全面达成；gpu-execution-final-20261017。k8/64三图54份全核验，对reference1.01284×、cut均比0.99946，3快3慢、最坏回退0.69%；表在gpu-execution-k8k64-20261017，不将前置批次收益相乘 |

| 10-17，修复查询首版初筛 | 内部点零外部亲和力证明、Sparse非零枚举，原目标排序和完整容量规则 | stokes/nlpkkt200/kmer_V2a的k128，5重复、同二进制开关对照，30份全核验；速度1.08597/1.05800/1.07315×，cut比1.00002/1.00305/0.99671。此时尚无CDF及cut布局资格 | 保留方向；repair-enumeration-screen-20261017 |
| 10-17，修复CDF版本 | 冻结接收余量CDF，只在全部非空接收者可容纳完整顶点时二分；其余原完整余量哈希 | 2b093efb二进制，九图k128×5次×3方法，135份全核验；对同binary原查询几何平均1.04014×，cut算术平均0.99599；soc-Pokec为0.9504×，三个弱配置仍低于Jet1.15×。不是最终版成绩 | 保留并继续优化；repair-enumeration-final-20261017。原版/该版Nsight查询核stokes约68→29ms、nlpkkt200约59→25ms、kmer_V2a约52→26ms；调用数不同且有剖析扰动，不作为原生加速比 |
| 10-17，cut上界Sparse初筛 | sum(q_v)<=N+2*cut作为资格启发式，保留内存/长行保护；只改布局选择 | stokes/nlpkkt200/soc-Pokec的k128×3次×2方法，18份全核验；同binary查询优化已开启，切换布局资格，速度1.07472/1.05983/0.97205×，cut比0.99884/1.00209/1.00131。soc-Pokec细化中位基本相同，端到端未提速 | 继续最终九类复测，不能把两批倍数相乘；affinity-cut-bound-screen-20261017 |

| 10-17，移除big及双宽模板 | 构建仅standard；图/层次/算法接口去掉Types模板，亲和力视图去掉偏移/边权双宽分支；脚本跳过超范围图 | 单类型改动先通过10项CTest；uint64/int64累计cut、负载和gain、按证据选择的缓存宽度仍保留。旧big生成物从build移除，历史实验核验仍可读取归档big哈希 | 保留；未把减少构建工作量称为算法加速 |
| 10-17，去重/冲突筛选端到端验证 | 固定LP去重将20006个非空候选压至10979，最终提交及标签不变；重试增加kernel与全N清空 | 九类5重复未获得总体提速，k128去重0.98762×、冲突0.98219×。nlpkkt200 k8总时间中位下降约11%，但细化中位未降低，不能归功于冲突机制。原生两图组CPU核隔离但共享主机内存/IO，微小差异不作强因果解释 | 保留实验开关，不作为成功加速贡献；日志/版本在joint-filter-effects-20261017 |

| 10-17，外部审查的GPU方向 | 核对修复中重复亲和力查询及接收者重试、粗化排序量等候选瓶颈；本轮只改联合候选筛选 | 未修改修复/粗化，未取得本轮Nsight剖析；不能把代码上界视为实测热点。冲突恢复有额外全N清空与kernel成本，诊断从run.sh计时环境移除 | 修复/粗化待剖析；筛选实测另列 |

| 10-17，双向组GPU执行优化 | 首版单线程商图匹配改为128线程互选；提名阶段避免反复完整扫描候选CSR，仅对选中成员精确扫描；有效事务先压缩再排序 | 新版11项CTest通过、完整uncoarsen memcheck 0错误；新细化定向racecheck和20图精确前缀racecheck均0 hazards。全库racecheck在旧粗化测试异常退出，未报告通过 | 保留，单独记录检查范围；原始日志joint-refinement-20261017 |

| 10-17，row512候选 | CSR局部排序由128扩到512，增加64项分支，长短kernel隔离寄存器压力；保持原度元数据与regret决策 | 最终13CTest及standard memcheck零错误，追加长行完整CSR/map对照通过；9图k8/128共162份全核验。对优化前1.02313×、cut比0.99887；对Jet1.37390×、cut比1.06259；5/18仍不足1.15×，整体收益有限 | 保留；results/manual/row512-final-20261017；冻结旧版maintenance/before-row512-20261017 |
| 10-17，row512宽度候选 | 在row512上按平均行长>=16使用warp32搬运，其余subwarp8 | 13CTest及standard memcheck零错误；2图k128各5次、共20份输出全核验。nlpkkt200粗化中位179.858→174.732ms，但完整470.088→494.660ms；af_shell10完整80.477→81.020ms，未见可靠端到端收益；带事件的16份剖析存在分配延迟波动 | 撤回宽度选择，保留原8线程搬运；results/manual/row512-width-screen-20261017，源码及剖析在同名archive |
| 10-17，容量证明快路径 | 用W+W*D*M<=C证明所有请求均可接纳；安全批跳过次强、排序/前缀/gather，直接提交。失败只代表界不够紧，继续完整regret | 13项CTest与standard memcheck通过；8组完整层次与冻结源码逐字节一致。九类k128×3次×三方法81份全核验，相对冻结regret0.99513361×、cut比0.99783292；相对Jet1.29499991×、cut比1.04084749，3/9低于1.15×。同binary剖析中grid/nlpkkt200准入阶段降低6.4%/8.8%，但没有稳定整体提速 | 保留执行路径继续研究；experiments/regret-capacity-proof-20261017；FORCE_FULL=1可消融 |
| 10-17，regret缓冲/消费优化 | 次强值在decode中原位转换为备选损失，去掉独立priority数组及无效提案的清零写；two-hop只取最强favorite，不计算次强 | 少一份8*N字节工作区；真实gain独立。standard/big粗化与完整回归13项通过，standard memcheck零错误。九类代表图k128×3次×三方法=81份全核验；相对冻结regret速度0.97990494×、cut比0.99949127；相对Jet1.27264750×、cut比1.04475392，3/9低于1.15×。未取得整体加速，后续继续容量证明快路径 | 保留；测试日志maintenance/before-regret-mainline-20261017，新计时experiments/regret-mainline-20261017 |
| 10-17，regret top-two | 低/中度、单点快路径融合次大值归约；高度使用已有按簇归并结果原子top-two，无额外原图边扫描 | 增加两个O(N) uint64缓冲与归约开销；同binary消融未获得整体加速。k128首重复中grid前六层零容量拒绝、stokes前两层零拒绝、nlpkkt200前五层零拒绝，仍计算top-two。需研究按实际竞争启用，当前未实现 | 已实现候选；experiments/regret-20261017 |
| 10-17，residual-v1阶段核对 | 复核用户全集原生阶段与冻结二进制；本次只分析，未启动GPU任务 | k128阶段中位数：grid粗化35.72→51.99ms；nlpkkt200反粗化/细化155.91→234.25ms；mycielskian17粗化163.13→64.56ms。各阶段中位数不相加冒充总时间。nlpkkt200旧粗化有287ms离群值，不能用均值断言新粗化更快。新粗化不是各图普遍减少工作，映射变化会影响后续细化 | 诊断完成；[逐次阶段](../results/manual/20261016-211749/runs.csv)及manual原始日志；缺少单因素消融，具体子机制贡献尚未独立证明 |
| 10-16，残余源行过滤/实验入口 | 所有精确亲和力路径使用冻结残余角色；two-hop也只扫描残余单点源边；高行仅排序活动源边。run.sh默认ours/legacy/Jet，三个CSV增加旧模式比值及原生阶段耗时 | CPU模拟三方法端到端流程通过：独立CSR核验、模式区分、逐阶段输出、断点恢复、错误cut剔除、核验后删除标签。无CUDA编译/GPU执行，不能据此声称内核提速；仍有O(N)角色和提案扫描 | 执行待GPU验证；tests/test_manual_workflow.py |
| 10-14，warp-ab | 高k亲和力协作读取、内部点过滤和候选列表压缩 | Products64/128旧/新1.012/1.004×，Pokec1.027/1.011×；只属局部效果，不称大幅提速 | 历史采用；归档gpu-optimization-20261014/warp-ab |
| 10-15，4f5f347c | 流序池覆盖层次CSR/点权/映射、异步Thrust、缓存覆写初始化、细粒度计时opt-in | 9图486份整版同批旧/新1.332×、Jet1.189×；混有容量调度贡献，不能归因全为GPU kernel | 保留基础；[正式表](../results/metis-speed-20261014/execution-final/case-medians.csv) |
| 10-15 | 删除结构padding、整数缓存比较、跨池生命周期检查 | 解决initcheck/临时转换问题，无抑制；此项没有独立加速比 | 保留；原验证日志归档 |
| 10-15，0419a5f3 | Sparse亲和力、脏行/边界/超载源队列、覆写工作区、粗化度分类融合、小组空项压缩 | 9图486份整版旧/新1.173×、Jet1.368×；容量调度亦包含其中，仍35/54低于Jet1.3× | 保留；[正式表](../results/k512-optimization-20261015/k4-128-final/case-medians.csv) |
| 10-15，host空闲块缓存 | 不限大小缓存；再试单块1MiB/总64MiB限制 | 初筛约1.005×；4图72份受限版约1.019×，收益不足，恢复原CUDA池分配 | 否决；归档k512-optimization-20261015/{pool-g8-screen,bounded-pool-3repeat-valid} |
| 10-15 | 扩展k512与更宽缓存/队列候选 | 显存受限后按用户要求停止512，不计当前主性能均值；保留现有k<=128 | 停止512；旧表只作历史 |
| 10-15，ac366852 | 大层条件图LP、OnDemand/Sparse/Dense布局、uint8分区键、短行subwarp、组radix/分块树、投影cut传递 | 9图486份，旧/新1.03965×、Jet1.41078×；21/54回退。较宽OnDemand条件导致grid128退化，已收紧；cage稀疏条件亦修订 | 保留收紧版；[正式表](../results/gpu-resident-20261015/k4-128-revised-final/case-medians.csv) |
| 10-15，预合并 | 原无条件warp预合并收缩记录 | circuit5M明显退化；改为M>=2^20、平均度>=8且无长行等条件下启用 | 否决无条件版/保留受限版；归档gpu-resident-20261015/precombine-screen |
| 10-15–16，80145dbb | 短粗行精确CSR局部排序、稳定有效ID压缩、无冗余清零、工作标签/点权池化、小组有效位排序 | 57图3078份核验，整版旧/新1.10586×、Jet1.42503×；HEM也同版改变，单项未隔离，55/342旧版回退 | 保留；[正式表](../results/coarsen-20261015/final-57/optimization-cases.csv) |
| 10-16，refactor | 删除2个未引用树kernel及1结构，拆SCLP/Affinity模块 | 76个保留kernel体字节一致；8CTest、42严格合成、6完整层次字节一致。GPU初始化在此之前已移除，不重复算本轮成果 | 保留；归档refactor-speed-20261016/refactor-version及validation-refactor |
| 10-16，mixed CSR | 少量长粗行改用CUB分段排序，与短行混用 | stokes粗化约175–180->229–237ms；19份核验，3完整配置旧/新0.86277×，及时停止。该实验不完整 | 否决并移除；[部分表](../results/refactor-speed-20261016/mixed-screen/optimization-cases.csv) |
| 10-16，keys | SCLP准入和收缩记录有效位压缩、按实际度缩小hash活动范围、输入异步释放 | 162份核验，旧/新1.01751×、Jet1.11323×；键位/hash保留，输入异步free无明确收益撤回 | 部分保留；[表](../results/refactor-speed-20261016/keys-screen/optimization-cases.csv) |
| 10-16，Sparse阈值误判 | 曾将has_heavy_rows误认为degree256，而实际是4096 | 门槛修改及不一致元数据测试均撤回，不作为bug修复或加速贡献 | 撤回；原STATE及docs-before-consolidation归档 |
| 10-16，heavy/growth | 覆写缓冲增长先释放旧块；首轮degree>=4096单点目标用CTA协作精确归约 | 72份核验，旧/新1.00422×、Jet1.08575×；不能称普遍显著提速 | 保留；[表](../results/refactor-speed-20261016/heavy-default-screen/optimization-cases.csv) |
| 10-16，unit-v2 | 完整主机边权全1时省略设备边权数组，统一精确访问器；粗层保持显式权重 | 9CTest、8GPU sanitizer、54严格划分、6层次字节一致；162份同批旧/新1.02503×、Jet1.13887×，18配置11低于1.2× | 当前保留；[速度](../results/refactor-speed-20261016/unit-screen/SPEEDUP.md)、[切边](../results/refactor-speed-20261016/unit-screen/CUT_RATIOS.md) |
| 10-16，Nsight unit | 定位stokes128热点 | 再平衡提案约70.7ms、radix54ms、warpLP35.7ms；pool trim45.5ms。输入H2D约456ms在native外，不混作算法瓶颈 | 已分析；原剖析文件归档 |
| 10-16，balance | 大层提案改8/32lane协作，GPU按原公式建损失桶查表 | 10CTest、9san、54strict；108份旧/新0.96664×，慢约3.45%。剖析提案合计90.7ms，高于旧70.7ms，确认方案回退 | 否决，源码恢复；[表](../results/refactor-speed-20261016/balance-screen/optimization-cases.csv) |
| 10-16，receiver-list | 每轮压缩接收分区列表、标量提案只遍历有效接收者、精确查表 | 108份旧/新1.00527×，约0.5%；提案kernel下降但完整时间噪声大，未证明稳健提升 | 未推广；[表](../results/refactor-speed-20261016/receiver-list-screen/optimization-cases.csv) |
| 10-16，恢复unit | 撤回边界优先原型和未推广执行候选，恢复冻结unit源码 | 核心44文件逐一相同；重新配置构建成功，9CTest通过。重建哈希变化，不冒称新性能成绩 | 当前状态；归档refactor-speed-20261016/restored-unit-source.json |
| 10-16，未实现候选 | 无向上三角收缩＋稳定镜像排序、warp合并源桶原子、覆写CSR省初始化 | 有设计/瓶颈依据但未实现、未验证；对称性/位宽等前提必须证明，不能引用现有成绩 | 待研究；归档ORIENTED_CSR_DESIGN.md及STATE |
| 10-16，计时边界审查 | 对比Jet调用者输入所有权及内部清理 | 保留当前完整native边界，不移走free/trim达标；普通free约3.5ms不能解释45ms池清理 | 保留计时；归档TIMING_SCOPE.md |
| 10-16，仓库与结果整理 | 图工具迁出；标签核验后删除；表格与原始材料分开；合并历史文档 | 删除13923个part，逻辑390219575124字节；补70份逐次CSV。工具改为先保存核验再删标签，保留失败记录；不改算法及性能计时 | 已完成整理；6项主机CTest/4项存储回归通过，3078条旧记录审计通过；[结构](STRUCTURE.md)、[结果索引](../results/INDEX.md) |


旧实验中其他screen/build目录保留在归档，完整目录索引列于归档README。若单项没有有效隔离结果，状态记为“原型/未独立归因”，不以目录存在推断成功。CPU Mt-METIS/KaMinPar旧全集1950次均有运行记录（包含崩溃及超载，不等于1950份有效输出）；2026-10-18按用户要求仅补跑当前选集中的未核验缺项，原始七列表在[CPU结果](../results/cpu-baselines-20261014/full-suite/REPORT.md)。

后续每项记录至少包含：日期、阶段、机制/实现变化、来源、版本、对照和范围、时间/cut/容量结果、保留或拒绝原因。失败和负结果继续写在对应部分；当前算法文档只描述最终保留状态。

2026-10-16工作流调整：用户自行编译build/，使用run.sh跑Acc-GP/Jet并独立核验、清理标签，analyze_cuts.sh可重跑CSV分析。旧报告/绘图脚本和旧构建缓存迁出，未改算法、未新增性能成绩。两个入口以模拟计时程序及真实Python CSR oracle验证，不启动GPU实验或编译。

## 2026-10-17 regret-v1筛选的解释与复现

九类每类一个代表图，固定在实验前：wb-edu、products、stokes、road_usa、nlpkkt200、af_shell10、kmer_V2a、grid、kron_g500-logn20；6k与3次重复，共54配置486份输出。选择包含原有弱图，不根据本候选结果换图。ours=regret，reference=同一binary的residual，Jet为独立基线。standard SHA256 086d9ad5e196516ebff8a14f8d75e3a5d547b458a75cb8a260c25385ae5e1133，Jet/oracle哈希见combined/metadata.json。粗化种子、容量、轮数、two-hop、METIS和细化相同，改动是准入优先级及所需top-two计算。每配置以三次中位数比较，速度按配置几何平均、cut比按配置算术平均；不是多随机种子的稳健性结论。

所有输出均由CPU CSR oracle独立验证cut及严格容量，核验持久化后删除标签。两张相同5090按图并行，每图三方法固定同一UUID串行、轮换顺序。一次初始编号误分配导致重叠，脚本丢弃并重测，终止的重复warmup单独归档，不纳入486条记录。初始批只选前三图，余下六图分批；combined是原生记录及对应检查的只读并集，保留source_batches来源，未改写原始记录。LATEST指向combined，analyze_cuts.sh可重新分析，但不应用run.sh续跑合并目录。

结果为[逐次/阶段](../results/manual/regret-20261017/runs.csv)、[逐图逐k](../results/manual/regret-20261017/comparison.csv)、[九类代表图汇总](../results/manual/regret-20261017/categories.csv)。不因平均cut略降就推广：products k8 cut比1.1315、road_usa k4约1.1285；grid k128约快5.8%且cut降2.2%，但grid六k总体0.98885×且cut增0.59%。stokes总体1.0040×、cut降2.76%，表明存在局部质量收益。

阶段中位数诊断：kron20 k128总时间reference293.83→regret392.66ms，粗化105.64→131.91ms、反粗化132.86→184.70ms；变化不只是top-two局部执行开销，也伴随后续细化开销变化，不能由端到端数据单独归因。grid k16粗化41.89→42.11ms，但反粗化30.32→38.93ms。各阶段中位数不可相加代替总时间中位数。

当时筛选结论：没有性能依据将纯备选损失排序推广为默认。其后用户明确选择以该机制作为研究主线，旧分支归档；这不改变本段实验结果。该机制只是单因素候选，不等于完整容量竞争自适应粗化已完成。后续需要检验如何避开无竞争大层的无效计算，以及并发竞争下备选是否真正可用；不按图名选择分支，不把减少搜索预算当算法收益。

2026-10-17主线回归说明：旧测试要求HEM层只产生成对簇，更新为精确容量二的种子测试，并允许合法two-hop；独立CPU CSR/权重及容量核验继续执行。旧SCLP专用Python oracle已归档，其目标算法不再维护。更新测试时曾误改局部CSR测试的层数，已恢复原检查；失败日志与修复后的成功日志均保留。保存的旧coarsen-only executable未更新到regret，尝试执行时明确拒绝该模式；不将其用作regret对照，另从冻结源码重建用于层次等价检查。正式性能reference始终为已经验证支持regret的086d9ad5划分binary。

## 2026-10-17：主线整理后的两轮执行优化

用户明确要求以regret为唯一研究主线，因此删除旧生产分支、保留归档对照。新默认不以首轮regret实验成绩作为优越性证据。第一步缓冲复用/two-hop简化：九类各一图k128、81份输出全核验，相对冻结regret0.97990494×、cut比0.99949127，未提速；结果`results/manual/regret-mainline-20261017/`。随后增加充分容量证明与直接提交，当前standard=4cb8bb4d、big=1cc128a5；对照仍为冻结regret086d9ad5，Jet独立基线，两版均同METIS/细化和预算。

当前九图仅k128、三重复中位数：相对冻结regret几何平均0.99513361×（约慢0.49%），平均cut比0.99783292（约降0.22%）；4/9配置较快、5/9较慢。相对Jet几何平均1.29499991×、平均cut比1.04084749。stokes、nlpkkt200、kmer_V2a低于1.15×；没有达到逐配置目标。当前逐配置/九类/逐次表在`results/manual/regret-capacity-proof-20261017/`，仅为九类代表图k128筛选，不代表52图六k全集。

首重复快路径触发批数：road_usa 2/38，nlpkkt200 1/35，af_shell10 1/29，kmer_V2a 1/50，grid 1/34；wb-edu/products/stokes/kron20均0。全局最大度与点重量上界较保守，不能把实际零拒绝等同于事前可证明安全。当前无试跑后回退，证明失败直接使用完整regret。

另在GPU-b5f8e180-c156-522e-fb60-cc3f659106f8对grid/nlpkkt200做同binary FORCE_FULL开关剖析，启用GPU子阶段事件，交替次序，各模式1预热+3次测量，共16份输出全核验并清理标签。GPU事件会引入同步，该剖析不是正式端到端时间。准入中位数：grid 5.08138→4.75699ms（降6.4%），nlpkkt200 8.18496→7.46816ms（降8.8%）；聚合总GPU时间分别14.902→14.5873ms、60.8957→60.0489ms。nlpkkt200粗CSR收缩仍117.863ms，表明当前准入优化覆盖范围及占比不足。阶段中位数不相加冒充完整时间，剖析原始记录在同名experiments/profile。

本轮不声称大幅加速成功。后续重点是粗CSR收缩与长行亲和力，并收紧容量证明范围以覆盖更多安全批；不按图名挑分支。两轮原始/版本/核验均保留，结果只保存CSV；完整13CTest通过，标准memcheck0错误，8组完整层次字节相同，快路径开关的生产每层映射一致。实验全部结束，无后台待续任务。

## 2026-10-17：row512执行优化结果回填

九类各一图×k8/128×3重复×3方法，共162份输出，全部独立cut/严格整数容量核验通过，临时标签已清理。按每配置三次中位数，相对本轮优化前regret 4cb8bb4d几何平均1.02312532×（耗时几何比下降2.2603%），平均cut比0.99887248；13/18较快、5/18较慢。相对Jet几何平均1.37389645×、平均cut比1.06258773，5/18低于1.15×（也低于1.2×）。

本次保留的改动只有CSR局部排序扩展（128→512条原始记录）、64项分支与长短行kernel分离；保持旧度元数据判定边界以免改变种子选择。主线仍为regret，没有新质量算法。nlpkkt200完整时间k8约322.6→308.0ms、k128约515.2→483.4ms（约省4.5%/6.2%）；af_shell10约省2.5%/6.3%。这些是完整原生时间，包含METIS、细化和清理，不把GPU事件阶段和相加当总耗时。

这是九类代表图、两种k的筛选，不是52图六k全集；重复固定seed=0，不是多种子稳健性验证。切边微小变化不能归因为新的质量算法：本次保留regret合并准则、严格容量、METIS和细化预算。道路k8 cut/Jet=1.29391、电路stokes k8=1.17514，质量差距仍未解决。GPU按同一UUID轮换三方法、检查重叠；没有做CPU/NUMA独占，因此小幅端到端变化仍需更大样本确认。

先做row512与旧版两图子阶段剖析，16份输出全核验。再试8/32线程自适应搬运，16份剖析及20份五重复原生输出全核验；完整耗时无可靠收益，已撤回。所有正负记录保留于experiments/row512-20261017、row512-width-20261017、row512-width-screen-20261017，正式本轮筛选位于row512-final-20261017。逐配置/九类/逐次CSV只存results/manual下同名目录。早期memcheck因/tmp满未启动，设置TMPDIR到archive/build-tmp后最终检查零错误；不把环境失败当内核测试通过。

测量standard=f316f4c7a69fdd57d589c26e3182c3580f5b5277c2517c41f66004f17eb10a2c，reference=4cb8bb4d7e74630dab7c5ef466674f358e7b6b584addecf7475d85d81bfc98f7。撤回宽度候选后重编译standard=dd536dfc01a68341ca3956c2a0d4143a105fa25615ab13866f0d1efe8940b63e，big=5f8248d10d17e02fbbdcc20d87edc99984da183cface86a49b7d7f7e3a063308；二进制哈希不同，31个生产源码文件逐字相同，哈希与重编译说明保存于实验目录。性能数字明确对应冻结f316f4c7，不混称二进制相同。最终13CTest及standard memcheck在重编译库上完成。所有后台实验均已结束。

## 2026-10-18：CPU对照补缺与k64/128入口（实验基础设施）

不修改GPU算法或CPU基线算法。官方Mt-METIS 0.7.2采用HS、KaMinPar 3.7.3采用default，固定seed0、32物理核（0–31）、NUMA节点0/1交错，沿用旧版原生计时边界。当前51图k2/4/8/16/32的1530槽位中，1504份原输出已核验；其余26份均为Mt-METIS退出-11，KaMinPar没有未核验缺项。复用既有核验记录，包括超载结果；只重试未取得核验输出的槽位，不选最快或最低cut。导入校验程序/动态库哈希、物理核与NUMA、种子、输入标识和容量，逐行保留来源；旧oracle身份保留于来源元数据，新运行使用当前冻结oracle。

新增根目录run_cpu_baselines.sh，默认51图×k64/128×三重复×两方法，共612次，留给用户启动；相同命令续跑，仅重试未核验失败。现有runner增加相容结果导入、完整尝试历史、coverage.csv和attempts.csv，结果表仍按方法保存七列及逐次记录；核验后删除标签，原始材料保留仓库外。

测试：三项主机测试通过（含真实SIGINT终止子进程检查），使用256点环图、模拟CPU程序及真实C++ CSR oracle，覆盖k64/128、失败重试、身份/输入不匹配拒绝、超载不重跑、report-only配置恢复及标签删除。真实fe_rotor上两方法×k64/128各一次共4份输出均完成独立核验，KaMinPar两份容量合格；Mt-METIS实际最大负载比分别1.045283436/1.094752904，均超出1.03。该四份仅验证高k入口，不代表612次全集完成。report-only重分析及shell语法检查通过；未重新构建或运行GPU测试。

崩溃诊断与正式计时分离：kmer_U1a k8、相同Mt-METIS HS/T32参数在gdb中复现SIGSEGV，调用栈为S_move_vertex()←S_par_kwayrefine_HS()；仅定位函数，未确定根因或修补上游实现。诊断不计入原生统计。日志及工作流测试在../Acc-GP-archive/experiments/cpu-gap-audit-20261018/，补跑原始记录在cpu-baselines-20261018/completed-k2-k32/，高k入口核验在cpu-baselines-20261018/k64-k128-smoke/。

最终补跑完成两轮，共43次新增原生尝试：首轮26次补出9份，第二轮仅重试剩余17次、再补出4份。26个原缺项最终13份取得核验输出（3份容量合格、10份超载），13份仍退出-11。当前1530槽位中1517份输出已核验：KaMinPar 765/765均容量合格；Mt-METIS 752/765取得输出，其中452份合格、300份超载。每槽只保留首个核验输出，先前失败43份单独存档（含原始失败和本轮被后续尝试替换的失败），attempts.csv共1573行；不是1530次全量新测。

剩余Mt-METIS缺项（repeat按1起算）：com-LiveJournal k32/r2；soc-LiveJournal1 k16/r1；kmer_V2a k8/r1,3及k32/r1,2；kmer_U1a k8/r2,3、k16/r1,3及k32/r1,2,3。保留官方原参数，不替换为其他细化器/线程数凑齐。覆盖表510行，两个方法中位数表各255行，只有三个重复均核验后才填中位数。全部1530记录检查唯一键、核验负载及整数容量，两个新实验目录无残留.part。最终审计见archive的cpu-gap-audit-20261018/final-audit.json。原生cut与独立复算不一致的143份仍逐条保留（包括历史记录），表格使用独立复算值，不以原生日志替代核验。

## 2026-10-18：用户要求再次重跑Mt-METIS缺项

沿用官方Mt-METIS 0.7.2 HS、32物理核、NUMA0/1、seed0及冻结程序，未改算法、线程或种子。用户明确忽略容量超限进行cut比较，因此仅重试未取得核验输出的43个槽位，已有超载结果保留。k64/128重试30次补出14份（1容量合格/13超载），16份仍退出-11；旧k2–32重试13次补出5份（3容量合格/2超载），8份仍退出-11。新核验输出19份，剩余失败24份集中于soc-Pokec、com-LiveJournal、soc-LiveJournal1及两个kmer图。kmer_U1a的k64/128仍全部失败，不能补造cut。

前后逐行检查所有既有核验记录未改，1071份KaMinPar全部合格且未重跑，程序/元数据身份一致；新增失败历史完整保存。19份输出独立复算cut/容量后删除标签，其中4份原生cut与独立复算不一致，表格继续采用独立复算值。无需重编译/修改代码，没有新增GPU试验。43次新尝试及逐配置结果在results/cpu-retry-20261018/{attempts,summary}.csv；archive/experiments/cpu-retry-20261018保存前后快照、日志和final-audit.json。

当前17图k128的CPU切边比较同步刷新。按用户忽略超载的口径，对KaMinPar仍13/17更低、逐图比值均值0.966136；对Mt-METIS仍11/16更低、均值从0.948085变为0.947617。soc-Pokec现在2次、kmer_V2a仍2次、kron20补齐3次，其余有输出图3次；kmer_U1a无输出不计。每图按可用核验重复取中位数，不能将缺失样本声称为完整三重复。原严格容量表也刷新，重跑前比较快照归档。

## 2026-10-18：Mt-METIS崩溃原因定位（诊断，不计性能）

针对用户询问原因，读取既有kmer_U1a k8栈，并用相同官方HS/T32/seed0 binary在kmer_U1a k128上进行一次gdb复现；未修改源码或构建。确认崩溃位于S_move_vertex的mynbrs[k].ed读取（src/kwayrefine.c:329），二进制偏移0x49a6d，与先前k8故障一致。搜索目标分区失败时k=NULL_PID（uint32最大值4294967295），内部权重id=0使追加条目分支跳过，随后仍无条件访问mynbrs[k]。现场id=0、ed=2、nnbrs=2，邻接表基址0x7ffc2e0db4b0，故障读取地址0x800c2e0db4a0，差0xffffffff0=4294967295×16字节，直接证实无效下标越界。调用点对应HS待处理跨线程移动请求路径。

源码字节与官方0.7.2发布tar包一致，binary仍404620b3；这是已复现输入下的上游边界处理缺陷。尚未对每一个失败配置复现，也未证明触发状态的完整并发因果链，不能笼统把所有崩溃归因于数据竞争。此诊断无输出标签，不进入CPU正式时间/cut汇总；日志、命令、汇编和diagnosis.json位于archive/experiments/cpu-crash-diagnosis-20261018。官方程序未修补；当前正式失败记录保留。

## 2026-10-18：最低CPU baseline覆盖的追加重试

用户要求对已确定的崩溃图多跑几次，至少每个图/k得到一份baseline，并明确数据需用于论文加速比。检查当前51图×7k发现，KaMinPar357配置都有输出；Mt-METIS354配置有输出，仅kmer_U1a的k32/64/128为空。最初检测到其他用户CUDA编译，等待期间误将工作转为quality-only，跑出2次SIGSEGV并中断第3次，零成功；用户纠正后停止，EXCLUDED.json明确排除，正式记录未改。用户要求等待通知，控制器停止；收到恢复通知后才重新启动。

12:41恢复前无编译进程，3秒CPU总忙采样2.4478%。保持原官方HS/T32/seed0/绑定CPU0–31及NUMA0/1，每配置最多5次，首个核验输出即可停止。实际15次全部退出-11，三个配置仍无输出，不能把失败墙钟写成划分耗时。119次外部CPU监控样本未检测到编译重叠，但有rsyslogd、firefox及MainThread短暂负载，未声称整机物理独占；由于全部失败，本轮没有可用性能数字。旧runs/metadata/attempt-history与开始前快照逐字节一致，原CPU切边比较未改变。

`results/cpu-minimum-coverage-20261018/minimum-coverage.csv`逐图/k/方法记录最低覆盖和已有核验重复数，含超载结果且标出容量合格次数；`native-retries.csv`记录本轮15次失败，全部usable_for_speedup=False。完整控制器、二进制身份、输入哈希、失败日志、外部CPU监控及final-audit.json保存在archive/experiments/cpu-minimum-coverage-20261018；无残留.part。没有改变GPU或Mt-METIS源码/算法，没有通过改变线程数或seed填补正式表。反复重跑未消除已定位的越界缺陷，最低覆盖目标仍缺这三个配置。


### 2026-10-18：G-kway公开代码初筛（用户要求停止）

保留作者20k阈值和原容量规则，在5090/CUDA13上仅加计时与设备属性API兼容。预装ModernGPU含额外扫描改动的初测整批撤回；恢复作者锁定子模块后重测。计划九图×k8/32/128×三方法×三重复，用户叫停时仅记录95/243槽位（含失败和明确跳过），不是完整九类对比。停止自有控制器及其子进程，已核验输出和原始错误保留，临时标签删除。k128在小图Compute Sanitizer中确认update_vertex_info共享数组越界；soc-Pokec的k8/32报非法访问，尚未定位根因。不修复后冒充原版，也不把崩溃时间计作速度。表格见results/manual/gkway-current-20261018及STATUS.csv；源码/依赖/补丁/诊断/STOPPED.json在同级archive对应目录。


### 2026-10-18：G-kway论文阈值对照完成

质量/算法机制：按用户要求将baseline停止阈值从20k恢复为原图N/(20log2k)，无额外上限；不改其容量、METIS调用或细化。四图(grid、wb-edu、soc-Pokec、stokes)×k8/32×新旧G-kway/Acc-GP/Jet×三重复共96次，84份输出独立cut核验一致；12次失败全部为soc-Pokec的新旧G-kway非法内存访问，调整阈值没有消除这一故障。其余三图六配置的新阈值G-kway均三次有输出。超载按用户要求保留比较，不作为运行失败；k4/16/64未测，k128因已确认共享数组越界不测。不能称为全图集可运行。

GPU执行/计时：RTX5090 GPU0，沿用冻结f35523a9 Acc-GP与ca8fc1f9 Jet，作者锁定ModernGPU仅CUDA13设备属性API兼容；新旧G-kway计时同步和清理边界相同。每图方法预热后交错三次，检查外部GPU计算进程重叠。原生计时不含输入读取与输出核验；G-kway初始分配仍在原计时外，清理按额外区间加回，保留原始计时边界限制。未修改Acc-GP算法，也未调优G-kway。表格见results/manual/gkway-paper-threshold-20261018/{runs,comparison,coverage}.csv，源码/二进制/补丁/日志/核验及final-audit.json见同级archive对应目录。所有临时划分标签已删除。


### 2026-10-18：G-kway全选集可运行性排查启动

按用户要求，data/README.md删除重复次数、齐全次数和表格括号次数，保留原最终cut/时间、缺失配置及计时身份，原始CSV未改。新增run_gkway.sh与驱动，使用已验证的论文阈值冻结程序；不改任何划分算法。51图×k2/4/8/16/32/64，每配置一次，有效输出独立核验；允许超载，非法访问/超时继续其他配置，OOM后排除同图余下配置。预检306项输入通过，两个无GPU工作流测试通过；全量已启动，未完成前不能称所有配置可运行。公共表在results/gkway-paper，原始证据在同级archive/experiments/gkway-paper。


2026-10-18 G-kway全选集排查已完成：51图×k2/4/8/16/32/64共306配置，247份有效输出（133容量合格、114超载），59次运行错误；无超时、OOM或未处理项。41图六k全部成功，ppa只有k2成功，9图六k全失败。失败中54次报GPU非法访问、3次报CUDA invalid argument、2次仅留下usage日志；具体根因未单独诊断，不能视为同一问题。所有有效输出日志cut与独立核验一致，标签均删除，final-audit.json已保存，控制器/划分进程已退出。最终表在results/gkway-paper，原始证据在同级archive/experiments/gkway-paper。


### 2026-10-18：G-kway失败根因诊断（非性能测量）

已定位粗化各层共享边存储预分配不足：graph_partitioner.hpp使用MAX_COARSEN_LEVEL=6、COARSEN_RATE=0.6，固定分配约2.38336倍原图邻接项，真实图粗化后的边数下降不满足这一假设。外层越界预警仅输出文字，没有扩容或中止，最终construct_coarsen_graph写出数组。未改变任何生产算法/二进制；诊断副本仅加-g/-lineinfo，soc-Pokec k8经Compute Sanitizer确认coarsen.hpp:242全局写越界，3074条错误。其原图/前两层边项合计约114.8M，预分配106.3M。

另在诊断副本中加入“已算出实际粗边数后、写出之前”的精确边界检查。9张全失败图各取k2，以及ppa k4/k32，共11配置全部在此处触发容量越界（具体数字见results/gkway-paper/diagnosis.csv）。这是代表配置的定位，不声称对59个失败逐一运行sanitizer。ppa k4的gdb异常落在metis_partition.hpp:19，即拷贝越界的粗图邻接区；ppa k32也在写入前边界检查中被拦截，说明其不同报错前已发生相同容量缺陷。更深层错误不能仅按异常文字分类。

这些诊断不进入划分速度/切边统计；原306配置结果不修改。诊断源码、guard补丁、编译命令、sanitizer/gdb日志及summary.json在同级archive/experiments/gkway-failure-diagnosis-20261018。修复方向为按实际层次容量扩容或分层分配，并进行完整边界检查；k128的12000共享int不足是另一个独立缺陷。尚未实施生产修复或重测。


2026-10-18阈值因果核对：用户询问是否修改粗化停止阈值导致社交图失败。使用保留的原20k冻结二进制(gkway_old)对enwiki-2021、com-Orkut、soc-Pokec、citation、com-LiveJournal、soc-LiveJournal1、ljournal-2008各跑k2一次，7/7全部退出-6，全部出现global_edge_offset超出容量提示及GPU illegal memory access。与论文阈值k2失败一致，说明在当前5090/CUDA13环境这些故障并非改阈值后才出现。现有soc-Pokec k8/32三重复对照亦新旧均失败。源仓库git diff仅阈值、cmath及说明；实测副本额外含同步/清理计时，ModernGPU锁定作者版本且只改CUDA13设备属性API。诊断guard/-g/-lineinfo仅在独立副本，未进入正式baseline。阈值会改变层数/质量/时间，但固定容量估算缺陷在原阈值同样触发；不能据此宣称作者原平台也必然失败。对照为诊断，不计性能成绩；CSV在results/gkway-paper/old-threshold-check.csv，完整日志及命令在archive的gkway-failure-diagnosis-20261018。


2026-10-18 G-kway与Jet既有结果对齐：41图×k4/8/16/32/64共205配置。按用户口径保留108份G-kway超载，排除失败，k2因data中Jet表不含该k而不比，k128未测。Jet相对G-kway耗时比几何平均2.008012×，146/205更快；G-kway/Jet切边比算术平均1.355718，Jet在200/205配置切边更低。97个G-kway容量合格子集对应1.559891×与1.294003。使用新阈值G-kway本轮结果和data既有Jet结果，不是同轮交错重测；保留G-kway原计时边界（初始分配在外、末尾清理另行加回）限制。表在results/gkway-paper/vs-jet*.csv，来源哈希与统计口径在archive同名目录jet-comparison-audit.json。未新跑实验、未改算法。

### 2026-10-19：撤回 G-kway 层次存储容量修复

按用户要求撤回本次独立存储扩容修复，删除修复版源码、构建产物及全部补跑/验证结果、日志和冻结档案，移除实验入口的修复版选择参数。该尝试的长耗时原因未完成受控归因，其结果不纳入最终 baseline 或论文统计。原 G-kway 源码（保留此前论文阈值修改）、修复前冻结程序、原始结果和 data 汇总均保留；输入数据集及其他方法的实验结果未删除。仅保留本条撤回记录。


### 2026-10-19：指定第三方 iG-kway 实现的失败配置测试

用户明确要求测试 pragnasri74/Incremental-k-way-Graph-Partitioning-on-GPU 的全图入口。固定远端最新提交 034e7c14d4b83208954af458062e60d6ea918b83，原源码及算法不改。选取原 G-kway failed.csv 的59个配置（10图，k2–64；ppa缺5个k），单图首次预热，GPU0空闲窗口依次运行，GPU重叠丢弃，单次180秒上限，OOM后排除该图剩余配置。

独立测试入口直接调用 gkway_full_partition，Config只设置k，保留group_size=6、coarsen_min=35等默认值，不执行增量更新或构建增量bucket状态。为使用相同输入，入口将原有已核验int64二进制CSR逐项检查并转为该实现的int32 Graph，不改变边或编号，点边权均为1。时间含输出缓冲分配、库函数内上传/粗化/BFS初始化/投影细化/层次释放和输出缓冲释放；不含CUDA上下文建立、CPU读文件、输出标签D2H、cut复算和文件写入。结果是该第三方实现的探索性测试，不是论文作者G-kway†或原G-kway成绩，不并入data最终baseline。

入口每次输出标签后由已有独立oracle复算cut/负载，先持久化核验再删除标签。源码静态核对发现group_size=6与保留粗层所需90%点数下降不相容，可能将首次粗化结果丢弃，需诊断核实实际流程。结果位于results/igkway-thirdparty-failed；冻结源码、构建、适配器、控制器和运行核验位于同级archive/experiments/igkway-thirdparty-failed-20261019。

2026-10-19 测试完成：59配置全部结束，47个返回有效标签且独立cut复算一致，12个runtime_error。ppa的5个待测配置（k4–64），以及soc-Pokec、citation、kron20、ljournal-2008、kron21、com-Orkut、enwiki-2021各6个配置（k2–64）成功；com-LiveJournal和soc-LiveJournal1各6个配置失败。没有OOM或超时，标签已删除。逐配置时间/cut在results.csv，comparison.csv仅与data历史同图同k的Jet/Mt-METIS/KaMinPar切边对齐；k2没有该表中的对照，不伪填。

流程诊断（不计性能）：ppa k4首次粗化576039→99409，减少82.7427%；soc-Pokec k4首次粗化1632803→272134，减少83.3333%。两者均被源码的90%门槛拒绝，最终标签与该库直接对原图执行BFS初始化逐点完全相同。默认分组最多6点，粗点数至少ceil(N/6)，单层最多减少83.3333%，因此有效分组不会达到90%门槛；原图BFS后levels只有一层，反粗化/细化循环不执行。保留算法原样，未调整门槛来包装速度成绩。

失败诊断：com-LiveJournal k2在原binary上用Compute Sanitizer限定scatter_vertex_weights_kernel，报告13505个全局atomic越界错误，退出86；日志在logs/com-LiveJournal-memcheck.log。源码另有subset_index对组首标记做exclusive_scan的问题：标记[1,0,1,0]生成[0,1,1,2]，正确组号应为[0,0,1,1]，后者被用作粗组base索引；该问题与已撤回的旧G-kway固定层次存储修复不同。尚未做修正后的因果复验，不宣称排除了其他缺陷。sanitizer通过子进程启动，原生监视器会把其目标子进程标为overlap；该诊断不作时间样本。

结果定位：第三方未改源码的运行筛查已完成，但这份实现的默认流程与完整多层划分不符，不能直接作为论文官方G-kway†基线，也不能将47份输出补入原G-kway统计。所有证据单独保留，data和原G-kway表不变。
