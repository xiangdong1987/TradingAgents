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
                              fetch_quote=ok_quote, fetch_news=lambda t, s, e: f"{t} news",
                              fetch_money_flow=lambda t, d: None,
                              fetch_positioning=lambda t: None, fetch_futures=lambda: [])
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
                              fetch_news=lambda t, s, e: (_ for _ in ()).throw(RuntimeError("net down")),
                              fetch_money_flow=lambda t, d: None,
                              fetch_positioning=lambda t: None, fetch_futures=lambda: [])
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
                              fetch_quote=ok_quote, fetch_news=lambda t, s, e: f"{t} news",
                              fetch_money_flow=lambda t, d: None,
                              fetch_positioning=lambda t: None, fetch_futures=lambda: [])
    assert md                                                 # still generates
    assert "无成本价" in llm.prompts[0]                        # degraded label in prompt
    assert "GOOG" in llm.prompts[0]                           # ticker still included


def test_brief_stores_structured_quotes():
    store, llm = make_store(), FakeLLM()
    generate_daily_brief(store, llm, "2026-08-01",
                         fetch_quote=ok_quote, fetch_news=lambda t, s, e: "n",
                         fetch_money_flow=lambda t, d: None,
                         fetch_positioning=lambda t: None, fetch_futures=lambda: [])
    saved = store.get_brief("2026-08-01")
    assert saved["quotes"]["NVDA"] == {"close": 110.0, "pctChange": 10.0}
    assert saved["quotes"]["AAPL"] == {"close": 110.0, "pctChange": 10.0}


def test_failed_quote_ticker_absent_from_quotes_map():
    def flaky_quote(ticker, **kw):
        if ticker == "NVDA":
            raise QuoteUnavailable("nope")
        return ok_quote(ticker)

    store, llm = make_store(), FakeLLM()
    generate_daily_brief(store, llm, "2026-08-01",
                         fetch_quote=flaky_quote, fetch_news=lambda t, s, e: "n",
                         fetch_money_flow=lambda t, d: None,
                         fetch_positioning=lambda t: None, fetch_futures=lambda: [])
    saved = store.get_brief("2026-08-01")
    assert "NVDA" not in saved["quotes"]
    assert saved["quotes"]["AAPL"]["close"] == 110.0


def test_top_up_quotes_fills_only_missing_tickers():
    from assistant.daily_brief import top_up_quotes

    store = make_store()  # watchlist NVDA + position AAPL
    store.save_brief("2026-08-01", {
        "date": "2026-08-01", "markdownZh": "x", "tickers": ["NVDA"],
        "createdAt": "2026-08-01T10:00:00+00:00",
        "quotes": {"NVDA": {"close": 100.0, "pctChange": 1.0}},
    })
    added = top_up_quotes(store, "2026-08-01", fetch_quote=ok_quote)
    assert added == 2                                   # 补 AAPL + EURUSD 汇率
    quotes = store.get_brief("2026-08-01")["quotes"]
    assert quotes["NVDA"] == {"close": 100.0, "pctChange": 1.0}   # 原值保留
    assert quotes["AAPL"] == {"close": 110.0, "pctChange": 10.0}
    assert "EURUSD=X" in quotes


def test_top_up_quotes_looks_back_to_latest_brief_and_survives_failures():
    from assistant.daily_brief import top_up_quotes
    from assistant.quotes import QuoteUnavailable

    store = make_store()
    store.save_brief("2026-07-31", {                    # 周五的日报，周日补
        "date": "2026-07-31", "markdownZh": "x", "tickers": [],
        "createdAt": "2026-07-31T10:00:00+00:00", "quotes": {},
    })

    def flaky(ticker, **kw):
        if ticker == "NVDA":
            raise QuoteUnavailable("nope")
        return ok_quote(ticker)

    added = top_up_quotes(store, "2026-08-02", fetch_quote=flaky)
    assert added == 2                                   # AAPL+汇率成功，NVDA 失败跳过
    quotes = store.get_brief("2026-07-31")["quotes"]
    assert "AAPL" in quotes and "EURUSD=X" in quotes and "NVDA" not in quotes


def test_top_up_quotes_no_brief_or_no_tickers_is_noop():
    from assistant.daily_brief import top_up_quotes
    from assistant.store import MemoryStore

    assert top_up_quotes(make_store(), "2026-08-01", fetch_quote=ok_quote) == 0  # 无日报
    empty = MemoryStore()
    empty.save_brief("2026-08-01", {"date": "2026-08-01", "quotes": {}})
    assert top_up_quotes(empty, "2026-08-01", fetch_quote=ok_quote) == 0         # 无股票


