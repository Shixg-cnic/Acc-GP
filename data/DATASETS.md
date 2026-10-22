# 当前实验数据集清单

整理日期：2026-10-19。当前选集共 **9 类、51 个数据集名称**，与 [benchmark_selection.json](../tools/benchmark_selection.json) 及 [baselines.csv](baselines.csv) 一致。各 baseline 的运行覆盖单独记录。

## 分类清单

| 类别 | 数量 | 数据集 |
| --- | ---: | --- |
| Web Crawl（网页图） | 2 | `wb-edu`、`uk-2002` |
| Social Network（社会网络） | 8 | `enwiki-2021`、`com-Orkut`、`hollywood-2011`、`soc-Pokec`、`citation`、`com-LiveJournal`、`soc-LiveJournal1`、`ljournal-2008` |
| Semiconductor（半导体/电路图） | 4 | `circuit5M`、`vas_stokes_2M`、`vas_stokes_4M`、`stokes` |
| Road Network（道路网络） | 2 | `road_usa`、`europe_osm` |
| Optimization（优化问题） | 3 | `nlpkkt120`、`nlpkkt160`、`nlpkkt200` |
| Finite Element（有限元） | 14 | `fe_rotor`、`af_shell10`、`Hook_1498`、`Geo_1438`、`Serena`、`audikw_1`、`channel-500x100x100-b050`、`Long_Coup_dt0`、`dielFilterV3real`、`ML_Geer`、`Flan_1565`、`af_shell1`、`dielFilterV3clx`、`Long_Coup_dt6` |
| Biology（生物图） | 4 | `ppa`、`cage15`、`kmer_V2a`、`kmer_U1a` |
| Artificial Mesh（人工网格） | 10 | `grid`、`cube`、`delaunay_n23`、`hugebubbles-00000`、`hugebubbles-00010`、`rgg_n_2_22_s0`、`hugebubbles-00020`、`delaunay_n24`、`rgg_n_2_23_s0`、`rgg_n_2_24_s0` |
| Artificial Complex（人工复杂图） | 4 | `kron_g500-logn20`、`mycielskian17`、`kron_g500-logn21`、`mycielskian18` |
| **合计** | **51** | |

## 输入与实验范围

- 图文件目录：`../../dataset_benchmark/`。名称以表中实际实验标识为准。
- 主实验 k：4、8、16、32、64、128；G-kway 当前测试范围为 2、4、8、16、32、64。
- `Long_Coup_dt0` 与 `Long_Coup_dt6` 的现有 CSR 输入哈希相同，因此上述 51 个名称对应 **50 个唯一 CSR 结构**；当前清单仍保留两个名称。

## 已排除的数据集

- 按用户要求排除：`Cube_Coup_dt6`、`Queen_4147`、`HV15R`、`Cube_Coup_dt0`、`Bump_2911`、`products`。
- 因显存问题排除：`kmer_P1a`、`kmer_A2a`、`kmer_V1r`。
