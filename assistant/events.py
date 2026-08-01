"""Collect earnings/dividend calendar events for tracked tickers.

One document (``meta/calendar``) holds all upcoming events for the
watchlist ∪ positions; the app renders it as the home-screen agenda.
Refreshed once per day by the runner (and on user-requested refresh).
"""
from __future__ import annotations

import logging

from assistant.quotes import is_isin
from assistant.store import utc_now_iso

logger = logging.getLogger(__name__)


def _default_fetch_calendar(ticker: str) -> dict:
    import yfinance as yf  # lazy heavy import

    return yf.Ticker(ticker).calendar or {}


def _iso(d) -> str:
    return d.strftime("%Y-%m-%d") if hasattr(d, "strftime") else str(d)


def ticker_events(ticker: str, fetch_calendar=_default_fetch_calendar) -> list[dict]:
    """Earnings/ex-dividend/pay dates for one ticker, as
    ``{ticker, type, date}`` dicts (type: earnings|exDividend|dividendPay)."""
    cal = fetch_calendar(ticker)
    events = []
    for d in (cal.get("Earnings Date") or []):
        events.append({"ticker": ticker, "type": "earnings", "date": _iso(d)})
    if cal.get("Ex-Dividend Date"):
        events.append({"ticker": ticker, "type": "exDividend",
                       "date": _iso(cal["Ex-Dividend Date"])})
    if cal.get("Dividend Date"):
        events.append({"ticker": ticker, "type": "dividendPay",
                       "date": _iso(cal["Dividend Date"])})
    return events


def refresh_calendar(store, *, fetch_calendar=_default_fetch_calendar) -> int:
    """Rebuild meta/calendar for the current watchlist ∪ positions.

    Single-ticker failures are skipped; ISIN bonds have no Yahoo calendar.
    Returns the number of events stored.
    """
    tickers = {w["ticker"] for w in store.get_watchlist()}
    tickers |= {p["ticker"] for p in store.get_positions()}
    events: list[dict] = []
    for t in sorted(tickers):
        if is_isin(t):
            continue
        try:
            events.extend(ticker_events(t, fetch_calendar))
        except Exception:
            logger.warning("calendar fetch failed for %s", t, exc_info=True)
    events.sort(key=lambda e: (e["date"], e["ticker"]))
    store.save_calendar({"updatedAt": utc_now_iso(), "events": events})
    return len(events)
