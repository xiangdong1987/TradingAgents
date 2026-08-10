"""Daily lightweight brief: one quick-LLM call over quotes + news + P&L."""
from __future__ import annotations

from datetime import datetime, timedelta

from assistant.lang import BILINGUAL_INSTRUCTION, split_bilingual
from assistant.quotes import (get_futures_snapshot, get_money_flow,
                              get_positioning, get_quote)
from assistant.store import utc_now_iso

_PROMPT_TEMPLATE = """你是一位谨慎的投资研究助理。基于以下数据写一份每日投资日报（Markdown）。
结构：## 组合概览（含现金与浮动盈亏）→ ## 持仓点评（每只一两句，结合资金流）→ ## 自选分析与推荐 → ## 值得注意（异动、风险，若某只股值得做一次深度多agent分析请点名）。
「自选分析与推荐」只写这些未持仓的自选股：{watch_only_line}。每只 1-2 句，结合行情、资金流与新闻，并以固定标签之一结尾：【值得深挖】【回调关注】【观望】【建议移除】。持仓股只出现在持仓点评，不要重复。
只依据给出的数据，不要编造数字。资金流口径：量比 = 今日成交量/20日均量；MFI 为 14 日资金流指标（>80 超买，<20 超卖）；OBV 为能量潮方向。多空口径：空头占流通盘越高、环比上升 = 看空压力增；回补天数为空头全部回补所需交易日；期权 P/C>1 偏空、<1 偏多；做空数据为 FINRA 双周频，非实时。若有期指数据，组合概览开头点一句隔夜期指情绪。日期：{today}
{bilingual}

# 股指期货
{futures_block}

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


def generate_daily_brief(store, llm, today: str, *, fetch_quote=get_quote,
                         fetch_news=None, fetch_money_flow=get_money_flow,
                         fetch_positioning=get_positioning,
                         fetch_futures=get_futures_snapshot) -> str:
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
        try:
            mf = fetch_money_flow(t, today)
        except Exception:
            mf = None
        if mf:
            trend_txt = {"up": "5日走高", "down": "5日走低",
                         "flat": "5日走平"}[mf["obvTrend"]]
            mf_line = (f"资金流: 量比 {mf['volumeRatio']:.2f}，"
                       f"MFI {mf['mfi14']:.0f}，OBV {trend_txt}，"
                       f"5日 {mf['chg5dPct']:+.1f}%")
        else:
            mf_line = "资金流: 无量价数据"
        try:
            posi = fetch_positioning(t)
        except Exception:
            posi = None
        if posi:
            segs = []
            if "shortPctFloat" in posi:
                seg = f"空头占流通 {posi['shortPctFloat']:.1f}%"
                if "shortChangePct" in posi:
                    seg += f"（环比 {posi['shortChangePct']:+.1f}%）"
                segs.append(seg)
            elif "shortChangePct" in posi:
                segs.insert(0, f"空头环比 {posi['shortChangePct']:+.1f}%")
            if "shortRatioDays" in posi:
                segs.append(f"回补 {posi['shortRatioDays']} 天")
            pc_bits = []
            if "pcOi" in posi:
                pc_bits.append(f"持仓 {posi['pcOi']}")
            if "pcVol" in posi:
                pc_bits.append(f"成交 {posi['pcVol']}")
            if pc_bits:
                segs.append("期权P/C " + " / ".join(pc_bits))
            posi_line = "多空: " + "，".join(segs) if segs else "多空: 无数据"
        else:
            posi_line = "多空: 无数据"
        tag = "（持仓）" if t in positions else "（自选）"
        ticker_parts.append(
            f"## {t}{tag}\n{quote_line}\n{mf_line}\n{posi_line}\n近日新闻:\n{news}")

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

    watch_only = sorted(watch - set(positions))
    watch_only_line = ("、".join(watch_only)
                       or "（无，此节写「今日无未持仓自选」即可）")
    try:
        futs = fetch_futures()
    except Exception:
        futs = []
    futures_block = ("\n".join(
        f"{f['name']}: {f['close']}，{f['pctChange']:+.2f}%" for f in futs)
        or "（期指数据缺失）")
    prompt = _PROMPT_TEMPLATE.format(
        today=today,
        bilingual=BILINGUAL_INSTRUCTION,
        cash=meta.get("cash", 0.0),
        currency=meta.get("currency", "USD"),
        positions_block="\n".join(position_parts) or "（无持仓）",
        tickers_block="\n\n".join(ticker_parts) or "（自选与持仓均为空）",
        watch_only_line=watch_only_line,
        futures_block=futures_block,
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
