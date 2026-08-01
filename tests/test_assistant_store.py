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


def test_resolve_credentials_path_env_override(tmp_path):
    from assistant.store import resolve_credentials_path
    default = resolve_credentials_path({})
    assert default.endswith(".tradingagents/firebase-service-account.json")
    custom = str(tmp_path / "sa.json")
    assert resolve_credentials_path({"TRADINGAGENTS_FIREBASE_CREDENTIALS": custom}) == custom
