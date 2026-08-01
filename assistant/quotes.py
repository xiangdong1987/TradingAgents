"""Numeric quote helpers for the assistant (engine dataflows return prose)."""
from __future__ import annotations

from datetime import datetime, timedelta


class QuoteUnavailable(Exception):
    pass


def _yf_history(ticker: str, start: str, end: str) -> list[tuple[str, float]]:
    """Return ascending [(YYYY-MM-DD, close)] via yfinance. Lazy import."""
    import yfinance as yf

    end_excl = (datetime.strptime(end, "%Y-%m-%d") + timedelta(days=1)).strftime("%Y-%m-%d")
    df = yf.Ticker(ticker).history(start=start, end=end_excl)
    if df.empty:
        return []
    # Non-US listings (e.g. Borsa Italiana .MI) can carry all-NaN filler rows
    # for sessions Yahoo has no data for — drop them or the "last two bars"
    # arithmetic turns into NaN.
    df = df.dropna(subset=["Close"])
    if df.empty:
        return []
    if df.index.tz is not None:
        df.index = df.index.tz_localize(None)
    return [(idx.strftime("%Y-%m-%d"), float(row["Close"])) for idx, row in df.iterrows()]


def get_quote(ticker: str, _history=_yf_history) -> dict:
    end = datetime.utcnow().strftime("%Y-%m-%d")
    start = (datetime.utcnow() - timedelta(days=7)).strftime("%Y-%m-%d")
    rows = _history(ticker, start, end)
    if len(rows) < 2:
        raise QuoteUnavailable(f"not enough daily bars for {ticker}")
    prev_close, close = rows[-2][1], rows[-1][1]
    if not prev_close:
        raise QuoteUnavailable(f"zero/NaN previous close for {ticker}")
    return {
        "ticker": ticker,
        "close": close,
        "prevClose": prev_close,
        "pctChange": round((close - prev_close) / prev_close * 100, 2),
    }


def get_return_pct(ticker: str, start_date: str, end_date: str, _history=_yf_history) -> float:
    rows = _history(ticker, start_date, end_date)
    if len(rows) < 2:
        raise QuoteUnavailable(f"not enough daily bars for {ticker}")
    first, last = rows[0][1], rows[-1][1]
    return round((last - first) / first * 100, 2)


def last_trading_day(date_str: str, _history=_yf_history) -> str:
    """Most recent trading day on or before ``date_str`` (by SPY daily bars).

    User-triggered deep-analysis jobs can land on weekends/holidays, but the
    engine needs a date that has market data or it fails with "no rows".
    """
    start = (datetime.strptime(date_str, "%Y-%m-%d") - timedelta(days=10)).strftime("%Y-%m-%d")
    rows = _history("SPY", start, date_str)
    if not rows:
        raise QuoteUnavailable(f"no trading days on or before {date_str}")
    return rows[-1][0]


def is_trading_day_now(now_et: datetime, _history=_yf_history) -> bool:
    today = now_et.strftime("%Y-%m-%d")
    rows = _history("SPY", today, today)
    return bool(rows) and rows[-1][0] == today
