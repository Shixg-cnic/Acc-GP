# 算法与GPU加速尝试历史

更新：2026-10-17。本文是维护中的统一历史入口，分为两部分；成功、失败、撤回和未验证都保留。状态“保留”表示进入当前源码，“历史采用”表示曾进入旧版本，“否决/撤回”表示不在当前主线，“待验证”不代表已实现或有成绩。每项倍数只对应注明的版本、输入和对照，整版结果不等于单项贡献。

当前主线为regret（2026-10-17按用户决定）；旧粗化分支已归档删除。该决定不改变此前九图筛选偏弱的结论，也不代表新颖性和速度目标已经达成。历史材料和失败结果继续保留，当前代码与运行方式见ALGORITHM/README。

## 一、划分质量与算法机制的创新/修改历史

本部分包括影响合并映射、候选、迁移、容量或搜索预算的修改；通用机制与Jet等继承机制不当作已证明原创。

| 日期/版本 | 尝试与动机 | 结果、局限及决定 | 状态/证据 |
| --- | --- | --- | --- |
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

本部分优先记录保持给定算法含义的布局、调度、压缩、缓存与资源管理。GPU调度可改变原子平局到达顺序，因此cut可能波动；精确CSR、容量和独立核验仍必须成立。

| 日期/版本 | 尝试 | 实测或验证、失败原因/限制 | 决定/证据 |
| --- | --- | --- | --- |
| 10-17，移除big及双宽模板 | 构建仅standard；图/层次/算法接口去掉Types模板，亲和力视图去掉偏移/边权双宽分支；脚本跳过超范围图 | 单类型改动先通过10项CTest；uint64/int64累计cut、负载和gain、按证据选择的缓存宽度仍保留。旧big生成物从build移除，历史实验核验仍可读取归档big哈希 | 保留；未把减少构建工作量称为算法加速 |
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

旧实验中其他screen/build目录保留在归档，完整目录索引列于归档README。若单项没有有效隔离结果，状态记为“原型/未独立归因”，不以目录存在推断成功。CPU Mt-METIS/KaMinPar全集1950次已完成，仅作对照不恢复重跑；其七列表在[CPU结果](../results/cpu-baselines-20261014/full-suite/REPORT.md)。

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
