"""Daily lightweight brief: one quick-LLM call over quotes + news + P&L."""
from __future__ import annotations

from datetime import datetime, timedelta

from assistant.quotes import get_quote
from assistant.store import utc_now_iso

_PROMPT_TEMPLATE = """你是一位谨慎的投资研究助理。基于以下数据写一份简体中文的每日投资日报（Markdown）。
结构：## 组合概览（含现金与浮动盈亏）→ ## 个股点评（每只一两句）→ ## 值得注意（异动、风险，若某只股值得做一次深度多agent分析请点名）。
只依据给出的数据，不要编造数字。日期：{today}

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
        cash=meta.get("cash", 0.0),
        currency=meta.get("currency", "USD"),
        positions_block="\n".join(position_parts) or "（无持仓）",
        tickers_block="\n\n".join(ticker_parts) or "（自选与持仓均为空）",
    )
    markdown = llm.invoke(prompt).content
    store.save_brief(today, {
        "date": today,
        "markdownZh": markdown,
        "tickers": tickers,
        "createdAt": utc_now_iso(),
        "quotes": quotes_map,
    })
    return markdown
