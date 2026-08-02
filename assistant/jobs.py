"""Execute one claimed job; failures land in the job doc, never raise."""
from __future__ import annotations

import logging
from datetime import datetime
from zoneinfo import ZoneInfo

from assistant.store import utc_now_iso

logger = logging.getLogger(__name__)


def execute_job(store, job: dict, *, brief_fn, deep_fn, refresh_fn=None,
                chat_fn=None, strategy_fn=None, translate_fn=None) -> None:
    jid = job["id"]
    try:
        today = job.get("date")
        if today is None:
            today = datetime.now(ZoneInfo("America/New_York")).strftime("%Y-%m-%d")
        if job["type"] == "daily_brief":
            brief_fn(today)
            store.update_job(jid, {"status": "done", "finishedAt": utc_now_iso()})
        elif job["type"] == "deep_analysis":
            analysis_id, _decision = deep_fn(job["ticker"], today)
            store.update_job(jid, {"status": "done", "finishedAt": utc_now_iso(),
                                   "analysisId": analysis_id})
        elif job["type"] == "refresh_quotes":
            if refresh_fn is None:
                raise ValueError("refresh_fn not wired")
            refresh_fn(today)
            store.update_job(jid, {"status": "done", "finishedAt": utc_now_iso()})
        elif job["type"] == "chat":
            if chat_fn is None:
                raise ValueError("chat_fn not wired")
            chat_fn(job["chatId"], today)
            store.update_job(jid, {"status": "done", "finishedAt": utc_now_iso()})
        elif job["type"] == "translate":
            if translate_fn is None:
                raise ValueError("translate_fn not wired")
            translate_fn(job["analysisId"], job.get("sections") or [])
            store.update_job(jid, {"status": "done", "finishedAt": utc_now_iso()})
        elif job["type"] == "strategy_scan":
            if strategy_fn is None:
                raise ValueError("strategy_fn not wired")
            result = strategy_fn(job, today)
            store.update_job(jid, {"status": "done", "finishedAt": utc_now_iso(),
                                   **(result or {})})
        else:
            raise ValueError(f"unknown job type: {job['type']}")
    except Exception as exc:
        logger.exception("job %s failed", jid)
        store.update_job(jid, {"status": "failed", "error": str(exc),
                               "finishedAt": utc_now_iso()})
