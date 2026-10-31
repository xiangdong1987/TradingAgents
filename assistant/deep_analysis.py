"""Wrap TradingAgentsGraph.propagate() and persist a structured analysis doc."""
from __future__ import annotations

import re

from assistant.store import utc_now_iso


def _default_graph_factory(config: dict):
    from tradingagents.graph.trading_graph import TradingAgentsGraph  # lazy heavy import

    return TradingAgentsGraph(debug=False, config=config)


def _sections_from_state(state: dict) -> dict:
    debate = state.get("investment_debate_state") or {}
    risk = state.get("risk_debate_state") or {}
    sections = {
        "market": state.get("market_report") or "",
        "sentiment": state.get("sentiment_report") or "",
        "news": state.get("news_report") or "",
        "fundamentals": state.get("fundamentals_report") or "",
        "bull": debate.get("bull_history") or "",
        "bear": debate.get("bear_history") or "",
        "researchManager": debate.get("judge_decision") or "",
        "traderPlan": state.get("trader_investment_plan") or "",
        "riskAggressive": risk.get("aggressive_history") or "",
        "riskConservative": risk.get("conservative_history") or "",
        "riskNeutral": risk.get("neutral_history") or "",
        "portfolioDecision": risk.get("judge_decision") or "",
        "finalDecision": state.get("final_trade_decision") or "",
    }
    
    valuation_data = _extract_valuation(state.get("fundamentals_report") or "")
    if valuation_data:
        sections["valuation"] = valuation_data
    
    return sections


def _extract_valuation(fundamentals_report: str) -> dict | None:
    """Extract DCF valuation data from fundamentals report.
    
    Returns dict with bear/base/bull values, implied_growth, and valuation_date,
    or None if no DCF data found.
    """
    if "DCF 估值报告" not in fundamentals_report and "DCF Valuation" not in fundamentals_report:
        return None
    
    valuation = {}
    
    bear_match = re.search(r"熊市.*?\$(\d+\.?\d*)", fundamentals_report, re.DOTALL)
    base_match = re.search(r"中性.*?\$(\d+\.?\d*)", fundamentals_report, re.DOTALL)
    bull_match = re.search(r"牛市.*?\$(\d+\.?\d*)", fundamentals_report, re.DOTALL)
    
    if bear_match:
        valuation["intrinsic_bear"] = float(bear_match.group(1))
    if base_match:
        valuation["intrinsic_base"] = float(base_match.group(1))
    if bull_match:
        valuation["intrinsic_bull"] = float(bull_match.group(1))
    
    implied_match = re.search(r"隐含的.*?年收入增速.*?约为.*?(\d+\.?\d*)%", fundamentals_report)
    if implied_match:
        valuation["implied_growth_pct"] = float(implied_match.group(1))
    
    date_match = re.search(r"估值基准日.*?(\d{4}-\d{2}-\d{2})", fundamentals_report)
    if date_match:
        valuation["valuation_date"] = date_match.group(1)
    
    return valuation if valuation else None


def run_deep_analysis(store, ticker: str, trade_date: str, config: dict,
                      *, graph_factory=None) -> tuple[str, str]:
    factory = graph_factory or _default_graph_factory
    graph = factory(config)
    final_state, decision = graph.propagate(ticker, trade_date)
    analysis_id = store.save_analysis({
        "ticker": ticker,
        "tradeDate": trade_date,
        "decision": decision,
        "sections": _sections_from_state(final_state),
        "createdAt": utc_now_iso(),
    })
    return analysis_id, decision
