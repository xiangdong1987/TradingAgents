# 德股支持 + atCost 开关 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `.DE` 德股按欧元正确估值/计税/展示；持仓新增 `atCost` 开关让无行情资产按欧元成本计价并全链路跳过行情拉取。

**Architecture:** 两端「欧元上市」判定（Dart `isEurListing` / Python `is_eur_listing`）加 `.DE`；Dart 税率分支从 `isEurListing` 拆出新谓词 `isItalianListing`（Python 现有实现已按意大利条件硬分支，不改只钉测试）；`positions.atCost` 字段贯穿 Dart 三个聚合器与 Python `policy.snapshot` 的估值（欧元成本、零美元敞口、默认防守层），runner 侧日报/行情补齐/策略扫描三处跳过 atCost 票。

**Tech Stack:** Python 3.12（repo `.venv`）+ pytest；Flutter/Dart + flutter_test（fake_cloud_firestore）。

## Global Constraints

- Python 测试从仓库根目录：`source .venv/bin/activate && python -m pytest tests/<file> -q; echo RC=$?`
- Flutter 测试从 `app/` 目录：`flutter test <file>`；cwd 会漂，用绝对路径最稳
- 无新第三方依赖；brief 文档 schema 不变；双语机制不动
- atCost 资产**按欧元成本计价**（写死的假设，开关文案写明「按欧元成本计价」）
- 德股分红默认税率 37.1%（同美股）；意大利上市（`.MI` ∨ IT 开头 ISIN）26%
- 直接提交本地 `main`，commit message 带 `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

---

### Task 1: Python 数据层——`.DE` 欧元判定 + positioning 跳过 + snapshot 支持 atCost

**Files:**
- Modify: `assistant/policy.py`（`is_eur_listing`、`layer_of`、`snapshot`）
- Modify: `assistant/quotes.py`（`get_positioning` 跳过条件）
- Test: `tests/test_assistant_policy.py`、`tests/test_assistant_quotes.py`、`tests/test_assistant_income.py`（都追加到模块顶层）

**Interfaces:**
- Consumes: 既有 `is_isin`、`merged`、`Holding`、`Snapshot`、`default_tax_pct`
- Produces（Task 2/3 依赖的语义）: `is_eur_listing("SAP.DE") == True`；`snapshot` 接受含 `"atCost": True` 的 position dict（估值 = shares×avgCost 欧元、usd_pct=0、缺省层 defensive）；`layer_of` 对 atCost 持仓返回 `"defensive"`；`get_positioning` 对 `.DE` 不发请求返回 None

- [ ] **Step 1: 写失败测试**

`tests/test_assistant_policy.py` 末尾追加：

```python
# ---------- 德股（.DE）与 atCost ----------

def test_de_listing_is_eur():
    from assistant.policy import is_eur_listing
    assert is_eur_listing("SAP.DE")
    assert is_eur_listing("ENEL.MI")
    assert not is_eur_listing("MSFT")


def test_de_stock_valued_without_fx_division():
    from assistant import policy
    snap = policy.snapshot(
        [{"ticker": "SAP.DE", "shares": 10, "avgCost": 150.0}],
        1000.0, "EUR",
        {"SAP.DE": {"close": 100.0}, "EURUSD=X": {"close": 1.25}},
    )
    h = snap.holdings[0]
    assert h.value_eur == 1000.0          # 10×100 欧元，不该再除 1.25
    assert h.usd_pct == 0.0               # 德股不是美元敞口


def test_de_only_portfolio_needs_no_fx():
    from assistant import policy
    snap = policy.snapshot(
        [{"ticker": "SAP.DE", "shares": 10, "avgCost": 150.0}],
        1000.0, "EUR", {"SAP.DE": {"close": 100.0}},   # 无 EURUSD=X
    )
    assert snap is not None and snap.total_eur == 2000.0


def test_at_cost_position_valued_at_eur_cost():
    from assistant import policy
    snap = policy.snapshot(
        [{"ticker": "DEPOSITO2027", "shares": 1, "avgCost": 5000.0,
          "atCost": True}],
        0.0, "EUR", {},                                 # 无任何行情、无汇率
    )
    h = snap.holdings[0]
    assert h.value_eur == 5000.0
    assert h.usd_pct == 0.0
    assert h.layer == "defensive"          # atCost 缺省归防守


