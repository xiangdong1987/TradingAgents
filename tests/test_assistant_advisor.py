from types import SimpleNamespace
from assistant.advisor import generate_suggestion
from assistant.store import MemoryStore


class FakeLLM:
    def __init__(self, reply):
        self.reply, self.prompts = reply, []

    def invoke(self, prompt):
        self.prompts.append(prompt)
        return SimpleNamespace(content=self.reply)


def make_store(with_position=True):
    s = MemoryStore()
    if with_position:
        s.seed_positions([{"ticker": "NVDA", "shares": 10, "avgCost": 100.0, "updatedAt": "x"}])
    s.seed_meta({"cash": 1000.0, "currency": "USD"})
    return s


def quote_110(ticker, **kw):
    return {"ticker": ticker, "close": 110.0, "prevClose": 100.0, "pctChange": 10.0}


def test_json_reply_becomes_pending_suggestion():
    store = make_store()
    llm = FakeLLM('{"action": "trim", "targetWeightPct": 15, "rationale": "估值过高"}')
    sid = generate_suggestion(store, llm, "NVDA", "SELL", "analysis1", fetch_quote=quote_110)
    doc = store._suggestions[sid]
    assert doc["action"] == "trim" and doc["targetWeightPct"] == 15
    assert doc["status"] == "pending" and doc["analysisId"] == "analysis1"
    # prompt 里有当前仓位占比：10*110=1100 股票 + 1000 现金 → 52.4%
    assert "52.4" in llm.prompts[0]


def test_hold_with_no_position_returns_none():
    store = make_store(with_position=False)
    llm = FakeLLM("should not be called")
    assert generate_suggestion(store, llm, "NVDA", "HOLD", "a1", fetch_quote=quote_110) is None
    assert store._suggestions == {} and llm.prompts == []


def test_malformed_llm_reply_degrades_gracefully():
    store = make_store()
    llm = FakeLLM("我觉得应该减仓，但我不会说 JSON")
    sid = generate_suggestion(store, llm, "NVDA", "SELL", "a1", fetch_quote=quote_110)
    doc = store._suggestions[sid]
    assert doc["action"] == "sell"                  # 从 decision 降级映射
    assert doc["targetWeightPct"] is None
    assert "减仓" in doc["rationale"]                # 原始输出保留


def test_quote_fetch_failure_falls_back_to_cost_basis():
    store = make_store()

    def quote_unavailable(ticker, **kw):
        raise RuntimeError("quote service down")

    llm = FakeLLM('{"action": "hold", "targetWeightPct": null, "rationale": "使用成本价估值"}')
    sid = generate_suggestion(store, llm, "NVDA", "BUY", "a2", fetch_quote=quote_unavailable)
    doc = store._suggestions[sid]
    assert doc["status"] == "pending"
    assert sid is not None  # suggestion still generated despite quote failure
    # prompt should use cost basis: 10*100=1000 股票 + 1000 现金 → 50.0% 权重
    assert "50.0" in llm.prompts[0]
    assert "100" in llm.prompts[0]  # cost basis in the prompt
