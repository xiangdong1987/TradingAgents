"""Wrap TradingAgentsGraph.propagate() and persist a structured analysis doc."""
from __future__ import annotations

from assistant.store import utc_now_iso


def _default_graph_factory(config: dict):
    from tradingagents.graph.trading_graph import TradingAgentsGraph  # lazy heavy import

    return TradingAgentsGraph(debug=False, config=config)


def _sections_from_state(state: dict) -> dict:
    debate = state.get("investment_debate_state") or {}
    risk = state.get("risk_debate_state") or {}
    return {
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