def test_at_cost_explicit_layer_wins():
    from assistant import policy
    snap = policy.snapshot(
        [{"ticker": "DEPOSITO2027", "shares": 1, "avgCost": 5000.0,
          "atCost": True, "layer": "core"}],
        0.0, "EUR", {},
    )
    assert snap.holdings[0].layer == "core"
```

`tests/test_assistant_quotes.py` 末尾追加：

```python
def test_positioning_none_for_de_without_fetching():
    from assistant.quotes import get_positioning
    def boom(t):
        raise AssertionError("德股不应该发请求")
    assert get_positioning("SAP.DE", _ticker_factory=boom) is None
```

`tests/test_assistant_income.py` 末尾追加（钉住现状，防止有人日后把税率分支改成 is_eur_listing）：

```python
def test_german_dividend_defaults_to_us_style_tax():
    from assistant.income import default_tax_pct, TAX_PCT_US_TOTAL, TAX_PCT_IT
    assert default_tax_pct("SAP.DE") == TAX_PCT_US_TOTAL   # 37.1，非 26
    assert default_tax_pct("ENEL.MI") == TAX_PCT_IT
```

- [ ] **Step 2: 跑测试确认失败**

```bash
source .venv/bin/activate && python -m pytest tests/test_assistant_policy.py tests/test_assistant_quotes.py tests/test_assistant_income.py -q -k "de_ or at_cost or german"; echo RC=$?
```

预期：policy/quotes 的新测试 FAIL（income 的可能已过——现有实现本就正确）

- [ ] **Step 3: 实现**

`assistant/policy.py` 三处：

① `is_eur_listing`：

```python
def is_eur_listing(ticker: str) -> bool:
    """.MI/.DE 上市与 IT 开头的 ISIN 按欧元计价（与 App 侧 isEurListing 同义）。"""
    return (ticker.endswith(".MI") or ticker.endswith(".DE")
            or (ticker.startswith("IT") and is_isin(ticker)))
```

② `layer_of` 最后一行改为：

```python
    if is_isin(ticker) or (position or {}).get("atCost"):
        return "defensive"
    return "satellite"
```

③ `snapshot` 的 holdings 循环，在 `price = ...` 之前插入：

```python
        if pos.get("atCost"):
            # 无行情资产：按欧元成本计价（spec B2），不查行情、不折汇率
            cost = float(pos.get("avgCost") or 0.0)
            holdings.append(Holding(
                ticker=ticker, shares=shares, price_native=cost,
                value_eur=shares * cost,
                layer=layer_of(ticker, pos, p), usd_pct=0.0,
                hold_to_maturity=is_hold_to_maturity(ticker, pos, p),
            ))
            continue
```

`assistant/quotes.py` `get_positioning` 跳过条件改为：

```python
    if is_isin(ticker) or ticker.upper().endswith((".MI", ".DE")):
        return None
```

同函数 docstring 里的「ISIN、.MI 无此数据」改为「ISIN、.MI、.DE 无此数据」。

- [ ] **Step 4: 跑测试确认通过（含既有回归）**

```bash
source .venv/bin/activate && python -m pytest tests/test_assistant_policy.py tests/test_assistant_quotes.py tests/test_assistant_income.py tests/test_assistant_strategies.py tests/test_assistant_advisor.py -q; echo RC=$?
```

预期：全绿，RC=0

- [ ] **Step 5: Commit**

```bash
git add assistant/policy.py assistant/quotes.py tests/test_assistant_policy.py tests/test_assistant_quotes.py tests/test_assistant_income.py
git commit -m "feat(assistant): .DE 欧元判定 + snapshot 支持 atCost

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Python runner 侧——日报/行情补齐/策略扫描跳过 atCost

**Files:**
- Modify: `assistant/daily_brief.py`（`generate_daily_brief` 循环、`top_up_quotes`）
- Modify: `assistant/strategies/engine.py`（`run_scan` 的 ticker 循环）
- Test: `tests/test_assistant_daily_brief.py`、`tests/test_assistant_strategies.py`

