# 国债资产类型 + 票息自动入账 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 买入支持「国债」类型（只填金额、数量恒 1、票息参数填一次），runner 按付息日历自动入账利息（12.5% 税），日报如实标注并做到期提醒。

**Architecture:** 国债 = 既有 `atCost` 资产 + 票息参数（`assetType/couponPct/payFreq/maturity` 存 position 文档）。Python `income.py` 新增 `sync_bond_coupons`（付息日从到期日倒推、幂等、挂进 runner 现有 income 同步档）；`daily_brief.py` 的 atCost 分支对债券升级文案 + 到期提醒；Dart 侧 `_BuyDialog` 加股票/国债分段表单，repo 新增 `applyBondBuy`（applyTrade 1 股@金额 + position merge 债券字段）。

**Tech Stack:** Python 3.12（repo `.venv`）+ pytest；Flutter/Dart + flutter_test（fake_cloud_firestore）。

## Global Constraints

- Python 测试从仓库根目录：`source .venv/bin/activate && python -m pytest tests/<file> -q; echo RC=$?`
- Flutter 测试从 `app/` 目录跑；cwd 会漂，路径用绝对路径最稳
- 无新第三方依赖（日期运算用标准库 `calendar.monthrange`，不引 dateutil）
- 意大利国债票息税率 **12.5%**（`TAX_PCT_IT_GOV`）；`default_tax_pct`（分红）不动
- 利息 = 投入金额 × 票面% ÷ 年付息次数；付息日严格满足 `openedAt < d ≤ today` 才入账；income 文档 id `{ticker}_{d}` 幂等
- 系统不自动动钱：到期只提醒，本金回收由用户记卖出
- 直接提交本地 `main`，commit message 带 `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

---

### Task 1: Python 票息引擎（income.py）

**Files:**
- Modify: `assistant/income.py`（常量 + `_coupon_dates` + `sync_bond_coupons`）
- Test: `tests/test_assistant_income.py`（追加模块顶层）

**Interfaces:**
- Consumes: 既有 `opened_floor(store, ticker)`、`store.get_positions()`、以及 `sync_dividends` 里已在用的 income 写入/查重 store 调用（**先读 `sync_dividends` 的实现，add_income/has_income 的调用形状照它原样用**）
- Produces（Task 2 依赖）: `sync_bond_coupons(store, today: str) -> int`（新增行数）；`TAX_PCT_IT_GOV = 12.5`；income 记录含 `ticker/date/amount/taxPct/taxAmount/source='auto'/note='国债票息'/creditedCash=False`

- [ ] **Step 1: 写失败测试**

`tests/test_assistant_income.py` 末尾追加（store 搭建沿用本文件既有测试的 `MemoryStore` + seed 模式，照相邻测试写法）：

```python
# ---------- 国债票息引擎 ----------

def _bond_store(**overrides):
    from assistant.store import MemoryStore
    s = MemoryStore()
    pos = {"ticker": "BTP2030", "shares": 1, "avgCost": 45000.0,
           "updatedAt": "x", "atCost": True, "assetType": "bond",
           "couponPct": 4.0, "payFreq": "semiannual",
           "maturity": "2030-03-15", "openedAt": "2026-02-01", **overrides}
    s.seed_positions([pos])
    return s


def test_coupon_dates_semiannual_backwards_from_maturity():
    from assistant.income import _coupon_dates
    # 锚点 2030-03-15 半年倒推 → …-03-15 / -09-15；区间 (2026-02-01, 2026-09-30]
    assert _coupon_dates("2030-03-15", 2, "2026-02-01", "2026-09-30") == [
        "2026-03-15", "2026-09-15"]


def test_coupon_dates_annual_and_floor_exclusive():
    from assistant.income import _coupon_dates
    # 年付；floor 恰为付息日当天 → 当天不算（严格大于）
    assert _coupon_dates("2030-03-15", 1, "2026-03-15", "2027-12-31") == [
        "2027-03-15"]


def test_coupon_dates_clamp_month_end():
    from assistant.income import _coupon_dates
    # 锚点 8-31 半年倒推到 2 月 → 夹到 2-28（平年）
    assert _coupon_dates("2027-08-31", 2, "2026-01-01", "2027-03-01") == [
        "2026-02-28", "2026-08-31", "2027-02-28"]


