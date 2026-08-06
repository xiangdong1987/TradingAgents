# 日报资金流向 + 自选分析与推荐 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 每日简报每只票带一行量价资金流数据；未持仓的自选股单独成节，每只给分析 + 固定建议标签。

**Architecture:** Python（`assistant/quotes.py`）从 yfinance 日线算量比/MFI14/OBV 方向/5 日涨跌，`assistant/daily_brief.py` 把数字拼进 prompt 并把结构改成「组合概览 → 持仓点评 → 自选分析与推荐 → 值得注意」；LLM 只解读不发明数据。买入建议仍由策略/顾问走 Policy 闸门，日报不产建议卡。

**Tech Stack:** Python 3.11+（repo `.venv`）、yfinance（已有依赖）、pytest。App 端零改动。

## Global Constraints

- 测试从仓库根目录跑：`source .venv/bin/activate && python -m pytest tests/<file> -q`；断言退出码时先 `RC=$?` 再看输出（pipe-to-tail 会吃掉退出码）
- 双语机制不动：`BILINGUAL_INSTRUCTION` + `split_bilingual` 原样保留
- 无新第三方依赖
- brief 文档 schema 不变（`date/markdownZh/markdownEn/tickers/createdAt/quotes`）
- `get_money_flow` 任何失败都返回 `None`，绝不抛出；日报单票失败只降级该票
- 直接提交本地 `main`，commit message 带 `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

---

### Task 1: `get_money_flow` 资金流指标（quotes.py）

**Files:**
- Modify: `assistant/quotes.py`（`_yf_history_ohlc` 加 volume；文件末尾加 `get_money_flow`）
- Test: `tests/test_assistant_quotes.py`（追加到 `main` 顶层，别掉进已有函数体内）

**Interfaces:**
- Consumes: 已有 `_yf_history_ohlc(ticker, start, end) -> list[dict]`、`is_isin(ticker) -> bool`
- Produces: `get_money_flow(ticker: str, end_date: str, *, _history=_yf_history_ohlc) -> dict | None`，成功返回 `{"volumeRatio": float, "mfi14": float, "obvTrend": "up"|"down"|"flat", "chg5dPct": float}`（Task 2 依赖这些确切键名）

- [ ] **Step 1: 写失败测试**

追加到 `tests/test_assistant_quotes.py` 末尾（顶层）：

```python
# ---------- get_money_flow ----------

def _mf_bars(closes, volumes):
    """等长 closes/volumes 造日线；high=low=close 让 typical price = close，便于手算。"""
    return [
        {"date": f"2026-07-{i+1:02d}", "high": c, "low": c, "close": c, "volume": v}
        for i, (c, v) in enumerate(zip(closes, volumes))
    ]


def test_money_flow_all_up_hand_computed():
    from assistant.quotes import get_money_flow
    closes = list(range(10, 31))            # 21 根，10..30 严格上涨
    volumes = [100.0] * 20 + [200.0]        # 末日放量
    mf = get_money_flow("NVDA", "2026-08-01", _history=lambda t, s, e: _mf_bars(closes, volumes))
    assert mf["volumeRatio"] == 2.0          # 200 / mean(前20根=100)
    assert mf["mfi14"] == 100.0              # 全是正资金流
    assert mf["obvTrend"] == "up"
    assert mf["chg5dPct"] == 20.0            # (30-25)/25


def test_money_flow_all_down():
    from assistant.quotes import get_money_flow
    closes = list(range(30, 9, -1))          # 30..10 严格下跌
    volumes = [100.0] * 21
    mf = get_money_flow("NVDA", "2026-08-01", _history=lambda t, s, e: _mf_bars(closes, volumes))
    assert mf["mfi14"] == 0.0
    assert mf["obvTrend"] == "down"
    assert mf["chg5dPct"] == round((10 - 15) / 15 * 100, 2)


def test_money_flow_flat_prices():
    from assistant.quotes import get_money_flow
    mf = get_money_flow("NVDA", "2026-08-01",
                        _history=lambda t, s, e: _mf_bars([20.0] * 21, [100.0] * 21))
    assert mf["mfi14"] == 50.0               # 无正无负 → 中性
    assert mf["obvTrend"] == "flat"          # OBV 一直是 0
    assert mf["chg5dPct"] == 0.0


