"""On-demand translation of deep-analysis sections (engine writes English).

The app enqueues a ``translate`` job ``{analysisId, sections: [keys]}`` when
the user is in Chinese mode and a section has no translation yet. Each key is
translated with the quick LLM and merged into ``analyses/{id}.sectionsZh``
incrementally; keys already translated are skipped so re-runs are idempotent.
"""
from __future__ import annotations

import logging

logger = logging.getLogger(__name__)

_PROMPT = """把下面这段投资研究报告翻译成简体中文。要求：
- 保留原有 Markdown 结构（标题、表格、加粗标记等）；
- 术语准确（Overweight=增持、Underweight=减持、stop loss=止损 等）；
- 股票代码、数字、日期原样保留；
- 只输出译文，不要任何解释。

{text}
"""


def translate_sections(store, llm, analysis_id: str, sections: list[str]) -> dict:
    """Translate the requested section keys; returns {key: 'done'|'skipped'|'missing'}."""
    analysis = store.get_analysis(analysis_id)
    if analysis is None:
        raise ValueError(f"analysis {analysis_id} not found")
    originals = analysis.get("sections") or {}
    existing = analysis.get("sectionsZh") or {}

    result: dict[str, str] = {}
    translated: dict[str, str] = {}
    for key in sections:
        text = (originals.get(key) or "").strip()
        if not text:
            result[key] = "missing"
            continue
        if (existing.get(key) or "").strip():
            result[key] = "skipped"  # 已有译文，幂等跳过
            continue
        translated[key] = llm.invoke(_PROMPT.format(text=text)).content
        result[key] = "done"
    if translated:
        store.merge_analysis_sections_zh(analysis_id, translated)
        logger.info("translated %d section(s) of analysis %s: %s",
                    len(translated), analysis_id, ", ".join(sorted(translated)))
    return result