def test_brief_always_includes_eurusd_rate():
    store, llm = make_store(), FakeLLM()
    store.seed_watchlist([{"ticker": "ENEL.MI", "deepFreq": "manual", "note": "", "addedAt": "x"}])
    generate_daily_brief(store, llm, "2026-08-01",
                         fetch_quote=ok_quote, fetch_news=lambda t, s, e: "n",
                         fetch_money_flow=lambda t, d: None,
                         fetch_positioning=lambda t: None, fetch_futures=lambda: [])
    assert "EURUSD=X" in store.get_brief("2026-08-01")["quotes"]

    store2, llm2 = make_store(), FakeLLM()   # 纯美股也带汇率（总额按欧元计价）
    generate_daily_brief(store2, llm2, "2026-08-01",
                         fetch_quote=ok_quote, fetch_news=lambda t, s, e: "n",
                         fetch_money_flow=lambda t, d: None,
                         fetch_positioning=lambda t: None, fetch_futures=lambda: [])
    assert "EURUSD=X" in store2.get_brief("2026-08-01")["quotes"]


def test_top_up_adds_fx_for_milan_tickers():
    from assistant.daily_brief import top_up_quotes

    store = make_store()
    store.seed_watchlist([{"ticker": "ENEL.MI", "deepFreq": "manual", "note": "", "addedAt": "x"}])
    store.save_brief("2026-08-01", {"date": "2026-08-01", "quotes": {}})
    added = top_up_quotes(store, "2026-08-01", fetch_quote=ok_quote)
    quotes = store.get_brief("2026-08-01")["quotes"]
    assert "ENEL.MI" in quotes and "EURUSD=X" in quotes
    assert added >= 2


def test_top_up_quotes_force_overwrites_existing():
    from assistant.daily_brief import top_up_quotes

    store = make_store()  # watchlist NVDA + position AAPL
    store.save_brief("2026-08-01", {
        "date": "2026-08-01", "quotes": {"NVDA": {"close": 1.0, "pctChange": 0.0}},
    })
    n = top_up_quotes(store, "2026-08-01", fetch_quote=ok_quote, force=True)
    quotes = store.get_brief("2026-08-01")["quotes"]
    assert quotes["NVDA"]["close"] == 110.0     # 旧值被强制刷新
    assert quotes["AAPL"]["close"] == 110.0
    assert "EURUSD=X" in quotes
    assert n == 3


def test_brief_bilingual_reply_saves_both_languages():
    store = make_store()

    class BiLLM(FakeLLM):
        def invoke(self, prompt):
            self.prompts.append(prompt)
            return SimpleNamespace(content="===ZH===\n# 日报\n===EN===\n# Brief")

    llm = BiLLM()
    md = generate_daily_brief(store, llm, "2026-08-01", fetch_quote=ok_quote,
                              fetch_news=lambda *a: "news", fetch_money_flow=lambda t, d: None,
                              fetch_positioning=lambda t: None, fetch_futures=lambda: [])
    assert md == "# 日报"
    brief = store.get_brief("2026-08-01")
    assert brief["markdownZh"] == "# 日报"
    assert brief["markdownEn"] == "# Brief"
    assert "===ZH===" in llm.prompts[0]  # prompt 要求双语输出


def _mf(t, d):
    return {"volumeRatio": 1.8, "mfi14": 62.0, "obvTrend": "up", "chg5dPct": 3.2}


def test_brief_money_flow_line_in_prompt():
    store, llm = make_store(), FakeLLM()
    generate_daily_brief(store, llm, "2026-08-01",
                         fetch_quote=ok_quote, fetch_news=lambda t, s, e: "n",
                         fetch_money_flow=_mf,
                         fetch_positioning=lambda t: None, fetch_futures=lambda: [])
    prompt = llm.prompts[0]
    assert "量比 1.80" in prompt
    assert "MFI 62" in prompt
    assert "5日走高" in prompt
    assert "+3.2%" in prompt


def test_brief_money_flow_degrades_to_placeholder():
    def boom(t, d):
        raise RuntimeError("no data")

    store, llm = make_store(), FakeLLM()
    generate_daily_brief(store, llm, "2026-08-01",
                         fetch_quote=ok_quote, fetch_news=lambda t, s, e: "n",
                         fetch_money_flow=boom,
                         fetch_positioning=lambda t: None, fetch_futures=lambda: [])
    assert "无量价数据" in llm.prompts[0]


