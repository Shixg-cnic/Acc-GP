# 辅助工具

日常只用仓库根目录的两个入口：

```bash
./run.sh
./analyze_cuts.sh
```

构建目录为`build/`，由用户自行编译。用法、默认52图/六种k/三次重复/新粗化与旧粗化及Jet三方法、GPU选择、断点恢复和三个CSV的列含义见[根目录说明](../README.md)。脚本不生成报告或图片。

| 文件 | 用途 |
| --- | --- |
| benchmark_selection.json | 九类选集、k、用户删除/显存排除与目标 |
| verify_csr.cpp | 编译成build/gpart_verify_csr，从原始CSR独立计算cut、负载、容量 |
| verify_partition.py | Python独立核验参考，支持二进制/文本标签 |
| run_gpu_optimization.py | 保留的历史三方法实验入口，日常由run.sh代替 |
| run_gpu_categories.py | 保留的历史九类两方法入口，日常由run.sh代替 |
| compare_jet.py | 保留的显式输入旧对照入口与回归检查 |
| run_cpu_baselines.py | 已有官方CPU基线入口；旧1950次任务已完成，不自动重启 |
| check_gpu_optimization.py / check_gpu_categories.py | 历史实验保存记录的审计 |
| result_storage.py | 旧入口的路径迁移、标签清理和CSV辅助 |

旧`report_gpu_*.py`和`plot_gpu_*.py`已迁到同级`../Acc-GP-archive/legacy-tools-20261016/`，不再作为当前流程的依赖。单独的Python/C++核验器只读标签，不替调用者删除标签；自动清理由两个.sh入口负责。
