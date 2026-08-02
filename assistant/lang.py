"""Bilingual LLM-output helpers.

Light content (brief / chat / advisor rationale) is generated in BOTH
languages in a single LLM call; the reply carries ``===ZH===`` /
``===EN===`` block markers which :func:`split_bilingual` separates. Missing
markers degrade gracefully: the whole text counts as Chinese (the app falls
back to whichever language exists, so nothing ever renders blank).
"""
from __future__ import annotations

import re

_MARKER = re.compile(r"^\s*=+\s*(ZH|EN)\s*=+\s*$", re.IGNORECASE | re.MULTILINE)

BILINGUAL_INSTRUCTION = (
    "请输出中英两个语言版本，格式严格如下（分隔行顶格、单独一行）：\n"
    "===ZH===\n<简体中文版本>\n===EN===\n<English version>"
)


def split_bilingual(text: str) -> tuple[str, str]:
    """Split LLM output into ``(zh, en)`` by ===ZH===/===EN=== markers.

    No markers → the whole text is Chinese (legacy behaviour), en empty.
    """
    if not text:
        return "", ""
    parts: dict[str, list[str]] = {}
    current: str | None = None
    matches = list(_MARKER.finditer(text))
    if not matches:
        return text.strip(), ""
    # 标记之前的引言丢弃（LLM 偶尔加一句"好的"之类）
    for i, m in enumerate(matches):
        lang = m.group(1).upper()
        start = m.end()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        parts.setdefault(lang, []).append(text[start:end].strip())
    zh = "\n\n".join(parts.get("ZH", [])).strip()
    en = "\n\n".join(parts.get("EN", [])).strip()
    if not zh and not en:
        return text.strip(), ""
    return zh, en
