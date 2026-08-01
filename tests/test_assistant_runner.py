"""Integration-ish tests for the run_once() assembly core (network-free)."""
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from zoneinfo import ZoneInfo

from assistant.runner import run_once
from assistant.store import MemoryStore, utc_now_iso

ET = ZoneInfo("America/New_York")
WED = datetime(2026, 8, 5, 17, 0, tzinfo=ET)  # Wednesday, after the 16:30 ET close


class FakeLLM:
    def __init__(self, content="ok"):
        self.content = content
        self.calls = 0

    def invoke(self, prompt):
        self.calls += 1
        return SimpleNamespace(content=self.content)


class RaisingLLM:
    """Always fails — used to exercise the advisor-failure isolation path."""

    def invoke(self, prompt):
        raise RuntimeError("advisor llm boom")


class FakeGraph:
    def __init__(self, decision="BUY"):
        self.decision = decision
        self.calls = []

    def propagate(self, ticker, date):
        self.calls.append((ticker, date))
        return {"final_trade_decision": "final"}, self.decision


def fake_quote(ticker, **kw):
    return {"ticker": ticker, "close": 100.0, "prevClose": 99.0, "pctChange": 1.01}


def fake_news(ticker, start, end):
    return "(no news)"


def test_run_once_runs_all_four_stages_in_order():
    store = MemoryStore()
    store.seed_watchlist([{"ticker": "AAPL", "deepFreq": "manual", "note": "", "addedAt": "x"}])

    # Stage 1: a stale "running" job should be failed by zombie cleanup.
    stale_id = store.add_job({
        "type": "deep_analysis", "ticker": "MSFT", "status": "running",
        "requestedBy": "user",
        "startedAt": (datetime.now(timezone.utc) - timedelta(hours=5)).isoformat(),
        "createdAt": utc_now_iso(),
    })

    # Stage 2: a queued user job should be claimed and executed.
    user_job_id = store.add_job({
        "type": "deep_analysis", "ticker": "NVDA", "status": "queued",
        "requestedBy": "user", "createdAt": utc_now_iso(),
    })

    llm = FakeLLM("brief markdown")

    result = run_once(
        store, llm, {"any": "cfg"},
        now_et=WED, is_trading_day=lambda n: True,
        graph_factory=lambda cfg: FakeGraph("BUY"),
        fetch_quote=fake_quote, fetch_news=fake_news,
    )

    assert result == 0

    # Stage 1: zombie cleanup marked the stale job failed.
    assert store.get_job(stale_id)["status"] == "failed"

    # Stage 2: the seeded user job was claimed and completed with an analysisId.
    done_user_job = store.get_job(user_job_id)
    assert done_user_job["status"] == "done"
    assert done_user_job["analysisId"]

    # Stage 3: no brief existed yet, so one was planned and executed under the
    # ET date computed from now_et (not whatever UTC happens to say).
    today = WED.strftime("%Y-%m-%d")
    brief = store.get_brief(today)
    assert brief is not None
    assert brief["markdownZh"] == "brief markdown"

    # Stage 4 (review) ran without error; nothing was due so nothing changed.


def test_scheduling_stage_error_is_isolated_and_review_still_runs():
    store = MemoryStore()

    def boom(now):
        raise RuntimeError("network hiccup")

    result = run_once(
        store, FakeLLM(), {"any": "cfg"},
        now_et=WED, is_trading_day=boom,
    )

    # No exception escapes, and the wake-up still reports success.
    assert result == 0
    # The scheduling stage failed before creating anything.
    assert store.get_brief(WED.strftime("%Y-%m-%d")) is None


def test_suggestion_failure_does_not_discard_completed_analysis():
    store = MemoryStore()
    job_id = store.add_job({
        "type": "deep_analysis", "ticker": "TSLA", "status": "queued",
        "requestedBy": "user", "createdAt": utc_now_iso(),
    })

    result = run_once(
        store, RaisingLLM(), {"any": "cfg"},
        now_et=WED, is_trading_day=lambda n: False,  # skip scheduling stage entirely
        graph_factory=lambda cfg: FakeGraph("BUY"),
    )

    assert result == 0
    done = store.get_job(job_id)
    # The analysis itself completed even though generate_suggestion's llm call
    # raised — the job should still be "done" with its analysisId intact.
    assert done["status"] == "done"
    assert done["analysisId"]
    assert store._analyses[done["analysisId"]]["ticker"] == "TSLA"
