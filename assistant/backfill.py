"""One-off backfill: normalise legacy Chinese analyses to the bilingual schema.

Historically the engine wrote Chinese sections (``TRADINGAGENTS_OUTPUT_LANGUAGE``
was Chinese). The bilingual schema wants ``sections`` = English canonical and
``sectionsZh`` = Chinese. For every legacy doc this moves the Chinese original
into ``sectionsZh`` and fills ``sections`` with a zh→en translation.

Idempotent: sections already in English (CJK heuristic) are skipped, so a
re-run after the first pass is a no-op. Run while the runner keeps going —
this only touches ``analyses`` docs, which the runner never mutates.

Usage: ``python -m assistant.backfill [--dry-run]``
"""
from __future__ import annotations

import logging
import re

logger = logging.getLogger(__name__)

_CJK = re.compile(r"[一-鿿]")

_EN_PROMPT = """Translate this investment research report section from Chinese to English.
Requirements:
- Preserve the Markdown structure exactly (headings, tables, bold markers);
- Keep structured labels intact and in English (e.g. **Rating**:, **Recommendation**:,
  Action, Entry Price, Stop Loss, Score: x/10, indicator table columns);
- Keep tickers, numbers and dates unchanged;
- Use standard finance terminology (增持=Overweight, 减持=Underweight, 止损=stop loss);
- Output ONLY the translation, no commentary.

{text}
"""


def is_chinese(text: str, *, sample: int = 400, threshold: int = 20) -> bool:
    """True when the leading sample contains a substantial amount of CJK."""
    if not text:
        return False
    return len(_CJK.findall(text[:sample])) >= threshold


def backfill_english_sections(store, llm, *, dry_run: bool = False) -> dict:
    """Returns {'analyses': touched_docs, 'sections': translated_sections}."""
    touched = translated = 0
    for doc in store.all_analyses():
        sections = doc.get("sections") or {}
        zh_keys = {k: v for k, v in sections.items() if is_chinese(v or "")}
        if not zh_keys:
            continue
        touched += 1
        if dry_run:
            translated += len(zh_keys)
            logger.info("[dry-run] %s %s: %d chinese section(s): %s",
                        doc.get("ticker"), doc.get("tradeDate"), len(zh_keys),
                        ", ".join(sorted(zh_keys)))
            continue
        existing_zh = doc.get("sectionsZh") or {}
        new_en, new_zh = {}, {}
        for key, zh_text in sorted(zh_keys.items()):
            new_en[key] = llm.invoke(_EN_PROMPT.format(text=zh_text)).content
            if not (existing_zh.get(key) or "").strip():
                new_zh[key] = zh_text  # 原中文归位为译文，不覆盖已有
            translated += 1
            logger.info("%s %s: translated %s (%d chars)", doc.get("ticker"),
                        doc.get("tradeDate"), key, len(zh_text))
        fields: dict = {"sections": new_en}
        if new_zh:
            fields["sectionsZh"] = new_zh
        store.merge_analysis_fields(doc["id"], fields)
    return {"analyses": touched, "sections": translated}


def main(argv: list[str] | None = None) -> int:
    import argparse

    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true",
                        help="只统计要翻译哪些段，不调 LLM 不写库")
    args = parser.parse_args(argv)

    from assistant.store import FirestoreStore
    from tradingagents.default_config import DEFAULT_CONFIG
    from tradingagents.llm_clients.factory import create_llm_client

    store = FirestoreStore.connect()
    llm = None
    if not args.dry_run:
        llm = create_llm_client(
            DEFAULT_CONFIG["llm_provider"], DEFAULT_CONFIG["quick_think_llm"],
            DEFAULT_CONFIG.get("backend_url"),
        ).get_llm()
    result = backfill_english_sections(store, llm, dry_run=args.dry_run)
    logger.info("backfill complete: %(analyses)d analyses, %(sections)d sections", result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
