"""Numeric quote helpers for the assistant (engine dataflows return prose)."""
from __future__ import annotations

import math
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


def get_quote(ticker: str, _history=_yf_history, _fetch_html=None) -> dict:
    if is_isin(ticker):
        kwargs = {} if _fetch_html is None else {"_fetch_html": _fetch_html}
        # 1) 已映射的基金 → Borsa 基金页官方 NAV（Yahoo 法兰克福源会漂）
        if ticker in _BORSA_FUND_CODES:
            return _borsa_fund_quote(ticker, **kwargs)
        # 2) 债券 → Borsa BTP 页；3) 都不是 → 兜底 yfinance 裸 ISIN
        try:
            return _borsa_bond_quote(ticker, **kwargs)
        except Exception:
            pass
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


def _clean_volume(v) -> float:
    try:
        f = float(v)
    except (TypeError, ValueError):
        return 0.0
    return 0.0 if f != f else f   # NaN != NaN


def _yf_history_ohlc(ticker: str, start: str, end: str) -> list[dict]:
    """Ascending [{date, high, low, close, volume}] daily bars via yfinance. Lazy import."""
    import yfinance as yf

    end_excl = (datetime.strptime(end, "%Y-%m-%d") + timedelta(days=1)).strftime("%Y-%m-%d")
    df = yf.Ticker(ticker).history(start=start, end=end_excl)
    if df.empty:
        return []
    df = df.dropna(subset=["Close", "High", "Low"])
    if df.empty:
        return []
    if df.index.tz is not None:
        df.index = df.index.tz_localize(None)
    return [
        {"date": idx.strftime("%Y-%m-%d"), "high": float(r["High"]),
         "low": float(r["Low"]), "close": float(r["Close"]),
         "volume": _clean_volume(r.get("Volume"))}
        for idx, r in df.iterrows()
    ]


def get_ohlc_history(ticker: str, end_date: str, days: int = 200,
                     _history=_yf_history_ohlc) -> list[dict]:
    """~`days` 个自然日的日线 OHLC（升序）。策略层（海龟等）用它算通道和 ATR。"""
    start = (datetime.strptime(end_date, "%Y-%m-%d") - timedelta(days=days)).strftime("%Y-%m-%d")
    return _history(ticker, start, end_date)


def _yf_dividends(ticker: str, start: str, end: str) -> list[tuple[str, float]]:
    """升序 [(除息日, 每股分红)]，区间含两端。Lazy import。

    yfinance 的 ``.dividends`` 是每股金额（税前），ETF 的分派也走同一字段。
    单只债券（ISIN）Yahoo 没有覆盖，付息只能手工补录。
    """
    import yfinance as yf

    series = yf.Ticker(ticker).dividends
    if series is None or series.empty:
        return []
    idx = series.index
    if getattr(idx, "tz", None) is not None:
        series = series.tz_localize(None)
    out = []
    for ts, amount in series.items():
        day = ts.strftime("%Y-%m-%d")
        if start <= day <= end and float(amount) > 0:
            out.append((day, float(amount)))
    return sorted(out)


def get_dividends(ticker: str, start_date: str, end_date: str,
                  _dividends=_yf_dividends) -> list[tuple[str, float]]:
    """区间内的每股分红（升序）。ISIN 直接返回空——Yahoo 无单券覆盖。"""
    if is_isin(ticker):
        return []
    return _dividends(ticker, start_date, end_date)


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


# --- Borsa Italiana MOT bonds (by ISIN) ------------------------------------
# Yahoo has no per-bond coverage; borsaitaliana.it's public quote page does.
# Prices are per-100 nominal (standard bond convention).

import re

_ISIN_RE = re.compile(r"^[A-Z]{2}[A-Z0-9]{9}[0-9]$")


def is_isin(ticker: str) -> bool:
    return bool(_ISIN_RE.match(ticker))


def _parse_it_number(s: str) -> float:
    """Italian format: '.' thousands, ',' decimals — '1.234,56' -> 1234.56."""
    return float(s.replace(".", "").replace(",", "."))


def _parse_borsa_price(html: str) -> float:
    flat = re.sub(r"\s+", " ", html)
    for label in ("Prezzo ufficiale", "Prezzo di riferimento"):
        m = re.search(re.escape(label) + r".{0,200}?([0-9]{1,3}(?:\.[0-9]{3})*,[0-9]+)", flat)
        if m:
            return _parse_it_number(m.group(1))
    raise QuoteUnavailable("no price found on Borsa Italiana page")


def _fetch_borsa_html(isin: str) -> str:
    import requests

    url = f"https://www.borsaitaliana.it/borsa/obbligazioni/mot/btp/scheda/{isin}.html"
    resp = requests.get(url, headers={"User-Agent": "Mozilla/5.0"}, timeout=15)
    resp.raise_for_status()
    return resp.text