def test_money_flow_none_when_insufficient_or_no_volume():
    from assistant.quotes import get_money_flow
    few = _mf_bars(list(range(10, 30)), [100.0] * 20)          # 只有 20 根
    assert get_money_flow("NVDA", "2026-08-01", _history=lambda t, s, e: few) is None
    zero = _mf_bars(list(range(10, 31)), [0.0] * 21)           # 量全零
    assert get_money_flow("NVDA", "2026-08-01", _history=lambda t, s, e: zero) is None


def test_money_flow_none_for_isin_without_fetching():
    from assistant.quotes import get_money_flow
    def boom(t, s, e):
        raise AssertionError("ISIN 不应该去拉日线")
    assert get_money_flow("IT0005696320", "2026-08-01", _history=boom) is None


def test_money_flow_none_on_fetch_error():
    from assistant.quotes import get_money_flow
    def boom(t, s, e):
        raise RuntimeError("network down")
    assert get_money_flow("NVDA", "2026-08-01", _history=boom) is None
```

- [ ] **Step 2: 跑测试确认失败**

```bash
source .venv/bin/activate && python -m pytest tests/test_assistant_quotes.py -q -k money_flow; echo RC=$?
```

预期：FAIL / ERROR（`cannot import name 'get_money_flow'`）

- [ ] **Step 3: 实现**

`assistant/quotes.py` — 两处改动。

① `_yf_history_ohlc` 的返回 dict 加 `volume`（NaN/缺列归 0，海龟只读 high/low/close 不受影响）：

```python
def _clean_volume(v) -> float:
    try:
        f = float(v)
    except (TypeError, ValueError):
        return 0.0
    return 0.0 if f != f else f   # NaN != NaN


# _yf_history_ohlc 内的列表推导改为：
    return [
        {"date": idx.strftime("%Y-%m-%d"), "high": float(r["High"]),
         "low": float(r["Low"]), "close": float(r["Close"]),
         "volume": _clean_volume(r.get("Volume"))}
        for idx, r in df.iterrows()
    ]
```

② 文件末尾追加：

```python
def get_money_flow(ticker: str, end_date: str, *,
                   _history=_yf_history_ohlc) -> dict | None:
    """个股量价资金流：量比 / MFI14 / OBV 5日方向 / 5日涨跌 %。

    日报用它给 LLM 喂可验证的数字。任何取数或数据不足的情况一律返回
    None（调用方按「无量价数据」降级），绝不抛出。ISIN（Borsa 债券/基金）
    没有成交量概念，直接 None。
    """
    if is_isin(ticker):
        return None
    try:
        start = (datetime.strptime(end_date, "%Y-%m-%d")
                 - timedelta(days=60)).strftime("%Y-%m-%d")
        bars = [b for b in _history(ticker, start, end_date)
                if b.get("volume") is not None]
    except Exception:
        return None
    if len(bars) < 21:
        return None
    vols = [b["volume"] for b in bars]
    avg20 = sum(vols[-21:-1]) / 20
    if avg20 <= 0:
        return None

    # MFI14：typical price × volume 的正/负流量占比
    tp = [(b["high"] + b["low"] + b["close"]) / 3 for b in bars]
    pos = neg = 0.0
    for i in range(len(bars) - 14, len(bars)):
        flow = tp[i] * vols[i]
        if tp[i] > tp[i - 1]:
            pos += flow
        elif tp[i] < tp[i - 1]:
            neg += flow
    mfi = 50.0 if pos + neg == 0 else 100 * pos / (pos + neg)

    # OBV 近 5 日方向：首尾差 < 区间内绝对摆动的 20% 视为走平
    obv = [0.0]
    for i in range(1, len(bars)):
        if bars[i]["close"] > bars[i - 1]["close"]:
            obv.append(obv[-1] + vols[i])
        elif bars[i]["close"] < bars[i - 1]["close"]:
            obv.append(obv[-1] - vols[i])
        else:
            obv.append(obv[-1])
    window = obv[-6:]
    diff = window[-1] - window[0]
    swing = sum(abs(window[j + 1] - window[j]) for j in range(len(window) - 1))
    if swing == 0 or abs(diff) < 0.2 * swing:
        obv_trend = "flat"
    else:
        obv_trend = "up" if diff > 0 else "down"

    return {
        "volumeRatio": round(vols[-1] / avg20, 2),
        "mfi14": round(mfi, 1),
        "obvTrend": obv_trend,
        "chg5dPct": round((bars[-1]["close"] - bars[-6]["close"])
                          / bars[-6]["close"] * 100, 2),
    }
