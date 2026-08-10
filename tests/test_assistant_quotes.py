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


def test_unmapped_isin_falls_back_to_yfinance_when_borsa_has_no_price():
    """未映射的 ISIN：Borsa 债券页无价时兜底走 yfinance 历史。"""
    from assistant.quotes import get_quote

    rows = [("2026-07-30", 8.70), ("2026-07-31", 8.71)]
    q = get_quote("IT0001086567",     # 不在基金映射表里
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


# ---------- get_money_flow ----------

def _mf_bars(closes, volumes):
    """等长 closes/volumes 造日线；high=low=close 让 typical price = close，便于手算。"""
    return [
        {"date": f"2026-07-{i+1:02d}", "high": c, "low": c, "close": c, "volume": v}
        for i, (c, v) in enumerate(zip(closes, volumes))
    ]


def test_money_flow_all_up_hand_computed():
    from assistant.quotes import get_money_flow
    closes = list(range(10, 31))            # 21 根，10..30 严格上涨
    volumes = [100.0] * 20 + [200.0]        # 末日放量
    mf = get_money_flow("NVDA", "2026-08-01", _history=lambda t, s, e: _mf_bars(closes, volumes))
    assert mf["volumeRatio"] == 2.0          # 200 / mean(前20根=100)
    assert mf["mfi14"] == 100.0              # 全是正资金流
    assert mf["obvTrend"] == "up"
    assert mf["chg5dPct"] == 20.0            # (30-25)/25


def test_money_flow_all_down():
    from assistant.quotes import get_money_flow
    closes = list(range(30, 9, -1))          # 30..10 严格下跌
    volumes = [100.0] * 21
    mf = get_money_flow("NVDA", "2026-08-01", _history=lambda t, s, e: _mf_bars(closes, volumes))
    assert mf["mfi14"] == 0.0
    assert mf["obvTrend"] == "down"
    assert mf["chg5dPct"] == round((10 - 15) / 15 * 100, 2)


def test_money_flow_flat_prices():
    from assistant.quotes import get_money_flow
    mf = get_money_flow("NVDA", "2026-08-01",
                        _history=lambda t, s, e: _mf_bars([20.0] * 21, [100.0] * 21))
    assert mf["mfi14"] == 50.0               # 无正无负 → 中性
    assert mf["obvTrend"] == "flat"          # OBV 一直是 0
    assert mf["chg5dPct"] == 0.0


def test_money_flow_none_when_insufficient_or_no_volume():
    from assistant.quotes import get_money_flow
    few = _mf_bars(list(range(10, 30)), [100.0] * 20)          # 只有 20 根
    assert get_money_flow("NVDA", "2026-08-01", _history=lambda t, s, e: few) is None
    zero = _mf_bars(list(range(10, 31)), [0.0] * 21)           # 量全零
    assert get_money_flow("NVDA", "2026-08-01", _history=lambda t, s, e: zero) is None


def test_money_flow_none_for_isin_without_fetching():
    from assistant.quotes import get_money_flow
    def boom(t, s, e):
        raise AssertionError("ISIN 不应该去拉日线")
    assert get_money_flow("IT0005696320", "2026-08-01", _history=boom) is None


def test_money_flow_none_on_fetch_error():
    from assistant.quotes import get_money_flow
    def boom(t, s, e):
        raise RuntimeError("network down")
    assert get_money_flow("NVDA", "2026-08-01", _history=boom) is None


def test_money_flow_none_on_dirty_zero_close():
    from assistant.quotes import get_money_flow
    # 21 根 bars，close[-6] == 0（其余正常），不应抛 ZeroDivisionError，应返回 None
    closes = list(range(10, 31))
    closes[15] = 0.0  # bars[-6] 对应 index 15（倒数第6个）
    volumes = [100.0] * 21
    assert get_money_flow("NVDA", "2026-08-01", _history=lambda t, s, e: _mf_bars(closes, volumes)) is None


# ---------- get_positioning / get_futures_snapshot ----------

class _FakeChain:
    def __init__(self, calls_oi, puts_oi, calls_vol, puts_vol):
        import pandas as pd
        self.calls = pd.DataFrame({"openInterest": calls_oi, "volume": calls_vol})
        self.puts = pd.DataFrame({"openInterest": puts_oi, "volume": puts_vol})


class _FakeYfTicker:
    def __init__(self, info=None, expiries=(), chain=None):
        self.info = info or {}
        self.options = expiries
        self._chain = chain

    def option_chain(self, expiry):
        if self._chain is None:
            raise RuntimeError("no chain")
        return self._chain


def test_positioning_full_data_hand_computed():
    from assistant.quotes import get_positioning
    fake = _FakeYfTicker(
        info={"shortPercentOfFloat": 0.0139, "sharesShort": 108,
              "sharesShortPriorMonth": 100, "shortRatio": 2.24},
        expiries=("2026-08-08",),
        chain=_FakeChain(calls_oi=[100, 100], puts_oi=[49, 49],
                         calls_vol=[10, 10], puts_vol=[5, 5]),
    )
    p = get_positioning("NVDA", _ticker_factory=lambda t: fake)
    assert p == {"shortPctFloat": 1.39, "shortChangePct": 8.0,
                 "shortRatioDays": 2.24, "pcOi": 0.49, "pcVol": 0.5}


def test_positioning_partial_data_keeps_available_keys():
    from assistant.quotes import get_positioning
    fake = _FakeYfTicker(info={"shortRatio": 3.5})     # 无期权链、无占比/环比
    p = get_positioning("SPCX", _ticker_factory=lambda t: fake)
    assert p == {"shortRatioDays": 3.5}


def test_positioning_chain_failure_keeps_short_keys():
    from assistant.quotes import get_positioning
    fake = _FakeYfTicker(info={"shortRatio": 3.5}, expiries=("2026-08-08",),
                         chain=None)                   # option_chain 会抛
    p = get_positioning("VST", _ticker_factory=lambda t: fake)
    assert p == {"shortRatioDays": 3.5}


def test_positioning_none_when_no_data_at_all():
    from assistant.quotes import get_positioning
    assert get_positioning("KO", _ticker_factory=lambda t: _FakeYfTicker()) is None


def test_positioning_none_for_mi_and_isin_without_fetching():
    from assistant.quotes import get_positioning
    def boom(t):
        raise AssertionError("非美股不应该发请求")
    assert get_positioning("ENEL.MI", _ticker_factory=boom) is None
    assert get_positioning("IT0005696320", _ticker_factory=boom) is None


def test_positioning_none_on_error():
    from assistant.quotes import get_positioning
    def boom(t):
        raise RuntimeError("network down")
    assert get_positioning("NVDA", _ticker_factory=boom) is None


def test_futures_snapshot_skips_failures():
    from assistant.quotes import get_futures_snapshot
    def flaky(symbol):
        if symbol == "NQ=F":
            raise RuntimeError("nope")
        return {"ticker": symbol, "close": 7779.75, "prevClose": 7755.0,
                "pctChange": 0.31}
    out = get_futures_snapshot(_fetch_quote=flaky)
    assert out == [{"name": "标普500期指", "close": 7779.75, "pctChange": 0.31}]


def test_futures_snapshot_empty_when_all_fail():
    from assistant.quotes import get_futures_snapshot
    def boom(symbol):
        raise RuntimeError("nope")
    assert get_futures_snapshot(_fetch_quote=boom) == []


def test_positioning_none_for_de_without_fetching():
    from assistant.quotes import get_positioning
    def boom(t):
        raise AssertionError("德股不应该发请求")
    assert get_positioning("SAP.DE", _ticker_factory=boom) is None
