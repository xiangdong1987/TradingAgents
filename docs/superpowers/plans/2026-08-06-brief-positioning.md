# 日报个股多空 + 股指期货 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 日报每只美股带一行做空+期权多空数据，数据区加 ES/NQ 股指期货块，LLM 按真实数据粒度解读。

**Architecture:** `assistant/quotes.py` 新增 `get_positioning`（yfinance info 做空三键 + 最近到期期权链 P/C 两键，键可部分缺省）与 `get_futures_snapshot`（ES=F/NQ=F 两条，复用 get_quote）；`assistant/daily_brief.py` 在资金流行下加「多空:」行、数据区加「# 股指期货」块；runner 同 fetch_quote 模式透传。全部延续「Python 算数字、LLM 只解读」。

**Tech Stack:** Python 3.12（repo `.venv`）、yfinance + pandas（已有依赖）、pytest。App 端零改动。

## Global Constraints

- 测试从仓库根目录跑：`source .venv/bin/activate && python -m pytest tests/<file> -q; echo RC=$?`（pipe 会吃退出码）
- 双语机制不动（BILINGUAL_INSTRUCTION + split_bilingual）
- 无新第三方依赖
- brief 文档 schema 不变（date/markdownZh/markdownEn/tickers/createdAt/quotes）
- `get_positioning` 返回 None / `get_futures_snapshot` 返回 `[]` 覆盖一切失败，**绝不抛出**；日报单票/期指块失败只降级自身
- 五键数值一律 round(2)；展示层对百分比用 `.1f` 格式化
- 直接提交本地 `main`，commit message 带 `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

---

### Task 1: `get_positioning` + `get_futures_snapshot`（quotes.py）

**Files:**
- Modify: `assistant/quotes.py`（文件末尾追加两个函数与 `_FUTURES` 常量）
- Test: `tests/test_assistant_quotes.py`（追加到模块顶层，别掉进已有函数体内）

**Interfaces:**
- Consumes: 已有 `is_isin(ticker) -> bool`、`get_quote(ticker) -> dict`（含 close/pctChange）
- Produces（Task 2 依赖确切键名）:
  - `get_positioning(ticker: str, *, _ticker_factory=None) -> dict | None`，键全部可选：`shortPctFloat`（float，%）、`shortChangePct`（float，%）、`shortRatioDays`（float）、`pcOi`（float）、`pcVol`（float）；至少一键才返回 dict
  - `get_futures_snapshot(*, _fetch_quote=get_quote) -> list[dict]`，元素 `{"name": str, "close": float, "pctChange": float}`

- [ ] **Step 1: 写失败测试**

追加到 `tests/test_assistant_quotes.py` 末尾（顶层）：

```python
# ---------- get_positioning / get_futures_snapshot ----------

class _FakeChain:
    def __init__(self, calls_oi, puts_oi, calls_vol, puts_vol):
        import pandas as pd
        self.calls = pd.DataFrame({"openInterest": calls_oi, "volume": calls_vol})
        self.puts = pd.DataFrame({"openInterest": puts_oi, "volume": puts_vol})


class _FakeYfTicker:
    def __init__(self, info=None, expiries=(), chain=None):
        self.info = info or {}
        self.options = expiries
        self._chain = chain

    def option_chain(self, expiry):
        if self._chain is None:
            raise RuntimeError("no chain")
        return self._chain


def test_positioning_full_data_hand_computed():
    from assistant.quotes import get_positioning
    fake = _FakeYfTicker(
        info={"shortPercentOfFloat": 0.0139, "sharesShort": 108,
              "sharesShortPriorMonth": 100, "shortRatio": 2.24},
        expiries=("2026-08-08",),
        chain=_FakeChain(calls_oi=[100, 100], puts_oi=[49, 49],
                         calls_vol=[10, 10], puts_vol=[5, 5]),
    )
    p = get_positioning("NVDA", _ticker_factory=lambda t: fake)
    assert p == {"shortPctFloat": 1.39, "shortChangePct": 8.0,
                 "shortRatioDays": 2.24, "pcOi": 0.49, "pcVol": 0.5}


def test_positioning_partial_data_keeps_available_keys():
    from assistant.quotes import get_positioning
    fake = _FakeYfTicker(info={"shortRatio": 3.5})     # 无期权链、无占比/环比
    p = get_positioning("SPCX", _ticker_factory=lambda t: fake)
    assert p == {"shortRatioDays": 3.5}


