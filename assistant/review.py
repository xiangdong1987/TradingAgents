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
