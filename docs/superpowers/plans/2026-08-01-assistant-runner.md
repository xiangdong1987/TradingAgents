# Assistant Runner + Firestore 数据层实施计划（理财助手·计划一）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在本仓新增 `assistant/` Python 包：launchd 每 15 分钟拉起的 runner，复用 TradingAgents 引擎生成每日轻量日报、按需/每周深度分析与操作建议，全部读写 Firestore。

**Architecture:** Firestore 为中心（spec 方案 A）。`store.py` 定义存储协议并提供内存假实现（测试用）与 firebase-admin 真实现；业务模块（daily_brief / deep_analysis / advisor / review / scheduler）全部面向协议编程并注入外部依赖（LLM、行情、新闻），因此单测零网络零花费。`runner.py` 只做装配。

**Tech Stack:** Python 3.10+（本仓现状）、pytest、firebase-admin（新增依赖）、yfinance（已有）、现有 `tradingagents.llm_clients.factory` 与 `tradingagents.dataflows`。

**对应 spec:** `docs/superpowers/specs/2026-08-01-wealth-assistant-design.md`。一处修正：spec §4 提到复盘时调 `reflect_and_remember`——该方法已不存在；引擎在每次 `propagate()` 开头通过 `_resolve_pending_entries()` 自动对历史决策做收益回溯和反思（memory log 机制）。因此 `review.py` 只负责给 suggestion 算 `outcomePct` 写回 Firestore 供 App 展示，引擎学习闭环自动发生，无需额外接线。

## Global Constraints

- 现有 `tradingagents/` 代码**只加不改**；现有 `tests/` 必须全部保持通过（`pytest tests/ -x -q`）
- Firestore 字段名一律 camelCase，与 spec §3 数据模型完全一致
- 所有时间戳存 UTC ISO-8601 字符串（`datetime.now(timezone.utc).isoformat()`）；调度判断用 `America/New_York` 时区
- 日报文档 ID = `YYYY-MM-DD`（天然幂等）；job 失败**不自动重试**
- 业务模块不得在模块顶层 import 重依赖（firebase_admin、TradingAgentsGraph 都在函数内 import，保持测试收集轻量——与 `llm_clients/factory.py` 的既有惯例一致）
- 单测不联网、不花 LLM 钱：LLM/行情/新闻一律注入 fake
- 服务账号密钥路径默认 `~/.tradingagents/firebase-service-account.json`，可用环境变量 `TRADINGAGENTS_FIREBASE_CREDENTIALS` 覆盖；密钥不进仓库
- 提交信息遵循仓库现有 conventional commits 风格（feat/fix/docs/test 前缀）

## 引擎现有接口速查（实现时直接用，勿凭记忆改名）

```python
# 完整深度分析
from tradingagents.default_config import DEFAULT_CONFIG
from tradingagents.graph.trading_graph import TradingAgentsGraph
ta = TradingAgentsGraph(debug=False, config=config)
final_state, decision = ta.propagate("NVDA", "2026-08-01")
# final_state 键: market_report, sentiment_report, news_report, fundamentals_report,
#   investment_debate_state{bull_history,bear_history,judge_decision},
#   trader_investment_plan, risk_debate_state{aggressive_history,conservative_history,
#   neutral_history,judge_decision}, final_trade_decision
# decision: process_signal 提炼后的 "BUY"/"SELL"/"HOLD" 类信号字符串

# LLM 单次调用（日报/advisor 用 quick_think_llm）
from tradingagents.llm_clients.factory import create_llm_client
llm = create_llm_client(config["llm_provider"], config["quick_think_llm"],
                        config.get("backend_url")).get_llm()
text = llm.invoke("prompt string").content   # LangChain chat model

# 新闻（格式化字符串，直接可入 prompt）
from tradingagents.dataflows.interface import route_to_vendor
news_text = route_to_vendor("get_news", "NVDA", "2026-07-31", "2026-08-01")
```

---

### Task 1: Store 协议与内存实现（`assistant/store.py`）

**Files:**
- Create: `assistant/__init__.py`（空文件）
- Create: `assistant/store.py`
- Test: `tests/test_assistant_store.py`

**Interfaces:**
- Consumes: 无（本任务是地基）
- Produces: 后续所有任务依赖的 `Store` 协议与 `MemoryStore`：

```python
class Store(Protocol):
    # watchlist / portfolio
    def get_watchlist(self) -> list[dict]: ...           # [{ticker,note,addedAt,deepFreq}]
    def get_positions(self) -> list[dict]: ...           # [{ticker,shares,avgCost,updatedAt}]
    def get_portfolio_meta(self) -> dict: ...            # {cash,currency}；无文档时返回 {"cash":0.0,"currency":"USD"}
    # briefs
    def get_brief(self, date_str: str) -> dict | None: ...
    def save_brief(self, date_str: str, data: dict) -> None: ...
    # analyses
    def save_analysis(self, data: dict) -> str: ...      # 返回新文档 id
    def has_analysis_since(self, ticker: str, since_iso: str) -> bool: ...
    # suggestions
    def save_suggestion(self, data: dict) -> str: ...
    def update_suggestion(self, sid: str, fields: dict) -> None: ...
    def suggestions_due_review(self, cutoff_iso: str) -> list[dict]: ...
        # status in ("accepted","dismissed") 且 createdAt <= cutoff_iso 且无 outcomePct；
        # 返回的每个 dict 附带 "id" 键
    # jobs
    def add_job(self, data: dict) -> str: ...
    def claim_queued_jobs(self) -> list[dict]: ...       # 取全部 status=="queued"，原子置为 running 并回填 startedAt，返回含 "id"
    def update_job(self, jid: str, fields: dict) -> None: ...
    def fail_zombie_jobs(self, cutoff_iso: str) -> int: ...
        # status=="running" 且 startedAt < cutoff_iso → 置 failed，error="runner killed"；返回清理数
```

- [ ] **Step 1: 写失败测试**

```python
# tests/test_assistant_store.py
"""MemoryStore 行为测试——它是所有 assistant 单测的地基，行为必须与 FirestoreStore 语义一致。"""
from assistant.store import MemoryStore


def test_watchlist_and_positions_roundtrip():
    s = MemoryStore()
    s.seed_watchlist([{"ticker": "NVDA", "note": "", "addedAt": "2026-07-01T00:00:00+00:00", "deepFreq": "weekly"}])
    s.seed_positions([{"ticker": "NVDA", "shares": 10, "avgCost": 100.0, "updatedAt": "2026-07-01T00:00:00+00:00"}])
    assert s.get_watchlist()[0]["ticker"] == "NVDA"
    assert s.get_positions()[0]["shares"] == 10


def test_portfolio_meta_defaults_when_missing():
    assert MemoryStore().get_portfolio_meta() == {"cash": 0.0, "currency": "USD"}


def test_brief_save_and_get_is_idempotent_by_date():
    s = MemoryStore()
    assert s.get_brief("2026-08-01") is None
    s.save_brief("2026-08-01", {"date": "2026-08-01", "markdownZh": "v1"})
    s.save_brief("2026-08-01", {"date": "2026-08-01", "markdownZh": "v2"})  # 重跑覆盖
    assert s.get_brief("2026-08-01")["markdownZh"] == "v2"


def test_has_analysis_since():
    s = MemoryStore()
    s.save_analysis({"ticker": "NVDA", "tradeDate": "2026-07-28",
                     "createdAt": "2026-07-28T21:00:00+00:00", "decision": "HOLD", "sections": {}})
    assert s.has_analysis_since("NVDA", "2026-07-27T00:00:00+00:00") is True
    assert s.has_analysis_since("NVDA", "2026-07-29T00:00:00+00:00") is False
    assert s.has_analysis_since("AAPL", "2026-07-01T00:00:00+00:00") is False


def test_suggestions_due_review_filters_correctly():
    s = MemoryStore()
    due = s.save_suggestion({"ticker": "NVDA", "action": "trim", "status": "accepted",
                             "createdAt": "2026-07-10T00:00:00+00:00"})
    s.save_suggestion({"ticker": "AAPL", "action": "buy", "status": "pending",       # pending 不复盘
                       "createdAt": "2026-07-10T00:00:00+00:00"})
    s.save_suggestion({"ticker": "MSFT", "action": "buy", "status": "accepted",      # 太新
                       "createdAt": "2026-07-30T00:00:00+00:00"})
    reviewed = s.save_suggestion({"ticker": "TSLA", "action": "sell", "status": "dismissed",
                                  "createdAt": "2026-07-01T00:00:00+00:00", "outcomePct": 3.2})
    hits = s.suggestions_due_review("2026-07-18T00:00:00+00:00")
    assert [h["id"] for h in hits] == [due]
    s.update_suggestion(due, {"outcomePct": -1.5})
    assert s.suggestions_due_review("2026-07-18T00:00:00+00:00") == []
    assert reviewed  # 已复盘的不再出现


def test_job_queue_claim_and_zombie_cleanup():
    s = MemoryStore()
    j1 = s.add_job({"type": "daily_brief", "status": "queued",
                    "requestedBy": "schedule", "createdAt": "2026-08-01T20:00:00+00:00"})
    s.add_job({"type": "deep_analysis", "ticker": "NVDA", "status": "done",
               "requestedBy": "user", "createdAt": "2026-08-01T19:00:00+00:00"})
    claimed = s.claim_queued_jobs()
    assert [c["id"] for c in claimed] == [j1]
    assert claimed[0]["status"] == "running" and claimed[0]["startedAt"]
    assert s.claim_queued_jobs() == []           # 二次领取为空
    # 僵尸清理：running 且 startedAt 早于 cutoff
    s.update_job(j1, {"startedAt": "2026-08-01T00:00:00+00:00"})
    assert s.fail_zombie_jobs("2026-08-01T18:00:00+00:00") == 1
    assert s.get_job(j1)["status"] == "failed"
```