**Interfaces:**
- Consumes: position dict 的 `atCost` 字段（Task 1 语义）
- Produces: 日报里 atCost 票的数据块固定为 `## {t}（持仓）\n按成本计价资产（无行情）`，持仓块该票行尾为 `按成本计`；`top_up_quotes`/`run_scan` 对 atCost 票零 fetch

- [ ] **Step 1: 写失败测试**

`tests/test_assistant_daily_brief.py` 末尾追加：

```python
def test_brief_at_cost_position_skips_all_fetches():
    calls = {"quote": [], "news": [], "mf": [], "posi": []}
    store, llm = make_store(), FakeLLM()
    store.seed_positions([
        {"ticker": "AAPL", "shares": 10, "avgCost": 100.0, "updatedAt": "x"},
        {"ticker": "DEPOSITO2027", "shares": 1, "avgCost": 5000.0,
         "updatedAt": "x", "atCost": True},
    ])
    def rec(bucket, ret):
        def f(t, *a, **kw):
            calls[bucket].append(t)
            return ret
        return f
    generate_daily_brief(
        store, llm, "2026-08-01",
        fetch_quote=rec("quote", {"ticker": "AAPL", "close": 110.0,
                                  "prevClose": 100.0, "pctChange": 10.0}),
        fetch_news=rec("news", "n"),
        fetch_money_flow=rec("mf", None),
        fetch_positioning=rec("posi", None),
        fetch_futures=lambda: [])
    prompt = llm.prompts[0]
    assert "## DEPOSITO2027（持仓）\n按成本计价资产（无行情）" in prompt
    assert "DEPOSITO2027: 1 股 @ 成本 5000.0，按成本计" in prompt
    for bucket in calls.values():
        assert "DEPOSITO2027" not in bucket        # 四类 fetch 全部没碰它
    saved = store.get_brief("2026-08-01")
    assert "DEPOSITO2027" in saved["tickers"]      # 照常计入 tickers


def test_top_up_skips_at_cost_ticker():
    store = make_store()
    store.seed_positions([
        {"ticker": "DEPOSITO2027", "shares": 1, "avgCost": 5000.0,
         "updatedAt": "x", "atCost": True},
    ])
    store.save_brief("2026-08-01", {
        "date": "2026-08-01", "markdownZh": "x", "tickers": [],
        "createdAt": "2026-08-01T00:00:00+00:00", "quotes": {}})
    fetched = []
    def q(t):
        fetched.append(t)
        return {"ticker": t, "close": 1.0, "prevClose": 1.0, "pctChange": 0.0}
    top_up_quotes(store, "2026-08-01", fetch_quote=q)
    assert "DEPOSITO2027" not in fetched
```

（文件顶部 import 行若缺 `top_up_quotes` 就补上：`from assistant.daily_brief import generate_daily_brief, top_up_quotes`。）

`tests/test_assistant_strategies.py` 末尾追加（参照文件内既有 run_scan 测试的 store 搭建方式——通常是 `MemoryStore` + `seed_strategy_config` 开启 turtle + `seed_positions`；照抄相邻测试的搭建代码）：

```python
def test_run_scan_skips_at_cost_positions():
    store = _scan_store()          # ← 用文件里既有的搭建 helper；没有就照相邻测试内联搭建
    store.seed_positions([
        {"ticker": "DEPOSITO2027", "shares": 1, "avgCost": 5000.0,
         "updatedAt": "x", "atCost": True},
    ])
    bars_calls = []
    def fetch_bars(t, today, days=200):
        bars_calls.append(t)
        return []
    from assistant.strategies.engine import run_scan
    run_scan(store, {"type": "strategy_scan", "strategy": "turtle"},
             "2026-08-01", fetch_bars=fetch_bars,
             fetch_quote=lambda t: {"ticker": t, "close": 1.0,
                                    "prevClose": 1.0, "pctChange": 0.0})
    assert "DEPOSITO2027" not in bars_calls
```

- [ ] **Step 2: 跑测试确认失败**

```bash
source .venv/bin/activate && python -m pytest tests/test_assistant_daily_brief.py tests/test_assistant_strategies.py -q -k at_cost; echo RC=$?
```

