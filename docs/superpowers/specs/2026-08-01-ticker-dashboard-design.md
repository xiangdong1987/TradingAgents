# 自选股分析仪表盘（Ticker Dashboard）设计

日期：2026-08-01 ｜ 状态：已实现

## 目标

自选 tab 点进一只股票后，第一屏即以可视化仪表盘展示**最近一次深度分析**：
评级、关键价位、多空观点、技术信号、基本面要点、风控结论、历史评级，一页看全；
所有原文可在本页内展开，不再需要「历史列表 → 逐条点进 → 逐节展开」三层跳转。

## 数据来源（全部已有，无 runner 改动）

- `repo.analysesForTicker(ticker)` → 最新一条做仪表盘，其余做历史评级时间线
- `latestBriefProvider` → 现价 / 当日涨跌
- `activeJobsProvider` + `enqueueDeepAnalysis` → 「重新分析」按钮与排队/运行状态
- `Analysis.decision` → 5 档评级：Sell / Underweight / Hold / Overweight / Buy
  （runner 侧 `parse_rating` 保证枚举，App 侧仍容错解析）

### sections 的可解析结构（对 Firestore 真实文档实测）

| section | 结构 |
|---|---|
| portfolioDecision / finalDecision | `**Rating**: X`、`**Executive Summary**: …`、`**Time Horizon**: …` |
| traderPlan | `**Action**:`、`**Entry Price**:`、`**Stop Loss**:`、`**Position Sizing**:` |
| sentiment | `**Overall Sentiment:** **Neutral** (Score: 5.0/10)`、`**Confidence:**` |
| researchManager | `**Recommendation**:`、`**Rationale**:` |
| market | 末尾「关键指标汇总表」：\| 指标 \| 当前值 \| 信号 \| 强度 \| |
| fundamentals | 「核心估值指标」表：\| 指标 \| 数值 \| 分析评估 \| |
| bull / bear / risk* | `Bull Analyst: …` 等前缀的辩论文本 |

LLM 输出有波动 ⇒ 所有解析器缺数据时返回空，对应区块**整块隐藏**，绝不渲染坏数据。

## 架构

### `lib/logic/analysis_insights.dart` — 纯函数解析层（可单测）

- `kvValue(md, keys)`：解析 `**Key**: v` 与 `**Key:** v` 两种加粗形态
- `ratingIndex(decision)` 0..4、`ratingZh`、评级色
- `sentimentScore(md)` → `Score: x/10`
- `parseMdTables(md)` → 通用 markdown 表格解析
- `indicatorRows(marketMd)` → 指标行（名称/当前值/信号 + 多空 tone）
- `fundamentalRows(fundamentalsMd)` → 估值指标行
- `toneOf(text)` → 偏多/偏空/中性（✅⚠️➡️/看涨看跌/多空 关键词）
- `priceLevels(sections)` → 现价/入场/止损/均线/布林 数值提取（供价位标尺）
- `cleanDebate(md)` → 去 `X Analyst:` 前缀
- `firstSentences(md, n)` → 摘要截取（去 markdown 语法噪声）

### `lib/ui/ticker_dashboard_page.dart` — 仪表盘页

区块自上而下（数据缺失即隐藏）：

1. **评级横幅**：5 档色带标尺（卖出→买入，当前档指针）+ 大徽章 + 现价/涨跌 + 分析日期 + 重新分析按钮（复用 job 状态 chip）
2. **交易计划磁贴**：方向 / 入场价 / 止损价 / 仓位建议 / 时间视野 + 情绪分进度条
3. **价位标尺**（CustomPaint 数轴）：止损、布林三轨、50/200 均线、入场、现价落点
4. **技术信号**：多空计数堆叠条（x 偏多 · y 中性 · z 偏空）+ 指标 chips（↑↓→ 着色）
5. **基本面要点**：估值指标网格（市盈率/PEG/股息率/ROE/负债…）
6. **多空对辩**：绿/红双栏摘要，点击内联展开全文
7. **结论三卡**：研究主管 / 交易员 / 组合经理（摘要 + 展开）
8. **风控视角**：激进 / 中性 / 保守 三栏（摘要 + 展开）
9. **新闻卡**：摘要 + 展开
10. **历史评级时间线**：横向评级色点 chips，点开旧报告全文（AnalysisDetailPage）

- AppBar action → 原 `TickerAnalysesPage`（完整历史列表保留）
- 空态：无分析 → 引导排队；ISIN 债券 → 提示不支持深度分析
- `watch_tab.dart` 的 onTap 改跳 `TickerDashboardPage`

## 测试

- `test/analysis_insights_test.dart`：以真实 ENEL.MI 分析片段做 fixture，覆盖 kv 双格式、
  评级容错（`**SELL**`/中文）、Score 解析、表格解析、tone 判定、价位提取
- `test/ticker_dashboard_test.dart`：fake_cloud_firestore 全流程——评级徽章、磁贴数值、
  技术信号 chips、时间线、展开原文、空态 CTA、重新分析入队 job

## 取舍

- 不引入图表库：评级标尺/价位数轴/堆叠条用原生 widget + CustomPaint 即可，避免 fl_chart 依赖
- 不做价格 K 线：briefs 里仅有当日收盘价、历史太短；价位标尺已表达「现价相对关键位」
- 不改 runner/Firestore schema：纯客户端解析已够；将来 runner 若写结构化字段可平滑替换
