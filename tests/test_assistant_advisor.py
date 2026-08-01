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