- [ ] **Step 2: 跑测试确认失败**

Run: `pytest tests/test_assistant_store.py -q`
Expected: FAIL，`ModuleNotFoundError: No module named 'assistant'`

- [ ] **Step 3: 最小实现**

```python
# assistant/store.py
"""Storage layer for the wealth assistant.

``Store`` is the protocol every business module programs against.
``MemoryStore`` is the in-memory fake used by tests (and the reference
semantics for the real ``FirestoreStore`` added in Task 2).
"""
from __future__ import annotations

import itertools
from datetime import datetime, timezone
from typing import Protocol


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


class Store(Protocol):
    def get_watchlist(self) -> list[dict]: ...
    def get_positions(self) -> list[dict]: ...
    def get_portfolio_meta(self) -> dict: ...
    def get_brief(self, date_str: str) -> dict | None: ...
    def save_brief(self, date_str: str, data: dict) -> None: ...
    def save_analysis(self, data: dict) -> str: ...
    def has_analysis_since(self, ticker: str, since_iso: str) -> bool: ...
    def save_suggestion(self, data: dict) -> str: ...
    def update_suggestion(self, sid: str, fields: dict) -> None: ...
    def suggestions_due_review(self, cutoff_iso: str) -> list[dict]: ...
    def add_job(self, data: dict) -> str: ...
    def claim_queued_jobs(self) -> list[dict]: ...
    def update_job(self, jid: str, fields: dict) -> None: ...
    def fail_zombie_jobs(self, cutoff_iso: str) -> int: ...


class MemoryStore:
    """Dict-backed fake with FirestoreStore-identical semantics."""

    def __init__(self):
        self._watchlist: list[dict] = []
        self._positions: list[dict] = []
        self._meta: dict | None = None
        self._briefs: dict[str, dict] = {}
        self._analyses: dict[str, dict] = {}
        self._suggestions: dict[str, dict] = {}
        self._jobs: dict[str, dict] = {}
        self._ids = itertools.count(1)

    def _next_id(self) -> str:
        return f"id{next(self._ids)}"

    # --- seeding helpers (tests only) ---
    def seed_watchlist(self, items: list[dict]) -> None:
        self._watchlist = list(items)

    def seed_positions(self, items: list[dict]) -> None:
        self._positions = list(items)

    def seed_meta(self, meta: dict) -> None:
        self._meta = dict(meta)

    # --- watchlist / portfolio ---
    def get_watchlist(self) -> list[dict]:
        return list(self._watchlist)

    def get_positions(self) -> list[dict]:
        return list(self._positions)

    def get_portfolio_meta(self) -> dict:
        return dict(self._meta) if self._meta else {"cash": 0.0, "currency": "USD"}

    # --- briefs ---
    def get_brief(self, date_str: str) -> dict | None:
        doc = self._briefs.get(date_str)
        return dict(doc) if doc else None

    def save_brief(self, date_str: str, data: dict) -> None:
        self._briefs[date_str] = dict(data)

    # --- analyses ---
    def save_analysis(self, data: dict) -> str:
        aid = self._next_id()
        self._analyses[aid] = dict(data)
        return aid

    def has_analysis_since(self, ticker: str, since_iso: str) -> bool:
        return any(
            a["ticker"] == ticker and a["createdAt"] >= since_iso
            for a in self._analyses.values()
        )

    # --- suggestions ---
    def save_suggestion(self, data: dict) -> str:
        sid = self._next_id()
        self._suggestions[sid] = dict(data)
        return sid

    def update_suggestion(self, sid: str, fields: dict) -> None:
        self._suggestions[sid].update(fields)

    def suggestions_due_review(self, cutoff_iso: str) -> list[dict]:
        out = []
        for sid, s in self._suggestions.items():
            if (
                s.get("status") in ("accepted", "dismissed")
                and s.get("createdAt", "") <= cutoff_iso
                and "outcomePct" not in s
            ):
                out.append({"id": sid, **s})
        return out

    # --- jobs ---
    def add_job(self, data: dict) -> str:
        jid = self._next_id()
        self._jobs[jid] = dict(data)
        return jid

    def get_job(self, jid: str) -> dict:
        return dict(self._jobs[jid])

    def claim_queued_jobs(self) -> list[dict]:
        claimed = []
        for jid, job in self._jobs.items():
            if job.get("status") == "queued":
                job["status"] = "running"
                job["startedAt"] = utc_now_iso()
                claimed.append({"id": jid, **job})
        return claimed

    def update_job(self, jid: str, fields: dict) -> None:
        self._jobs[jid].update(fields)

    def fail_zombie_jobs(self, cutoff_iso: str) -> int:
        n = 0
        for job in self._jobs.values():
            if job.get("status") == "running" and job.get("startedAt", "") < cutoff_iso:
                job["status"] = "failed"
                job["error"] = "runner killed"
                n += 1
        return n
```

`assistant/__init__.py` 内容为空。

- [ ] **Step 4: 跑测试确认通过**

Run: `pytest tests/test_assistant_store.py -q`
Expected: 6 passed

- [ ] **Step 5: 全量回归 + 提交**

Run: `pytest tests/ -x -q`（现有测试不得破坏）

```bash
git add assistant/__init__.py assistant/store.py tests/test_assistant_store.py
git commit -m "feat(assistant): add Store protocol and MemoryStore fake"
```

---

### Task 2: FirestoreStore 真实现 + 依赖声明

**Files:**
- Modify: `assistant/store.py`（追加 FirestoreStore）
- Modify: `requirements.txt`（追加 `firebase-admin`）
- Test: `tests/test_assistant_store.py`（追加凭证解析测试）

**Interfaces:**
- Consumes: Task 1 的 `Store` 协议
- Produces: `FirestoreStore.connect(cred_path: str | None = None) -> FirestoreStore`（classmethod；`resolve_credentials_path(env: dict) -> str` 独立可测）

FirestoreStore 本体**不写单测**（需要真实/模拟器 Firestore），语义以 MemoryStore 为准，联调靠 Task 9 的 smoke 脚本；但凭证路径解析是纯逻辑，必须测。

- [ ] **Step 1: 写失败测试（追加到 tests/test_assistant_store.py）**

```python
def test_resolve_credentials_path_env_override(tmp_path):
    from assistant.store import resolve_credentials_path
    default = resolve_credentials_path({})
    assert default.endswith(".tradingagents/firebase-service-account.json")
    custom = str(tmp_path / "sa.json")
    assert resolve_credentials_path({"TRADINGAGENTS_FIREBASE_CREDENTIALS": custom}) == custom
```

- [ ] **Step 2: 跑测试确认失败**

Run: `pytest tests/test_assistant_store.py::test_resolve_credentials_path_env_override -q`
Expected: FAIL，ImportError

- [ ] **Step 3: 实现（追加到 assistant/store.py）**