```

- [ ] **Step 4: 跑测试确认通过（含既有海龟/回测不回归）**

```bash
source .venv/bin/activate && python -m pytest tests/test_assistant_quotes.py tests/test_assistant_turtle.py tests/test_assistant_backtest.py -q; echo RC=$?
```

预期：全绿，RC=0

- [ ] **Step 5: Commit**

```bash
git add assistant/quotes.py tests/test_assistant_quotes.py
git commit -m "feat(assistant): get_money_flow 量价资金流指标

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: 日报四节结构 + 资金流行 + 自选推荐（daily_brief.py / runner.py）

**Files:**
- Modify: `assistant/daily_brief.py`（`_PROMPT_TEMPLATE`、`generate_daily_brief`）
- Modify: `assistant/runner.py:26-62`（`run_once` 加 `fetch_money_flow` 透传，模式同 `fetch_quote`）
- Test: `tests/test_assistant_daily_brief.py`（改 3 个既有测试 + 加新测试）、`tests/test_assistant_runner.py:72`（run_once 调用加注入）

**Interfaces:**
- Consumes: Task 1 的 `get_money_flow(ticker, end_date) -> dict | None`（键：`volumeRatio/mfi14/obvTrend/chg5dPct`）
- Produces: `generate_daily_brief(store, llm, today, *, fetch_quote=get_quote, fetch_news=None, fetch_money_flow=get_money_flow) -> str`；`run_once(..., fetch_money_flow=None, ...)`

- [ ] **Step 1: 写失败测试**

`tests/test_assistant_daily_brief.py`：

① 先给 3 个既有测试注入假资金流，隔离网络（`generate_daily_brief` 的新默认参数是真 yfinance 调用）。给每个 `generate_daily_brief(...)` 调用加一个 kwarg：

```python
fetch_money_flow=lambda t, d: None
```

涉及：`test_brief_covers_watchlist_and_positions_and_saves`、`test_brief_survives_single_ticker_failures`、`test_brief_handles_zero_cost_basis`（以及文件里其余所有直接调 `generate_daily_brief` 的测试）。

② 文件末尾追加：