def test_sync_bond_coupons_creates_income_with_gov_tax():
    from assistant.income import sync_bond_coupons, TAX_PCT_IT_GOV
    s = _bond_store()
    n = sync_bond_coupons(s, "2026-09-30")
    assert n == 2                                  # 03-15 与 09-15
    rows = {r["date"]: r for r in s.list_income()}
    r = rows["2026-03-15"]
    assert r["amount"] == 900.0                    # 45000×4%÷2
    assert r["taxPct"] == TAX_PCT_IT_GOV == 12.5
    assert r["taxAmount"] == 112.5                 # 900×12.5%
    assert r["source"] == "auto" and r["creditedCash"] is False


def test_sync_bond_coupons_idempotent():
    from assistant.income import sync_bond_coupons
    s = _bond_store()
    assert sync_bond_coupons(s, "2026-09-30") == 2
    assert sync_bond_coupons(s, "2026-09-30") == 0   # 再跑不重复


def test_sync_bond_coupons_skips_incomplete_or_unknown_start():
    from assistant.income import sync_bond_coupons
    assert sync_bond_coupons(_bond_store(couponPct=None), "2026-09-30") == 0
    assert sync_bond_coupons(_bond_store(payFreq="quarterly"), "2026-09-30") == 0
    # 无 openedAt 且无买入成交 → 不猜，跳过
    assert sync_bond_coupons(_bond_store(openedAt=None), "2026-09-30") == 0


def test_sync_bond_coupons_falls_back_to_first_buy_trade():
    from assistant.income import sync_bond_coupons
    s = _bond_store(openedAt=None)
    s.seed_trades([{"ticker": "BTP2030", "side": "buy", "shares": 1,
                    "price": 45000.0, "date": "2026-02-01"}])
    assert sync_bond_coupons(s, "2026-09-30") == 2


def test_sync_bond_coupons_isolates_per_position_errors():
    from assistant.income import sync_bond_coupons
    s = _bond_store()
    # 再塞一条坏数据（maturity 非法），不应影响好的那条
    s.seed_positions([
        {"ticker": "BAD", "shares": 1, "avgCost": 1000.0, "updatedAt": "x",
         "atCost": True, "assetType": "bond", "couponPct": 3.0,
         "payFreq": "annual", "maturity": "not-a-date", "openedAt": "2026-01-01"},
        *s.get_positions(),
    ])
    assert sync_bond_coupons(s, "2026-09-30") == 2

    # 股票持仓完全不受影响
    s2 = _bond_store(assetType=None)
    assert sync_bond_coupons(s2, "2026-09-30") == 0
```

（若 `MemoryStore` 的 seed_positions 是覆盖式而非追加式，错误隔离测试改为一次性 seed 两条。）

- [ ] **Step 2: 跑测试确认失败**

```bash
source .venv/bin/activate && python -m pytest tests/test_assistant_income.py -q -k "coupon"; echo RC=$?
```

预期：ERROR（`cannot import name '_coupon_dates'`）

- [ ] **Step 3: 实现**

`assistant/income.py` 追加（常量放文件顶部既有税率常量旁）：

```python
TAX_PCT_IT_GOV = 12.5   # 意大利国债/政府债票息优惠税率（≠26%）


def _coupon_dates(maturity: str, per_year: int, floor: str, today: str) -> list[str]:
    """付息日历：从到期日按频率倒推，取 (floor, today] 区间内的日期（升序）。

    锚定到期日是国债惯例（BTP 半年付 = 到期月/日 ±6 个月）。锚定**日号**
    单独保存、每期对目标月重新夹紧——若先夹紧再倒推，8-31 夹到 2-28 后
    下一期会错成 8-28。floor 是买入日，严格大于——买入当天的付息属于前手。
    """
    from calendar import monthrange
    step = 12 // per_year
    y, m, anchor_day = (int(x) for x in maturity.split("-"))
    dates = []
    while True:
        d = min(anchor_day, monthrange(y, m)[1])
        cur = f"{y:04d}-{m:02d}-{d:02d}"
        if cur <= floor:
            break
        if cur <= today:
            dates.append(cur)
        m -= step
        while m <= 0:
            m += 12
            y -= 1
    return sorted(dates)


