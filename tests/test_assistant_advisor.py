from types import SimpleNamespace
from assistant.advisor import generate_suggestion
from assistant.store import MemoryStore


class FakeLLM:
    def __init__(self, reply):
        self.reply, self.prompts = reply, []

    def invoke(self, prompt):
        self.prompts.append(prompt)
        return SimpleNamespace(content=self.reply)


def make_store(with_position=True):
    s = MemoryStore()
    if with_position:
        s.seed_positions([{"ticker": "NVDA", "shares": 10, "avgCost": 100.0, "updatedAt": "x"}])
    s.seed_meta({"cash": 1000.0, "currency": "USD"})
    return s


def quote_110(ticker, **kw):
    return {"ticker": ticker, "close": 110.0, "prevClose": 100.0, "pctChange": 10.0}


def test_json_reply_becomes_pending_suggestion():
    store = make_store()
    llm = FakeLLM('{"action": "trim", "targetWeightPct": 15, "rationale": "估值过高"}')
    sid = generate_suggestion(store, llm, "NVDA", "SELL", "analysis1", fetch_quote=quote_110)
    doc = store._suggestions[sid]
    # Policy 层把 15% 钳到单票上限 8%，并在 meta/理由里留痕
    assert doc["action"] == "trim" and doc["targetWeightPct"] == 8.0
    assert doc["meta"]["targetClampedFrom"] == 15
    assert "单一标的上限" in doc["rationale"]
    assert doc["status"] == "pending" and doc["analysisId"] == "analysis1"
    # prompt 里有当前仓位占比：10*110=1100 股票 + 1000 现金 → 52.4%
    assert "52.4" in llm.prompts[0]


def test_hold_with_no_position_returns_none():
    store = make_store(with_position=False)
    llm = FakeLLM("should not be called")
    assert generate_suggestion(store, llm, "NVDA", "HOLD", "a1", fetch_quote=quote_110) is None
    assert store._suggestions == {} and llm.prompts == []


def test_malformed_llm_reply_degrades_gracefully():
    store = make_store()
    llm = FakeLLM("我觉得应该减仓，但我不会说 JSON")
    sid = generate_suggestion(store, llm, "NVDA", "SELL", "a1", fetch_quote=quote_110)
    doc = store._suggestions[sid]
    assert doc["action"] == "sell"                  # 从 decision 降级映射
    assert doc["targetWeightPct"] is None
    assert "减仓" in doc["rationale"]                # 原始输出保留


def test_quote_fetch_failure_falls_back_to_cost_basis():
    store = make_store()

    def quote_unavailable(ticker, **kw):
        raise RuntimeError("quote service down")

    llm = FakeLLM('{"action": "hold", "targetWeightPct": null, "rationale": "使用成本价估值"}')
    sid = generate_suggestion(store, llm, "NVDA", "BUY", "a2", fetch_quote=quote_unavailable)
    doc = store._suggestions[sid]
    assert doc["status"] == "pending"
    assert sid is not None  # suggestion still generated despite quote failure
    # prompt should use cost basis: 10*100=1000 股票 + 1000 现金 → 50.0% 权重
    assert "50.0" in llm.prompts[0]
    assert "100" in llm.prompts[0]  # cost basis in the prompt


# --- Policy 接线 ---------------------------------------------------------------

def quotes_with_fx(prices, rate=1.25):
    def fetch(ticker, **kw):
        if ticker == "EURUSD=X":
            return {"ticker": ticker, "close": rate, "prevClose": rate, "pctChange": 0.0}
        px = prices.get(ticker, 100.0)
        return {"ticker": ticker, "close": px, "prevClose": px, "pctChange": 0.0}
    return fetch


LOOSE = {"cashFloorPct": 0, "maxSingleStockPct": 100, "maxSingleFundPct": 100,
         "maxSatellitePct": 100, "maxUsdExposurePct": 100, "maxTotalRiskPct": 100,
         "maxSingleIssuerPct": 100}


def eur_store(cash=10_000.0, positions=()):
    s = MemoryStore()
    s.seed_positions(list(positions))
    s.seed_meta({"cash": cash, "currency": "EUR"})
    return s


