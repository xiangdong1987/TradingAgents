# 德国股票支持 + 按成本计价开关

日期：2026-08-10 ｜ 状态：已落地（2026-08-10）

## 背景与目标

1. **德股（.DE，Xetra）当前会被算错**：两端「欧元上市」判定硬编码为
   `.MI ∨ 意大利 ISIN`，德股被当美元资产——欧元报价被再除一次 EURUSD
   汇率（估值错 ~13%）、价格前缀显示 $、Policy 把它计入美元敞口。
   实测（SAP.DE/SIE.DE）：yfinance 欧元报价 ✓、成交量 ✓（资金流可用）、
   做空/期权数据无（同意股，如实标注）。
2. **无行情资产缺显式开关**：估值早已自动「无行情→按成本」，但非 ISIN
   代码显示「无行情」标签，且 runner 每轮白拉行情。加 `atCost` 开关。

用户已拍板：德股分红默认税率 **37.1%**（同美股，假设条约 15% 预扣）；
`atCost` 开关要做。

## A. 德股支持

### A1. 欧元上市判定（两端）

- Dart [portfolio_math.dart](app/lib/logic/portfolio_math.dart)
  `isEurListing` 加 `ticker.endsWith('.DE')`
- Python [policy.py](assistant/policy.py) `is_eur_listing` 加 `.DE`

这一条自动修好：EUR 折算（summarize/concentration/layerBreakdown/
Snapshot）、`currencyPrefix` 的 €、Policy `usd_pct_of`（德股=0 美元敞口）。

### A2. 分红默认税率（关键陷阱）

「欧元上市」≠「意大利税率」。两端拆出**意大利上市**概念：

- Dart `tax.dart`：`defaultIncomeTaxPct` 改用新谓词
  `isItalianListing(ticker)`（= `.MI` ∨ IT 开头 ISIN，加进
  portfolio_math.dart 并导出）→ 意大利 26%，其余（美/德）37.1%。
  若不拆，`.DE` 进 `isEurListing` 后德股分红会错落 26%。
- Python `income.py` `default_tax_pct` 现有实现已按 `.MI ∨ IT-ISIN`
  硬分支，德股自动 37.1% —— **不改**，加测试钉住即可。

### A3. 多空数据跳过

`quotes.py get_positioning` 的跳过条件 `.MI` 后缀改为 `.MI` 或 `.DE`
（实测德股无做空/期权数据，省两次白调用）。`get_money_flow`、日报、
海龟对 .DE 零改动自动可用。

## B. `atCost` 按成本计价开关

### B1. 数据模型

- `positions/{ticker}` 新字段 `atCost: bool`（缺省视为 false）
- Dart `Position` 加 `atCost`；`repo.setPosition` 加 `bool? atCost`
  参数（merge 写，模式同 `holdToMaturity`）

### B2. 估值语义（写死的假设：atCost 资产以欧元计）

- 估值统一规则：`atCost == true` 的持仓，市值 = `shares × avgCost`，
  **按 EUR 原币**，不查行情、不折汇率。落点：Dart `summarize` /
  `concentration` / `layerBreakdown`，Python `policy.snapshot`
- 分层推断：`atCost` 且未显式设 layer → `defensive`
  （Dart `layerOf` 与 Python `layer_of` 同步）
- 用户的无行情资产为欧元存单类，非欧元的 atCost 资产不支持
  （开关文案写明「按欧元成本计价」）

### B3. UI

- 持仓编辑框（`_PositionDialog`）加 SwitchListTile
  「无行情资产（按欧元成本计价）」，key `posAtCost`
- 持仓行 trailing：`p.atCost == true` → 显示「按成本计」
  （复用 `t.atCost`），优先于「无行情」；ISIN 现有行为不变

### B4. runner 侧跳过（省白调用 + 日报如实标注）

- `daily_brief.generate_daily_brief`：atCost 持仓的数据块写
  `按成本计价资产（无行情）`，跳过 fetch_quote/news/资金流/多空
  四类调用；持仓块该票盈亏写「按成本计」；照常计入 tickers 列表
- `daily_brief.top_up_quotes`：跳过 atCost 票
- `strategies/engine.scan`：跳过 atCost 票（现在只是取不到 bars
  静默失败，显式跳过更省更清晰）

判定方式：以上三处都拿得到 position dict，读 `p.get("atCost")`；
自选（watchlist）没有该字段，不受影响。

## 不做

- 非欧元的 atCost 资产（YAGNI）
- 法兰克福 `.F` 等其他德国后缀（Yahoo 上 Xetra `.DE` 覆盖即可，
  需要时一行扩展）
- 德股基准指数映射（deep analysis 的 benchmark backlog 项，另议）

## 测试

- Dart：`isEurListing('SAP.DE')` true / `isItalianListing('SAP.DE')`
  false / 德股分红默认 37.1%、意股 26%；德股持仓 EUR 估值不除汇率、
  € 前缀；atCost 持仓估值 = 欧元成本、无汇率也能算出总值；
  layerBreakdown 里 atCost 归防守、usdPct 不含德股；开关写入 Firestore；
  trailing 标签「按成本计」
- Python：`is_eur_listing(".DE")` true；`default_tax_pct("SAP.DE")`
  = 37.1（钉住现状）；`get_positioning("SAP.DE")` 不发请求返回 None；
  snapshot 里 atCost 按欧元成本、德股不进 usd exposure；日报跳过
  atCost 的四类 fetch 且 prompt 有「按成本计价资产」；top_up 跳过；
  engine 跳过
- 既有测试回归两端全绿

## 交付

App 有改动：完成后 web 部署（届时单独征求同意）+ runner 重启。
