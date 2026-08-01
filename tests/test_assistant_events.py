"""Calendar events collector tests (network-free)."""
import datetime

from assistant.events import refresh_calendar, ticker_events
from assistant.store import MemoryStore


def fake_calendar(ticker):
    if ticker == "BROKEN":
        raise RuntimeError("no data")
    return {
        "Earnings Date": [datetime.date(2026, 8, 26)],
        "Ex-Dividend Date": datetime.date(2026, 8, 4),
        "Dividend Date": datetime.date(2026, 9, 1),
    }


def test_ticker_events_maps_all_three_types():
    events = ticker_events("NVDA", fake_calendar)
    assert {e["type"] for e in events} == {"earnings", "exDividend", "dividendPay"}
    assert all(e["ticker"] == "NVDA" for e in events)
    assert events[0]["date"] == "2026-08-26"


def test_refresh_calendar_covers_watch_and_positions_skips_isin_and_failures():
    s = MemoryStore()
    s.seed_watchlist([
        {"ticker": "NVDA", "deepFreq": "manual", "note": "", "addedAt": "x"},
        {"ticker": "IT0001247391", "deepFreq": "manual", "note": "", "addedAt": "x"},  # 债券跳过
        {"ticker": "BROKEN", "deepFreq": "manual", "note": "", "addedAt": "x"},        # 失败跳过
    ])
    s.seed_positions([{"ticker": "ENEL.MI", "shares": 1, "avgCost": 9.0, "updatedAt": "x"}])

    n = refresh_calendar(s, fetch_calendar=fake_calendar)

    cal = s.get_calendar()
    tickers = {e["ticker"] for e in cal["events"]}
    assert tickers == {"NVDA", "ENEL.MI"}
    assert n == 6 and len(cal["events"]) == 6
    assert cal["updatedAt"]
    dates = [e["date"] for e in cal["events"]]
    assert dates == sorted(dates)                       # 按日期排序


def test_empty_calendar_fields_yield_no_events():
    assert ticker_events("X", lambda t: {}) == []
