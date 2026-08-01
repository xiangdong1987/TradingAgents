from assistant.deep_analysis import run_deep_analysis
from assistant.store import MemoryStore

FINAL_STATE = {
    "market_report": "m", "sentiment_report": "s", "news_report": "n",
    "fundamentals_report": "f",
    "investment_debate_state": {"bull_history": "bull", "bear_history": "bear",
                                "judge_decision": "judge"},
    "trader_investment_plan": "plan",
    "risk_debate_state": {"aggressive_history": "agg", "conservative_history": "con",
                          "neutral_history": "neu", "judge_decision": "pm"},
    "final_trade_decision": "final",
}


class FakeGraph:
    def __init__(self):
        self.calls = []

    def propagate(self, ticker, date):
        self.calls.append((ticker, date))
        return FINAL_STATE, "BUY"


def test_run_deep_analysis_maps_state_to_sections():
    store, graph = MemoryStore(), FakeGraph()
    aid, decision = run_deep_analysis(store, "NVDA", "2026-08-01", {"any": "cfg"},
                                      graph_factory=lambda cfg: graph)
    assert decision == "BUY" and graph.calls == [("NVDA", "2026-08-01")]
    doc = store._analyses[aid]
    assert doc["ticker"] == "NVDA" and doc["tradeDate"] == "2026-08-01"
    sec = doc["sections"]
    assert sec["market"] == "m" and sec["bull"] == "bull" and sec["portfolioDecision"] == "pm"
    assert sec["finalDecision"] == "final" and doc["decision"] == "BUY"


def test_missing_state_keys_become_empty_strings():
    store = MemoryStore()

    class Sparse:
        def propagate(self, t, d):
            return {"market_report": "only"}, "HOLD"

    aid, _ = run_deep_analysis(store, "AAPL", "2026-08-01", {}, graph_factory=lambda c: Sparse())
    sec = store._analyses[aid]["sections"]
    assert sec["market"] == "only" and sec["bear"] == "" and sec["riskNeutral"] == ""