预期：FAIL（prompt 无「按成本计价资产」/ fetch 被调到）

- [ ] **Step 3: 实现**

`assistant/daily_brief.py` 两处：

① `generate_daily_brief` 的 ticker 循环开头（`for t in tickers:` 之后第一件事）插入，并把循环尾部原有的 `pos = positions.get(t)` 删掉、后续引用改用这里的 `pos`：

```python
        pos = positions.get(t)
        if pos and pos.get("atCost"):
            # 无行情资产：按欧元成本计价，行情/新闻/资金流/多空全部不拉
            ticker_parts.append(f"## {t}（持仓）\n按成本计价资产（无行情）")
            position_parts.append(
                f"- {t}: {pos['shares']} 股 @ 成本 {pos['avgCost']}，按成本计")
            continue
```

② `top_up_quotes` 里 tickers 的构造改为同时收集 atCost 集合并从补齐范围排除：

```python
    at_cost: set[str] = set()
    tickers = {w["ticker"] for w in store.get_watchlist()}
    for p in store.get_positions():
        tickers.add(p["ticker"])
        if p.get("atCost"):
            at_cost.add(p["ticker"])
    if not tickers:
        return 0
```

补齐循环行改为：

```python
    for t in sorted(tickers - set(existing) - at_cost):
```

`assistant/strategies/engine.py` `run_scan` 的 ticker 循环开头（`for ticker in _tickers_for(...)` 之后、bars_cache 判断之前）插入：

```python
            if (positions.get(ticker) or {}).get("atCost"):
                continue    # 无行情资产，扫描无意义
```

- [ ] **Step 4: 跑测试确认通过**

```bash
source .venv/bin/activate && python -m pytest tests/test_assistant_daily_brief.py tests/test_assistant_strategies.py tests/test_assistant_runner.py tests/test_assistant_jobs.py -q; echo RC=$?
```

预期：全绿，RC=0

- [ ] **Step 5: Commit**

```bash
git add assistant/daily_brief.py assistant/strategies/engine.py tests/test_assistant_daily_brief.py tests/test_assistant_strategies.py
git commit -m "feat(assistant): 日报/补齐/扫描跳过 atCost 资产

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Dart 逻辑层——.DE/isItalianListing/税率/atCost 估值

**Files:**
- Modify: `app/lib/logic/portfolio_math.dart`（`isEurListing`、新 `isItalianListing`、`summarize`、`concentration`）
- Modify: `app/lib/logic/tax.dart`（`defaultIncomeTaxPct`）
- Modify: `app/lib/logic/policy.dart`（`layerOf`、`layerBreakdown`）
- Modify: `app/lib/models/models.dart`（`Position.atCost`）
- Modify: `app/lib/data/repo.dart`（`setPosition` 加 `atCost`）
- Test: `app/test/portfolio_math_test.dart`、`app/test/tax_test.dart`、`app/test/policy_test.dart`、`app/test/repo_test.dart`

**Interfaces:**
- Consumes: 既有 `Position`/`PortfolioMeta`/`TickerQuote`、`summarize`/`concentration`/`layerBreakdown`
- Produces（Task 4 依赖）: `Position.atCost`（`bool?`，fromDoc 读 `d['atCost'] as bool?`）；`repo.setPosition(..., bool? atCost)`（merge 写 `'atCost': ?atCost`）；`isItalianListing(String) -> bool`；atCost 持仓在三个聚合器里 = shares×avgCost 欧元、层缺省 defensive、不进 usdPct

- [ ] **Step 1: 写失败测试**

`app/test/portfolio_math_test.dart` 末尾追加（沿用文件内既有的 `_pos`/`_meta`/quote 构造 helper，命名以文件实际为准；没有就内联构造）：

```dart
  group('.DE 与 atCost', () {
    test('SAP.DE 按欧元计价，不再除汇率', () {
      expect(isEurListing('SAP.DE'), isTrue);
      expect(isItalianListing('SAP.DE'), isFalse);
      expect(isItalianListing('ENEL.MI'), isTrue);
      expect(isItalianListing('IT0005696320'), isTrue);
      final s = summarize(
        [Position(ticker: 'SAP.DE', shares: 10, avgCost: 90.0,
            updatedAt: DateTime.utc(2026))],
        const PortfolioMeta(cash: 0, currency: 'EUR'),
        {'SAP.DE': const TickerQuote(close: 100.0, pctChange: 0),
         'EURUSD=X': const TickerQuote(close: 1.25, pctChange: 0)},
      );
      expect(s.stockValueEur, 1000.0);        // 10×100，除了 1.25 就是 800（bug）
    });

    test('atCost 持仓无行情无汇率也能按欧元成本估值', () {
      final s = summarize(
        [Position(ticker: 'DEPOSITO2027', shares: 1, avgCost: 5000.0,
            updatedAt: DateTime.utc(2026), atCost: true)],
        const PortfolioMeta(cash: 100, currency: 'EUR'),
        const {},                              // 无任何行情
      );
      expect(s.stockValueEur, 5000.0);
      expect(s.totalEur, 5100.0);
    });

    test('concentration 对 atCost 用欧元成本', () {
      final c = concentration(
        [Position(ticker: 'DEPOSITO2027', shares: 1, avgCost: 5000.0,
            updatedAt: DateTime.utc(2026), atCost: true)],
        const PortfolioMeta(cash: 5000, currency: 'EUR'),
        const {},
      )!;
      expect(c.stats.single.weightPct, 50.0);
    });
  });
