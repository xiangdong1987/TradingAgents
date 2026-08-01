"""Chat answering tests (network-free)."""
from types import SimpleNamespace

from assistant.chat import answer_chat, build_context
from assistant.store import MemoryStore


class FakeLLM:
    def __init__(self, reply="回答内容"):
        self.reply, self.prompts = reply, []

    def invoke(self, prompt):
        self.prompts.append(prompt)
        return SimpleNamespace(content=self.reply)


def seeded_store():
    s = MemoryStore()
    s.seed_positions([{"ticker": "KO", "shares": 10, "avgCost": 60.0, "updatedAt": "x"}])
    s.seed_meta({"cash": 5000.0, "currency": "EUR"})
    s.seed_watchlist([{"ticker": "ISP.MI", "deepFreq": "manual", "note": "", "addedAt": "x"}])
    s.save_brief("2026-08-01", {"date": "2026-08-01", "quotes": {
        "KO": {"close": 66.0, "pctChange": 1.0},
        "EURUSD=X": {"close": 1.15, "pctChange": 0.0},
    }})
    s.save_analysis({"ticker": "ISP.MI", "tradeDate": "2026-08-01", "decision": "Overweight",
                     "sections": {}, "createdAt": "2026-08-01T20:00:00+00:00"})
    return s


def test_build_context_includes_positions_quotes_and_analyses():
    ctx = build_context(seeded_store(), "2026-08-01")
    assert "KO: 10 股 @ 成本 60.0" in ctx and "+10.00%" in ctx
    assert "ISP.MI" in ctx and "Overweight" in ctx
    assert "EURUSD" in ctx and "5000.0 EUR" in ctx


def test_answer_chat_writes_answer_and_status():
    s = seeded_store()
    cid = s.add_chat({"question": "KO 和 ISP.MI 买哪个？", "status": "pending",
                      "createdAt": "2026-08-01T00:00:00+00:00"})
    llm = FakeLLM("先看结论……")
    answer_chat(s, llm, cid, "2026-08-01")
    chat = s.get_chat(cid)
    assert chat["status"] == "answered" and chat["answer"] == "先看结论……"
    assert "KO 和 ISP.MI 买哪个？" in llm.prompts[0]
    assert "现价 66.0" in llm.prompts[0]          # 上下文进入 prompt


def test_answer_chat_failure_marks_failed():
    s = seeded_store()
    cid = s.add_chat({"question": "q", "status": "pending", "createdAt": "x"})

    class Boom:
        def invoke(self, p):
            raise RuntimeError("llm down")

    import pytest
    with pytest.raises(RuntimeError):
        answer_chat(s, Boom(), cid, "2026-08-01")
    assert s.get_chat(cid)["status"] == "failed"
