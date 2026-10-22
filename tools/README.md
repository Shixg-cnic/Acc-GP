# 当前运行与核验工具

| 文件 | 用途 |
| --- | --- |
| `benchmark_selection.json` | 当前九类51图清单、排除项及实验参数 |
| `run_cpu_baselines.py` | 官方Mt-METIS、KaMinPar和mt-KaHIP测量；按变体保存身份，独立核验cut/负载，支持恢复、失败历史与临时标签清理 |
| `run_gkway.py` | 既有G-kway基线测量、错误记录、核验及断点续跑 |
| `result_storage.py` | 原始记录映射到仓库外archive，发布表格，持久化核验后删除标签 |
| `verify_csr.cpp` | 独立CPU CSR核验器，构建为`gpart_verify_csr` |

GPU批量测量与切边分析分别由根目录`run.sh`和`analyze_cuts.sh`执行。CPU/G-kway命令由`run_cpu_baselines.sh`和`run_gkway.sh`启动，详见根目录README及各入口`--help`。

旧`compare_jet.py`、`verify_partition.py`、`run_gpu_categories.py`、`check_gpu_categories.py`、`run_gpu_optimization.py`和`check_gpu_optimization.py`已从主仓库移除，清理前版本保存在同级archive的`maintenance/source-cleanup-20261019/before/tools/`。当前入口不依赖这些文件。