def _borsa_bond_quote(isin: str, _fetch_html=_fetch_borsa_html) -> dict:
    price = _parse_borsa_price(_fetch_html(isin))
    # 页面无前收盘，涨跌幅暂记 0；持仓盈亏按成本价计算，不受影响。
    return {"ticker": isin, "close": price, "prevClose": price, "pctChange": 0.0}


# --- Borsa Italiana funds (fondi comuni) ------------------------------------
# Fund NAVs on Yahoo (Frankfurt feed) can diverge badly from the official
# Italian NAV (seen: 8.71 vs 8.328). Borsa's fondi detail page is authoritative
# but is keyed by an internal code, not ISIN — map maintained by hand: 用户给
# 出 dettaglio 链接即可添加。
_BORSA_FUND_CODES = {
    "IT0003110886": "1BAPOOE",  # BancoPosta Obbligazionario Euro Medio-Lungo T.
}


def _fetch_borsa_fund_html(code: str) -> str:
    import requests

    url = f"https://www.borsaitaliana.it/borsa/fondi/dettaglio/{code}.html"
    resp = requests.get(url, headers={"User-Agent": "Mozilla/5.0"}, timeout=15)
    resp.raise_for_status()
    return resp.text


def _parse_borsa_fund_nav(html: str) -> tuple[float, float]:
    """(close, prev) from the fund header: 第一组意大利数字是最新 NAV，
    随后 Variazione 区块给出最新/前值。"""
    flat = re.sub(r"\s+", " ", html)
    nums = [_parse_it_number(m.group(1))
            for m in re.finditer(r">\s*([0-9]{1,2},[0-9]{2,5})\s*<", flat)][:4]
    if not nums:
        raise QuoteUnavailable("no NAV found on Borsa fund page")
    close = nums[0]
    prev = next((n for n in nums[1:] if n != close), close)
    return close, prev


def _borsa_fund_quote(isin: str, _fetch_html=_fetch_borsa_fund_html) -> dict:
    close, prev = _parse_borsa_fund_nav(_fetch_html(_BORSA_FUND_CODES[isin]))
    pct = 0.0 if not prev else round((close - prev) / prev * 100, 2)
    return {"ticker": isin, "close": close, "prevClose": prev, "pctChange": pct}


def get_money_flow(ticker: str, end_date: str, *,
                   _history=_yf_history_ohlc) -> dict | None:
    """个股量价资金流：量比 / MFI14 / OBV 5日方向 / 5日涨跌 %。

    日报用它给 LLM 喂可验证的数字。任何取数或数据不足的情况一律返回
    None（调用方按「无量价数据」降级），绝不抛出。ISIN（Borsa 债券/基金）
    没有成交量概念，直接 None。
    """
    if is_isin(ticker):
        return None
    try:
        start = (datetime.strptime(end_date, "%Y-%m-%d")
                 - timedelta(days=60)).strftime("%Y-%m-%d")
        bars = [b for b in _history(ticker, start, end_date)
                if b.get("volume") is not None]
        if len(bars) < 21:
            return None
        vols = [b["volume"] for b in bars]
        avg20 = sum(vols[-21:-1]) / 20
        if avg20 <= 0:
            return None

        # MFI14：typical price × volume 的正/负流量占比
        tp = [(b["high"] + b["low"] + b["close"]) / 3 for b in bars]
        pos = neg = 0.0
        for i in range(len(bars) - 14, len(bars)):
            flow = tp[i] * vols[i]
            if tp[i] > tp[i - 1]:
                pos += flow
            elif tp[i] < tp[i - 1]:
                neg += flow
        mfi = 50.0 if pos + neg == 0 else 100 * pos / (pos + neg)

        # OBV 近 5 日方向：首尾差 < 区间内绝对摆动的 20% 视为走平
        obv = [0.0]
        for i in range(1, len(bars)):
            if bars[i]["close"] > bars[i - 1]["close"]:
                obv.append(obv[-1] + vols[i])
            elif bars[i]["close"] < bars[i - 1]["close"]:
                obv.append(obv[-1] - vols[i])
            else:
                obv.append(obv[-1])
        window = obv[-6:]
        diff = window[-1] - window[0]
        swing = sum(abs(window[j + 1] - window[j]) for j in range(len(window) - 1))
        if swing == 0 or abs(diff) < 0.2 * swing:
            obv_trend = "flat"
        else:
            obv_trend = "up" if diff > 0 else "down"

        return {
            "volumeRatio": round(vols[-1] / avg20, 2),
            "mfi14": round(mfi, 1),
            "obvTrend": obv_trend,
            "chg5dPct": round((bars[-1]["close"] - bars[-6]["close"])
                              / bars[-6]["close"] * 100, 2),
        }
    except Exception:
        return None


_FUTURES = (("ES=F", "标普500期指"), ("NQ=F", "纳指100期指"))


