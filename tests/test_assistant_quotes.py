import pytest
from assistant.quotes import QuoteUnavailable, get_quote, get_return_pct, is_trading_day_now
from datetime import datetime
from zoneinfo import ZoneInfo


def fake_history(rows):
    def _h(ticker, start, end):
        return rows
    return _h


def test_get_quote_computes_pct_change():
    q = get_quote("NVDA", _history=fake_history([("2026-07-30", 100.0), ("2026-07-31", 110.0)]))
    assert q == {"ticker": "NVDA", "close": 110.0, "prevClose": 100.0, "pctChange": 10.0}


def test_get_quote_raises_when_insufficient_data():
    with pytest.raises(QuoteUnavailable):
        get_quote("NVDA", _history=fake_history([("2026-07-31", 110.0)]))


def test_get_return_pct():
    rows = [("2026-07-01", 100.0), ("2026-07-15", 105.0), ("2026-07-31", 120.0)]
    assert get_return_pct("NVDA", "2026-07-01", "2026-07-31", _history=fake_history(rows)) == 20.0


def test_is_trading_day_now_true_when_spy_has_todays_bar():
    now = datetime(2026, 7, 31, 17, 0, tzinfo=ZoneInfo("America/New_York"))
    assert is_trading_day_now(now, _history=fake_history([("2026-07-31", 500.0)])) is True
    assert is_trading_day_now(now, _history=fake_history([("2026-07-30", 500.0)])) is False
    assert is_trading_day_now(now, _history=fake_history([])) is False


def test_last_trading_day_returns_latest_bar_on_or_before():
    from assistant.quotes import last_trading_day
    rows = [("2026-07-30", 1.0), ("2026-07-31", 1.0)]
    assert last_trading_day("2026-08-01", _history=fake_history(rows)) == "2026-07-31"
    assert last_trading_day("2026-07-31", _history=fake_history(rows)) == "2026-07-31"
    with pytest.raises(QuoteUnavailable):
        last_trading_day("2026-08-01", _history=fake_history([]))


def test_isin_quotes_use_borsa_italiana():
    from assistant.quotes import get_quote, is_isin, _parse_borsa_price

    assert is_isin("IT0001247391") and not is_isin("ENEL.MI") and not is_isin("NVDA")

    fixture = ('<strong>Prezzo ufficiale</strong> </span> </td> <td> '
               '<span class="t-text -right">1.098,42</span>')
    assert _parse_borsa_price(fixture) == 1098.42

    q = get_quote("IT0001247391", _fetch_html=lambda isin: fixture)
    assert q["close"] == 1098.42 and q["pctChange"] == 0.0

    with pytest.raises(QuoteUnavailable):
        _parse_borsa_price("<html>nothing here</html>")