def test_positioning_chain_failure_keeps_short_keys():
    from assistant.quotes import get_positioning
    fake = _FakeYfTicker(info={"shortRatio": 3.5}, expiries=("2026-08-08",),
                         chain=None)                   # option_chain 会抛
    p = get_positioning("VST", _ticker_factory=lambda t: fake)
    assert p == {"shortRatioDays": 3.5}


def test_positioning_none_when_no_data_at_all():
    from assistant.quotes import get_positioning
    assert get_positioning("KO", _ticker_factory=lambda t: _FakeYfTicker()) is None


def test_positioning_none_for_mi_and_isin_without_fetching():
    from assistant.quotes import get_positioning
    def boom(t):
        raise AssertionError("非美股不应该发请求")
    assert get_positioning("ENEL.MI", _ticker_factory=boom) is None
    assert get_positioning("IT0005696320", _ticker_factory=boom) is None


def test_positioning_none_on_error():
    from assistant.quotes import get_positioning
    def boom(t):
        raise RuntimeError("network down")
    assert get_positioning("NVDA", _ticker_factory=boom) is None


def test_futures_snapshot_skips_failures():
    from assistant.quotes import get_futures_snapshot
    def flaky(symbol):
        if symbol == "NQ=F":
            raise RuntimeError("nope")
        return {"ticker": symbol, "close": 7779.75, "prevClose": 7755.0,
                "pctChange": 0.31}
    out = get_futures_snapshot(_fetch_quote=flaky)
    assert out == [{"name": "标普500期指", "close": 7779.75, "pctChange": 0.31}]


def test_futures_snapshot_empty_when_all_fail():
    from assistant.quotes import get_futures_snapshot
    def boom(symbol):
        raise RuntimeError("nope")
    assert get_futures_snapshot(_fetch_quote=boom) == []
```

- [ ] **Step 2: 跑测试确认失败**

```bash
source .venv/bin/activate && python -m pytest tests/test_assistant_quotes.py -q -k "positioning or futures"; echo RC=$?
```

预期：FAIL/ERROR（`cannot import name 'get_positioning'`）

- [ ] **Step 3: 实现**

`assistant/quotes.py` 文件末尾追加：

```python
_FUTURES = (("ES=F", "标普500期指"), ("NQ=F", "纳指100期指"))


def get_positioning(ticker: str, *, _ticker_factory=None) -> dict | None:
    """个股多空：做空数据（FINRA 双周频）+ 最近到期期权 put/call 比。

    键全部可选（数据源缺哪个就不写哪个），至少一键才返回 dict。美股以外
    （ISIN、.MI 无此数据，省两次白调用）、五键全无、任何异常一律返回
    None，绝不抛出。``_ticker_factory`` 供测试注入假 ``yf.Ticker``。
    """
    if is_isin(ticker) or ticker.upper().endswith(".MI"):
        return None
    try:
        if _ticker_factory is None:
            import yfinance as yf
            _ticker_factory = yf.Ticker
        tk = _ticker_factory(ticker)
        out: dict = {}
        info = tk.info or {}
        spf = info.get("shortPercentOfFloat")
        if spf:
            out["shortPctFloat"] = round(spf * 100, 2)
        cur, prior = info.get("sharesShort"), info.get("sharesShortPriorMonth")
        if cur and prior:
            out["shortChangePct"] = round((cur - prior) / prior * 100, 2)
        if info.get("shortRatio"):
            out["shortRatioDays"] = round(info["shortRatio"], 2)
        try:
            expiries = tk.options
            if expiries:
                chain = tk.option_chain(expiries[0])
                call_oi = float(chain.calls["openInterest"].sum())
                put_oi = float(chain.puts["openInterest"].sum())
                if call_oi > 0:
                    out["pcOi"] = round(put_oi / call_oi, 2)
                call_vol = float(chain.calls["volume"].sum())
                put_vol = float(chain.puts["volume"].sum())
                if call_vol > 0:
                    out["pcVol"] = round(put_vol / call_vol, 2)
        except Exception:
            pass  # 期权链失败不拖累做空数据
        return out or None
    except Exception:
        return None


