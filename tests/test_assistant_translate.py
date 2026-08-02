from types import SimpleNamespace

import pytest

from assistant.store import MemoryStore
from assistant.translate import translate_sections


class FakeLLM:
    def __init__(self):
        self.prompts = []

    def invoke(self, prompt):
        self.prompts.append(prompt)
        return SimpleNamespace(content=f"译文#{len(self.prompts)}")


def make_analysis(store, sections=None, sections_zh=None):
    data = {
        "ticker": "MSFT", "tradeDate": "2026-08-01", "decision": "BUY",
        "sections": sections or {"finalDecision": "Buy it.", "market": "Uptrend."},
        "createdAt": "2026-08-01T00:00:00+00:00",
    }
    if sections_zh:
        data["sectionsZh"] = sections_zh
    return store.save_analysis(data)


def test_translates_requested_sections_and_merges():
    store, llm = MemoryStore(), FakeLLM()
    aid = make_analysis(store)
    result = translate_sections(store, llm, aid, ["finalDecision", "market"])
    assert result == {"finalDecision": "done", "market": "done"}
    saved = store.get_analysis(aid)["sectionsZh"]
    assert set(saved) == {"finalDecision", "market"}
    assert saved["finalDecision"].startswith("译文")
    assert "Buy it." in llm.prompts[0]


def test_existing_translation_skipped_idempotent():
    store, llm = MemoryStore(), FakeLLM()
    aid = make_analysis(store, sections_zh={"finalDecision": "已有译文"})
    result = translate_sections(store, llm, aid, ["finalDecision", "market"])
    assert result == {"finalDecision": "skipped", "market": "done"}
    saved = store.get_analysis(aid)["sectionsZh"]
    assert saved["finalDecision"] == "已有译文"   # 不覆盖
    assert len(llm.prompts) == 1                  # 只翻了缺的那段


def test_empty_or_unknown_section_marked_missing():
    store, llm = MemoryStore(), FakeLLM()
    aid = make_analysis(store, sections={"finalDecision": "", "market": "Up."})
    result = translate_sections(store, llm, aid, ["finalDecision", "nope"])
    assert result == {"finalDecision": "missing", "nope": "missing"}
    assert llm.prompts == []
    assert "sectionsZh" not in store.get_analysis(aid)


def test_unknown_analysis_raises():
    store, llm = MemoryStore(), FakeLLM()
    with pytest.raises(ValueError):
        translate_sections(store, llm, "nope", ["market"])