```python
def _mf(t, d):
    return {"volumeRatio": 1.8, "mfi14": 62.0, "obvTrend": "up", "chg5dPct": 3.2}


def test_brief_money_flow_line_in_prompt():
    store, llm = make_store(), FakeLLM()
    generate_daily_brief(store, llm, "2026-08-01",
                         fetch_quote=ok_quote, fetch_news=lambda t, s, e: "n",
                         fetch_money_flow=_mf)
    prompt = llm.prompts[0]
    assert "量比 1.80" in prompt
    assert "MFI 62" in prompt
    assert "5日走高" in prompt
    assert "+3.2%" in prompt


def test_brief_money_flow_degrades_to_placeholder():
    def boom(t, d):
        raise RuntimeError("no data")

    store, llm = make_store(), FakeLLM()
    generate_daily_brief(store, llm, "2026-08-01",
                         fetch_quote=ok_quote, fetch_news=lambda t, s, e: "n",
                         fetch_money_flow=boom)
    assert "无量价数据" in llm.prompts[0]


def test_brief_watch_only_section_lists_unheld_tickers():
    # make_store(): watch=NVDA、持仓=AAPL → 自选节只该点名 NVDA
    store, llm = make_store(), FakeLLM()
    generate_daily_brief(store, llm, "2026-08-01",
                         fetch_quote=ok_quote, fetch_news=lambda t, s, e: "n",
                         fetch_money_flow=lambda t, d: None)
    prompt = llm.prompts[0]
    assert "未持仓的自选股：NVDA" in prompt
    assert "## 持仓点评" in prompt and "## 自选分析与推荐" in prompt
    assert "值得深挖" in prompt and "建议移除" in prompt      # 固定标签写进指令
    assert "## AAPL（持仓）" in prompt and "## NVDA（自选）" in prompt


def test_brief_watch_only_empty_when_all_watch_held():
    s = MemoryStore()
    s.seed_watchlist([{"ticker": "AAPL", "deepFreq": "manual", "note": "", "addedAt": "x"}])
    s.seed_positions([{"ticker": "AAPL", "shares": 10, "avgCost": 100.0, "updatedAt": "x"}])
    s.seed_meta({"cash": 5000.0, "currency": "USD"})
    llm = FakeLLM()
    generate_daily_brief(s, llm, "2026-08-01",
                         fetch_quote=ok_quote, fetch_news=lambda t, s2, e: "n",
                         fetch_money_flow=lambda t, d: None)
    assert "未持仓的自选股：（无，此节写「今日无未持仓自选」即可）" in llm.prompts[0]
```

`tests/test_assistant_runner.py` 的 `run_once(...)` 调用（≈line 72）加：

```python
        fetch_money_flow=lambda t, d: None,
```

- [ ] **Step 2: 跑测试确认失败**

```bash
source .venv/bin/activate && python -m pytest tests/test_assistant_daily_brief.py tests/test_assistant_runner.py -q; echo RC=$?
```

预期：新测试 FAIL（`unexpected keyword argument 'fetch_money_flow'`）

- [ ] **Step 3: 实现**

`assistant/daily_brief.py`：

① import 行加 `get_money_flow`：

```python
from assistant.quotes import get_money_flow, get_quote
```

② `_PROMPT_TEMPLATE` 整体替换为：

```python
_PROMPT_TEMPLATE = """你是一位谨慎的投资研究助理。基于以下数据写一份每日投资日报（Markdown）。
结构：## 组合概览（含现金与浮动盈亏）→ ## 持仓点评（每只一两句，结合资金流）→ ## 自选分析与推荐 → ## 值得注意（异动、风险，若某只股值得做一次深度多agent分析请点名）。
「自选分析与推荐」只写这些未持仓的自选股：{watch_only_line}。每只 1-2 句，结合行情、资金流与新闻，并以固定标签之一结尾：【值得深挖】【回调关注】【观望】【建议移除】。持仓股只出现在持仓点评，不要重复。
只依据给出的数据，不要编造数字。资金流口径：量比 = 今日成交量/20日均量；MFI 为 14 日资金流指标（>80 超买，<20 超卖）；OBV 为能量潮方向。日期：{today}
{bilingual}

# 组合
现金: {cash} {currency}
持仓:
{positions_block}

# 个股数据
{tickers_block}
"""
```

③ `generate_daily_brief` 签名加参数：

```python
def generate_daily_brief(store, llm, today: str, *, fetch_quote=get_quote,
                         fetch_news=None, fetch_money_flow=get_money_flow) -> str:
```

④ ticker 循环里、`news` 之后加资金流行，并把小节标题带上（持仓）/（自选）标签；`ticker_parts.append` 改为：

```python
        try:
            mf = fetch_money_flow(t, today)
        except Exception:
            mf = None
        if mf:
            trend_txt = {"up": "5日走高", "down": "5日走低",
                         "flat": "5日走平"}[mf["obvTrend"]]
            mf_line = (f"资金流: 量比 {mf['volumeRatio']:.2f}，"
                       f"MFI {mf['mfi14']:.0f}，OBV {trend_txt}，"
                       f"5日 {mf['chg5dPct']:+.1f}%")
        else:
            mf_line = "资金流: 无量价数据"
        tag = "（持仓）" if t in positions else "（自选）"
        ticker_parts.append(f"## {t}{tag}\n{quote_line}\n{mf_line}\n近日新闻:\n{news}")
```

