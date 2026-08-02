"""Answer user questions with full portfolio context (one quick-LLM call).

The app writes a ``chats/{id}`` doc + a ``chat`` job; the runner calls
``answer_chat`` which builds a context snapshot (positions, cash, quotes,
recent deep-analysis conclusions) and writes the answer back.
"""
from __future__ import annotations

import logging
from datetime import datetime, timedelta

from assistant.lang import BILINGUAL_INSTRUCTION, split_bilingual
from assistant.store import utc_now_iso

logger = logging.getLogger(__name__)

_PROMPT = """你是用户的私人投资研究助手。基于下面的真实组合快照回答用户的问题：
- 简洁直接，先给结论再给理由；
- 必须结合当前持仓（集中度、现金水位、已有仓位）评估可行性；
- 若信息不足请明说缺什么；
- 结尾用一句话提醒：以上是研究参考，交易请自行决策（英文版用对应英文表述）。
{bilingual}

# 组合快照
{context}

# 用户问题
{question}
"""


def build_context(store, today: str) -> str:
    lines = []
    meta = store.get_portfolio_meta()
    lines.append(f"现金: {meta.get('cash', 0.0)} {meta.get('currency', 'USD')}")

    brief = None
    day = datetime.strptime(today, "%Y-%m-%d")
    for back in range(4):
        brief = store.get_brief((day - timedelta(days=back)).strftime("%Y-%m-%d"))
        if brief:
            break
    quotes = (brief or {}).get("quotes", {})

    lines.append("持仓:")
    positions = store.get_positions()
    if not positions:
        lines.append("  （无持仓）")
    for p in positions:
        q = quotes.get(p["ticker"])
        if q and p.get("avgCost"):
            pnl = round((q["close"] - p["avgCost"]) / p["avgCost"] * 100, 2)
            lines.append(f"  {p['ticker']}: {p['shares']} 股 @ 成本 {p['avgCost']}，"
                         f"现价 {q['close']}，盈亏 {pnl:+.2f}%")
        else:
            lines.append(f"  {p['ticker']}: {p['shares']} 股 @ 成本 {p.get('avgCost')}（无现价，按成本计）")

    watch = [w["ticker"] for w in store.get_watchlist()]
    if watch:
        lines.append(f"自选: {', '.join(sorted(watch))}")
    if "EURUSD=X" in quotes:
        lines.append(f"汇率 EURUSD: {quotes['EURUSD=X']['close']}")

    recents = store.recent_analyses(limit=6)
    if recents:
        lines.append("最近引擎深度分析结论:")
        for a in recents:
            lines.append(f"  {a.get('ticker')} ({a.get('tradeDate')}): {str(a.get('decision'))[:120]}")
    return "\n".join(lines)


def answer_chat(store, llm, chat_id: str, today: str) -> None:
    chat = store.get_chat(chat_id)
    if chat is None:
        raise ValueError(f"chat {chat_id} not found")
    try:
        context = build_context(store, today)
        reply = llm.invoke(_PROMPT.format(context=context,
                                          bilingual=BILINGUAL_INSTRUCTION,
                                          question=chat["question"])).content
        zh, en = split_bilingual(reply)
        store.update_chat(chat_id, {"answer": zh, "answerEn": en,
                                    "status": "answered",
                                    "answeredAt": utc_now_iso()})
    except Exception as exc:
        store.update_chat(chat_id, {"status": "failed", "error": str(exc),
                                    "answeredAt": utc_now_iso()})
        raise