```python
import os


def resolve_credentials_path(env: dict | None = None) -> str:
    env = os.environ if env is None else env
    return env.get(
        "TRADINGAGENTS_FIREBASE_CREDENTIALS",
        os.path.join(os.path.expanduser("~"), ".tradingagents", "firebase-service-account.json"),
    )


class FirestoreStore:
    """firebase-admin backed implementation. Semantics mirror MemoryStore."""

    def __init__(self, db):
        self._db = db

    @classmethod
    def connect(cls, cred_path: str | None = None) -> "FirestoreStore":
        # Lazy import: keep test collection light (repo convention, see factory.py)
        import firebase_admin
        from firebase_admin import credentials, firestore

        if not firebase_admin._apps:
            cred = credentials.Certificate(cred_path or resolve_credentials_path())
            firebase_admin.initialize_app(cred)
        return cls(firestore.client())

    # --- watchlist / portfolio ---
    def get_watchlist(self) -> list[dict]:
        return [d.to_dict() for d in self._db.collection("watchlist").stream()]

    def get_positions(self) -> list[dict]:
        return [d.to_dict() for d in self._db.collection("positions").stream()]

    def get_portfolio_meta(self) -> dict:
        snap = self._db.collection("meta").document("portfolio").get()
        return snap.to_dict() if snap.exists else {"cash": 0.0, "currency": "USD"}

    # --- briefs ---
    def get_brief(self, date_str: str) -> dict | None:
        snap = self._db.collection("briefs").document(date_str).get()
        return snap.to_dict() if snap.exists else None

    def save_brief(self, date_str: str, data: dict) -> None:
        self._db.collection("briefs").document(date_str).set(data)

    # --- analyses ---
    def save_analysis(self, data: dict) -> str:
        ref = self._db.collection("analyses").document()
        ref.set(data)
        return ref.id

    def has_analysis_since(self, ticker: str, since_iso: str) -> bool:
        q = (
            self._db.collection("analyses")
            .where("ticker", "==", ticker)
            .where("createdAt", ">=", since_iso)
            .limit(1)
        )
        return len(list(q.stream())) > 0

    # --- suggestions ---
    def save_suggestion(self, data: dict) -> str:
        ref = self._db.collection("suggestions").document()
        ref.set(data)
        return ref.id

    def update_suggestion(self, sid: str, fields: dict) -> None:
        self._db.collection("suggestions").document(sid).update(fields)

    def suggestions_due_review(self, cutoff_iso: str) -> list[dict]:
        out = []
        q = self._db.collection("suggestions").where("status", "in", ["accepted", "dismissed"])
        for snap in q.stream():
            s = snap.to_dict()
            if s.get("createdAt", "") <= cutoff_iso and "outcomePct" not in s:
                out.append({"id": snap.id, **s})
        return out

    # --- jobs ---
    def add_job(self, data: dict) -> str:
        ref = self._db.collection("jobs").document()
        ref.set(data)
        return ref.id

    def claim_queued_jobs(self) -> list[dict]:
        from assistant.store import utc_now_iso  # self-module ok; explicit for clarity

        claimed = []
        q = self._db.collection("jobs").where("status", "==", "queued")
        for snap in q.stream():
            fields = {"status": "running", "startedAt": utc_now_iso()}
            snap.reference.update(fields)
            claimed.append({"id": snap.id, **snap.to_dict(), **fields})
        return claimed

    def update_job(self, jid: str, fields: dict) -> None:
        self._db.collection("jobs").document(jid).update(fields)

    def fail_zombie_jobs(self, cutoff_iso: str) -> int:
        n = 0
        q = self._db.collection("jobs").where("status", "==", "running")
        for snap in q.stream():
            if snap.to_dict().get("startedAt", "") < cutoff_iso:
                snap.reference.update({"status": "failed", "error": "runner killed"})
                n += 1
        return n
```

`requirements.txt` 追加一行：`firebase-admin`。

- [ ] **Step 4: 跑测试确认通过**

Run: `pytest tests/test_assistant_store.py -q`
Expected: 7 passed（FirestoreStore 仅要求可 import：`python -c "import assistant.store"`）

- [ ] **Step 5: 提交**

```bash
git add assistant/store.py tests/test_assistant_store.py requirements.txt
git commit -m "feat(assistant): add FirestoreStore backed by firebase-admin"
```

---

### Task 3: 行情工具（`assistant/quotes.py`）

**Files:**
- Create: `assistant/quotes.py`
- Test: `tests/test_assistant_quotes.py`

**Interfaces:**
- Consumes: yfinance（已有依赖）
- Produces:
  - `get_quote(ticker: str) -> dict`：`{"ticker","close","prevClose","pctChange"}`，近 7 个自然日日线的最后两根算涨跌；不足两根抛 `QuoteUnavailable`
  - `get_return_pct(ticker: str, start_date: str, end_date: str) -> float`：期间收盘价收益率百分比
  - `is_trading_day_now(now_et: datetime) -> bool`：SPY 当日有日线即为交易日
  - `class QuoteUnavailable(Exception)`
  - 三个函数都接受仅测试用的 `_history` 注入参数：`_history(ticker, start, end) -> list[tuple[str, float]]`（(date, close) 升序）

- [ ] **Step 1: 写失败测试**

```python
# tests/test_assistant_quotes.py
import pytest
from assistant.quotes import QuoteUnavailable, get_quote, get_return_pct, is_trading_day_now
from datetime import datetime
from zoneinfo import ZoneInfo


def fake_history(rows):
    def _h(ticker, start, end):
        return rows
    return _h


def test_get_quote_computes_pct_change():
    q = get_quote("NVDA", _history=fake_history([("2026-07-30", 100.0), ("2026-07-31", 110.0)]))
    assert q == {"ticker": "NVDA", "close": 110.0, "prevClose": 100.0, "pctChange": 10.0}


def test_get_quote_raises_when_insufficient_data():
    with pytest.raises(QuoteUnavailable):
        get_quote("NVDA", _history=fake_history([("2026-07-31", 110.0)]))


def test_get_return_pct():
    rows = [("2026-07-01", 100.0), ("2026-07-15", 105.0), ("2026-07-31", 120.0)]
    assert get_return_pct("NVDA", "2026-07-01", "2026-07-31", _history=fake_history(rows)) == 20.0


def test_is_trading_day_now_true_when_spy_has_todays_bar():
    now = datetime(2026, 7, 31, 17, 0, tzinfo=ZoneInfo("America/New_York"))
    assert is_trading_day_now(now, _history=fake_history([("2026-07-31", 500.0)])) is True
    assert is_trading_day_now(now, _history=fake_history([("2026-07-30", 500.0)])) is False
    assert is_trading_day_now(now, _history=fake_history([])) is False
```

- [ ] **Step 2: 跑测试确认失败**

Run: `pytest tests/test_assistant_quotes.py -q`
Expected: FAIL，ModuleNotFoundError

- [ ] **Step 3: 最小实现**

```python
# assistant/quotes.py
"""Numeric quote helpers for the assistant (engine dataflows return prose)."""
from __future__ import annotations

from datetime import datetime, timedelta


class QuoteUnavailable(Exception):
    pass


def _yf_history(ticker: str, start: str, end: str) -> list[tuple[str, float]]:
    """Return ascending [(YYYY-MM-DD, close)] via yfinance. Lazy import."""
    import yfinance as yf

    end_excl = (datetime.strptime(end, "%Y-%m-%d") + timedelta(days=1)).strftime("%Y-%m-%d")
    df = yf.Ticker(ticker).history(start=start, end=end_excl)
    if df.empty:
        return []
    if df.index.tz is not None:
        df.index = df.index.tz_localize(None)
    return [(idx.strftime("%Y-%m-%d"), float(row["Close"])) for idx, row in df.iterrows()]


def get_quote(ticker: str, _history=_yf_history) -> dict:
    end = datetime.utcnow().strftime("%Y-%m-%d")
    start = (datetime.utcnow() - timedelta(days=7)).strftime("%Y-%m-%d")
    rows = _history(ticker, start, end)
    if len(rows) < 2:
        raise QuoteUnavailable(f"not enough daily bars for {ticker}")
    prev_close, close = rows[-2][1], rows[-1][1]
    return {
        "ticker": ticker,
        "close": close,
        "prevClose": prev_close,
        "pctChange": round((close - prev_close) / prev_close * 100, 2),
    }


def get_return_pct(ticker: str, start_date: str, end_date: str, _history=_yf_history) -> float:
    rows = _history(ticker, start_date, end_date)
    if len(rows) < 2:
        raise QuoteUnavailable(f"not enough daily bars for {ticker}")
    first, last = rows[0][1], rows[-1][1]
    return round((last - first) / first * 100, 2)


def is_trading_day_now(now_et: datetime, _history=_yf_history) -> bool:
    today = now_et.strftime("%Y-%m-%d")
    rows = _history("SPY", today, today)
    return bool(rows) and rows[-1][0] == today
```

- [ ] **Step 4: 跑测试确认通过**

Run: `pytest tests/test_assistant_quotes.py -q` → 4 passed

- [ ] **Step 5: 提交**

```bash
git add assistant/quotes.py tests/test_assistant_quotes.py
git commit -m "feat(assistant): add numeric quote helpers"
```

