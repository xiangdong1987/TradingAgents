"""Translate an engine decision into a concrete position suggestion.

The LLM proposes a direction and a target weight; the Policy layer then has
final say — the target is clamped to the per-name cap, the share count comes
from the risk formula capped by every portfolio-level gate, and a buy with no
headroom is recorded as ``meta.blocked`` with funding candidates instead of a
number the portfolio can't honour. See assistant/policy.py.
"""
from __future__ import annotations

import json
import logging
import re

from assistant import policy
from assistant.quotes import get_quote
from assistant.store import utc_now_iso

logger = logging.getLogger(__name__)

_PROMPT = """你是一位重视风控的组合经理。引擎对 {ticker} 的最新结论是: {decision}
当前组合（EUR 计价）: 总市值 {total:.2f}，现金 {cash:.2f}。
{ticker} 当前持仓: {holding_desc}，占组合 {weight:.1f}%。现价 {price}。

仓位纪律（你的建议必须落在这些约束内，否则会被系统钳制）:
{constraints}

请给出一条具体操作建议，只输出 JSON（不要 markdown 代码块）:
{{"action": "buy|add|trim|sell|hold", "targetWeightPct": <目标仓位百分比数字或null>, "rationale": "<一段简体中文理由>", "rationaleEn": "<the same rationale in English>"}}
"""

_DECISION_ACTION = {"BUY": "buy", "SELL": "sell", "HOLD": "hold"}


def _constraints_text(snap: policy.Snapshot | None, ticker: str) -> str:
    if snap is None:
        return "- （组合快照不可用，按常识保守建议）"
    p = snap.p
    layer = policy.layer_of(ticker, None, p)
    cap = (p["maxSingleStockPct"] if layer == "satellite" else p["maxSingleFundPct"])
    return "\n".join([
        f"- 该标的属于{layer}层，单一标的上限 {cap}%",
        f"- 现金缓冲不得低于组合的 {p['cashFloorPct']}%",
        f"- 个股（卫星层）合计上限 {p['maxSatellitePct']}%",
        f"- 美元敞口（含欧元计价的美股宽基）上限 {p['maxUsdExposurePct']}%",
        f"- 单笔风险预算 {p['riskPerTradePct']}%，在场总风险上限 {p['maxTotalRiskPct']}%",
    ])


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

    quotes: dict[str, dict] = {}

    def price_of(t: str, fallback: float = 0.0) -> float:
        if t in quotes:
            return quotes[t]["close"]
        try:
            close = fetch_quote(t)["close"]
        except Exception:
            close = fallback  # degrade to cost basis so the suggestion still lands
        quotes[t] = {"close": close}
        return close

    for t, p in positions.items():
        price_of(t, p.get("avgCost", 0.0))
    price = price_of(ticker, pos.get("avgCost", 0.0) if pos else 0.0)
    try:
        quotes["EURUSD=X"] = {"close": fetch_quote("EURUSD=X")["close"]}
    except Exception:
        logger.warning("EURUSD rate unavailable; policy gates skipped for %s", ticker)

    meta_doc = store.get_portfolio_meta()
    cash = meta_doc.get("cash", 0.0)
    snap = policy.snapshot(list(positions.values()), cash,
                           meta_doc.get("currency", "EUR"), quotes,
                           store.get_policy_config())

    total = snap.total_eur if snap else cash + sum(
        p["shares"] * price_of(p["ticker"]) for p in positions.values())
    cash_eur = snap.cash_eur if snap else cash
    ticker_value = snap.value_of(ticker) if snap else (pos["shares"] * price if pos else 0.0)
    weight = (ticker_value / total * 100) if total else 0.0
    holding_desc = f"{pos['shares']} 股 @ 成本 {pos['avgCost']}" if pos else "无持仓"

    reply = llm.invoke(_PROMPT.format(
        ticker=ticker, decision=decision, total=total, cash=cash_eur,
        holding_desc=holding_desc, weight=round(weight, 1), price=price,
        constraints=_constraints_text(snap, ticker),
    )).content
    parsed = _parse_reply(reply, decision)

    meta: dict = {}
    rationale, rationale_en = parsed["rationale"], parsed["rationaleEn"]
    target = parsed["targetWeightPct"]

    if snap is not None:
        clamped_target = policy.clamp_target_weight(snap, ticker, target)
        if target is not None and clamped_target != target:
            meta["targetClampedFrom"] = target
            note_zh = f"目标仓位由 {target}% 钳到 {clamped_target}%（单一标的上限）。"
            note_en = (f"Target weight clamped {target}% → {clamped_target}% "
                       f"(per-name cap).")
            rationale = f"{rationale}\n\n⚠️ {note_zh}"
            rationale_en = f"{rationale_en}\n\n⚠️ {note_en}".strip()
        target = clamped_target

        if parsed["action"] in ("buy", "add") and price > 0:
            # 三重取小：风险定股数 → 过组合级闸 → 现金可买
            stop = round(price * (1 - snap.p["defaultStopPct"] / 100), 4)
            want = policy.risk_shares(snap, ticker, price, stop)
            verdict = policy.check_buy(snap, ticker, want, price, stop_native=stop)
            meta["stop"] = stop
            if verdict.blocked:
                meta["blocked"] = True
                meta["blockedBy"] = verdict.binding
                if verdict.funding_candidates:
                    meta["fundingCandidates"] = verdict.funding_candidates
                rationale = f"{rationale}\n\n⚠️ {verdict.reason}"
                rationale_en = f"{rationale_en}\n\n⚠️ {verdict.reason_en}".strip()
            else:
                meta["shares"] = verdict.allowed_shares
                if verdict.clamped:
                    meta["clampedFrom"] = verdict.requested_shares
                    meta["clampedBy"] = verdict.binding
                    rationale = f"{rationale}\n\n⚠️ {verdict.reason}"
                    rationale_en = f"{rationale_en}\n\n⚠️ {verdict.reason_en}".strip()

    return store.save_suggestion({
        "ticker": ticker,
        "action": parsed["action"],
        "targetWeightPct": target,
        "rationale": rationale,
        "rationaleEn": rationale_en,
        "analysisId": analysis_id,
        "meta": meta,
        "status": "pending",
        "createdAt": utc_now_iso(),
    })
