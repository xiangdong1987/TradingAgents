from types import SimpleNamespace

from assistant.backfill import backfill_english_sections, is_chinese
from assistant.store import MemoryStore

ZH = ("好的，朋友们，作为今天的看多分析师，我非常兴奋。数据已经摆在这里了，"
      "让我们抛开焦虑的标题党，直击核心：这是一家处于黄金时代的公司。")
EN = "The bull case rests on accelerating cloud growth and margin expansion."


class FakeLLM:
    def __init__(self):
        self.prompts = []

    def invoke(self, prompt):
        self.prompts.append(prompt)
        return SimpleNamespace(content=f"EN#{len(self.prompts)}")


def _mk(store, sections, sections_zh=None):
    data = {"ticker": "MSFT", "tradeDate": "2026-07-31", "decision": "BUY",
            "sections": sections, "createdAt": "2026-07-31T00:00:00+00:00"}
    if sections_zh:
        data["sectionsZh"] = sections_zh
    return store.save_analysis(data)


def test_is_chinese_heuristic():
    assert is_chinese(ZH)
    assert not is_chinese(EN)
    assert not is_chinese("")


def test_legacy_chinese_doc_swapped_to_bilingual():
    store, llm = MemoryStore(), FakeLLM()
    aid = _mk(store, {"bull": ZH, "market": ZH, "news": ""})
    result = backfill_english_sections(store, llm)
    assert result == {"analyses": 1, "sections": 2}
    doc = store.get_analysis(aid)
    assert doc["sections"]["bull"].startswith("EN#")     # 英文回填为准
    assert doc["sections"]["news"] == ""                 # 空段不动
    assert doc["sectionsZh"]["bull"] == ZH               # 原中文归位为译文
    assert doc["sectionsZh"]["market"] == ZH
    assert ZH in llm.prompts[0]


def test_english_doc_untouched_and_idempotent():
    store, llm = MemoryStore(), FakeLLM()
    aid = _mk(store, {"bull": EN})
    assert backfill_english_sections(store, llm) == {"analyses": 0, "sections": 0}
    assert llm.prompts == []
    # 混合文档只翻中文段；再跑一遍无事发生（幂等）
    aid2 = _mk(store, {"bull": EN, "bear": ZH})
    backfill_english_sections(store, llm)
    doc = store.get_analysis(aid2)
    assert doc["sections"]["bull"] == EN
    assert doc["sections"]["bear"].startswith("EN#")
    assert backfill_english_sections(store, llm) == {"analyses": 0, "sections": 0}
    assert store.get_analysis(aid)["sections"]["bull"] == EN


def test_existing_sections_zh_not_overwritten():
    store, llm = MemoryStore(), FakeLLM()
    aid = _mk(store, {"bull": ZH}, sections_zh={"bull": "人工精修译文"})
    backfill_english_sections(store, llm)
    assert store.get_analysis(aid)["sectionsZh"]["bull"] == "人工精修译文"


def test_dry_run_counts_without_llm_or_writes():
    store, llm = MemoryStore(), FakeLLM()
    aid = _mk(store, {"bull": ZH})
    result = backfill_english_sections(store, llm, dry_run=True)
    assert result == {"analyses": 1, "sections": 1}
    assert llm.prompts == []
    assert store.get_analysis(aid)["sections"]["bull"] == ZH