---

### Task 4: 每日轻量日报（`assistant/daily_brief.py`）

**Files:**
- Create: `assistant/daily_brief.py`
- Test: `tests/test_assistant_daily_brief.py`

**Interfaces:**
- Consumes: `Store`（get_watchlist/get_positions/get_portfolio_meta/save_brief）、`get_quote`
- Produces: `generate_daily_brief(store, llm, today: str, *, fetch_quote=get_quote, fetch_news=None) -> str`
  - 返回生成的 Markdown；同时写入 `briefs/{today}`
  - `llm`：LangChain chat model（`.invoke(str).content`）
  - `fetch_news(ticker, start, end) -> str`；默认 None 时实现内部包一层 `route_to_vendor("get_news", ...)`（懒 import），单只股新闻失败降级为 "（新闻获取失败）" 而不中断
  - brief 文档结构：`{date, markdownZh, tickers: [...], createdAt}`

- [ ] **Step 1: 写失败测试**

```python
# tests/test_assistant_daily_brief.py
from types import SimpleNamespace
from assistant.daily_brief import generate_daily_brief
from assistant.store import MemoryStore
from assistant.quotes import QuoteUnavailable


class FakeLLM:
    def __init__(self):
        self.prompts = []

    def invoke(self, prompt):
        self.prompts.append(prompt)
        return SimpleNamespace(content="# 日报\n一切正常")


def make_store():
    s = MemoryStore()
    s.seed_watchlist([{"ticker": "NVDA", "deepFreq": "weekly", "note": "", "addedAt": "x"}])
    s.seed_positions([{"ticker": "AAPL", "shares": 10, "avgCost": 100.0, "updatedAt": "x"}])
    s.seed_meta({"cash": 5000.0, "currency": "USD"})
    return s


def ok_quote(ticker, **kw):
    return {"ticker": ticker, "close": 110.0, "prevClose": 100.0, "pctChange": 10.0}


def test_brief_covers_watchlist_and_positions_and_saves():
    store, llm = make_store(), FakeLLM()
    md = generate_daily_brief(store, llm, "2026-08-01",
                              fetch_quote=ok_quote, fetch_news=lambda t, s, e: f"{t} news")
    assert md == "# 日报\n一切正常"
    saved = store.get_brief("2026-08-01")
    assert saved["markdownZh"] == md and saved["date"] == "2026-08-01"
    assert sorted(saved["tickers"]) == ["AAPL", "NVDA"]      # watchlist ∪ positions 去重
    prompt = llm.prompts[0]
    assert "NVDA" in prompt and "AAPL" in prompt
    assert "10.0" in prompt                                   # 涨跌幅进 prompt
    assert "5000" in prompt                                   # 现金进 prompt
    assert "+10.00%" in prompt or "10.0%" in prompt or "浮动盈亏" in prompt  # AAPL 持仓盈亏(110 vs 100)


def test_brief_survives_single_ticker_failures():
    def flaky_quote(ticker, **kw):
        if ticker == "NVDA":
            raise QuoteUnavailable("nope")
        return ok_quote(ticker)

    store, llm = make_store(), FakeLLM()
    md = generate_daily_brief(store, llm, "2026-08-01",
                              fetch_quote=flaky_quote,
                              fetch_news=lambda t, s, e: (_ for _ in ()).throw(RuntimeError("net down")))
    assert md                                                 # 仍产出
    assert "行情获取失败" in llm.prompts[0]                    # 失败股在 prompt 里标注而非丢弃
    assert "新闻获取失败" in llm.prompts[0]
```

- [ ] **Step 2: 跑测试确认失败**

Run: `pytest tests/test_assistant_daily_brief.py -q`
Expected: FAIL，ModuleNotFoundError

- [ ] **Step 3: 最小实现**

```python
# assistant/daily_brief.py
"""Daily lightweight brief: one quick-LLM call over quotes + news + P&L."""
from __future__ import annotations

from datetime import datetime, timedelta

from assistant.quotes import get_quote
from assistant.store import utc_now_iso

_PROMPT_TEMPLATE = """你是一位谨慎的投资研究助理。基于以下数据写一份简体中文的每日投资日报（Markdown）。
结构：## 组合概览（含现金与浮动盈亏）→ ## 个股点评（每只一两句）→ ## 值得注意（异动、风险，若某只股值得做一次深度多agent分析请点名）。
只依据给出的数据，不要编造数字。日期：{today}

# 组合
现金: {cash} {currency}
持仓:
{positions_block}

# 个股数据
{tickers_block}
"""


def _default_fetch_news(ticker: str, start: str, end: str) -> str:
    from tradingagents.dataflows.interface import route_to_vendor  # lazy import

    return route_to_vendor("get_news", ticker, start, end)


def generate_daily_brief(store, llm, today: str, *, fetch_quote=get_quote, fetch_news=None) -> str:
    if fetch_news is None:
        fetch_news = _default_fetch_news

    watch = {w["ticker"] for w in store.get_watchlist()}
    positions = {p["ticker"]: p for p in store.get_positions()}
    meta = store.get_portfolio_meta()
    tickers = sorted(watch | set(positions))

    yesterday = (datetime.strptime(today, "%Y-%m-%d") - timedelta(days=1)).strftime("%Y-%m-%d")
    ticker_parts, position_parts = [], []
    for t in tickers:
        try:
            q = fetch_quote(t)
            quote_line = f"收盘 {q['close']}，涨跌 {q['pctChange']}%"
        except Exception:
            q = None
            quote_line = "行情获取失败"
        try:
            news = fetch_news(t, yesterday, today)
        except Exception:
            news = "（新闻获取失败）"
        ticker_parts.append(f"## {t}\n{quote_line}\n近日新闻:\n{news}")

        pos = positions.get(t)
        if pos:
            if q:
                pnl = round((q["close"] - pos["avgCost"]) / pos["avgCost"] * 100, 2)
                pnl_str = f"浮动盈亏 {pnl:+.2f}%"
            else:
                pnl_str = "浮动盈亏 未知（行情获取失败）"
            position_parts.append(
                f"- {t}: {pos['shares']} 股 @ 成本 {pos['avgCost']}，{pnl_str}"
            )

    prompt = _PROMPT_TEMPLATE.format(
        today=today,
        cash=meta.get("cash", 0.0),
        currency=meta.get("currency", "USD"),
        positions_block="\n".join(position_parts) or "（无持仓）",
        tickers_block="\n\n".join(ticker_parts) or "（自选与持仓均为空）",
    )
    markdown = llm.invoke(prompt).content
    store.save_brief(today, {
        "date": today,
        "markdownZh": markdown,
        "tickers": tickers,
        "createdAt": utc_now_iso(),
    })
    return markdown
```

- [ ] **Step 4: 跑测试确认通过**

Run: `pytest tests/test_assistant_daily_brief.py -q` → 2 passed

- [ ] **Step 5: 提交**

```bash
git add assistant/daily_brief.py tests/test_assistant_daily_brief.py
git commit -m "feat(assistant): generate daily lightweight brief"
```

---

### Task 5: 深度分析封装（`assistant/deep_analysis.py`）

**Files:**
- Create: `assistant/deep_analysis.py`
- Test: `tests/test_assistant_deep_analysis.py`

**Interfaces:**
- Consumes: `Store.save_analysis`；`TradingAgentsGraph`（通过 `graph_factory` 注入以便测试）
- Produces: `run_deep_analysis(store, ticker: str, trade_date: str, config: dict, *, graph_factory=None) -> tuple[str, str]`
  - 返回 `(analysis_id, decision)`
  - `graph_factory(config) -> obj`，obj 需有 `propagate(ticker, date) -> (final_state, decision)`；默认懒 import `TradingAgentsGraph` 并以 `debug=False` 构建
  - 写入的 analysis 文档：`{ticker, tradeDate, decision, sections: {market, sentiment, news, fundamentals, bull, bear, researchManager, traderPlan, riskAggressive, riskConservative, riskNeutral, portfolioDecision, finalDecision}, createdAt}`；缺失的 state 键存空字符串

- [ ] **Step 1: 写失败测试**

