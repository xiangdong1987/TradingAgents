"""投资大师理念加载器（text-based investing principles loader）。

设计：
- 原则存于 assistant/principles.yaml，便于维护与扩展；
- load_principles() 返回适合注入 prompt 的简明文本；
- 缺省只加载白圭，未来可扩展为多大师联合或可配置选择。
"""
from __future__ import annotations

import logging
from pathlib import Path

import yaml

logger = logging.getLogger(__name__)

_PRINCIPLES_FILE = Path(__file__).parent / "principles.yaml"


def load_principles(*, concise: bool = True) -> str:
    """加载投资原则文本，供 advisor/chat prompt 注入。

    Args:
        concise: True 时只返回原则要点（token 友好）；False 时包含完整说明。

    Returns:
        格式化的原则文本，缺失或解析失败时返回空字符串（不中断流程）。
    """
    if not _PRINCIPLES_FILE.exists():
        logger.warning("principles file not found: %s", _PRINCIPLES_FILE)
        return ""

    try:
        with open(_PRINCIPLES_FILE, encoding="utf-8") as f:
            data = yaml.safe_load(f)
    except Exception as exc:
        logger.error("failed to load principles: %s", exc, exc_info=True)
        return ""

    if not data or "masters" not in data or not data["masters"]:
        logger.warning("principles file has no masters")
        return ""

    lines = []
    for master in data["masters"]:
        name = master.get("name", "未知")
        principles = master.get("principles", [])
        guardrails = master.get("guardrails", "").strip()

        if concise:
            # 简明模式：只列原则 key + text，省略 application
            lines.append(f"# {name}")
            for p in principles:
                key = p.get("key", "")
                text = p.get("text", "").strip()
                if key and text:
                    # 单行化：去掉内部换行，保持简洁
                    text_oneline = " ".join(text.split())
                    lines.append(f"- {key}：{text_oneline}")
            if guardrails:
                lines.append(f"⚠️ 边界：{' '.join(guardrails.split())}")
        else:
            # 完整模式：包含 application 与 notes（调试或详细分析用）
            title = master.get("title", "")
            source = master.get("source", "")
            notes = master.get("notes", "").strip()
            lines.append(f"# {name}（{title}）" if title else f"# {name}")
            if source:
                lines.append(f"来源：{source}")
            if notes:
                lines.append(f"说明：{notes}")
            for p in principles:
                key = p.get("key", "")
                text = p.get("text", "").strip()
                application = p.get("application", "").strip()
                if key:
                    lines.append(f"\n## {key}")
                    if text:
                        lines.append(text)
                    if application:
                        lines.append(f"应用：{application}")
            if guardrails:
                lines.append(f"\n⚠️ 硬性边界\n{guardrails}")

    return "\n".join(lines)


def load_principles_for_prompt() -> str:
    """为 prompt 注入准备的简明原则文本（带前导说明）。"""
    principles = load_principles(concise=True)
    if not principles:
        return ""
    return f"""
投资理念参考（作为价值判断的检验框架，不覆盖数值纪律）:
{principles}
""".strip()