def get_futures_snapshot(*, _fetch_quote=get_quote) -> list[dict]:
    """股指期货快照（ES/NQ）。单条失败跳过，全失败返回 []，绝不抛出。"""
    out = []
    for symbol, name in _FUTURES:
        try:
            q = _fetch_quote(symbol)
            out.append({"name": name, "close": q["close"],
                        "pctChange": q["pctChange"]})
        except Exception:
            continue
    return out
```

- [ ] **Step 4: 跑测试确认通过**

```bash
source .venv/bin/activate && python -m pytest tests/test_assistant_quotes.py -q; echo RC=$?
```

预期：全绿（既有 15 + 新 8 = 23 passed），RC=0

- [ ] **Step 5: Commit**

```bash
git add assistant/quotes.py tests/test_assistant_quotes.py
git commit -m "feat(assistant): get_positioning 个股多空 + 股指期货快照

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: 日报多空行 + 期指块（daily_brief.py / runner.py）

**Files:**
- Modify: `assistant/daily_brief.py`（import、`_PROMPT_TEMPLATE`、`generate_daily_brief`）
- Modify: `assistant/runner.py`（`run_once` 签名与 `brief_fn`，模式同 `fetch_money_flow`）
- Test: `tests/test_assistant_daily_brief.py`（既有测试注入 + 新测试）、`tests/test_assistant_runner.py`（run_once 调用点补注入）

**Interfaces:**
- Consumes: Task 1 的 `get_positioning(ticker) -> dict | None`（键 shortPctFloat/shortChangePct/shortRatioDays/pcOi/pcVol，全可选）、`get_futures_snapshot() -> list[dict]`（name/close/pctChange）
- Produces: `generate_daily_brief(store, llm, today, *, fetch_quote=get_quote, fetch_news=None, fetch_money_flow=get_money_flow, fetch_positioning=get_positioning, fetch_futures=get_futures_snapshot) -> str`；`run_once(..., fetch_positioning=None, fetch_futures=None, ...)`

- [ ] **Step 1: 写失败测试**

① `tests/test_assistant_daily_brief.py`：先 grep 找出**所有**直接调 `generate_daily_brief` 的测试（含资金流特性加的），每个调用补两个 kwarg 隔离网络：

```python
fetch_positioning=lambda t: None, fetch_futures=lambda: [],
```

② 文件末尾追加：

```python
def _posi(t):
    return {"shortPctFloat": 1.39, "shortChangePct": 8.0,
            "shortRatioDays": 2.24, "pcOi": 0.49, "pcVol": 0.5}


def _futs():
    return [{"name": "标普500期指", "close": 7779.75, "pctChange": 0.31},
            {"name": "纳指100期指", "close": 29834.75, "pctChange": 0.55}]


def test_brief_positioning_line_in_prompt():
    store, llm = make_store(), FakeLLM()
    generate_daily_brief(store, llm, "2026-08-01",
                         fetch_quote=ok_quote, fetch_news=lambda t, s, e: "n",
                         fetch_money_flow=lambda t, d: None,
                         fetch_positioning=_posi, fetch_futures=lambda: [])
    prompt = llm.prompts[0]
    assert "多空: 空头占流通 1.4%（环比 +8.0%），回补 2.24 天，期权P/C 持仓 0.49 / 成交 0.5" in prompt


def test_brief_positioning_partial_keys_render_available_segments():
    store, llm = make_store(), FakeLLM()
    generate_daily_brief(store, llm, "2026-08-01",
                         fetch_quote=ok_quote, fetch_news=lambda t, s, e: "n",
                         fetch_money_flow=lambda t, d: None,
                         fetch_positioning=lambda t: {"shortRatioDays": 3.5},
                         fetch_futures=lambda: [])
    prompt = llm.prompts[0]
    assert "多空: 回补 3.5 天" in prompt
    # 注意：口径说明行本身含「空头占流通盘」「期权 P/C」字样，
    # 这里必须断言带「多空: 」前缀/渲染专用格式的片段，才不会误伤
    assert "多空: 空头占流通" not in prompt and "期权P/C 持仓" not in prompt


def test_brief_positioning_degrades_to_placeholder():
    def boom(t):
        raise RuntimeError("no data")
    store, llm = make_store(), FakeLLM()
    generate_daily_brief(store, llm, "2026-08-01",
                         fetch_quote=ok_quote, fetch_news=lambda t, s, e: "n",
                         fetch_money_flow=lambda t, d: None,
                         fetch_positioning=boom, fetch_futures=lambda: [])
    assert "多空: 无数据" in llm.prompts[0]


def test_brief_futures_block_in_prompt():
    store, llm = make_store(), FakeLLM()
    generate_daily_brief(store, llm, "2026-08-01",
                         fetch_quote=ok_quote, fetch_news=lambda t, s, e: "n",
                         fetch_money_flow=lambda t, d: None,
                         fetch_positioning=lambda t: None, fetch_futures=_futs)
    prompt = llm.prompts[0]
    assert "# 股指期货" in prompt
    assert "标普500期指: 7779.75，+0.31%" in prompt
    assert "纳指100期指: 29834.75，+0.55%" in prompt


def test_brief_futures_block_placeholder_when_empty_or_raising():
    def boom():
        raise RuntimeError("nope")
    store, llm = make_store(), FakeLLM()
    generate_daily_brief(store, llm, "2026-08-01",
                         fetch_quote=ok_quote, fetch_news=lambda t, s, e: "n",
                         fetch_money_flow=lambda t, d: None,
                         fetch_positioning=lambda t: None, fetch_futures=boom)
    assert "（期指数据缺失）" in llm.prompts[0]
```

