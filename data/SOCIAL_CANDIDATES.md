# 新增社交网络候选：G-kway 运行筛查

日期：2026-10-19。基于此前 G-kway 能输出结果的 41 张图，以下 **5 张新增图均通过 k=2、4、8、16、32、64**。通过表示输出标签合法、切边经独立复算一致；按用户要求，超载输出保留。未修改 G-kway 算法，使用此前论文粗化阈值冻结版本。

## 已通过的五张图

| 图 | 实测点数 | 无向边数 | 网络含义 | 通过配置 |
| --- | ---: | ---: | --- | --- |
| wiki-Talk | 2,394,385 | 4,659,565 | Wikipedia 用户讨论 | 全部六个 k |
| com-DBLP | 317,080 | 1,049,866 | DBLP 合著 | 全部六个 k |
| dblp-2010 | 226,413 | 716,460 | DBLP 合著（现有处理版本） | 全部六个 k |
| hollywood-2009 | 1,069,126 | 56,306,653 | 演员合作（现有处理版本） | 全部六个 k |
| ego-Facebook | 4,039 | 88,234 | Facebook 好友 | 全部六个 k |

`ego-Facebook` 仅 4,039 点，适合作为运行兼容性候选，不能代表大图 GPU 性能。目前另行准备 `com-Youtube`、`loc-gowalla`，检查能否提供更大规模替代；尚未给它们标记通过。

`amazon-2008` 也通过六个 k，但它属于商品共同购买网络，单列为备选，不计入上表五张真实社交/合著网络。

## 全部候选筛查结果

| 图 | 有效输出配置数 / 6 | 其他结果 |
| --- | ---: | --- |
| soc-Epinions1 | 0/6 | runtime_error: 6 |
| soc-Slashdot0902 | 0/6 | runtime_error: 6 |
| wiki-Talk | 6/6 | 全部通过 |
| com-DBLP | 6/6 | 全部通过 |
| ca-AstroPh | 3/6 | out_of_memory: 1；skipped_after_oom: 2 |
| dblp-2010 | 6/6 | 全部通过 |
| hollywood-2009 | 6/6 | 全部通过 |
| amazon-2008 | 6/6 | 全部通过 |
| ca-CondMat | 2/6 | out_of_memory: 1；skipped_after_oom: 3 |
| ca-HepTh | 1/6 | out_of_memory: 1；skipped_after_oom: 4 |
| ca-GrQc | 0/6 | skipped_after_oom: 6 |
| ego-Facebook | 6/6 | 全部通过 |
| ca-HepPh | 2/6 | out_of_memory: 1；skipped_after_oom: 3 |

完整逐配置时间、切边、状态见 [social_gkway_candidates.csv](social_gkway_candidates.csv)。`out_of_memory` 表示程序报告内存分配错误；已停止该图后续 k。没有用失败运行的墙钟时间充当划分时间。

## 来源和复现

- SNAP：[wiki-Talk](https://snap.stanford.edu/data/wiki-Talk.html)、[com-DBLP](https://snap.stanford.edu/data/com-DBLP.html)、[ego-Facebook](https://snap.stanford.edu/data/ego-Facebook.html)。新下载图做稠密 ID 重编号、去自环、对称化和无向边去重。
- 已有处理图：[dblp-2010](https://sparse.tamu.edu/LAW/dblp-2010)、[hollywood-2009](https://sparse.tamu.edu/LAW/hollywood-2009)。沿用本项目已有核验输入，表中尺寸为实际 CSR 尺寸。
- 冻结 G-kway SHA256：`5014ba48486c7afcc25c6f4aa43dcc3b60e61b5f45026fd46903a4657442d509`。
- 筛查原始日志、独立核验与冻结程序在仓库外 `Acc-GP-archive/experiments/social-candidates-20261019/` 和 `social-extra-20261019/`；下载 URL、源文件哈希、转换过程在 `cohort41-social-20261019/`。
- 划分标签已在核验保存后删除。未改动主实验 `benchmark_selection.json`；新图尚无 Acc-GP、Jet、CPU 的完整对照，不混入 41 图平均加速比。
