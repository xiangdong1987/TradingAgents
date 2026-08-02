"""Translate an engine decision into a concrete position suggestion."""
from __future__ import annotations

import json
import re

from assistant.quotes import get_quote
from assistant.store import utc_now_iso

_PROMPT = """你是一位重视风控的组合经理。引擎对 {ticker} 的最新结论是: {decision}
当前组合: 总市值 {total:.2f} USD，现金 {cash:.2f} USD。
{ticker} 当前持仓: {holding_desc}，占组合 {weight:.1f}%。现价 {price}。

请给出一条具体操作建议，只输出 JSON（不要 markdown 代码块）:
{{"action": "buy|add|trim|sell|hold", "targetWeightPct": <目标仓位百分比数字或null>, "rationale": "<一段简体中文理由>", "rationaleEn": "<the same rationale in English>"}}
"""

_DECISION_ACTION = {"BUY": "buy", "SELL": "sell", "HOLD": "hold"}


def _parse_reply(reply: str, decision: str) -> dict:
    m = re.search(r"\{.*\}", reply, re.DOTALL)
    if m:
        try:
            data = json.loads(m.group(0))
            return {
                "action": data.get("action") or _fallback_action(decision),
                "targetWeightPct": data.get("targetWeightPct"),
                "rationale": data.get("rationale") or reply,
                "rationaleEn": data.get("rationaleEn") or "",
            }
        except (json.JSONDecodeError, AttributeError):
            pass
    return {"action": _fallback_action(decision), "targetWeightPct": None,
            "rationale": reply, "rationaleEn": ""}


def _fallback_action(decision: str) -> str:
    for key, action in _DECISION_ACTION.items():
        if key in decision.upper():
            return action
    return "hold"


def generate_suggestion(store, llm, ticker: str, decision: str, analysis_id: str,
                        *, fetch_quote=get_quote) -> str | None:
    positions = {p["ticker"]: p for p in store.get_positions()}
    pos = positions.get(ticker)
    if "HOLD" in decision.upper() and pos is None:
        return None  # nothing held, nothing to do — skip the noise

    def price_of(p):
        try:
            return fetch_quote(p["ticker"])["close"]
        except Exception:
            return p["avgCost"]  # degrade to cost basis so the suggestion still lands

    cash = store.get_portfolio_meta().get("cash", 0.0)
    total = cash + sum(p["shares"] * price_of(p) for p in positions.values())
    price = price_of(pos) if pos else price_of({"ticker": ticker, "avgCost": 0.0, "shares": 0})
    ticker_value = pos["shares"] * price if pos else 0.0
    weight = (ticker_value / total * 100) if total else 0.0
    holding_desc = f"{pos['shares']} 股 @ 成本 {pos['avgCost']}" if pos else "无持仓"

    reply = llm.invoke(_PROMPT.format(
        ticker=ticker, decision=decision, total=total, cash=cash,
        holding_desc=holding_desc, weight=round(weight, 1), price=price,
    )).content
    parsed = _parse_reply(reply, decision)
    return store.save_suggestion({
        "ticker": ticker,
        "action": parsed["action"],
        "targetWeightPct": parsed["targetWeightPct"],
        "rationale": parsed["rationale"],
        "rationaleEn": parsed["rationaleEn"],
        "analysisId": analysis_id,
        "status": "pending",
        "createdAt": utc_now_iso(),
    })