```

`app/test/tax_test.dart` 末尾追加：

```dart
  test('德股分红默认 37.1%，意股 26%', () {
    expect(defaultIncomeTaxPct('SAP.DE'), taxPctUsTotal);
    expect(defaultIncomeTaxPct('ENEL.MI'), taxPctIt);
    expect(defaultIncomeTaxPct('IT0005696320'), taxPctIt);
    expect(defaultIncomeTaxPct('MSFT'), taxPctUsTotal);
  });
```

`app/test/policy_test.dart` 末尾追加：

```dart
  group('.DE 与 atCost（policy）', () {
    test('atCost 缺省归防守层，显式 layer 优先', () {
      const cfg = PolicyConfig();
      final atCost = Position(ticker: 'DEPOSITO2027', shares: 1,
          avgCost: 5000.0, updatedAt: DateTime.utc(2026), atCost: true);
      expect(cfg.layerOf('DEPOSITO2027', atCost), layerDefensive);
      final withLayer = Position(ticker: 'DEPOSITO2027', shares: 1,
          avgCost: 5000.0, updatedAt: DateTime.utc(2026), atCost: true,
          layer: 'core');
      expect(cfg.layerOf('DEPOSITO2027', withLayer), layerCore);
    });

    test('layerBreakdown：atCost 计防守、德股不进美元敞口', () {
      final b = layerBreakdown(
        [
          Position(ticker: 'SAP.DE', shares: 10, avgCost: 90.0,
              updatedAt: DateTime.utc(2026)),
          Position(ticker: 'DEPOSITO2027', shares: 1, avgCost: 1000.0,
              updatedAt: DateTime.utc(2026), atCost: true),
        ],
        const PortfolioMeta(cash: 0, currency: 'EUR'),
        {'SAP.DE': const TickerQuote(close: 100.0, pctChange: 0)},
        const PolicyConfig(),
      )!;
      expect(b.statOf(layerDefensive)!.valueEur, 1000.0);   // 存单
      expect(b.usdPct, 0.0);                                // 德股≠美元敞口
    });
  });
```

`app/test/repo_test.dart` 末尾追加（沿用文件内既有 repo 构造方式）：

```dart
  test('setPosition 写入 atCost', () async {
    final db = FakeFirebaseFirestore();
    final repo = WealthRepo(db);
    await repo.setPosition(
        ticker: 'DEPOSITO2027', shares: 1, avgCost: 5000.0, atCost: true);
    final doc = (await db.collection('positions').doc('DEPOSITO2027').get()).data()!;
    expect(doc['atCost'], isTrue);
  });
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd /Volumes/external/code/ai/projects/TradingAgents/app && flutter test test/portfolio_math_test.dart test/tax_test.dart test/policy_test.dart test/repo_test.dart
```

预期：编译错（`atCost`/`isItalianListing` 未定义）——TDD 里编译失败等同测试失败

- [ ] **Step 3: 实现**

① `app/lib/models/models.dart` `Position`：构造参数、字段、`fromDoc` 各加一行（模式与 `holdToMaturity` 完全相同）：

```dart
  /// 无行情资产（存单等）：按欧元成本计价，runner 跳过行情/扫描。
  final bool? atCost;
