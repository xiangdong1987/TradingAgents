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


def test_isin_falls_back_to_yfinance_when_borsa_has_no_price():
    """非债券 ISIN（如基金 NAV）：Borsa 页无价时兜底走 yfinance 历史。"""
    from assistant.quotes import get_quote

    rows = [("2026-07-30", 8.70), ("2026-07-31", 8.71)]
    q = get_quote("IT0003110886",
                  _history=fake_history(rows),
                  _fetch_html=lambda isin: "<html>404 not found</html>")
    assert q["close"] == 8.71
    assert q["pctChange"] == round((8.71 - 8.70) / 8.70 * 100, 2)


def test_mapped_fund_isin_uses_borsa_fund_nav():
    from assistant.quotes import get_quote, _parse_borsa_fund_nav

    fixture = ('<h1>Bancoposta Obbligazionario</h1> <strong> 8,328 </strong>'
               '<span>Variazione</span> <td> 8,328 </td> <td> 8,322 </td>')
    assert _parse_borsa_fund_nav(fixture) == (8.328, 8.322)

    q = get_quote("IT0003110886", _fetch_html=lambda code: fixture)
    assert q["close"] == 8.328 and q["prevClose"] == 8.322
    assert q["pctChange"] == 0.07

    with pytest.raises(QuoteUnavailable):
        _parse_borsa_fund_nav("<html>niente</html>")