③ `tests/test_assistant_runner.py`：给带 `fetch_money_flow=` 的 `run_once` 调用（触达 brief 的那处）补：

```python
        fetch_positioning=lambda t: None, fetch_futures=lambda: [],
```

- [ ] **Step 2: 跑测试确认失败**

```bash
source .venv/bin/activate && python -m pytest tests/test_assistant_daily_brief.py tests/test_assistant_runner.py -q; echo RC=$?
```

预期：FAIL（`unexpected keyword argument 'fetch_positioning'`）

- [ ] **Step 3: 实现**

`assistant/daily_brief.py`：

① import 行改为：

```python
from assistant.quotes import (get_futures_snapshot, get_money_flow,
                              get_positioning, get_quote)
```

② `_PROMPT_TEMPLATE` 两处改动。口径行（原第 13 行）整行替换为：

```python
只依据给出的数据，不要编造数字。资金流口径：量比 = 今日成交量/20日均量；MFI 为 14 日资金流指标（>80 超买，<20 超卖）；OBV 为能量潮方向。多空口径：空头占流通盘越高、环比上升 = 看空压力增；回补天数为空头全部回补所需交易日；期权 P/C>1 偏空、<1 偏多；做空数据为 FINRA 双周频，非实时。若有期指数据，组合概览开头点一句隔夜期指情绪。日期：{today}
```

`# 组合` 前插入期指块，即：

```python
{bilingual}

# 股指期货
{futures_block}

# 组合
```

③ `generate_daily_brief` 签名改为：

```python
def generate_daily_brief(store, llm, today: str, *, fetch_quote=get_quote,
                         fetch_news=None, fetch_money_flow=get_money_flow,
                         fetch_positioning=get_positioning,
                         fetch_futures=get_futures_snapshot) -> str:
```

④ ticker 循环内，`mf_line` 计算之后、`tag = ...` 之前插入：

```python
        try:
            posi = fetch_positioning(t)
        except Exception:
            posi = None
        if posi:
            segs = []
            if "shortPctFloat" in posi:
                seg = f"空头占流通 {posi['shortPctFloat']:.1f}%"
                if "shortChangePct" in posi:
                    seg += f"（环比 {posi['shortChangePct']:+.1f}%）"
                segs.append(seg)
            if "shortRatioDays" in posi:
                segs.append(f"回补 {posi['shortRatioDays']} 天")
            pc_bits = []
            if "pcOi" in posi:
                pc_bits.append(f"持仓 {posi['pcOi']}")
            if "pcVol" in posi:
                pc_bits.append(f"成交 {posi['pcVol']}")
            if pc_bits:
                segs.append("期权P/C " + " / ".join(pc_bits))
            posi_line = "多空: " + "，".join(segs)
        else:
            posi_line = "多空: 无数据"
```

`ticker_parts.append` 行改为：