```python
# tests/test_assistant_deep_analysis.py
from assistant.deep_analysis import run_deep_analysis
from assistant.store import MemoryStore

FINAL_STATE = {
    "market_report": "m", "sentiment_report": "s", "news_report": "n",
    "fundamentals_report": "f",
    "investment_debate_state": {"bull_history": "bull", "bear_history": "bear",
                                "judge_decision": "judge"},
    "trader_investment_plan": "plan",
    "risk_debate_state": {"aggressive_history": "agg", "conservative_history": "con",
                          "neutral_history": "neu", "judge_decision": "pm"},
    "final_trade_decision": "final",
}


class FakeGraph:
    def __init__(self):
        self.calls = []

    def propagate(self, ticker, date):
        self.calls.append((ticker, date))
        return FINAL_STATE, "BUY"


def test_run_deep_analysis_maps_state_to_sections():
    store, graph = MemoryStore(), FakeGraph()
    aid, decision = run_deep_analysis(store, "NVDA", "2026-08-01", {"any": "cfg"},
                                      graph_factory=lambda cfg: graph)
    assert decision == "BUY" and graph.calls == [("NVDA", "2026-08-01")]
    doc = store._analyses[aid]
    assert doc["ticker"] == "NVDA" and doc["tradeDate"] == "2026-08-01"
    sec = doc["sections"]
    assert sec["market"] == "m" and sec["bull"] == "bull" and sec["portfolioDecision"] == "pm"
    assert sec["finalDecision"] == "final" and doc["decision"] == "BUY"


def test_missing_state_keys_become_empty_strings():
    store = MemoryStore()

    class Sparse:
        def propagate(self, t, d):
            return {"market_report": "only"}, "HOLD"

    aid, _ = run_deep_analysis(store, "AAPL", "2026-08-01", {}, graph_factory=lambda c: Sparse())
    sec = store._analyses[aid]["sections"]
    assert sec["market"] == "only" and sec["bear"] == "" and sec["riskNeutral"] == ""
```

- [ ] **Step 2: 跑测试确认失败**

Run: `pytest tests/test_assistant_deep_analysis.py -q` → ModuleNotFoundError

- [ ] **Step 3: 最小实现**

```python
# assistant/deep_analysis.py
"""Wrap TradingAgentsGraph.propagate() and persist a structured analysis doc."""
from __future__ import annotations

from assistant.store import utc_now_iso


def _default_graph_factory(config: dict):
    from tradingagents.graph.trading_graph import TradingAgentsGraph  # lazy heavy import

    return TradingAgentsGraph(debug=False, config=config)


def _sections_from_state(state: dict) -> dict:
    debate = state.get("investment_debate_state") or {}
    risk = state.get("risk_debate_state") or {}
    return {
        "market": state.get("market_report") or "",
        "sentiment": state.get("sentiment_report") or "",
        "news": state.get("news_report") or "",
        "fundamentals": state.get("fundamentals_report") or "",
        "bull": debate.get("bull_history") or "",
        "bear": debate.get("bear_history") or "",
        "researchManager": debate.get("judge_decision") or "",
        "traderPlan": state.get("trader_investment_plan") or "",
        "riskAggressive": risk.get("aggressive_history") or "",
        "riskConservative": risk.get("conservative_history") or "",
        "riskNeutral": risk.get("neutral_history") or "",
        "portfolioDecision": risk.get("judge_decision") or "",
        "finalDecision": state.get("final_trade_decision") or "",
    }


def run_deep_analysis(store, ticker: str, trade_date: str, config: dict,
                      *, graph_factory=None) -> tuple[str, str]:
    factory = graph_factory or _default_graph_factory
    graph = factory(config)
    final_state, decision = graph.propagate(ticker, trade_date)
    analysis_id = store.save_analysis({
        "ticker": ticker,
        "tradeDate": trade_date,
        "decision": decision,
        "sections": _sections_from_state(final_state),
        "createdAt": utc_now_iso(),
    })
    return analysis_id, decision
```

- [ ] **Step 4: 跑测试确认通过**

Run: `pytest tests/test_assistant_deep_analysis.py -q` → 2 passed

- [ ] **Step 5: 提交**

```bash
git add assistant/deep_analysis.py tests/test_assistant_deep_analysis.py
git commit -m "feat(assistant): wrap engine deep analysis into Firestore docs"
```

---

### Task 6: 操作建议生成（`assistant/advisor.py`）

**Files:**
- Create: `assistant/advisor.py`
- Test: `tests/test_assistant_advisor.py`

**Interfaces:**
- Consumes: `Store`（get_positions/get_portfolio_meta/save_suggestion）、`get_quote`、LLM
- Produces: `generate_suggestion(store, llm, ticker: str, decision: str, analysis_id: str, *, fetch_quote=get_quote) -> str | None`
  - decision 含 "HOLD" 且该股无持仓 → 返回 None（不写文档，避免噪音）
  - LLM 要求只输出 JSON：`{"action": "buy|add|trim|sell|hold", "targetWeightPct": <number|null>, "rationale": "<中文一段>"}`；解析失败时降级为 `action=decision.lower()` 映射、rationale=原始输出
  - 写入 suggestion 文档：`{ticker, action, targetWeightPct, rationale, analysisId, status: "pending", createdAt}`
  - 组合市值 = Σ(股数×现价) + 现金；单股现价获取失败时该股按成本价估算（保证建议仍能生成）

- [ ] **Step 1: 写失败测试**

```python
# tests/test_assistant_advisor.py
from types import SimpleNamespace
from assistant.advisor import generate_suggestion
from assistant.store import MemoryStore


class FakeLLM:
    def __init__(self, reply):
        self.reply, self.prompts = reply, []

    def invoke(self, prompt):
        self.prompts.append(prompt)
        return SimpleNamespace(content=self.reply)


def make_store(with_position=True):
    s = MemoryStore()
    if with_position:
        s.seed_positions([{"ticker": "NVDA", "shares": 10, "avgCost": 100.0, "updatedAt": "x"}])
    s.seed_meta({"cash": 1000.0, "currency": "USD"})
    return s


def quote_110(ticker, **kw):
    return {"ticker": ticker, "close": 110.0, "prevClose": 100.0, "pctChange": 10.0}


def test_json_reply_becomes_pending_suggestion():
    store = make_store()
    llm = FakeLLM('{"action": "trim", "targetWeightPct": 15, "rationale": "估值过高"}')
    sid = generate_suggestion(store, llm, "NVDA", "SELL", "analysis1", fetch_quote=quote_110)
    doc = store._suggestions[sid]
    assert doc["action"] == "trim" and doc["targetWeightPct"] == 15
    assert doc["status"] == "pending" and doc["analysisId"] == "analysis1"
    # prompt 里有当前仓位占比：10*110=1100 股票 + 1000 现金 → 52.4%
    assert "52.4" in llm.prompts[0]


def test_hold_with_no_position_returns_none():
    store = make_store(with_position=False)
    llm = FakeLLM("should not be called")
    assert generate_suggestion(store, llm, "NVDA", "HOLD", "a1", fetch_quote=quote_110) is None
    assert store._suggestions == {} and llm.prompts == []


def test_malformed_llm_reply_degrades_gracefully():
    store = make_store()
    llm = FakeLLM("我觉得应该减仓，但我不会说 JSON")
    sid = generate_suggestion(store, llm, "NVDA", "SELL", "a1", fetch_quote=quote_110)
    doc = store._suggestions[sid]
    assert doc["action"] == "sell"                  # 从 decision 降级映射
    assert doc["targetWeightPct"] is None
    assert "减仓" in doc["rationale"]                # 原始输出保留
```

- [ ] **Step 2: 跑测试确认失败**

Run: `pytest tests/test_assistant_advisor.py -q` → ModuleNotFoundError

- [ ] **Step 3: 最小实现**