def sync_bond_coupons(store, today: str) -> int:
    """国债票息自动入账：按付息日历补齐 (买入日, 今天] 的利息记录。

    幂等（income id = ticker_日期，与分红同一套路）；单券异常只跳过该券。
    利息按投入金额近似面值（spec 写死的简化），税 12.5%。
    """
    added = 0
    for pos in store.get_positions():
        try:
            if pos.get("assetType") != "bond":
                continue
            coupon = pos.get("couponPct")
            maturity = pos.get("maturity")
            freq = pos.get("payFreq")
            if not coupon or not maturity or freq not in ("annual", "semiannual"):
                continue
            ticker = pos["ticker"]
            floor = pos.get("openedAt") or opened_floor(store, ticker)
            if not floor:
                continue    # 不知道从哪天起算，宁可不记
            per_year = 2 if freq == "semiannual" else 1
            base = float(pos.get("avgCost") or 0.0)
            if base <= 0:
                continue
            for d in _coupon_dates(maturity, per_year, floor, today):
                # 写入/查重与 sync_dividends 完全同套路（income id、字段形状）
                income_id = f"{ticker}_{d}"
                if store.has_income(income_id):
                    continue
                amount = round(base * float(coupon) / 100 / per_year, 2)
                store.add_income(income_id, {
                    "ticker": ticker, "date": d, "amount": amount,
                    "taxPct": TAX_PCT_IT_GOV,
                    "taxAmount": round(amount * TAX_PCT_IT_GOV / 100, 2),
                    "source": "auto", "note": "国债票息",
                    "creditedCash": False, "createdAt": utc_now_iso(),
                })
                added += 1
        except Exception:
            logger.exception("bond coupon sync failed for %s", pos.get("ticker"))
    return added
```

**注意**：`store.add_income`/`has_income` 的实际调用形状（参数个数、是否传 id）
以本文件 `sync_dividends` 现有用法为准——先读它，形状不同就照它改，别自创。
`utc_now_iso`/`logger` 本文件已有 import。

- [ ] **Step 4: 跑测试确认通过**

```bash
source .venv/bin/activate && python -m pytest tests/test_assistant_income.py -q; echo RC=$?
```

预期：全绿，RC=0

- [ ] **Step 5: Commit**

```bash
git add assistant/income.py tests/test_assistant_income.py
git commit -m "feat(assistant): 国债票息引擎——付息日历倒推+12.5%税

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: runner 接线 + 日报债券文案与到期提醒

**Files:**
- Modify: `assistant/runner.py`（income 同步档，约 163-175 行的 marker 块内）
- Modify: `assistant/daily_brief.py`（atCost 分支的债券文案 + prompt 到期提醒指示）
- Test: `tests/test_assistant_runner.py`、`tests/test_assistant_daily_brief.py`

**Interfaces:**
- Consumes: Task 1 的 `sync_bond_coupons(store, today) -> int`；position dict 的 `assetType/couponPct/payFreq/maturity/atCost`
- Produces: 日报里债券持仓数据块 `## {t}（持仓）\n国债 票面 4.00% 半年付 · 到期 2030-03-15 · 按成本计价`（到期追加 `【已到期，待处理本金回收】`）；持仓块行 `- {t}: 金额 {avgCost}，票面 4.00%，按成本计`

- [ ] **Step 1: 写失败测试**

`tests/test_assistant_daily_brief.py` 末尾追加（fetch 注入沿用本文件既有全套假参数模式）：

