# 每日简报：资金流向 + 自选股分析与推荐

日期：2026-08-06 ｜ 状态：已落地（2026-08-06）

## 目标

每日简报（`daily_brief.py`）新增两块内容：

1. **资金流向**：每只票一行量价资金流数据（个股口径——市场级板块/ETF 资金流
   免费数据源拿不到可靠数字，明确不做）。
2. **自选分析与推荐**：只在自选、未持仓的票（watch − positions）单独成节，
   每只 1–2 句分析 + 固定建议标签。推荐停留在日报文字层面——正式买入建议
   仍由策略/顾问生成建议卡走 Policy 闸门，日报不生成建议卡。

原则不变：LLM 只解读 Python 算好的数字，不自己发明数据。

## 1. 资金流指标 — `assistant/quotes.py`

- `_yf_history_ohlc` 增加 `volume` 字段（现有调用方海龟只读
  high/low/close，向后兼容）。
- 新增：

  ```python
  def get_money_flow(ticker: str, end_date: str, *, _history=_yf_history_ohlc) -> dict | None:
      # {"volumeRatio": 1.8, "mfi14": 62.0, "obvTrend": "up", "chg5dPct": 3.2}
  ```

  - **volumeRatio**（量比）= 最新一日成交量 ÷ 之前 20 个交易日均量
  - **mfi14** = 标准 14 日 Money Flow Index（typical price × volume 的
    正/负流量比）
  - **obvTrend** = 近 5 个交易日 OBV 方向：`up` / `down` / `flat`
    （首尾差超过区间内 OBV 绝对变动的 ±20% 才算方向，否则 flat）
  - **chg5dPct** = 最近收盘 vs 往回数第 5 根日线收盘（`close[-1]` vs
    `close[-6]`）的涨跌 %
- 返回 `None` 的情况：bars 不足 21 根、成交量全零、ISIN（Borsa 债券/基金
  无成交量）。调用方一律按「无量价数据」降级。

## 2. 日报改动 — `assistant/daily_brief.py`

- Prompt 结构从「组合概览 → 个股点评 → 值得注意」改为：

  ```
  ## 组合概览 → ## 持仓点评 → ## 自选分析与推荐 → ## 值得注意
  ```

- 每只票的数据块新增一行（Python 拼好，LLM 解读）：

  ```
  资金流: 量比 1.80，MFI 62，OBV 5日走高，5日 +3.2%
  ```

  拿不到时写「资金流: 无量价数据」；单票拉取异常同新闻一样只降级该票。
- 自选节要求（写进 prompt）：
  - 只覆盖 watch-only 票；持仓票只出现在持仓点评，不重复。
  - 每只 1–2 句，结合行情、资金流、新闻。
  - 结尾给固定标签之一：**值得深挖 / 回调关注 / 观望 / 建议移除**。
- 双语机制照旧（`BILINGUAL_INSTRUCTION` + `split_bilingual`）。
- brief 文档结构不变（`quotes` map 照旧）；资金流数字不单独入库——
  目前没有 App 端消费方，YAGNI。

## 3. 错误处理

- `get_money_flow` 内部不抛：任何取数/计算失败 → `None`。
- 日报层面单票失败不影响整份（与现有新闻失败同一策略）。

## 4. 测试

- `tests/.../quotes`：手工构造 bars 验证量比/MFI/OBV/5日涨跌数值；
  bars 不足、量全零、ISIN → None。
- `tests/.../daily_brief`：prompt 含资金流行；自选节票单 = watch −
  positions；money flow 失败降级为「无量价数据」；brief 文档字段不变。

## 5. 成本

每票多一次 yfinance ~60 天日线调用（当前 watch ∪ positions ≈ 23 只），
跑在现有日报 job 里，无新依赖。