```python
# assistant/advisor.py
"""Translate an engine decision into a concrete position suggestion."""
from __future__ import annotations

import json
import re

from assistant.quotes import get_quote
from assistant.store import utc_now_iso

_PROMPT = """你是一位重视风控的组合经理。引擎对 {ticker} 的最新结论是: {decision}
当前组合: 总市值 {total:.2f} USD，现金 {cash:.2f} USD。
{ticker} 当前持仓: {holding_desc}，占组合 {weight:.1f}%。现价 {price}。

请给出一条具体操作建议，只输出 JSON（不要 markdown 代码块）:
{{"action": "buy|add|trim|sell|hold", "targetWeightPct": <目标仓位百分比数字或null>, "rationale": "<一段简体中文理由>"}}
"""

_DECISION_ACTION = {"BUY": "buy", "SELL": "sell", "HOLD": "hold"}


def _parse_reply(reply: str, decision: str) -> dict:
    m = re.search(r"\{.*\}", reply, re.DOTALL)
    if m:
        try:
            data = json.loads(m.group(0))
            return {
                "action": data.get("action") or _fallback_action(decision),
                "targetWeightPct": data.get("targetWeightPct"),
                "rationale": data.get("rationale") or reply,
            }
        except (json.JSONDecodeError, AttributeError):
            pass
    return {"action": _fallback_action(decision), "targetWeightPct": None, "rationale": reply}


def _fallback_action(decision: str) -> str:
    for key, action in _DECISION_ACTION.items():
        if key in decision.upper():
            return action
    return "hold"


def generate_suggestion(store, llm, ticker: str, decision: str, analysis_id: str,
                        *, fetch_quote=get_quote) -> str | None:
    positions = {p["ticker"]: p for p in store.get_positions()}
    pos = positions.get(ticker)
    if "HOLD" in decision.upper() and pos is None:
        return None  # nothing held, nothing to do — skip the noise

    def price_of(p):
        try:
            return fetch_quote(p["ticker"])["close"]
        except Exception:
            return p["avgCost"]  # degrade to cost basis so the suggestion still lands

    cash = store.get_portfolio_meta().get("cash", 0.0)
    total = cash + sum(p["shares"] * price_of(p) for p in positions.values())
    price = price_of(pos) if pos else price_of({"ticker": ticker, "avgCost": 0.0, "shares": 0})
    ticker_value = pos["shares"] * price if pos else 0.0
    weight = (ticker_value / total * 100) if total else 0.0
    holding_desc = f"{pos['shares']} 股 @ 成本 {pos['avgCost']}" if pos else "无持仓"

    reply = llm.invoke(_PROMPT.format(
        ticker=ticker, decision=decision, total=total, cash=cash,
        holding_desc=holding_desc, weight=round(weight, 1), price=price,
    )).content
    parsed = _parse_reply(reply, decision)
    return store.save_suggestion({
        "ticker": ticker,
        "action": parsed["action"],
        "targetWeightPct": parsed["targetWeightPct"],
        "rationale": parsed["rationale"],
        "analysisId": analysis_id,
        "status": "pending",
        "createdAt": utc_now_iso(),
    })
```

- [ ] **Step 4: 跑测试确认通过**

Run: `pytest tests/test_assistant_advisor.py -q` → 3 passed
（若 52.4 断言因浮点格式失败：10×110=1100，1100/2100=52.38%→round 52.4，实现与测试以此为准）

- [ ] **Step 5: 提交**

```bash
git add assistant/advisor.py tests/test_assistant_advisor.py
git commit -m "feat(assistant): generate position suggestions from decisions"
```

---

### Task 7: 建议复盘（`assistant/review.py`）

**Files:**
- Create: `assistant/review.py`
- Test: `tests/test_assistant_review.py`

**Interfaces:**
- Consumes: `Store.suggestions_due_review/update_suggestion`、`get_return_pct`
- Produces: `review_due_suggestions(store, today: str, *, review_after_days: int = 14, fetch_return=get_return_pct) -> int`
  - cutoff = today − review_after_days 天（ISO 日期拼 `T00:00:00+00:00`）
  - 对每条到期 suggestion：`outcomePct = fetch_return(ticker, createdAt 的日期部分, today)`，连同 `reviewedAt` 写回；单条失败跳过不中断；返回成功复盘条数
  - 注：引擎侧学习闭环由 `propagate()` 内建 memory-log 机制自动完成，此处不重复接线

- [ ] **Step 1: 写失败测试**

```python
# tests/test_assistant_review.py
from assistant.review import review_due_suggestions
from assistant.store import MemoryStore


def seeded_store():
    s = MemoryStore()
    s.save_suggestion({"ticker": "NVDA", "action": "trim", "status": "accepted",
                       "createdAt": "2026-07-10T12:00:00+00:00"})
    s.save_suggestion({"ticker": "AAPL", "action": "buy", "status": "pending",   # 不复盘
                       "createdAt": "2026-07-10T12:00:00+00:00"})
    return s


def test_due_suggestions_get_outcome_pct():
    store = seeded_store()
    calls = []

    def fake_return(ticker, start, end):
        calls.append((ticker, start, end))
        return -4.2

    n = review_due_suggestions(store, "2026-08-01", fetch_return=fake_return)
    assert n == 1
    assert calls == [("NVDA", "2026-07-10", "2026-08-01")]
    reviewed = [s for s in store._suggestions.values() if "outcomePct" in s]
    assert reviewed[0]["outcomePct"] == -4.2 and reviewed[0]["reviewedAt"]


def test_single_failure_does_not_abort():
    store = seeded_store()
    store.save_suggestion({"ticker": "BROKEN", "action": "sell", "status": "dismissed",
                           "createdAt": "2026-07-05T00:00:00+00:00"})

    def flaky(ticker, start, end):
        if ticker == "BROKEN":
            raise RuntimeError("no data")
        return 1.0

    assert review_due_suggestions(store, "2026-08-01", fetch_return=flaky) == 1
```

- [ ] **Step 2: 跑测试确认失败** → ModuleNotFoundError

- [ ] **Step 3: 最小实现**

```python
# assistant/review.py
"""Score resolved suggestions after a holding window (App-facing review).

Engine-side learning is NOT wired here on purpose: TradingAgentsGraph
resolves its own pending memory-log entries at the start of every
``propagate()`` run, so reflection happens automatically.
"""
from __future__ import annotations

import logging
from datetime import datetime, timedelta

from assistant.quotes import get_return_pct
from assistant.store import utc_now_iso

logger = logging.getLogger(__name__)


def review_due_suggestions(store, today: str, *, review_after_days: int = 14,
                           fetch_return=get_return_pct) -> int:
    cutoff_date = datetime.strptime(today, "%Y-%m-%d") - timedelta(days=review_after_days)
    cutoff_iso = cutoff_date.strftime("%Y-%m-%d") + "T23:59:59+00:00"
    reviewed = 0
    for sug in store.suggestions_due_review(cutoff_iso):
        start_date = sug["createdAt"][:10]
        try:
            outcome = fetch_return(sug["ticker"], start_date, today)
        except Exception:
            logger.warning("review failed for %s (%s)", sug["id"], sug["ticker"], exc_info=True)
            continue
        store.update_suggestion(sug["id"], {"outcomePct": outcome, "reviewedAt": utc_now_iso()})
        reviewed += 1
    return reviewed
```

- [ ] **Step 4: 跑测试确认通过** → 2 passed

- [ ] **Step 5: 提交**

```bash
git add assistant/review.py tests/test_assistant_review.py
git commit -m "feat(assistant): review resolved suggestions with realized returns"
```

---

### Task 8: 定时任务规划（`assistant/scheduler.py`）

**Files:**
- Create: `assistant/scheduler.py`
- Test: `tests/test_assistant_scheduler.py`

**Interfaces:**
- Consumes: `Store`（get_brief/get_watchlist/has_analysis_since/add_job）
- Produces: `plan_scheduled_jobs(store, now_et: datetime, *, is_trading_day) -> list[str]`
  - 返回新建 job 的 id 列表（jobs 已写入 store，status="queued"，requestedBy="schedule"）
  - 规则一（日报）：`is_trading_day(now_et)` 且 `now_et.hour*60+minute >= 16*60+30` 且 `store.get_brief(今天ET日期)` 为 None → 建 `{"type":"daily_brief"}`
  - 规则二（周度深度）：周五收盘后（同上时间条件）对每只 `deepFreq=="weekly"` 的自选股，若 `has_analysis_since(ticker, 本周一ET 00:00 的 ISO)` 为 False → 建 `{"type":"deep_analysis","ticker":...}`
  - `is_trading_day` 必须注入（生产方为 `quotes.is_trading_day_now`），保证测试纯净

- [ ] **Step 1: 写失败测试**