def test_brief_watch_only_section_lists_unheld_tickers():
    # make_store(): watch=NVDA、持仓=AAPL → 自选节只该点名 NVDA
    store, llm = make_store(), FakeLLM()
    generate_daily_brief(store, llm, "2026-08-01",
                         fetch_quote=ok_quote, fetch_news=lambda t, s, e: "n",
                         fetch_money_flow=lambda t, d: None,
                         fetch_positioning=lambda t: None, fetch_futures=lambda: [])
    prompt = llm.prompts[0]
    assert "未持仓的自选股：NVDA" in prompt
    assert "## 持仓点评" in prompt and "## 自选分析与推荐" in prompt
    assert "值得深挖" in prompt and "建议移除" in prompt      # 固定标签写进指令
    assert "## AAPL（持仓）" in prompt and "## NVDA（自选）" in prompt


def test_brief_watch_only_empty_when_all_watch_held():
    s = MemoryStore()
    s.seed_watchlist([{"ticker": "AAPL", "deepFreq": "manual", "note": "", "addedAt": "x"}])
    s.seed_positions([{"ticker": "AAPL", "shares": 10, "avgCost": 100.0, "updatedAt": "x"}])
    s.seed_meta({"cash": 5000.0, "currency": "USD"})
    llm = FakeLLM()
    generate_daily_brief(s, llm, "2026-08-01",
                         fetch_quote=ok_quote, fetch_news=lambda t, s2, e: "n",
                         fetch_money_flow=lambda t, d: None,
                         fetch_positioning=lambda t: None, fetch_futures=lambda: [])
    assert "未持仓的自选股：（无，此节写「今日无未持仓自选」即可）" in llm.prompts[0]


def _posi(t):
    return {"shortPctFloat": 1.39, "shortChangePct": 8.0,
            "shortRatioDays": 2.24, "pcOi": 0.49, "pcVol": 0.5}


def _futs():
    return [{"name": "标普500期指", "close": 7779.75, "pctChange": 0.31},
            {"name": "纳指100期指", "close": 29834.75, "pctChange": 0.55}]


def test_brief_positioning_line_in_prompt():
    store, llm = make_store(), FakeLLM()
    generate_daily_brief(store, llm, "2026-08-01",
                         fetch_quote=ok_quote, fetch_news=lambda t, s, e: "n",
                         fetch_money_flow=lambda t, d: None,
                         fetch_positioning=_posi, fetch_futures=lambda: [])
    prompt = llm.prompts[0]
    assert "多空: 空头占流通 1.4%（环比 +8.0%），回补 2.24 天，期权P/C 持仓 0.49 / 成交 0.5" in prompt


def test_brief_positioning_partial_keys_render_available_segments():
    store, llm = make_store(), FakeLLM()
    generate_daily_brief(store, llm, "2026-08-01",
                         fetch_quote=ok_quote, fetch_news=lambda t, s, e: "n",
                         fetch_money_flow=lambda t, d: None,
                         fetch_positioning=lambda t: {"shortRatioDays": 3.5},
                         fetch_futures=lambda: [])
    prompt = llm.prompts[0]
    assert "多空: 回补 3.5 天" in prompt
    # 注意：口径说明行本身含「空头占流通盘」「期权 P/C」字样，
    # 这里必须断言带「多空: 」前缀/渲染专用格式的片段，才不会误伤
    assert "多空: 空头占流通" not in prompt and "期权P/C 持仓" not in prompt


def test_brief_positioning_degrades_to_placeholder():
    def boom(t):
        raise RuntimeError("no data")
    store, llm = make_store(), FakeLLM()
    generate_daily_brief(store, llm, "2026-08-01",
                         fetch_quote=ok_quote, fetch_news=lambda t, s, e: "n",
                         fetch_money_flow=lambda t, d: None,
                         fetch_positioning=boom, fetch_futures=lambda: [])
    assert "多空: 无数据" in llm.prompts[0]


def test_brief_futures_block_in_prompt():
    store, llm = make_store(), FakeLLM()
    generate_daily_brief(store, llm, "2026-08-01",
                         fetch_quote=ok_quote, fetch_news=lambda t, s, e: "n",
                         fetch_money_flow=lambda t, d: None,
                         fetch_positioning=lambda t: None, fetch_futures=_futs)
    prompt = llm.prompts[0]
    assert "# 股指期货" in prompt
    assert "标普500期指: 7779.75，+0.31%" in prompt
    assert "纳指100期指: 29834.75，+0.55%" in prompt


def test_brief_futures_block_placeholder_when_empty_or_raising():
    def boom():
        raise RuntimeError("nope")
    store, llm = make_store(), FakeLLM()
    generate_daily_brief(store, llm, "2026-08-01",
                         fetch_quote=ok_quote, fetch_news=lambda t, s, e: "n",
                         fetch_money_flow=lambda t, d: None,
                         fetch_positioning=lambda t: None, fetch_futures=boom)
    assert "（期指数据缺失）" in llm.prompts[0]