```

`fromDoc`：`atCost: d['atCost'] as bool?,`

② `app/lib/logic/portfolio_math.dart`：

```dart
/// Borsa Italiana (.MI) / Xetra (.DE) 与意大利 ISIN 按欧元报价。
bool isEurListing(String ticker) =>
    ticker.endsWith('.MI') || ticker.endsWith('.DE') ||
    (ticker.startsWith('IT') && isIsin(ticker));

/// 意大利上市（税率口径）：分红 26% 只适用于这些；德股虽是欧元计价，
/// 税负同美股 37.1%——所以这个谓词必须与 [isEurListing] 分开。
bool isItalianListing(String ticker) =>
    ticker.endsWith('.MI') || (ticker.startsWith('IT') && isIsin(ticker));
```

`summarize` 的持仓循环开头插入：

```dart
    if (p.atCost == true) {
      // 无行情资产：按欧元成本计价，不查行情、不折汇率
      stockValue = stockValue! + p.shares * p.avgCost;
      cost = cost! + p.shares * p.avgCost;
      continue;
    }
```

`concentration` 的循环里市值行改为：

```dart
    final v = p.atCost == true
        ? p.shares * p.avgCost
        : toEur(p.ticker, p.shares * (quotes[p.ticker]?.close ?? p.avgCost));
```

（原 `final priceNative = ...` 行合并进来，保持 null 早退逻辑不变。）

③ `app/lib/logic/tax.dart`：import 改为
`import 'portfolio_math.dart' show isItalianListing;`，

```dart
/// 分红/利息的缺省税率：意大利上市 26%，其余（美股、德股）37.1%。
double defaultIncomeTaxPct(String ticker) =>
    isItalianListing(ticker) ? taxPctIt : taxPctUsTotal;
```

④ `app/lib/logic/policy.dart`：`layerOf` 在 layerMap 判断之后、ISIN 判断之前加：

```dart
    if (position?.atCost == true) return layerDefensive;
```

`layerBreakdown` 的持仓循环里，市值与美元敞口改为：

```dart
    final double? v;
    if (p.atCost == true) {
      v = p.shares * p.avgCost;          // 欧元成本，atCost 不进美元敞口
    } else {
      final price = quotes[p.ticker]?.close ?? p.avgCost;
      v = toEur(p.ticker, p.shares * price);
    }
    if (v == null) return null;
    if (p.atCost != true) {
      usdEur += v * config.usdPctOf(p.ticker) / 100;
    }
```

（null 检查放在 if/else 之后才能触发 Dart 的类型提升——放 else 里面的话
后续 `byLayer` 行会编译报错；`usdEur` 累加只对非 atCost 生效。）

⑤ `app/lib/data/repo.dart` `setPosition`：签名加 `bool? atCost,`，写入 map 加 `'atCost': ?atCost,`（与 `holdToMaturity` 同模式）。

- [ ] **Step 4: 跑测试确认通过**

```bash
cd /Volumes/external/code/ai/projects/TradingAgents/app && flutter analyze && flutter test
```

预期：analyze 无 issue；全量 Flutter 测试全绿（≈256+ 新增若干）

- [ ] **Step 5: Commit**

```bash
git add app/lib app/test
git commit -m "feat(app): .DE 欧元判定/意税分家 + atCost 估值

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Dart UI + 全量验收

**Files:**
- Modify: `app/lib/ui/portfolio_tab.dart`（`_PositionDialog` 开关、trailing 标签）
- Modify: `app/lib/l10n.dart`（`atCostToggle` 键）
- Test: `app/test/portfolio_tab_test.dart`
- Modify: `docs/superpowers/specs/2026-08-10-german-stocks-atcost-design.md`（状态行）