```python
# tests/test_assistant_scheduler.py
from datetime import datetime
from zoneinfo import ZoneInfo

from assistant.scheduler import plan_scheduled_jobs
from assistant.store import MemoryStore

ET = ZoneInfo("America/New_York")
FRI_EVENING = datetime(2026, 7, 31, 17, 0, tzinfo=ET)   # 2026-07-31 是周五
WED_EVENING = datetime(2026, 7, 29, 17, 0, tzinfo=ET)
FRI_NOON = datetime(2026, 7, 31, 12, 0, tzinfo=ET)


def store_with_watchlist():
    s = MemoryStore()
    s.seed_watchlist([
        {"ticker": "NVDA", "deepFreq": "weekly", "note": "", "addedAt": "x"},
        {"ticker": "AAPL", "deepFreq": "manual", "note": "", "addedAt": "x"},
    ])
    return s


def test_after_close_on_trading_day_schedules_brief():
    s = store_with_watchlist()
    ids = plan_scheduled_jobs(s, WED_EVENING, is_trading_day=lambda now: True)
    jobs = [s.get_job(i) for i in ids]
    assert [j["type"] for j in jobs] == ["daily_brief"]
    assert jobs[0]["status"] == "queued" and jobs[0]["requestedBy"] == "schedule"


def test_no_brief_before_close_or_on_holiday_or_when_done():
    s = store_with_watchlist()
    assert plan_scheduled_jobs(s, FRI_NOON, is_trading_day=lambda n: True) == []       # 未收盘
    assert plan_scheduled_jobs(s, WED_EVENING, is_trading_day=lambda n: False) == []   # 休市
    s.save_brief("2026-07-29", {"date": "2026-07-29"})                                  # 已有日报
    assert plan_scheduled_jobs(s, WED_EVENING, is_trading_day=lambda n: True) == []


def test_friday_evening_schedules_weekly_deep_analysis():
    s = store_with_watchlist()
    s.save_brief("2026-07-31", {"date": "2026-07-31"})    # 日报已生成，只看深度
    ids = plan_scheduled_jobs(s, FRI_EVENING, is_trading_day=lambda n: True)
    jobs = [s.get_job(i) for i in ids]
    assert [(j["type"], j.get("ticker")) for j in jobs] == [("deep_analysis", "NVDA")]  # manual 的 AAPL 不排


def test_weekly_deep_skipped_if_already_analyzed_this_week():
    s = store_with_watchlist()
    s.save_brief("2026-07-31", {"date": "2026-07-31"})
    s.save_analysis({"ticker": "NVDA", "tradeDate": "2026-07-29",
                     "createdAt": "2026-07-29T21:00:00+00:00", "decision": "HOLD", "sections": {}})
    assert plan_scheduled_jobs(s, FRI_EVENING, is_trading_day=lambda n: True) == []


def test_non_friday_does_not_schedule_deep_analysis():
    s = store_with_watchlist()
    s.save_brief("2026-07-29", {"date": "2026-07-29"})
    assert plan_scheduled_jobs(s, WED_EVENING, is_trading_day=lambda n: True) == []
```

- [ ] **Step 2: 跑测试确认失败** → ModuleNotFoundError

- [ ] **Step 3: 最小实现**

```python
# assistant/scheduler.py
"""Decide which scheduled jobs are due at this wake-up (pure logic, injectable)."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from assistant.store import utc_now_iso

_CLOSE_MINUTES = 16 * 60 + 30  # 16:30 ET


def _monday_utc_iso(now_et: datetime) -> str:
    monday_et = (now_et - timedelta(days=now_et.weekday())).replace(
        hour=0, minute=0, second=0, microsecond=0
    )
    return monday_et.astimezone(timezone.utc).isoformat()


def plan_scheduled_jobs(store, now_et: datetime, *, is_trading_day) -> list[str]:
    after_close = now_et.hour * 60 + now_et.minute >= _CLOSE_MINUTES
    if not after_close or not is_trading_day(now_et):
        return []

    created: list[str] = []
    today = now_et.strftime("%Y-%m-%d")

    if store.get_brief(today) is None:
        created.append(store.add_job({
            "type": "daily_brief",
            "status": "queued",
            "requestedBy": "schedule",
            "createdAt": utc_now_iso(),
        }))

    if now_et.weekday() == 4:  # Friday
        week_start = _monday_utc_iso(now_et)
        for item in store.get_watchlist():
            if item.get("deepFreq") != "weekly":
                continue
            if store.has_analysis_since(item["ticker"], week_start):
                continue
            created.append(store.add_job({
                "type": "deep_analysis",
                "ticker": item["ticker"],
                "status": "queued",
                "requestedBy": "schedule",
                "createdAt": utc_now_iso(),
            }))
    return created
```

- [ ] **Step 4: 跑测试确认通过** → 5 passed

- [ ] **Step 5: 提交**

```bash
git add assistant/scheduler.py tests/test_assistant_scheduler.py
git commit -m "feat(assistant): plan daily brief and weekly deep-analysis jobs"
```

---

### Task 9: job 执行器与 runner 入口（`assistant/jobs.py`、`assistant/runner.py`）

**Files:**
- Create: `assistant/jobs.py`
- Create: `assistant/runner.py`
- Test: `tests/test_assistant_jobs.py`

**Interfaces:**
- Consumes: 前面全部模块
- Produces:
  - `jobs.execute_job(store, job: dict, *, brief_fn, deep_fn) -> None`
    - `brief_fn(today: str) -> str`；`deep_fn(ticker: str, today: str) -> tuple[str, str]`
    - 成功 → `update_job(id, {status:"done", finishedAt})`；异常 → `{status:"failed", error:str(exc), finishedAt}`，不向上抛
    - `deep_analysis` 的 job 完成后把 `analysisId` 也写进 job 文档（App 可跳转）
  - `runner.main() -> int`：装配真实依赖并按序执行（僵尸清理 → 领 job → 补定时 → 复盘）；返回 0；仅烟测 import
  - `python -m assistant.runner` 可执行（`if __name__ == "__main__": raise SystemExit(main())`）

- [ ] **Step 1: 写失败测试**

```python
# tests/test_assistant_jobs.py
from assistant.jobs import execute_job
from assistant.store import MemoryStore


def queued(store, **extra):
    jid = store.add_job({"type": extra.pop("type", "daily_brief"), "status": "queued",
                         "requestedBy": "user", "createdAt": "2026-08-01T00:00:00+00:00", **extra})
    return {"id": jid, **store.get_job(jid)}


def test_daily_brief_job_success():
    s = MemoryStore()
    job = queued(s)
    execute_job(s, job, brief_fn=lambda today: "md", deep_fn=None)
    done = s.get_job(job["id"])
    assert done["status"] == "done" and done["finishedAt"]


def test_deep_analysis_job_records_analysis_id():
    s = MemoryStore()
    job = queued(s, type="deep_analysis", ticker="NVDA")
    execute_job(s, job, brief_fn=None, deep_fn=lambda t, d: ("analysis42", "BUY"))
    done = s.get_job(job["id"])
    assert done["status"] == "done" and done["analysisId"] == "analysis42"


def test_failure_is_recorded_not_raised():
    s = MemoryStore()
    job = queued(s, type="deep_analysis", ticker="NVDA")
    execute_job(s, job, brief_fn=None,
                deep_fn=lambda t, d: (_ for _ in ()).throw(RuntimeError("boom")))
    failed = s.get_job(job["id"])
    assert failed["status"] == "failed" and "boom" in failed["error"]


def test_unknown_job_type_marked_failed():
    s = MemoryStore()
    job = queued(s, type="mystery")
    execute_job(s, job, brief_fn=None, deep_fn=None)
    assert s.get_job(job["id"])["status"] == "failed"


def test_runner_module_imports():
    import assistant.runner  # 装配层可导入即可（真实执行需要 Firestore 凭证）
    assert callable(assistant.runner.main)
```

- [ ] **Step 2: 跑测试确认失败** → ModuleNotFoundError

- [ ] **Step 3: 最小实现**

```python
# assistant/jobs.py
"""Execute one claimed job; failures land in the job doc, never raise."""
from __future__ import annotations

import logging
from datetime import datetime, timezone

from assistant.store import utc_now_iso

logger = logging.getLogger(__name__)


def execute_job(store, job: dict, *, brief_fn, deep_fn) -> None:
    jid = job["id"]
    try:
        today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        if job["type"] == "daily_brief":
            brief_fn(today)
            store.update_job(jid, {"status": "done", "finishedAt": utc_now_iso()})
        elif job["type"] == "deep_analysis":
            analysis_id, _decision = deep_fn(job["ticker"], today)
            store.update_job(jid, {"status": "done", "finishedAt": utc_now_iso(),
                                   "analysisId": analysis_id})
        else:
            raise ValueError(f"unknown job type: {job['type']}")
    except Exception as exc:
        logger.exception("job %s failed", jid)
        store.update_job(jid, {"status": "failed", "error": str(exc),
                               "finishedAt": utc_now_iso()})
```