```python
        ticker_parts.append(
            f"## {t}{tag}\n{quote_line}\n{mf_line}\n{posi_line}\n近日新闻:\n{news}")
```

⑤ `prompt = _PROMPT_TEMPLATE.format(...)` 之前加期指块构造，format 加一项：

```python
    try:
        futs = fetch_futures()
    except Exception:
        futs = []
    futures_block = ("\n".join(
        f"{f['name']}: {f['close']}，{f['pctChange']:+.2f}%" for f in futs)
        or "（期指数据缺失）")
```

format 调用加 `futures_block=futures_block,`。

`assistant/runner.py`：

⑥ `run_once` 签名 `fetch_money_flow=None,` 后加 `fetch_positioning=None, fetch_futures=None,`；`brief_fn` 里对应加：

```python
        if fetch_positioning is not None:
            kwargs["fetch_positioning"] = fetch_positioning
        if fetch_futures is not None:
            kwargs["fetch_futures"] = fetch_futures
```

- [ ] **Step 4: 跑测试确认通过**

```bash
source .venv/bin/activate && python -m pytest tests/test_assistant_daily_brief.py tests/test_assistant_runner.py tests/test_assistant_jobs.py -q; echo RC=$?
```

预期：全绿，RC=0

- [ ] **Step 5: Commit**

```bash
git add assistant/daily_brief.py assistant/runner.py tests/test_assistant_daily_brief.py tests/test_assistant_runner.py
git commit -m "feat(assistant): 日报加个股多空与股指期货

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: 真实数据验证 + 全量回归 + 收尾

**Files:**
- Modify: `docs/superpowers/specs/2026-08-06-brief-positioning-design.md`（状态行改「已落地（2026-08-06）」）

**Interfaces:**
- Consumes: Task 1/2 全部产出
- Produces: 无（验收）。Step 5（重启 runner）**由控制器执行，不在本任务范围**。

- [ ] **Step 1: 真实 ticker 冒烟**

```bash
source .venv/bin/activate && python - <<'EOF'
from assistant.quotes import get_positioning, get_futures_snapshot
for t in ["NVDA", "KO", "ENEL.MI", "IT0005696320"]:
    print(t, get_positioning(t))
print("futures:", get_futures_snapshot())
EOF
```

预期：NVDA 至少含 shortPctFloat/pcOi（数值合理：占比 0~30%、P/C 0.1~3）；KO 有做空键；ENEL.MI 与 IT0005696320 为 None；futures 两条（收盘时段单条缺失可接受，全空需重试一次）。

- [ ] **Step 2: 真实 store 干跑 prompt（MemoryStore 收写、FakeLLM 截获，不写库不花钱）**

```bash
source .venv/bin/activate && python - <<'EOF'
from types import SimpleNamespace
from datetime import datetime, timezone
from assistant.store import FirestoreStore, MemoryStore
from assistant.daily_brief import generate_daily_brief

real = FirestoreStore.connect()
mem = MemoryStore()
mem.seed_watchlist(real.get_watchlist())
mem.seed_positions(real.get_positions())
mem.seed_meta(real.get_portfolio_meta())

class FakeLLM:
    def invoke(self, prompt):
        print(prompt[:4000])
        return SimpleNamespace(content="dry-run\n===EN===\ndry-run")

today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
generate_daily_brief(mem, FakeLLM(), today, fetch_news=lambda t, s, e: "（略）")
EOF
```

预期：prompt 开头有「# 股指期货」两行真实数据；美股票（NVDA/MSFT/KO…）有「多空:」行且至少含做空或期权片段；.MI 与 ISIN 票显示「多空: 无数据」。

- [ ] **Step 3: 全量 Python 回归**

```bash
source .venv/bin/activate && python -m pytest tests -q 2>&1 | tail -3; echo RC=$?
```

预期：全绿（≈777+ passed, 2 skipped），RC=0

- [ ] **Step 4: spec 状态更新 + Commit**

spec 状态行 `已确认，待实现` → `已落地（2026-08-06）`。

```bash
git add docs/superpowers/specs/2026-08-06-brief-positioning-design.md
git commit -m "docs: 日报多空spec标记已落地

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 5: 重启 runner（控制器执行）**

代码启动时加载，须 `/runner stop` 再 `/runner` 重启才生效——本步骤由主会话控制器完成，实现者跳过。
