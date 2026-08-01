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
