from types import SimpleNamespace
from assistant.daily_brief import generate_daily_brief
from assistant.store import MemoryStore
from assistant.quotes import QuoteUnavailable


class FakeLLM:
    def __init__(self):
        self.prompts = []

    def invoke(self, prompt):
        self.prompts.append(prompt)
        return SimpleNamespace(content="# 日报\n一切正常")


def make_store():
    s = MemoryStore()
    s.seed_watchlist([{"ticker": "NVDA", "deepFreq": "weekly", "note": "", "addedAt": "x"}])
    s.seed_positions([{"ticker": "AAPL", "shares": 10, "avgCost": 100.0, "updatedAt": "x"}])
    s.seed_meta({"cash": 5000.0, "currency": "USD"})
    return s


def ok_quote(ticker, **kw):
    return {"ticker": ticker, "close": 110.0, "prevClose": 100.0, "pctChange": 10.0}


def test_brief_covers_watchlist_and_positions_and_saves():
    store, llm = make_store(), FakeLLM()
    md = generate_daily_brief(store, llm, "2026-08-01",
                              fetch_quote=ok_quote, fetch_news=lambda t, s, e: f"{t} news")
    assert md == "# 日报\n一切正常"
    saved = store.get_brief("2026-08-01")
    assert saved["markdownZh"] == md and saved["date"] == "2026-08-01"
    assert sorted(saved["tickers"]) == ["AAPL", "NVDA"]      # watchlist ∪ positions 去重
    prompt = llm.prompts[0]
    assert "NVDA" in prompt and "AAPL" in prompt
    assert "10.0" in prompt                                   # 涨跌幅进 prompt
    assert "5000" in prompt                                   # 现金进 prompt
    assert "+10.00%" in prompt or "10.0%" in prompt or "浮动盈亏" in prompt  # AAPL 持仓盈亏(110 vs 100)


def test_brief_survives_single_ticker_failures():
    def flaky_quote(ticker, **kw):
        if ticker == "NVDA":
            raise QuoteUnavailable("nope")
        return ok_quote(ticker)

    store, llm = make_store(), FakeLLM()
    md = generate_daily_brief(store, llm, "2026-08-01",
                              fetch_quote=flaky_quote,
                              fetch_news=lambda t, s, e: (_ for _ in ()).throw(RuntimeError("net down")))
    assert md                                                 # 仍产出
    assert "行情获取失败" in llm.prompts[0]                    # 失败股在 prompt 里标注而非丢弃
    assert "新闻获取失败" in llm.prompts[0]


def test_brief_handles_zero_cost_basis():
    s = MemoryStore()
    s.seed_watchlist([])
    s.seed_positions([{"ticker": "GOOG", "shares": 5, "avgCost": 0.0, "updatedAt": "x"}])  # gifted/spinoff stock
    s.seed_meta({"cash": 2000.0, "currency": "USD"})
    store, llm = s, FakeLLM()
    md = generate_daily_brief(store, llm, "2026-08-01",
                              fetch_quote=ok_quote, fetch_news=lambda t, s, e: f"{t} news")
    assert md                                                 # still generates
    assert "无成本价" in llm.prompts[0]                        # degraded label in prompt
    assert "GOOG" in llm.prompts[0]                           # ticker still included