```python
# assistant/runner.py
"""Assembly entry point: launchd wakes this every 15 minutes.

Order per wake-up: zombie cleanup -> claim queued jobs -> plan scheduled
jobs (and run them) -> review due suggestions. All state lives in
Firestore; this process exits when done.
"""
from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

logger = logging.getLogger(__name__)

ZOMBIE_AFTER_HOURS = 2


def main() -> int:
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    # Heavy/real deps are imported here, not at module top (keeps tests light).
    from tradingagents.default_config import DEFAULT_CONFIG
    from tradingagents.llm_clients.factory import create_llm_client

    from assistant import quotes
    from assistant.daily_brief import generate_daily_brief
    from assistant.deep_analysis import run_deep_analysis
    from assistant.advisor import generate_suggestion
    from assistant.jobs import execute_job
    from assistant.review import review_due_suggestions
    from assistant.scheduler import plan_scheduled_jobs
    from assistant.store import FirestoreStore

    config = DEFAULT_CONFIG.copy()
    store = FirestoreStore.connect()
    llm = create_llm_client(
        config["llm_provider"], config["quick_think_llm"], config.get("backend_url")
    ).get_llm()

    def brief_fn(today: str) -> str:
        return generate_daily_brief(store, llm, today)

    def deep_fn(ticker: str, today: str) -> tuple[str, str]:
        analysis_id, decision = run_deep_analysis(store, ticker, today, config)
        generate_suggestion(store, llm, ticker, decision, analysis_id)
        return analysis_id, decision

    # 1. zombie cleanup
    cutoff = (datetime.now(timezone.utc) - timedelta(hours=ZOMBIE_AFTER_HOURS)).isoformat()
    zombies = store.fail_zombie_jobs(cutoff)
    if zombies:
        logger.warning("marked %d zombie job(s) failed", zombies)

    # 2. user-requested jobs first, then 3. newly planned scheduled jobs
    for job in store.claim_queued_jobs():
        execute_job(store, job, brief_fn=brief_fn, deep_fn=deep_fn)

    now_et = datetime.now(ZoneInfo("America/New_York"))
    plan_scheduled_jobs(store, now_et, is_trading_day=quotes.is_trading_day_now)
    for job in store.claim_queued_jobs():
        execute_job(store, job, brief_fn=brief_fn, deep_fn=deep_fn)

    # 4. review
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    reviewed = review_due_suggestions(store, today)
    logger.info("wake-up complete (reviewed %d suggestion(s))", reviewed)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 4: 跑测试确认通过**

Run: `pytest tests/test_assistant_jobs.py -q` → 5 passed
Run: `pytest tests/ -q`（全量回归，现有测试不得破坏）

- [ ] **Step 5: 提交**

```bash
git add assistant/jobs.py assistant/runner.py tests/test_assistant_jobs.py
git commit -m "feat(assistant): add job executor and launchd runner entry point"
```

---

### Task 10: launchd 配置、安全规则与部署文档

**Files:**
- Create: `scripts/com.tradingagents.assistant.plist`
- Create: `firebase/firestore.rules`
- Create: `assistant/README.md`
- Modify: `.env.example`（追加 `TRADINGAGENTS_FIREBASE_CREDENTIALS` 注释项）
- Modify: `.gitignore`（追加 `firebase-service-account.json` 防误提交）

本任务无单测（配置与文档），验证方式为人工核对 + `plutil -lint`。

- [ ] **Step 1: 写 launchd plist**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.tradingagents.assistant</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Volumes/external/code/ai/projects/TradingAgents/.venv/bin/python</string>
        <string>-m</string>
        <string>assistant.runner</string>
    </array>
    <key>WorkingDirectory</key>
    <string>/Volumes/external/code/ai/projects/TradingAgents</string>
    <key>StartInterval</key>
    <integer>900</integer>
    <key>StandardOutPath</key>
    <string>/tmp/tradingagents-assistant.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/tradingagents-assistant.err.log</string>
</dict>
</plist>
```

Run: `plutil -lint scripts/com.tradingagents.assistant.plist` → `OK`

- [ ] **Step 2: 写 Firestore 安全规则**

```
// firebase/firestore.rules
// Single-user lock: replace OWNER_UID with the UID of the one account you
// create in Firebase console (Authentication -> Users). The assistant runner
// uses the Admin SDK and bypasses these rules by design.
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    match /{document=**} {
      allow read, write: if request.auth != null && request.auth.uid == "OWNER_UID";
    }
  }
}
```

- [ ] **Step 3: 写 assistant/README.md**

内容必须覆盖（写成有序清单，人跟着做即可跑通）：

1. **Firebase 项目创建**（用户手动，控制台操作）：console.firebase.google.com → 新建项目（无需 Analytics）→ Build → Firestore Database → Create database（Native mode，区域选 us-east 任一）
2. **服务账号密钥**：Project settings → Service accounts → Generate new private key → 保存为 `~/.tradingagents/firebase-service-account.json`（`chmod 600`）
3. **安全规则**：Firestore → Rules → 粘贴 `firebase/firestore.rules` 内容，替换 `OWNER_UID`（先在 Authentication → Sign-in method 启用 Email/Password，手动 Add user，复制其 UID）——此步为计划二 Flutter 端做准备，runner 走 Admin SDK 不受规则约束
4. **依赖安装**：`.venv/bin/pip install -r requirements.txt`
5. **初始数据**：在 Firestore 控制台手工建 `watchlist/NVDA` 文档 `{ticker:"NVDA", deepFreq:"weekly", note:"", addedAt:"<今天>"}` 作冒烟数据
6. **冒烟验证**：`python -m assistant.runner` 手动跑一次 → 控制台看 `briefs/` 出现今日文档（若在收盘后）；或手工建一条 `jobs` 文档 `{type:"deep_analysis", ticker:"NVDA", status:"queued", requestedBy:"user", createdAt:"<now iso>"}` 再跑 runner，看 `analyses/`、`suggestions/` 生成
7. **launchd 安装**：
   ```bash
   cp scripts/com.tradingagents.assistant.plist ~/Library/LaunchAgents/
   launchctl load ~/Library/LaunchAgents/com.tradingagents.assistant.plist
   ```
   卸载：`launchctl unload ...`；看日志：`tail -f /tmp/tradingagents-assistant.log`
8. **成本提示**：日报每天一次 quick LLM 调用（约几美分）；每次深度分析为完整多 agent run（数美元量级，取决于模型配置）
9. **免责声明**：所有产出为软件生成的分析信息，不构成投资建议；交易由用户自行在券商执行

- [ ] **Step 4: 更新 .env.example 与 .gitignore**

`.env.example` 追加：

```
# Firebase service account key for the assistant runner (Admin SDK).
# Default: ~/.tradingagents/firebase-service-account.json
#TRADINGAGENTS_FIREBASE_CREDENTIALS=
```

`.gitignore` 追加：

```
# Firebase service account keys must never be committed
firebase-service-account.json
```

- [ ] **Step 5: 提交**

```bash
git add scripts/com.tradingagents.assistant.plist firebase/firestore.rules assistant/README.md .env.example .gitignore
git commit -m "docs(assistant): add launchd config, Firestore rules, and setup guide"
```

---

## Self-Review 记录

- **Spec 覆盖**：§2 目录（store/quotes 替代 spec 的 firestore_sync 命名，职责一致；notify.py 已按用户决定移除）✓；§3 数据模型全字段落在 Task 1/2 ✓；§4 调度三步（僵尸清理→领job→补定时→复盘）落在 Task 8/9 ✓；daily_brief/deep_analysis/advisor/review 各有专属任务 ✓；§6 安全规则与凭证管理落在 Task 10 ✓；§7 测试策略（内存假实现+全 mock）贯穿 ✓。Flutter（§5）属计划二，不在本计划。
- **占位符扫描**：无 TBD/TODO；每个代码步骤都有完整代码。README 步骤为文档性清单，内容已列全。
- **类型一致性**：`Store` 协议方法签名在 Task 2-9 的用法一一核对（`get_brief(date_str)`、`has_analysis_since(ticker, since_iso)`、`claim_queued_jobs()` 返回含 `id`、`update_job(jid, fields)` dict 参数）✓；`brief_fn(today)->str`、`deep_fn(ticker, today)->(id, decision)` 在 Task 9 测试与实现一致 ✓；`MemoryStore.get_job` 仅测试用但在 Task 1 已定义 ✓。
- **最终评审补记**：Task 9 里 `jobs.py` 用 `datetime.now(timezone.utc)` 计算 `today` 是个缺陷 —— scheduler 用 ET 日期规划/去重（`store.get_brief(ET-today)`），jobs 执行时却用 UTC 日期，20:00–24:00 ET 这段窗口两者错位，导致补日报被写到 ET 明天的槽位、scheduler 持续重新排队、深度分析拿到错的 tradeDate。修复方式：把 scheduler 已经算好的 ET 日期以 `"date"` 字段写进两类 job 文档，`execute_job` 优先读 `job["date"]`，缺失时才回退到按 ET（不是 UTC）现算；同时把 `runner.main()` 拆成瘦身的 `main()` + 可测的 `run_once(store, llm, config, *, now_et=None, is_trading_day=None, graph_factory=None, fetch_quote=None, fetch_news=None)`，四个阶段各自 try/except 隔离，并让 `deep_fn` 里 `generate_suggestion` 失败不再连累已完成的分析文档。