```python
def _seed_bond(store, **overrides):
    store.seed_positions([
        {"ticker": "BTP2030", "shares": 1, "avgCost": 45000.0,
         "updatedAt": "x", "atCost": True, "assetType": "bond",
         "couponPct": 4.0, "payFreq": "semiannual",
         "maturity": "2030-03-15", **overrides},
    ])


def test_brief_bond_block_shows_coupon_and_maturity():
    store, llm = make_store(), FakeLLM()
    _seed_bond(store)
    generate_daily_brief(store, llm, "2026-08-11",
                         fetch_quote=ok_quote, fetch_news=lambda t, s, e: "n",
                         fetch_money_flow=lambda t, d: None,
                         fetch_positioning=lambda t: None,
                         fetch_futures=lambda: [])
    prompt = llm.prompts[0]
    assert "## BTP2030（持仓）\n国债 票面 4.00% 半年付 · 到期 2030-03-15 · 按成本计价" in prompt
    assert "- BTP2030: 金额 45000.0，票面 4.00%，按成本计" in prompt
    assert "【已到期" not in prompt


def test_brief_matured_bond_gets_reminder():
    store, llm = make_store(), FakeLLM()
    _seed_bond(store, maturity="2026-08-01")           # 已到期
    generate_daily_brief(store, llm, "2026-08-11",
                         fetch_quote=ok_quote, fetch_news=lambda t, s, e: "n",
                         fetch_money_flow=lambda t, d: None,
                         fetch_positioning=lambda t: None,
                         fetch_futures=lambda: [])
    assert "【已到期，待处理本金回收】" in llm.prompts[0]


def test_brief_non_bond_at_cost_copy_unchanged():
    store, llm = make_store(), FakeLLM()
    store.seed_positions([
        {"ticker": "CASHDEP01", "shares": 1, "avgCost": 5000.0,
         "updatedAt": "x", "atCost": True},
    ])
    generate_daily_brief(store, llm, "2026-08-11",
                         fetch_quote=ok_quote, fetch_news=lambda t, s, e: "n",
                         fetch_money_flow=lambda t, d: None,
                         fetch_positioning=lambda t: None,
                         fetch_futures=lambda: [])
    assert "## CASHDEP01（持仓）\n按成本计价资产（无行情）" in llm.prompts[0]
```

`tests/test_assistant_runner.py`：找到验证 income 同步档的既有测试（grep `sync_dividends` 或 `income_sync`），照它的模式加一条：seed 一个债券持仓（字段同上），跑 `run_once` 后断言票息 income 已生成（或 `sync_bond_coupons` 被执行——以该文件既有断言风格为准）。若既有测试通过注入 `fetch_dividends` 隔离网络，本测试同样注入全套假 fetch。

- [ ] **Step 2: 跑测试确认失败**

```bash
source .venv/bin/activate && python -m pytest tests/test_assistant_daily_brief.py tests/test_assistant_runner.py -q -k "bond"; echo RC=$?
```

预期：FAIL（债券文案不存在 / income 未生成）

- [ ] **Step 3: 实现**

`assistant/daily_brief.py`：atCost 分支改为区分债券（原「按成本计价资产」两行保留在 else）：

```python
        pos = positions.get(t)
        if pos and pos.get("atCost"):
            if pos.get("assetType") == "bond":
                freq_txt = "半年付" if pos.get("payFreq") == "semiannual" else "年付"
                coupon = float(pos.get("couponPct") or 0)
                mat = pos.get("maturity") or "未知"
                line = f"国债 票面 {coupon:.2f}% {freq_txt} · 到期 {mat} · 按成本计价"
                if pos.get("maturity") and pos["maturity"] <= today:
                    line += "【已到期，待处理本金回收】"
                ticker_parts.append(f"## {t}（持仓）\n{line}")
                position_parts.append(
                    f"- {t}: 金额 {pos['avgCost']}，票面 {coupon:.2f}%，按成本计")
            else:
                ticker_parts.append(f"## {t}（持仓）\n按成本计价资产（无行情）")
                position_parts.append(
                    f"- {t}: {pos['shares']} 股 @ 成本 {pos['avgCost']}，按成本计")
            continue
```

`_PROMPT_TEMPLATE` 的结构指示行（「值得注意」括号内）追加一句：
`；标注【已到期】的国债请提醒把本金回收记成一笔卖出`。

`assistant/runner.py`：income 同步档 marker 块内、`sync_dividends` 调用旁加：

```python
            coupons = sync_bond_coupons(store, today_str)
            if coupons:
                logger.info("bond coupon sync: %d new row(s)", coupons)
```

import 行 `from assistant.income import backfill_income_tax, sync_dividends`
加 `sync_bond_coupons`。

- [ ] **Step 4: 跑测试确认通过**

```bash
source .venv/bin/activate && python -m pytest tests/test_assistant_daily_brief.py tests/test_assistant_runner.py tests/test_assistant_income.py -q; echo RC=$?
```

预期：全绿，RC=0

- [ ] **Step 5: Commit**

