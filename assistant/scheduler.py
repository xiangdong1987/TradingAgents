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