def test_buy_gets_shares_and_stop_from_the_risk_formula():
    store = eur_store()
    store.seed_policy_config(LOOSE)
    llm = FakeLLM('{"action": "buy", "targetWeightPct": 5, "rationale": "看多", '
                  '"rationaleEn": "bullish"}')
    sid = generate_suggestion(store, llm, "KO.MI", "BUY", "a1",
                              fetch_quote=quotes_with_fx({"KO.MI": 100.0}))
    meta = store._suggestions[sid]["meta"]
    # 兜底止损 -8% → €92；每股风险 €8；预算 €10000 × 1% = €100 → 12 股
    assert meta["stop"] == 92.0
    assert meta["shares"] == 12
    assert "clampedBy" not in meta


def test_buy_is_clamped_by_the_per_name_cap():
    store = eur_store()
    store.seed_policy_config({**LOOSE, "maxSingleStockPct": 5})
    llm = FakeLLM('{"action": "buy", "targetWeightPct": 5, "rationale": "看多"}')
    sid = generate_suggestion(store, llm, "KO.MI", "BUY", "a1",
                              fetch_quote=quotes_with_fx({"KO.MI": 100.0}))
    doc = store._suggestions[sid]
    # 上限 5% × €10000 = €500 → 5 股（风险公式本来给 12 股）
    assert doc["meta"]["shares"] == 5
    assert doc["meta"]["clampedBy"] == "single" and doc["meta"]["clampedFrom"] == 12
    assert "钳" in doc["rationale"]


def test_buy_without_cash_is_blocked_with_funding_candidates():
    store = eur_store(cash=0.0,
                      positions=[{"ticker": "BIG.MI", "shares": 100, "avgCost": 100.0}])
    store.seed_policy_config({**LOOSE, "cashFloorPct": 5})
    llm = FakeLLM('{"action": "buy", "targetWeightPct": 5, "rationale": "看多"}')
    sid = generate_suggestion(store, llm, "KO.MI", "BUY", "a1",
                              fetch_quote=quotes_with_fx({"KO.MI": 100.0, "BIG.MI": 100.0}))
    meta = store._suggestions[sid]["meta"]
    assert meta["blocked"] is True and meta["blockedBy"] == "cash"
    assert meta["fundingCandidates"] == ["BIG.MI"]
    assert "shares" not in meta          # 拦住时不给股数，避免照着下单


def test_sell_side_advice_is_not_gated():
    store = eur_store(cash=0.0,
                      positions=[{"ticker": "KO.MI", "shares": 10, "avgCost": 100.0}])
    store.seed_policy_config({"cashFloorPct": 50})
    llm = FakeLLM('{"action": "sell", "targetWeightPct": 0, "rationale": "退出"}')
    sid = generate_suggestion(store, llm, "KO.MI", "SELL", "a1",
                              fetch_quote=quotes_with_fx({"KO.MI": 100.0}))
    meta = store._suggestions[sid]["meta"]
    assert "blocked" not in meta and "shares" not in meta


def test_prompt_carries_the_policy_constraints():
    store = eur_store()
    store.seed_policy_config({"maxSingleStockPct": 7, "cashFloorPct": 6})
    llm = FakeLLM('{"action": "hold", "targetWeightPct": null, "rationale": "观望"}')
    # 用 BUY：HOLD + 无持仓会被提前跳过（设计如此，不产生噪音建议）
    generate_suggestion(store, llm, "KO.MI", "BUY", "a1",
                        fetch_quote=quotes_with_fx({"KO.MI": 100.0}))
    prompt = llm.prompts[0]
    assert "单一标的上限 7%" in prompt
    assert "现金缓冲不得低于组合的 6%" in prompt


def test_gates_skipped_without_fx():
    """缺汇率时不钳不拦，保留 LLM 原始目标（宁可不管也不给错数）。"""
    store = MemoryStore()
    store.seed_positions([{"ticker": "NVDA", "shares": 10, "avgCost": 100.0}])
    store.seed_meta({"cash": 1000.0, "currency": "USD"})

    def no_fx(ticker, **kw):
        if ticker == "EURUSD=X":
            raise RuntimeError("no rate")
        return {"ticker": ticker, "close": 110.0, "prevClose": 110.0, "pctChange": 0.0}

    llm = FakeLLM('{"action": "buy", "targetWeightPct": 30, "rationale": "看多"}')
    sid = generate_suggestion(store, llm, "NVDA", "BUY", "a1", fetch_quote=no_fx)
    doc = store._suggestions[sid]
    assert doc["targetWeightPct"] == 30      # 未钳
    assert doc["meta"] == {}

