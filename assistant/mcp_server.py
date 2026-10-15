"""MCP server exposing the wealth assistant's Firestore data to external AI clients.

Run (stdio, for Claude Desktop & co.):  python -m assistant.mcp_server
Run (streamable HTTP, local only):      python -m assistant.mcp_server --http [--port 8765]

Everything is read-only except ``request_deep_analysis``, which enqueues one
``deep_analysis`` job (status=queued, requestedBy="mcp") for the runner to pick up.
Storage access goes through ``assistant.store.FirestoreStore`` and quotes through
``assistant.quotes`` — no Firestore logic is duplicated here.
"""
from __future__ import annotations

import argparse
import json
import re
from datetime import datetime
from zoneinfo import ZoneInfo

from mcp.server.fastmcp import FastMCP

from assistant import quotes
from assistant.store import utc_now_iso

_TICKER_RE = re.compile(r"^[A-Za-z0-9.^=\-]{1,20}$")
_DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
# 深度分析各章节正文很长；默认只回结论类章节，include_sections=True 才给全文
_SUMMARY_SECTIONS = ("portfolioDecision", "finalDecision", "traderPlan")


def _plain(obj):
    """Firestore 文档里可能带 datetime 等类型，统一转成可 JSON 序列化的结构。"""
    return json.loads(json.dumps(obj, default=str, ensure_ascii=False))


def _ticker(raw: str) -> str:
    t = (raw or "").strip().upper()
    if not _TICKER_RE.match(t):
        raise ValueError(f"invalid ticker: {raw!r}")
    return t


def _analysis_view(a: dict, include_sections: bool) -> dict:
    out = {k: v for k, v in a.items() if k not in ("sections", "sectionsZh")}
    sections = a.get("sections") or {}
    out["sections"] = sections if include_sections else {
        k: sections[k] for k in _SUMMARY_SECTIONS if k in sections}
    return out


def build_server(store_factory=None, quote_fn=None, **settings) -> FastMCP:
    """Build the FastMCP app. ``store_factory``/``quote_fn`` are injectable for tests."""
    if store_factory is None:
        def store_factory():
            from assistant.store import FirestoreStore
            return FirestoreStore.connect()
    quote_fn = quote_fn or quotes.get_quote

    holder: dict = {}

    def store():
        # 延迟连接：启动 / 列工具时不需要凭据
        if "s" not in holder:
            holder["s"] = store_factory()
        return holder["s"]

    mcp = FastMCP(
        "wealth-assistant",
        instructions=("Read-only access to the user's wealth assistant (watchlist, positions, "
                      "daily briefs, deep analyses, suggestion reviews, live quotes). "
                      "The only write is request_deep_analysis, which queues a job."),
        **settings,
    )

    @mcp.tool()
    def list_watchlist() -> list[dict]:
        """List the watchlist (ticker, note, deepFreq, addedAt)."""
        return _plain(store().get_watchlist())

    @mcp.tool()
    def list_positions() -> dict:
        """List current holdings (Firestore `positions`: ticker, shares, avgCost, ...)
        plus the cash/currency from `meta/portfolio`."""
        s = store()
        return _plain({"positions": s.get_positions(), "portfolio": s.get_portfolio_meta()})

    @mcp.tool()
    def get_latest_brief() -> dict:
        """Get the most recent daily brief. Returns {date, brief} or {} if none exist."""
        latest = store().latest_brief()
        if latest is None:
            return {}
        date_str, brief = latest
        return _plain({"date": date_str, "brief": brief})

    @mcp.tool()
    def get_brief(date: str) -> dict:
        """Get the daily brief for a date (YYYY-MM-DD). Returns {} if there is none."""
        if not _DATE_RE.match(date or ""):
            raise ValueError("date must be YYYY-MM-DD")
        brief = store().get_brief(date)
        return _plain({"date": date, "brief": brief}) if brief else {}

    @mcp.tool()
    def get_ticker_analysis(ticker: str, limit: int = 3, include_sections: bool = False) -> dict:
        """Latest deep analyses (newest first) and all suggestions for a ticker.

        Analyses carry only the conclusion sections unless include_sections=True
        (full multi-analyst reports, long)."""
        t = _ticker(ticker)
        s = store()
        limit = max(1, min(int(limit), 10))
        analyses = [_analysis_view(a, include_sections) for a in s.analyses_for_ticker(t, limit)]
        suggestions = sorted(s.suggestions_for_ticker(t),
                             key=lambda x: x.get("createdAt", ""), reverse=True)
        return _plain({"ticker": t, "analyses": analyses, "suggestions": suggestions})

    @mcp.tool()
    def list_suggestion_reviews(limit: int = 20) -> list[dict]:
        """Suggestions that have been reviewed after the holding window
        (outcomePct = realised return since the suggestion), newest review first."""
        return _plain(store().reviewed_suggestions(max(1, min(int(limit), 100))))

    @mcp.tool()
    def get_quote(ticker: str) -> dict:
        """Live quote: {ticker, close, prevClose, pctChange}. Supports ISIN bonds/funds."""
        t = _ticker(ticker)
        try:
            return _plain(quote_fn(t))
        except Exception as exc:  # QuoteUnavailable / 网络错误：给调用方可读的结果而非崩溃
            return {"ticker": t, "error": str(exc)}

    @mcp.tool()
    def request_deep_analysis(ticker: str) -> dict:
        """Queue a deep_analysis job for a ticker (WRITE). The runner executes it
        later; poll get_ticker_analysis for the result. Returns the job id."""
        t = _ticker(ticker)
        today = datetime.now(ZoneInfo("America/New_York")).strftime("%Y-%m-%d")
        job_id = store().add_job({
            "type": "deep_analysis",
            "ticker": t,
            "date": today,
            "status": "queued",
            "requestedBy": "mcp",
            "createdAt": utc_now_iso(),
        })
        return {"jobId": job_id, "ticker": t, "status": "queued"}

    return mcp


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(prog="python -m assistant.mcp_server",
                                 description="Wealth assistant MCP server")
    ap.add_argument("--http", action="store_true",
                    help="serve streamable HTTP instead of stdio")
    ap.add_argument("--host", default="127.0.0.1", help="HTTP bind host (default: loopback only)")
    ap.add_argument("--port", type=int, default=8765, help="HTTP port (default: 8765)")
    args = ap.parse_args(argv)
    if args.http:
        build_server(host=args.host, port=args.port).run(transport="streamable-http")
    else:
        build_server().run(transport="stdio")


if __name__ == "__main__":
    main()