```bash
git add assistant/runner.py assistant/daily_brief.py tests/test_assistant_daily_brief.py tests/test_assistant_runner.py
git commit -m "feat(assistant): 票息同步接入runner + 日报国债文案与到期提醒

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Dart 模型 + applyBondBuy（models/repo/tax）

**Files:**
- Modify: `app/lib/models/models.dart`（`Position` 加 4 字段）
- Modify: `app/lib/data/repo.dart`（新增 `applyBondBuy`）
- Modify: `app/lib/logic/tax.dart`（常量 `taxPctItGov`）
- Test: `app/test/models_test.dart`、`app/test/repo_test.dart`

**Interfaces:**
- Consumes: 既有 `applyTrade`（buy 会扣现金/记成交/加自选）、`Position` 既有字段模式（`holdToMaturity` 同款）
- Produces（Task 4 依赖）: `Position.assetType/couponPct/payFreq/maturity`（全可空）；`repo.applyBondBuy({required String ticker, required double amount, required double couponPct, required String payFreq, required String maturity, required String date}) -> Future<void>`

- [ ] **Step 1: 写失败测试**

`app/test/models_test.dart` 末尾追加（构造方式沿用文件内既有 Position 测试）：

```dart
  test('Position 债券字段 fromDoc', () {
    final p = Position.fromDoc('BTP2030', {
      'ticker': 'BTP2030', 'shares': 1, 'avgCost': 45000.0,
      'updatedAt': '2026-08-11T00:00:00+00:00', 'atCost': true,
      'assetType': 'bond', 'couponPct': 4.0, 'payFreq': 'semiannual',
      'maturity': '2030-03-15',
    });
    expect(p.assetType, 'bond');
    expect(p.couponPct, 4.0);
    expect(p.payFreq, 'semiannual');
    expect(p.maturity, '2030-03-15');
  });
```

`app/test/repo_test.dart` 末尾追加（repo 构造沿用文件既有方式）：

```dart
  test('applyBondBuy 记成交+扣现金+写债券字段', () async {
    final db = FakeFirebaseFirestore();
    await db.collection('meta').doc('portfolio').set(
        {'cash': 50000.0, 'currency': 'EUR'});
    final repo = WealthRepo(db);
    await repo.applyBondBuy(
        ticker: 'BTP2030', amount: 45000.0, couponPct: 4.0,
        payFreq: 'semiannual', maturity: '2030-03-15', date: '2026-08-11');

    final pos = (await db.collection('positions').doc('BTP2030').get()).data()!;
    expect(pos['shares'], 1.0);
    expect(pos['avgCost'], 45000.0);
    expect(pos['atCost'], isTrue);
    expect(pos['holdToMaturity'], isTrue);
    expect(pos['assetType'], 'bond');
    expect(pos['couponPct'], 4.0);
    expect(pos['payFreq'], 'semiannual');
    expect(pos['maturity'], '2030-03-15');
    expect(pos['openedAt'], '2026-08-11');

    final cash = (await db.collection('meta').doc('portfolio').get())
        .data()!['cash'];
    expect(cash, 5000.0);                                  // 50000 − 45000

    final trades = await db.collection('trades').get();
    expect(trades.docs.single.data()['side'], 'buy');
    expect(trades.docs.single.data()['shares'], 1.0);
    expect(trades.docs.single.data()['price'], 45000.0);
  });
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd /Volumes/external/code/ai/projects/TradingAgents/app && flutter test test/models_test.dart test/repo_test.dart
```

预期：编译错（字段/方法未定义）

- [ ] **Step 3: 实现**

① `models.dart` `Position`（构造参数、字段、fromDoc，模式同 `holdToMaturity`）：

```dart
  /// 资产类型：'bond' = 国债（atCost + 票息参数）；空 = 股票。
  final String? assetType;
  final double? couponPct;   // 票面年利率 %
  final String? payFreq;     // 'annual' | 'semiannual'
  final String? maturity;    // 到期日 YYYY-MM-DD
```

fromDoc：`assetType: d['assetType'] as String?,`、
`couponPct: (d['couponPct'] as num?)?.toDouble(),`、
`payFreq: d['payFreq'] as String?,`、`maturity: d['maturity'] as String?,`

② `repo.dart` 新增（放 `applyTrade` 之后）：

```dart
  /// 国债买入：1 股 @ 金额走 applyTrade（扣现金/记成交/加自选），
  /// 再把票息参数与 atCost 语义 merge 进 position 文档。
  Future<void> applyBondBuy({
    required String ticker, required double amount, required double couponPct,
    required String payFreq, required String maturity, required String date,
  }) async {
    await applyTrade(
        ticker: ticker, side: 'buy', shares: 1, price: amount, date: date);
    await _db.collection('positions').doc(ticker).set({
      'atCost': true, 'holdToMaturity': true, 'assetType': 'bond',
      'couponPct': couponPct, 'payFreq': payFreq, 'maturity': maturity,
      'openedAt': date,
    }, SetOptions(merge: true));
  }
