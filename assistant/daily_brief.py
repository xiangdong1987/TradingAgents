"""Daily lightweight brief: one quick-LLM call over quotes + news + P&L."""
from __future__ import annotations

from datetime import datetime, timedelta

from assistant.lang import BILINGUAL_INSTRUCTION, split_bilingual
from assistant.quotes import get_quote
from assistant.store import utc_now_iso

_PROMPT_TEMPLATE = """你是一位谨慎的投资研究助理。基于以下数据写一份每日投资日报（Markdown）。
结构：## 组合概览（含现金与浮动盈亏）→ ## 个股点评（每只一两句）→ ## 值得注意（异动、风险，若某只股值得做一次深度多agent分析请点名）。
只依据给出的数据，不要编造数字。日期：{today}
{bilingual}

# 组合
现金: {cash} {currency}
持仓:
{positions_block}

# 个股数据
{tickers_block}
"""


def _default_fetch_news(ticker: str, start: str, end: str) -> str:
    from tradingagents.dataflows.interface import route_to_vendor  # lazy import

    return route_to_vendor("get_news", ticker, start, end)


def generate_daily_brief(store, llm, today: str, *, fetch_quote=get_quote, fetch_news=None) -> str:
    if fetch_news is None:
        fetch_news = _default_fetch_news

    watch = {w["ticker"] for w in store.get_watchlist()}
    positions = {p["ticker"]: p for p in store.get_positions()}
    meta = store.get_portfolio_meta()
    tickers = sorted(watch | set(positions))

    yesterday = (datetime.strptime(today, "%Y-%m-%d") - timedelta(days=1)).strftime("%Y-%m-%d")
    ticker_parts, position_parts = [], []
    quotes_map: dict = {}
    for t in tickers:
        try:
            q = fetch_quote(t)
            quote_line = f"收盘 {q['close']}，涨跌 {q['pctChange']}%"
            quotes_map[t] = {"close": q["close"], "pctChange": q["pctChange"]}
        except Exception:
            q = None
            quote_line = "行情获取失败"
        try:
            news = fetch_news(t, yesterday, today)
        except Exception:
            news = "（新闻获取失败）"
        ticker_parts.append(f"## {t}\n{quote_line}\n近日新闻:\n{news}")

        pos = positions.get(t)
        if pos:
            if q:
                if pos["avgCost"] and pos["avgCost"] > 0:
                    pnl = round((q["close"] - pos["avgCost"]) / pos["avgCost"] * 100, 2)
                    pnl_str = f"浮动盈亏 {pnl:+.2f}%"
                else:
                    pnl_str = "浮动盈亏 未知（无成本价）"
            else:
                pnl_str = "浮动盈亏 未知（行情获取失败）"
            position_parts.append(
                f"- {t}: {pos['shares']} 股 @ 成本 {pos['avgCost']}，{pnl_str}"
            )

    prompt = _PROMPT_TEMPLATE.format(
        today=today,
        bilingual=BILINGUAL_INSTRUCTION,
        cash=meta.get("cash", 0.0),
        currency=meta.get("currency", "USD"),
        positions_block="\n".join(position_parts) or "（无持仓）",
        tickers_block="\n\n".join(ticker_parts) or "（自选与持仓均为空）",
    )
    _add_fx_if_needed(quotes_map, tickers, fetch_quote)
    zh, en = split_bilingual(llm.invoke(prompt).content)
    store.save_brief(today, {
        "date": today,
        "markdownZh": zh,
        "markdownEn": en,
        "tickers": tickers,
        "createdAt": utc_now_iso(),
        "quotes": quotes_map,
    })
    return zh


def top_up_quotes(store, today: str, *, fetch_quote=get_quote,
                  lookback_days: int = 3, force: bool = False) -> int:
    """Fill quotes missing from the most recent brief for the CURRENT
    watchlist ∪ positions.

    Tickers added after a brief was generated have no price in the client
    until the next brief; this tops them up cheaply (no LLM call). Looks
    back up to ``lookback_days`` for the latest brief doc (weekends). Returns
    the number of tickers added.
    """
    tickers = {w["ticker"] for w in store.get_watchlist()}
    tickers |= {p["ticker"] for p in store.get_positions()}
    if not tickers:
        return 0

    day = datetime.strptime(today, "%Y-%m-%d")
    brief, brief_date = None, None
    for back in range(lookback_days + 1):
        candidate = (day - timedelta(days=back)).strftime("%Y-%m-%d")
        brief = store.get_brief(candidate)
        if brief is not None:
            brief_date = candidate
            break
    if brief is None:
        return 0

    existing = {} if force else (brief.get("quotes") or {})
    added = {}
    for t in sorted(tickers - set(existing)):
        try:
            q = fetch_quote(t)
        except Exception:
            continue
        added[t] = {"close": q["close"], "pctChange": q["pctChange"]}
    if "EURUSD=X" not in existing:
        _add_fx_if_needed(added, tickers, fetch_quote)
    if added:
        store.merge_brief_quotes(brief_date, added)
    return len(added)


def _add_fx_if_needed(quotes_map: dict, tickers, fetch_quote) -> None:
    """Always ship the EURUSD rate: the client displays US listings in USD,
    Borsa Italiana (``.MI``) in EUR, and converts portfolio TOTALS to EUR."""
    if "EURUSD=X" in quotes_map:
        return
    try:
        q = fetch_quote("EURUSD=X")
        quotes_map["EURUSD=X"] = {"close": q["close"], "pctChange": q["pctChange"]}
    except Exception:
        pass
