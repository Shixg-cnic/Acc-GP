# 实验结果表格索引

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