（原 `ticker_parts.append(f"## {t}\n{quote_line}\n近日新闻:\n{news}")` 删除。）

⑤ `prompt = _PROMPT_TEMPLATE.format(...)` 前算 watch-only，format 加一项：

```python
    watch_only = sorted(watch - set(positions))
    watch_only_line = ("、".join(watch_only)
                       or "（无，此节写「今日无未持仓自选」即可）")
```

format 调用加 `watch_only_line=watch_only_line,`。

`assistant/runner.py`：

⑥ `run_once` 签名 `fetch_news=None,` 后加 `fetch_money_flow=None,`；`brief_fn` 里对应加：

```python
        if fetch_money_flow is not None:
            kwargs["fetch_money_flow"] = fetch_money_flow
```

- [ ] **Step 4: 跑测试确认通过**

```bash
source .venv/bin/activate && python -m pytest tests/test_assistant_daily_brief.py tests/test_assistant_runner.py tests/test_assistant_jobs.py -q; echo RC=$?
```

预期：全绿，RC=0

- [ ] **Step 5: Commit**

```bash
git add assistant/daily_brief.py assistant/runner.py tests/test_assistant_daily_brief.py tests/test_assistant_runner.py
git commit -m "feat(assistant): 日报加资金流向与自选分析推荐

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: 真实数据验证 + 全量回归 + 收尾

**Files:**
- Modify: `docs/superpowers/specs/2026-08-06-brief-money-flow-watchlist-design.md`（状态行改「已落地」）

**Interfaces:**
- Consumes: Task 1/2 的全部产出
- Produces: 无（验收）

- [ ] **Step 1: 真实 ticker 冒烟 `get_money_flow`**

```bash
source .venv/bin/activate && python - <<'EOF'
from datetime import datetime, timezone
from assistant.quotes import get_money_flow
today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
for t in ["NVDA", "ENEL.MI", "IT0005696320"]:
    print(t, get_money_flow(t, today))
EOF
```

预期：NVDA 与 ENEL.MI 返回四键 dict（数值合理：volumeRatio 0.2~5、mfi14 0~100）；IT0005696320 返回 `None`。

- [ ] **Step 2: 真实 store 干跑 prompt（FakeLLM 截获，不写库不花钱）**

```bash
source .venv/bin/activate && python - <<'EOF'
from types import SimpleNamespace
from datetime import datetime, timezone
from assistant.store import FirestoreStore, MemoryStore
from assistant.daily_brief import generate_daily_brief

real = FirestoreStore.connect()
mem = MemoryStore()          # 写到内存，不污染线上 briefs
mem.seed_watchlist(real.get_watchlist())
mem.seed_positions(real.get_positions())
mem.seed_meta(real.get_portfolio_meta())

class FakeLLM:
    def invoke(self, prompt):
        print(prompt[:3000])
        return SimpleNamespace(content="dry-run\n===EN===\ndry-run")

today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
generate_daily_brief(mem, FakeLLM(), today, fetch_news=lambda t, s, e: "（略）")
EOF
```

预期：prompt 里能看到真实自选（AAPL/AMZN/GOOG/ISP.MI/KO/NVDA/PWR/SPCX/TSLA…）出现在「未持仓的自选股」行；每只票有 `资金流:` 行；ISIN 显示「无量价数据」。

- [ ] **Step 3: 全量 Python 回归**

```bash
source .venv/bin/activate && python -m pytest tests -q 2>&1 | tail -3; echo RC=$?
```

预期：全绿（≈765+ passed），RC=0

- [ ] **Step 4: spec 状态更新 + Commit**

spec 状态行 `已确认，待实现` → `已落地（2026-08-06）`。

```bash
git add docs/superpowers/specs/2026-08-06-brief-money-flow-watchlist-design.md
git commit -m "docs: 日报资金流spec标记已落地

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 5: 重启 runner 让新代码生效**

runner 以 `--watch 120` 常驻，代码是启动时加载的——用 `/runner` 技能重启（stop 再 start），否则明早日报还是旧结构。
