from assistant.income import income_id, sync_dividends
from assistant.quotes import get_dividends
from assistant.store import MemoryStore


def make_store(positions=None):
    s = MemoryStore()
    s.seed_positions(positions if positions is not None else [
        {"ticker": "MSFT", "shares": 15, "avgCost": 385.0, "updatedAt": "x"},
    ])
    return s


def test_records_dividend_as_per_share_times_current_shares():
    store = make_store()
    divs = {"MSFT": [("2026-07-15", 0.83)]}
    added = sync_dividends(store, "2026-08-03",
                           fetch_dividends=lambda t, a, b: divs.get(t, []))
    assert added == 1
    row = store.list_income()[0]
    assert row["ticker"] == "MSFT"
    assert row["date"] == "2026-07-15"
    assert row["perShare"] == 0.83
    assert row["shares"] == 15
    assert row["amount"] == 12.45          # 0.83 × 15
    assert row["source"] == "auto"
    assert row["id"] == income_id("MSFT", "2026-07-15")


def test_rerun_is_idempotent():
    store = make_store()
    divs = {"MSFT": [("2026-07-15", 0.83)]}
    fetch = lambda t, a, b: divs.get(t, [])          # noqa: E731
    assert sync_dividends(store, "2026-08-03", fetch_dividends=fetch) == 1
    assert sync_dividends(store, "2026-08-03", fetch_dividends=fetch) == 0
    assert len(store.list_income()) == 1


def test_isin_positions_are_skipped():
    store = make_store([
        {"ticker": "IT0005696320", "shares": 1, "avgCost": 45000.0, "updatedAt": "x"},
    ])
    calls = []

    def fetch(t, a, b):
        calls.append(t)
        return [("2026-07-15", 100.0)]

    assert sync_dividends(store, "2026-08-03", fetch_dividends=fetch) == 0
    assert calls == []                     # 单券不去问 Yahoo，等手工补录


def test_zero_share_positions_are_skipped():
    store = make_store([{"ticker": "KO", "shares": 0, "avgCost": 80.0, "updatedAt": "x"}])
    assert sync_dividends(store, "2026-08-03",
                          fetch_dividends=lambda t, a, b: [("2026-07-15", 0.5)]) == 0


def test_lookback_window_is_passed_to_the_fetcher():
    store = make_store()
    seen = {}

    def fetch(ticker, start, end):
        seen[ticker] = (start, end)
        return []

    sync_dividends(store, "2026-08-03", fetch_dividends=fetch, lookback_days=30)
    assert seen["MSFT"] == ("2026-07-04", "2026-08-03")


def test_fetch_failure_for_one_ticker_does_not_abort_the_rest():
    store = make_store([
        {"ticker": "BOOM", "shares": 1, "avgCost": 1.0, "updatedAt": "x"},
        {"ticker": "KO", "shares": 10, "avgCost": 80.0, "updatedAt": "x"},
    ])

    def fetch(ticker, start, end):
        if ticker == "BOOM":
            raise RuntimeError("network down")
        return [("2026-07-20", 0.51)]

    assert sync_dividends(store, "2026-08-03", fetch_dividends=fetch) == 1
    assert store.list_income()[0]["ticker"] == "KO"


def test_get_dividends_filters_window_and_skips_isins():
    rows = [("2026-06-01", 0.5), ("2026-07-15", 0.83), ("2026-09-01", 0.9)]
    got = get_dividends("MSFT", "2026-07-01", "2026-08-03",
                        _dividends=lambda t, a, b: [r for r in rows if a <= r[0] <= b])
    assert got == [("2026-07-15", 0.83)]
    assert get_dividends("IT0005696320", "2026-07-01", "2026-08-03",
                         _dividends=lambda t, a, b: rows) == []
