# 生产实现导航

主流程：`coarsen.cu` → `initial_partition_metis.cu` → `uncoarsen.cu` / `refine.cu`，图表示由`graph.cpp`维护。

- `coarsening/`：重边种子、残余单点增长、备选损失准入和精确粗CSR构造。
- `refinement/`：精确亲和力、探索LP、容量修复、容量互补交换及增量维护。

`.cuh`保持原来的include位置与顺序，属于相应`.cu`的私有实现；不独立编译。核函数、调度、参数与计时未因目录整理改变。`SclpWorkspace`等历史C++标识继续保留，当前生产粗化只有备选损失准入主线。

[完整文件职责](../docs/STRUCTURE.md) · [算法与论文方法](../ALGORITHM.md) · [已有基础与贡献](../ALGORITHM_COMPARISON.md)
