# 划分实现布局

当前流程为coarsen → initial_partition_metis → uncoarsen/refine。初始化仅CPU METIS，没有GPU谱初始化后端；历史原型保存在同级../Acc-GP-archive/experiments的冻结快照，不参与构建。

| 文件 | 职责 |
|:--|:--|
| coarsen.cu | 粗化工作区、逐层调度、regret准入与精确CSR收缩主机编排 |
| coarsen_sclp.cuh | 共享精确亲和力、备选损失容量准入、two-hop、孤立点压缩设备实现 |
| coarsen_residual.cuh | 稳定接收簇、残余单点角色冻结、容量可行目标策略和已证明全接纳的直接提交 |
| coarsen_matching.cuh | 单轮容量合法互选重边种子 |
| coarsen_rows.cuh | 至多512条原始记录的行内精确排序和分段归并；短行/长行分开启动 |
| initial_partition_metis.cu | 最粗图传输、METIS类型/容量检查、一次METIS调用及可选CPU容量修复 |
| uncoarsen.cu | 解粗化公共入口和结果日志 |
| refine.cu | 细化工作区、层次投影与调度 |
| refine_affinity.cuh | 精确dense/sparse/on-demand邻接分区连接权重视图 |
| refine_incremental.cuh | 候选、迁移、精确cut/cache更新及细化主机编排 |
| refine_lp_graph.cuh | GPU条件图LP循环 |
| refine_rebalance_graph.cuh | 源桶/接收票据容量修复条件图 |
| refine_groups.cuh | legacy对照的小组候选、排序、范围树、事务准入 |
| refine_joint.cuh | 净容量引导双向连通组、并行分区对匹配、整组冲突过滤、精确事务前缀 |

.cuh为对应.cu的私有实现，不是可单独编译的后端。SCLP诊断、严格CSR核验和host LP参考仍有调用及正确性用途。默认流生产临时缓冲，非阻塞再平衡流先等待ready事件、返回前join；流序池及所有清理仍在完整算法计时内。

设备单位边权表示：include/detail/edge_weight.hpp统一读取精确整数边权；仅完整主机数组全为1时，DeviceWeightedGraph可省去该设备数组，coarse CSR仍保留完整显式权重。copy_device_weighted恢复完整主机CSR供METIS/核验。当前粗化唯一主线为regret；旧legacy/SCLP/residual分支已删除，冻结源码在仓库外。coarsen_sclp.cuh保留命名只表示共享基础算子。次强值缓冲在decode原位转为准入优先级，two-hop只求最强favorite；真实gain仍单独保存。结果边界及失败尝试见../docs/EXPERIMENT_HISTORY.md。

全接纳快路径使用W+W*D*M<=C的充分条件，证明失败时继续完整备选损失准入；不会先运行一种算法再丢弃结果。只在安全批省去top-two和排序/前缀/gather，不改变迭代预算或目标选择。详见根目录ALGORITHM.md。
