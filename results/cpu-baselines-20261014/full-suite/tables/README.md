# CPU baseline 七列结果表

两个方法分别存表；每个表覆盖所有选定图和 k。CSV 使用 UTF-8 BOM，可直接用 Excel 打开。

- `median.csv` / `median.md`：各指标分别取全部重复的中位数；只有重复输出均完成结构核验后才填写。超出平衡约束的输出仍参与统计。
- `run1.csv` / `run1.md` 等：逐次原始结果，运行编号在文件名中。
- 节点平衡比例 = 最大分区节点数 / (总节点数 / k)；配置上限为 1.03，表内填写实际测量值。
- 切边数按无向边计一次；切边比例 = 切边数 / 无向边总数，以小数表示。
- 划分时间单位为秒，排除输入加载、输出写盘与独立核验，采用原生完整划分时间。
- 空白表示尚未测得或未通过结构核验，具体运行/平衡状态见 `../runs.json` 和 `../summary.json`。
- 线程、CPU 绑定、NUMA、版本、种子和二进制哈希见 `../metadata.json`。

## 中位数表

- [Mt-METIS HS CSV](mtmetis/median.csv) / [Markdown](mtmetis/median.md)
- [KaMinPar CSV](kaminpar/median.csv) / [Markdown](kaminpar/median.md)