**Interfaces:**
- Consumes: Task 3 的 `Position.atCost`、`repo.setPosition(atCost:)`、既有 `t.atCost`（「按成本计」）
- Produces: 无（收尾）。web 部署与 runner 重启由控制器执行（部署需用户当次同意）。

- [ ] **Step 1: 写失败测试**

`app/test/portfolio_tab_test.dart` 末尾追加（沿用文件内既有 `_wrap`/`_pump` helper 与 seed 模式）：

```dart
  group('atCost 开关', () {
    Future<FakeFirebaseFirestore> seedAtCost() async {
      final db = FakeFirebaseFirestore();
      await db.collection('positions').doc('DEPOSITO2027').set({
        'ticker': 'DEPOSITO2027', 'shares': 1, 'avgCost': 5000.0,
        'updatedAt': '2026-08-01T00:00:00+00:00', 'atCost': true,
      });
      await db.collection('meta').doc('portfolio').set(
          {'cash': 1000.0, 'currency': 'EUR'});
      return db;
    }

    testWidgets('atCost 持仓行显示「按成本计」', (tester) async {
      final db = await seedAtCost();
      await _pump(tester, db);
      expect(find.text('按成本计'), findsOneWidget);
      expect(find.text('无行情'), findsNothing);
    });

    testWidgets('编辑框开关写入 atCost', (tester) async {
      final db = FakeFirebaseFirestore();
      await db.collection('positions').doc('DEPOSITO2027').set({
        'ticker': 'DEPOSITO2027', 'shares': 1, 'avgCost': 5000.0,
        'updatedAt': '2026-08-01T00:00:00+00:00',
      });
      await db.collection('meta').doc('portfolio').set(
          {'cash': 1000.0, 'currency': 'EUR'});
      await _pump(tester, db);
      await tester.tap(find.text('DEPOSITO2027'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('posAtCost')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('posSave')));
      await tester.pumpAndSettle();
      final doc = (await db.collection('positions')
          .doc('DEPOSITO2027').get()).data()!;
      expect(doc['atCost'], isTrue);
    });
  });
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd /Volumes/external/code/ai/projects/TradingAgents/app && flutter test test/portfolio_tab_test.dart
```

预期：FAIL（找不到 posAtCost / 显示「无行情」）

- [ ] **Step 3: 实现**

① `app/lib/l10n.dart` 分层文案区附近加：

```dart
  String get atCostToggle =>
      isZh ? '无行情资产（按欧元成本计价）' : 'No-quote asset (at EUR cost)';
```

② `app/lib/ui/portfolio_tab.dart`：

- `_positionTrailing` 开头加：

```dart
    if (p.atCost == true) return Text(t.atCost);
```

- `_PositionDialog` state 加 `bool? _atCost;`；`holdToMaturity` 的 SwitchListTile 后面加：

```dart
          SwitchListTile(
            key: const Key('posAtCost'),
            contentPadding: EdgeInsets.zero,
            title: Text(t.atCostToggle, style: const TextStyle(fontSize: 14)),
            value: _atCost ?? (widget.existing?.atCost ?? false),
            onChanged: (v) => setState(() => _atCost = v),
          ),
```

- `_save()` 的 `setPosition` 调用加 `atCost: _atCost,`

- [ ] **Step 4: 两端全量回归**

```bash
cd /Volumes/external/code/ai/projects/TradingAgents/app && flutter analyze && flutter test
```

```bash
cd /Volumes/external/code/ai/projects/TradingAgents && source .venv/bin/activate && python -m pytest tests -q 2>&1 | tail -2; echo RC=$?
```

预期：两端全绿（Python ≈785+，Flutter ≈258+）

- [ ] **Step 5: spec 状态 + Commit**

spec 状态行 `已确认，待实现` → `已落地（2026-08-10）`。

```bash
git add app/lib app/test docs/superpowers/specs/2026-08-10-german-stocks-atcost-design.md
git commit -m "feat(app): atCost 开关 UI + 德股/atCost spec 落地

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 6: 部署与 runner 重启（控制器执行）**

web 部署需用户当次同意后走 `/deploy-web`；runner `/runner stop` 再 `/runner`。实现者跳过本步。
