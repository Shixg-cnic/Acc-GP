# 结果校验与基线对照

`verify_partition.py` 从原始对称 CSR 独立复算切边、分区负载、容量和标签范围。
本项目输出为二进制 int32 标签，Jet 文本输出使用 `--partition-format text`。

```bash
python3 tools/verify_partition.py \
  --indptr indptr.bin --indices indices.bin --parts 4 --partition result.part
```

`compare_jet.py` 交替运行当前完整划分与 Jet，每个配置使用独立进程，匹配
严格整数容量，记录二进制 SHA256、全部 cut/时间和范围。计时结束后再进行
CPU 独立校验，结果写入被忽略的 `results/`。工具需要用户提供已构建的 Jet，
主项目编译不依赖 Jet。

可加 `--reference results/before/gpart_partition_standard`，将保存的旧生产二进制
加入同批比较；三个版本轮换运行顺序，分别记录 SHA256，并核验每份输出。

```bash
CUDA_VISIBLE_DEVICES=0 python3 tools/compare_jet.py \
  --indptr ../dataset_benchmark/social_network/products/products_indptr.bin \
  --indices ../dataset_benchmark/social_network/products/products_indices.bin \
  --jet-graph ../dataset_benchmark/social_network/products/products.metis \
  --jet ../sotas/.build-deps/jet-5090/build-jet/app/jet \
  --output results/products-jet --parts 4 8 --repeats 5
```

比较使用 `algorithm_total_seconds`，排除加载、输入上传和最终输出。
研究目标是质量接近或优于 Jet，同时缩短完整算法时间；已记录的结果见
[算法对比](../ALGORITHM_COMPARISON.md)，不能以单次最差 Jet 输出作为基准。


`gpart_verify_csr` 是 CMake 构建的 CPU C++ 独立核验器，使用 mmap 和可选 OpenMP。
当前容量口径固定为 `floor(1.03*N/k)`，适用于本项目原始无权 CSR；没有将粗层权重当作单位权重验证。
可追加 `--symmetric`，对有序 CSR 逐项检查反向边的重复次数，既不丢掉平行边，也不把自环算入切边。
CTest 包括与 Python 核验器的交叉核对，以及偶数边数仍不对称、非法标签和超载的反例。

```bash
OMP_NUM_THREADS=8 build-5090/gpart_verify_csr \
  indptr.bin indices.bin 32 result.part binary --symmetric
```

Jet 文本标签将 `binary` 换成 `text`。`compare_jet.py` 可加
`--oracle build-5090/gpart_verify_csr` 加速计时后的独立核验；这部分时间不算划分时间。
对照工具核对 METIS/CSR 维度并识别 LFS 指针，记录物理 GPU UUID 和逐次 UTC 时间。
每次计时前后检查选中 GPU 的计算进程；被其他任务干扰时停止比较。
`--wait-idle` 可在每次运行前等待空闲，若运行中出现其他任务，仍停止并保留已完成记录。
