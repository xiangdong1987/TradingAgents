"""Dividend / interest income tracking so cumulative return includes payouts.

The runner syncs dividends daily: for every non-ISIN position it pulls the
per-share amounts Yahoo reports in a lookback window and records one
``income`` doc per (ticker, ex-date). Doc ids are ``{ticker}_{date}`` so
re-running is idempotent.

Two deliberate approximations, both visible in the stored doc:

- ``shares`` is the **current** holding, not the holding on the ex-date
  (there is no historical position ledger). The short lookback window keeps
  the drift small, and ``source: "auto"`` marks the row as an estimate.
- ``perShare`` is Yahoo's **gross** amount, before withholding tax.

Auto-synced income never touches cash — cash stays user-maintained, so a
broker-reconciled balance can't be double counted. Manually entered income
from the app credits cash, because that is a user-initiated bookkeeping act.

Single bonds (ISIN) have no Yahoo coverage: their coupons must be entered
by hand in the app.
"""
from __future__ import annotations

import logging
from datetime import datetime, timedelta

from assistant.quotes import get_dividends, is_isin
from assistant.store import utc_now_iso

logger = logging.getLogger(__name__)

LOOKBACK_DAYS = 30


def income_id(ticker: str, date: str) -> str:
    return f"{ticker}_{date}"


def sync_dividends(store, today: str, *, fetch_dividends=get_dividends,
                   lookback_days: int = LOOKBACK_DAYS) -> int:
    """Record any newly-reported dividends for held tickers. Returns rows added."""
    start = (datetime.strptime(today, "%Y-%m-%d")
             - timedelta(days=lookback_days)).strftime("%Y-%m-%d")
    added = 0
    for pos in store.get_positions():
        ticker = pos["ticker"]
        if is_isin(ticker):
            continue  # 单券付息 Yahoo 无数据，靠 App 手工补录
        shares = float(pos.get("shares") or 0)
        if shares <= 0:
            continue
        try:
            divs = fetch_dividends(ticker, start, today)
        except Exception:
            logger.exception("dividend fetch failed for %s", ticker)
            continue
        for date, per_share in divs:
            if store.has_income(ticker, date):
                continue
            amount = round(per_share * shares, 4)
            store.add_income({
                "id": income_id(ticker, date),
                "ticker": ticker,
                "date": date,
                "perShare": per_share,
                "shares": shares,
                "amount": amount,
                "source": "auto",
                "createdAt": utc_now_iso(),
            })
            added += 1
            logger.info("income: %s %s %s/share × %s = %s",
                        ticker, date, per_share, shares, amount)
    return added
