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


def test_daily_brief_job_uses_stamped_date_not_utc_now():
    s = MemoryStore()
    job = queued(s, date="2026-07-31")
    seen = {}
    execute_job(s, job, brief_fn=lambda today: seen.setdefault("today", today), deep_fn=None)
    assert seen["today"] == "2026-07-31"


def test_deep_analysis_job_uses_stamped_date_not_utc_now():
    s = MemoryStore()
    job = queued(s, type="deep_analysis", ticker="NVDA", date="2026-07-31")
    seen = {}

    def deep_fn(ticker, today):
        seen["ticker"] = ticker
        seen["today"] = today
        return "analysis1", "BUY"

    execute_job(s, job, brief_fn=None, deep_fn=deep_fn)
    assert seen == {"ticker": "NVDA", "today": "2026-07-31"}


def test_refresh_quotes_job_invokes_refresh_fn():
    s = MemoryStore()
    job = queued(s, type="refresh_quotes")
    seen = []
    execute_job(s, job, brief_fn=None, deep_fn=None,
                refresh_fn=lambda today: seen.append(today))
    assert s.get_job(job["id"])["status"] == "done"
    assert len(seen) == 1


def test_refresh_quotes_without_wiring_fails_gracefully():
    s = MemoryStore()
    job = queued(s, type="refresh_quotes")
    execute_job(s, job, brief_fn=None, deep_fn=None)
    failed = s.get_job(job["id"])
    assert failed["status"] == "failed" and "refresh_fn" in failed["error"]


def test_chat_job_invokes_chat_fn_with_chat_id():
    s = MemoryStore()
    job = queued(s, type="chat", chatId="c1")
    seen = []
    execute_job(s, job, brief_fn=None, deep_fn=None,
                chat_fn=lambda cid, today: seen.append((cid, today)))
    assert s.get_job(job["id"])["status"] == "done"
    assert seen[0][0] == "c1"


def test_strategy_scan_job_invokes_strategy_fn_and_records_counts():
    s = MemoryStore()
    jid = s.add_job({"type": "strategy_scan", "strategy": "turtle", "status": "queued"})
    seen = {}

    def strategy_fn(job, today):
        seen["strategy"] = job["strategy"]
        return {"scanned": 3, "created": 1}

    job = {"id": jid, **s.get_job(jid)}
    execute_job(s, job, brief_fn=None, deep_fn=None, strategy_fn=strategy_fn)
    doc = s.get_job(jid)
    assert seen["strategy"] == "turtle"
    assert doc["status"] == "done" and doc["scanned"] == 3 and doc["created"] == 1


def test_strategy_scan_without_wiring_fails_gracefully():
    s = MemoryStore()
    jid = s.add_job({"type": "strategy_scan", "status": "queued"})
    execute_job(s, {"id": jid, **s.get_job(jid)}, brief_fn=None, deep_fn=None)
    doc = s.get_job(jid)
    assert doc["status"] == "failed" and "strategy_fn" in doc["error"]


def test_translate_job_routes_to_translate_fn():
    from assistant.jobs import execute_job
    from assistant.store import MemoryStore

    store = MemoryStore()
    jid = store.add_job({"type": "translate", "analysisId": "a1",
                         "sections": ["market"], "status": "queued",
                         "createdAt": "x"})
    calls = []
    job = {"id": jid, "type": "translate", "analysisId": "a1", "sections": ["market"]}
    execute_job(store, job, brief_fn=None, deep_fn=None,
                translate_fn=lambda aid, secs: calls.append((aid, secs)))
    assert calls == [("a1", ["market"])]
    assert store.get_job(jid)["status"] == "done"


def test_translate_job_without_fn_fails_job():
    from assistant.jobs import execute_job
    from assistant.store import MemoryStore

    store = MemoryStore()
    jid = store.add_job({"type": "translate", "analysisId": "a1",
                         "status": "queued", "createdAt": "x"})
    job = {"id": jid, "type": "translate", "analysisId": "a1"}
    execute_job(store, job, brief_fn=None, deep_fn=None)
    assert store.get_job(jid)["status"] == "failed"
