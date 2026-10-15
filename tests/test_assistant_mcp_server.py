"""MCP server tools, exercised in-process over FastMCP.call_tool with a MemoryStore."""
import asyncio
import json

import pytest

from assistant.mcp_server import build_server
from assistant.store import MemoryStore


def _call(server, name, args=None):
    res = asyncio.run(server.call_tool(name, args or {}))
    if isinstance(res, tuple):  # list returns: (content, {"result": [...]})
        return res[1]["result"]
    return json.loads(res[0].text)  # dict returns: JSON text content


@pytest.fixture
def env():
    store = MemoryStore()
    store.seed_watchlist([{"ticker": "NVDA", "note": "", "deepFreq": "weekly"}])
    store.seed_positions([{"ticker": "NVDA", "shares": 10, "avgCost": 100.0}])
    store.seed_meta({"cash": 500.0, "currency": "USD"})
    store.save_brief("2026-08-01", {"date": "2026-08-01", "markdownZh": "old"})
    store.save_brief("2026-08-02", {"date": "2026-08-02", "markdownZh": "new"})
    for d in ("2026-07-01", "2026-07-08"):
        store.save_analysis({"ticker": "NVDA", "tradeDate": d, "decision": "HOLD",
                             "createdAt": d + "T21:00:00+00:00",
                             "sections": {"finalDecision": "f" + d, "marketReport": "long"}})
    store.save_suggestion({"ticker": "NVDA", "action": "BUY", "status": "accepted",
                           "createdAt": "2026-07-01T00:00:00+00:00",
                           "outcomePct": 3.2, "reviewedAt": "2026-07-20T00:00:00+00:00"})
    store.save_suggestion({"ticker": "NVDA", "action": "SELL", "status": "pending",
                           "createdAt": "2026-07-02T00:00:00+00:00"})
    quote = lambda t: {"ticker": t, "close": 2.0, "prevClose": 1.0, "pctChange": 100.0}  # noqa: E731
    return store, build_server(store_factory=lambda: store, quote_fn=quote)


def test_tool_list(env):
    _, server = env
    names = {t.name for t in asyncio.run(server.list_tools())}
    assert names == {"list_watchlist", "list_positions", "get_latest_brief", "get_brief",
                     "get_ticker_analysis", "list_suggestion_reviews", "get_quote",
                     "request_deep_analysis"}


def test_watchlist_and_positions(env):
    _, server = env
    assert _call(server, "list_watchlist")[0]["ticker"] == "NVDA"
    pos = _call(server, "list_positions")
    assert pos["positions"][0]["shares"] == 10
    assert pos["portfolio"]["cash"] == 500.0


def test_briefs(env):
    _, server = env
    assert _call(server, "get_latest_brief")["date"] == "2026-08-02"
    assert _call(server, "get_brief", {"date": "2026-08-01"})["brief"]["markdownZh"] == "old"
    assert _call(server, "get_brief", {"date": "2026-01-01"}) == {}
    with pytest.raises(Exception):
        _call(server, "get_brief", {"date": "bad"})


def test_ticker_analysis_trims_sections_and_orders(env):
    _, server = env
    r = _call(server, "get_ticker_analysis", {"ticker": "nvda", "limit": 1})
    assert r["ticker"] == "NVDA"
    assert [a["tradeDate"] for a in r["analyses"]] == ["2026-07-08"]
    assert r["analyses"][0]["sections"] == {"finalDecision": "f2026-07-08"}
    assert len(r["suggestions"]) == 2
    full = _call(server, "get_ticker_analysis", {"ticker": "NVDA", "include_sections": True})
    assert "marketReport" in full["analyses"][0]["sections"]


def test_reviews_only_reviewed(env):
    _, server = env
    r = _call(server, "list_suggestion_reviews")
    assert [x["outcomePct"] for x in r] == [3.2]


def test_quote_ok_and_error():
    ok = build_server(store_factory=MemoryStore,
                      quote_fn=lambda t: {"ticker": t, "close": 1.0})
    assert _call(ok, "get_quote", {"ticker": "aapl"})["ticker"] == "AAPL"

    def boom(t):
        raise RuntimeError("no data")
    bad = build_server(store_factory=MemoryStore, quote_fn=boom)
    assert "no data" in _call(bad, "get_quote", {"ticker": "AAPL"})["error"]


def test_request_deep_analysis_queues_job(env):
    store, server = env
    r = _call(server, "request_deep_analysis", {"ticker": "tsla"})
    job = store.get_job(r["jobId"])
    assert job["type"] == "deep_analysis" and job["ticker"] == "TSLA"
    assert job["status"] == "queued" and job["requestedBy"] == "mcp"
    with pytest.raises(Exception):
        _call(server, "request_deep_analysis", {"ticker": "../x"})


def test_store_is_lazy():
    def explode():
        raise AssertionError("must not connect at build/list time")
    server = build_server(store_factory=explode)
    asyncio.run(server.list_tools())