```

③ `tax.dart` 常量区追加：

```dart
/// 意大利国债/政府债票息优惠税率（runner 的票息引擎用同名常量，两端同步）。
const taxPctItGov = 12.5;
```

- [ ] **Step 4: 跑测试确认通过**

```bash
cd /Volumes/external/code/ai/projects/TradingAgents/app && flutter analyze && flutter test test/models_test.dart test/repo_test.dart
```

预期：analyze 无 issue、全绿

- [ ] **Step 5: Commit**

```bash
git add app/lib app/test
git commit -m "feat(app): Position 债券字段 + applyBondBuy

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: 买入 UI 分段表单 + 全量验收

**Files:**
- Modify: `app/lib/ui/portfolio_tab.dart`（`_BuyDialog`）
- Modify: `app/lib/l10n.dart`（新 key）
- Test: `app/test/portfolio_tab_test.dart`
- Modify: `docs/superpowers/specs/2026-08-11-bond-asset-type-design.md`（状态行 → `已落地（2026-08-11）`）

**Interfaces:**
- Consumes: Task 3 的 `repo.applyBondBuy(...)`（签名见 Task 3 Produces）
- Produces: 无（收尾）。部署/runner 重启/存量 BTP 迁移由控制器执行。

- [ ] **Step 1: 写失败测试**

`app/test/portfolio_tab_test.dart` 末尾追加（`_pump` 沿用文件既有 helper）：

```dart
  group('国债买入', () {
    Future<FakeFirebaseFirestore> seedCash() async {
      final db = FakeFirebaseFirestore();
      await db.collection('meta').doc('portfolio').set(
          {'cash': 50000.0, 'currency': 'EUR'});
      return db;
    }

    testWidgets('切到国债后按金额+票息保存', (tester) async {
      final db = await seedCash();
      await _pump(tester, db);
      await tester.tap(find.byKey(const Key('addFab')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('fabBuy')));
      await tester.pumpAndSettle();
      // 切国债：股数/价格消失，金额/票息字段出现
      await tester.tap(find.descendant(
          of: find.byKey(const Key('buyAssetType')),
          matching: find.text('国债')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('buyShares')), findsNothing);
      await tester.enterText(find.byKey(const Key('buyTicker')), 'btp2030');
      await tester.enterText(find.byKey(const Key('buyAmount')), '45000');
      await tester.enterText(find.byKey(const Key('buyCouponPct')), '4.0');
      await tester.enterText(
          find.byKey(const Key('buyMaturity')), '2030-03-15');
      await tester.tap(find.byKey(const Key('buySave')));
      await tester.pumpAndSettle();

      final pos = (await db.collection('positions').doc('BTP2030').get()).data()!;
      expect(pos['assetType'], 'bond');
      expect(pos['shares'], 1.0);
      expect(pos['avgCost'], 45000.0);
      expect(pos['atCost'], isTrue);
      expect(pos['payFreq'], 'semiannual');            // 缺省半年付
      final cash = (await db.collection('meta').doc('portfolio').get())
          .data()!['cash'];
      expect(cash, 5000.0);
    });

    testWidgets('到期日格式非法不保存', (tester) async {
      final db = await seedCash();
      await _pump(tester, db);
      await tester.tap(find.byKey(const Key('addFab')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('fabBuy')));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
          of: find.byKey(const Key('buyAssetType')),
          matching: find.text('国债')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('buyTicker')), 'BTP2030');
      await tester.enterText(find.byKey(const Key('buyAmount')), '45000');
      await tester.enterText(find.byKey(const Key('buyCouponPct')), '4.0');
      await tester.enterText(find.byKey(const Key('buyMaturity')), '2030/3/15');
      await tester.tap(find.byKey(const Key('buySave')));
      await tester.pumpAndSettle();
      expect((await db.collection('positions').doc('BTP2030').get()).exists,
          isFalse);
    });

    testWidgets('股票模式回归不变', (tester) async {
      final db = await seedCash();
      await _pump(tester, db);
      await tester.tap(find.byKey(const Key('addFab')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('fabBuy')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('buyTicker')), 'aapl');
      await tester.enterText(find.byKey(const Key('buyShares')), '5');
      await tester.enterText(find.byKey(const Key('buyPrice')), '100');
      await tester.tap(find.byKey(const Key('buySave')));
      await tester.pumpAndSettle();
      final pos = (await db.collection('positions').doc('AAPL').get()).data()!;
      expect(pos['shares'], 5.0);
      expect(pos.containsKey('assetType'), isFalse);
    });
  });
```

