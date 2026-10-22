# 当前工作与接续

更新：2026-10-22。本次发布包含生产源码整理、容量互补细化及GPU执行优化，具体尝试与测量身份见实验历史。

## 已完成：默认 Mt-METIS → mt-KaHIP

用户授权51图、k=4/8/16/32/64、每配置3次。先运行Mt-METIS 0.7.2默认greedy（省略-r），再运行mt-KaHIP 1.00的multitrysocialparallel（MLS）。均使用32物理核、CPU0–31、NUMA交错0/1、seed0，每批765次；历史HS数据独立保留。

控制器：`../Acc-GP-archive/experiments/cpu-default-mtkahip-20261019/queue.py`。10月22日核对总队列状态为`complete`：Mt-METIS的765次中473次success、292次balance_exceeded；mt-KaHIP的765次中760次success、3次balance_exceeded、2次runtime_error。原始日志、程序身份与核验在archive；CSV位于：

- `results/cpu-default-mtkahip-20261019/mtmetis-greedy/`
- `results/cpu-default-mtkahip-20261019/mtkahip-mls/`

mt-KaHIP源码commit为`3afd84fe49f18ff05b80b4bfd2ecb877e44129d3`，未修改源码，Release/GCC13/64BITMODE构建，仅补TBB头文件搜索路径。其原生计时为perform_partitioning调用区间，不含此前的线程池创建。临时标签使用`/dev/shm/accgp-cpu-labels`并在核验后删除，避免逐行flush在NFS上耗时。小图验证结果不混入正式测量。

队列启动时锁定`tools/run_cpu_baselines.py`与`tools/benchmark_selection.json`哈希；测量身份读取归档记录，不用当前工作区状态覆盖历史身份。

## 已完成：生产源码与论文方法整理

移除15个测试源文件、独立粗化检查程序和6个旧实验脚本；删除对应构建目标。私有头文件归入`src/coarsening/`、`src/refinement/`，公共容量准入和收缩记录头按职责命名。生产编译单元、库边界及可执行文件名保持原样。

10月19日整理时，32份生产C++/CUDA文件经include路径还原后与整理前逐字节一致，所有本地include均可解析。该等价结论针对目录清理，不包含10月22日的事件归约改动。GPU编译仍由用户在`build/`中执行。

清理前源码、旧文档和未提交改动快照：`../Acc-GP-archive/maintenance/source-cleanup-20261019/before/`；迁移清单与核对结果在该目录的父目录。旧测试保存在快照中，不再是主仓库构建入口。

## 10月22日源码改动与验证

`src/refinement/exchange.cuh::joint_events`将写向本事务的逐边原子加改为warp内累计后至多一次原子写回，远端事件保持原位置。候选、容量、冲突筛选和前缀次序不变。CPU oracle共2508个案例、33267个前缀，旧事件、新事件与独立切边重算一致；尚未CUDA编译或GPU测量。本次发布不把历史加速比归因于这项改动。

## 写作入口

1. [ALGORITHM.md](ALGORITHM.md)：当前流程、两个方法贡献、公式、伪代码与GPU实现。
2. [ALGORITHM_COMPARISON.md](ALGORITHM_COMPARISON.md)：组成机制的来源与区别。
3. [docs/STRUCTURE.md](docs/STRUCTURE.md)：文件树、模块职责和构建边界。

当前粗化主线为稳定接收簇聚合，以最佳与次佳连接差值分配容量；细化为探索LP与容量互补交换；初始化调用METIS。论文工程位于同级`paper/`，不在本Git仓库中。当前讨论重点是两个机制如何重组GPU任务、局部化依赖并控制重复工作。

最新51图GPU测量位于`results/manual/cohort51-20261019/`，该批使用冻结程序并复用既有Jet结果。每份结果的程序身份按对应归档记录读取；目录清理不改变其来源。此前候选、失败试验及旧版本状态见[实验历史](docs/EXPERIMENT_HISTORY.md)和清理前快照，不作为新的运行指令。