def _bs_gamma(spot: float, strike: float, iv: float, t_years: float) -> float:
    """Black-Scholes gamma（r=0 简化）。参数非法一律 0，永不抛出。"""
    if iv <= 0 or t_years <= 0 or spot <= 0 or strike <= 0:
        return 0.0
    d1 = (math.log(spot / strike) + 0.5 * iv * iv * t_years) / (
        iv * math.sqrt(t_years))
    return math.exp(-0.5 * d1 * d1) / math.sqrt(2 * math.pi) / (
        spot * iv * math.sqrt(t_years))


def get_positioning(ticker: str, *, _ticker_factory=None, _today: str | None = None) -> dict | None:
    """个股多空：做空数据（FINRA 双周频）+ 30 天内到期链聚合的 put/call 比、净 Gamma 敞口（GEX）与 Call/Put 墙。

    键全部可选（数据源缺哪个就不写哪个），至少一键才返回 dict。美股以外
    （ISIN、.MI、.DE 无此数据，省两次白调用）、五键全无、任何异常一律返回
    None，绝不抛出。``_ticker_factory`` 供测试注入假 ``yf.Ticker``。``_today``
    供测试注入日期（缺省取 UTC 今天）。
    """
    if is_isin(ticker) or ticker.upper().endswith((".MI", ".DE")):
        return None
    try:
        if _ticker_factory is None:
            import yfinance as yf
            _ticker_factory = yf.Ticker
        tk = _ticker_factory(ticker)
        out: dict = {}
        info = tk.info or {}
        spf = info.get("shortPercentOfFloat")
        if spf:
            out["shortPctFloat"] = round(spf * 100, 2)
        cur, prior = info.get("sharesShort"), info.get("sharesShortPriorMonth")
        if cur and prior:
            out["shortChangePct"] = round((cur - prior) / prior * 100, 2)
        if info.get("shortRatio"):
            out["shortRatioDays"] = round(info["shortRatio"], 2)
        try:
            spot = info.get("regularMarketPrice") or info.get("previousClose")
            if spot:
                spot = float(spot)
                today_d = (datetime.strptime(_today, "%Y-%m-%d").date()
                           if _today else datetime.utcnow().date())
                expiries = []
                for e in tk.options or ():
                    try:
                        days = (datetime.strptime(e, "%Y-%m-%d").date()
                                - today_d).days
                    except ValueError:
                        continue
                    if 0 <= days <= 30:
                        expiries.append((e, days))
                expiries = expiries[:6]

                call_oi_total = put_oi_total = call_vol = put_vol = 0.0
                call_walls: dict[float, float] = {}
                put_walls: dict[float, float] = {}
                gex, gex_any = 0.0, False
                for e, days in expiries:
                    try:
                        chain = tk.option_chain(e)
                    except Exception:
                        continue          # 单到期失败跳过
                    t_years = max(days / 365, 1 / 365)
                    for df, sign, walls in ((chain.calls, 1, call_walls),
                                            (chain.puts, -1, put_walls)):
                        for _, row in df.iterrows():
                            oi = float(row.get("openInterest") or 0)
                            strike = float(row.get("strike") or 0)
                            if not (oi > 0 and strike > 0):
                                continue   # NaN 比较为 False，一并挡掉
                            walls[strike] = walls.get(strike, 0.0) + oi
                            g = _bs_gamma(spot, strike,
                                          float(row.get("impliedVolatility") or 0),
                                          t_years)
                            if g > 0:
                                gex += sign * g * oi * 100 * spot * spot * 0.01
                                gex_any = True
                        if sign > 0:
                            call_oi_total += float(df["openInterest"].sum())
                            call_vol += float(df["volume"].sum())
                        else:
                            put_oi_total += float(df["openInterest"].sum())
                            put_vol += float(df["volume"].sum())
                if call_oi_total > 0:
                    out["pcOi"] = round(put_oi_total / call_oi_total, 2)
                if call_vol > 0:
                    out["pcVol"] = round(put_vol / call_vol, 2)
                if gex_any:
                    out["gexMUsd"] = round(gex / 1e6, 0)
                if call_walls:
                    out["callWall"] = max(call_walls, key=call_walls.get)
                if put_walls:
                    out["putWall"] = max(put_walls, key=put_walls.get)
        except Exception:
            pass  # 期权链失败不拖累做空数据
        return out or None
    except Exception:
        return None


def get_futures_snapshot(*, _fetch_quote=get_quote) -> list[dict]:
    """股指期货快照（ES/NQ）。单条失败跳过，全失败返回 []，绝不抛出。"""
    out = []
    for symbol, name in _FUTURES:
        try:
            q = _fetch_quote(symbol)
            out.append({"name": name, "close": q["close"],
                        "pctChange": q["pctChange"]})
        except Exception:
            continue
    return out