**先 grep `_BuyDialog` 现有字段的 Key 名**（`buyTicker/buyShares/buyPrice/buySave` 若与现状不符，以现状为准改测试——别改既有 Key）。

- [ ] **Step 2: 跑测试确认失败**

```bash
cd /Volumes/external/code/ai/projects/TradingAgents/app && flutter test test/portfolio_tab_test.dart
```

预期：FAIL（找不到 buyAssetType）

- [ ] **Step 3: 实现**

① `l10n.dart` 追加：

```dart
  String get assetTypeStock => isZh ? '股票' : 'Stock';
  String get assetTypeBond => isZh ? '国债' : 'Gov bond';
  String get bondAmount => isZh ? '金额 €' : 'Amount €';
  String get bondCouponPct => isZh ? '票面利率 %' : 'Coupon %';
  String get bondPayFreq => isZh ? '付息频率' : 'Pay frequency';
  String get payFreqAnnual => isZh ? '年付' : 'Annual';
  String get payFreqSemiannual => isZh ? '半年付' : 'Semi-annual';
  String get bondMaturity => isZh ? '到期日 (YYYY-MM-DD)' : 'Maturity (YYYY-MM-DD)';
```

② `_BuyDialogState`：

- 状态：`var _assetType = 'stock';`、`var _payFreq = 'semiannual';` + 控制器
  `_amount/_couponPct/_maturity`（dispose 记得加）
- 表单顶部（仅新标的时，`widget.position == null`）加：

```dart
          SegmentedButton<String>(
            key: const Key('buyAssetType'),
            style: SegmentedButton.styleFrom(visualDensity: VisualDensity.compact),
            segments: [
              ButtonSegment(value: 'stock', label: Text(t.assetTypeStock)),
              ButtonSegment(value: 'bond', label: Text(t.assetTypeBond)),
            ],
            selected: {_assetType},
            onSelectionChanged: (v) => setState(() => _assetType = v.first),
          ),
```

- `_assetType == 'bond'` 时：隐藏股数/价格字段，显示 金额（`buyAmount`）、
  票面利率（`buyCouponPct`）、付息频率下拉或分段（`buyPayFreq`，缺省
  semiannual）、到期日文本框（`buyMaturity`）；日期字段沿用现有 `_date`。
- `_submit()` 分叉：

```dart
    if (_assetType == 'bond') {
      final amount = double.tryParse(_amount.text);
      final coupon = double.tryParse(_couponPct.text);
      final maturity = _maturity.text.trim();
      final ok = RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(maturity);
      if (ticker.isEmpty || amount == null || amount <= 0 ||
          coupon == null || coupon <= 0 || !ok || date.isEmpty) {
        return;
      }
      await ref.read(repoProvider).applyBondBuy(
          ticker: ticker, amount: amount, couponPct: coupon,
          payFreq: _payFreq, maturity: maturity, date: date);
      // 关闭与 snackbar 逻辑沿用股票分支现状
    }
```

（股票分支代码原样不动；关闭对话框/提示的收尾照抄股票分支。）

- [ ] **Step 4: 两端全量回归**

```bash
cd /Volumes/external/code/ai/projects/TradingAgents/app && flutter analyze && flutter test
```

```bash
cd /Volumes/external/code/ai/projects/TradingAgents && source .venv/bin/activate && python -m pytest tests -q 2>&1 | tail -2; echo RC=$?
```

预期：两端全绿（Python ≈803+，Flutter ≈271+）

- [ ] **Step 5: spec 状态 + Commit**

spec 状态行 `已确认，待实现` → `已落地（2026-08-11）`。

```bash
git add app/lib app/test docs/superpowers/specs/2026-08-11-bond-asset-type-design.md
git commit -m "feat(app): 买入分股票/国债 + 国债表单

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 6: 部署/重启/迁移（控制器执行）**

web 部署需用户当次同意；runner 重启；存量 BTP（IT0005696320）迁移需向用户
索要票面利率/付息频率/到期日后由控制器写入。实现者跳过本步。
