"""策略框架 engine 测试：配置/scope 解析、单元账本重建、去重、建议落库。"""
import pytest

from assistant.store import MemoryStore
from assistant.strategies.engine import (
    rebuild_units,
    resolve_scope,
    resolve_strategies,
    run_scan,
)

# 与 test_assistant_turtle 相同的「上次输了 → 今天 S1 突破」剧本
BREAKOUT_CLOSES = [100.0] * 55 + [103, 100.5] + [101.5] * 29 + [102.6]
QUIET_CLOSES = [100.0] * 90


def fake_bars_factory(closes_by_ticker):
    def fetch(ticker, today, days=200):
        closes = closes_by_ticker.get(ticker, [])
        return [
            {"date": f"d{i}", "high": c + 0.5, "low": c - 0.5, "close": c}
            for i, c in enumerate(closes)
        ]
    return fetch


def quote_100(ticker, **kw):
    return {"ticker": ticker, "close": 100.0, "prevClose": 100.0, "pctChange": 0.0}


def make_store(*, watch=("BRK",), positions=(), cash=100_000.0, cfg=None):
    s = MemoryStore()
    s.seed_watchlist([{"ticker": t, "deepFreq": "manual"} for t in watch])
    s.seed_positions(list(positions))
    s.seed_meta({"cash": cash, "currency": "USD"})
    if cfg is not None:
        s.seed_strategy_config(cfg)
    return s


def test_resolve_strategies_named_ignores_enabled():
    assert resolve_strategies({"strategy": "turtle"}, {}) == ["turtle"]
    with pytest.raises(ValueError):
        resolve_strategies({"strategy": "nope"}, {})


def test_resolve_strategies_from_config_enabled_only():
    cfg = {"turtle": {"enabled": True}, "ghost": {"enabled": True}, "off": {"enabled": False}}
    assert resolve_strategies({}, cfg) == ["turtle"]  # ghost 不在注册表，off 未启用
    assert resolve_strategies({}, {}) == []


def test_resolve_scope_job_overrides_config():
    assert resolve_scope({"scope": "positions"}, {"scope": "positions+watchlist"}) == "positions"
    assert resolve_scope({}, {"scope": "positions"}) == "positions"
    assert resolve_scope({}, {}) == "positions+watchlist"


def test_rebuild_units_from_accepted_suggestions_and_sell_reset():
    sugs = [
        {"source": "turtle", "status": "accepted", "action": "buy",
         "createdAt": "1", "meta": {"entry": 100.0, "shares": 5, "system": "s1", "n": 1.2}},
        {"source": "turtle", "status": "accepted", "action": "add",
         "createdAt": "2", "meta": {"entry": 101.0, "shares": 5, "system": "s1", "n": 1.3}},
        {"source": "other", "status": "accepted", "action": "buy",
         "createdAt": "3", "meta": {"entry": 999.0}},          # 别的策略，不算
        {"source": "turtle", "status": "pending", "action": "add",
         "createdAt": "4", "meta": {"entry": 999.0}},          # 未采纳，不算
    ]
    units = rebuild_units(sugs, "turtle", None)
    assert [u["entry"] for u in units] == [100.0, 101.0]
    # 卖出清空账本
    sugs.append({"source": "turtle", "status": "accepted", "action": "sell",
                 "createdAt": "5", "meta": {}})
    assert rebuild_units(sugs, "turtle", None) == []


def test_rebuild_units_seeds_from_position():
    units = rebuild_units([], "turtle", {"ticker": "T", "shares": 8, "avgCost": 55.0})
    assert units == [{"entry": 55.0, "shares": 8, "system": "s1", "n": None,
                      "seeded": True}]
    # 由已采纳建议重建的真单元不带 seeded 标记
    accepted = [{"source": "turtle", "status": "accepted", "action": "buy",
                 "createdAt": "1", "meta": {"entry": 50.0, "shares": 8, "n": 1.0}}]
    real = rebuild_units(accepted, "turtle", {"ticker": "T", "shares": 8, "avgCost": 55.0})
    assert "seeded" not in real[0]


def test_run_scan_creates_suggestion_with_source_and_meta():
    store = make_store()
    result = run_scan(store, {"strategy": "turtle"}, "2026-08-01",
                      fetch_bars=fake_bars_factory({"BRK": BREAKOUT_CLOSES}),
                      fetch_quote=quote_100)
    assert result == {"scanned": 1, "created": 1}
    (doc,) = store._suggestions.values()
    assert doc["source"] == "turtle" and doc["action"] == "buy"
    assert doc["status"] == "pending" and doc["analysisId"] == ""
    assert doc["meta"]["system"] == "s1" and doc["meta"]["shares"] >= 1
    assert "突破" in doc["rationale"]


def test_run_scan_dedups_same_pending_signal():
    store = make_store()
    bars = fake_bars_factory({"BRK": BREAKOUT_CLOSES})
    run_scan(store, {"strategy": "turtle"}, "2026-08-01",
             fetch_bars=bars, fetch_quote=quote_100)
    run_scan(store, {"strategy": "turtle"}, "2026-08-02",
             fetch_bars=bars, fetch_quote=quote_100)
    assert len(store._suggestions) == 1  # 第二次被 pending 去重


def test_run_scan_scope_positions_skips_watchlist():
    store = make_store(watch=("BRK",),
                       positions=[{"ticker": "HELD", "shares": 10, "avgCost": 100.0}])
    result = run_scan(store, {"strategy": "turtle", "scope": "positions"}, "2026-08-01",
                      fetch_bars=fake_bars_factory({"HELD": QUIET_CLOSES,
                                                    "BRK": BREAKOUT_CLOSES}),
                      fetch_quote=quote_100)
    assert result["scanned"] == 1  # 只扫了 HELD，横盘无信号
    assert result["created"] == 0


def test_run_scan_skips_isin_and_survives_fetch_failure():
    store = make_store(watch=("IT0005217390", "BOOM"))

    def bars(ticker, today, days=200):
        raise RuntimeError("yfinance down")

    result = run_scan(store, {"strategy": "turtle"}, "2026-08-01",
                      fetch_bars=bars, fetch_quote=quote_100)
    assert result == {"scanned": 0, "created": 0}  # ISIN 直接跳过，BOOM 取数失败也不炸


def test_run_scan_without_config_or_name_is_noop():
    store = make_store()
    result = run_scan(store, {}, "2026-08-01",
                      fetch_bars=fake_bars_factory({}), fetch_quote=quote_100)
    assert result == {"scanned": 0, "created": 0}


def test_run_scan_held_position_uses_seed_unit_for_exit():
    # 持仓 entry=avgCost 105，当前 ATR≈1.375，收盘 102 触发止损建议
    store = make_store(watch=(), cfg={"turtle": {"enabled": True}},
                       positions=[{"ticker": "HELD", "shares": 10, "avgCost": 105.0}])
    result = run_scan(store, {}, "2026-08-01",
                      fetch_bars=fake_bars_factory({"HELD": [110.0] * 70 + [102.0]}),
                      fetch_quote=quote_100)
    assert result["created"] == 1
    (doc,) = store._suggestions.values()
    assert doc["action"] == "sell" and doc["meta"]["trigger"] == "stop"


def test_run_scan_cooldown_after_dismissal():
    """忽略后 7 天内不重复生成；过了窗口才允许再来。"""
    store = make_store()
    bars = fake_bars_factory({"BRK": BREAKOUT_CLOSES})
    run_scan(store, {"strategy": "turtle"}, "2026-08-01",
             fetch_bars=bars, fetch_quote=quote_100)
    (sid,) = store._suggestions
    store.update_suggestion(sid, {"status": "dismissed",
                                  "resolvedAt": "2026-08-01T10:00:00+00:00"})

    # 3 天后：冷却期内，不生成
    run_scan(store, {"strategy": "turtle"}, "2026-08-04",
             fetch_bars=bars, fetch_quote=quote_100)
    assert len(store._suggestions) == 1

    # 9 天后：冷却期外，条件仍成立则允许再生成
    run_scan(store, {"strategy": "turtle"}, "2026-08-10",
             fetch_bars=bars, fetch_quote=quote_100)
    assert len(store._suggestions) == 2


def test_run_scan_cooldown_only_blocks_same_action():
    """冷却按动作区分：忽略过 buy 不影响 sell 类信号。"""
    store = make_store(watch=(),
                       positions=[{"ticker": "HELD", "shares": 10, "avgCost": 105.0}])
    # 先塞一条 3 天前被忽略的 add（同 ticker 不同动作）
    sid = store.save_suggestion({"ticker": "HELD", "source": "turtle",
                                 "action": "add", "status": "dismissed",
                                 "createdAt": "2026-07-30T00:00:00+00:00",
                                 "resolvedAt": "2026-07-30T00:00:00+00:00"})
    del sid
    # 大跌触发止损 sell（见 turtle 测试的种子止损剧本）
    closes = [110.0] * 70 + [102.0]
    run_scan(store, {"strategy": "turtle", "scope": "positions"}, "2026-08-01",
             fetch_bars=fake_bars_factory({"HELD": closes}), fetch_quote=quote_100)
    sells = [s for s in store._suggestions.values()
             if s.get("action") == "sell" and s.get("status") == "pending"]
    assert len(sells) == 1


# --- Policy 闸接线 -------------------------------------------------------------
# 汇率固定 1.25，其余标的报价按需给，方便算出确定的 EUR 口径数字。
def quotes_factory(prices):
    def fetch(ticker, **kw):
        if ticker == "EURUSD=X":
            return {"ticker": ticker, "close": 1.25, "prevClose": 1.25, "pctChange": 0.0}
        if ticker not in prices:
            raise KeyError(ticker)
        return {"ticker": ticker, "close": prices[ticker], "prevClose": prices[ticker],
                "pctChange": 0.0}
    return fetch


LOOSE_POLICY = {"cashFloorPct": 0, "maxSingleStockPct": 100, "maxSingleFundPct": 100,
                "maxSatellitePct": 100, "maxUsdExposurePct": 100,
                "maxTotalRiskPct": 100, "maxSingleIssuerPct": 100}


def test_buy_signal_is_clamped_by_the_policy_gate():
    store = make_store(watch=("BRK.MI",), cash=10_000.0)
    store.seed_meta({"cash": 10_000.0, "currency": "EUR"})
    store.seed_policy_config({**LOOSE_POLICY, "maxSingleStockPct": 8})
    run_scan(store, {"strategy": "turtle"}, "2026-08-01",
             fetch_bars=fake_bars_factory({"BRK.MI": BREAKOUT_CLOSES}),
             fetch_quote=quotes_factory({"BRK.MI": 102.6}))
    (doc,) = store._suggestions.values()
    assert doc["action"] == "buy"
    meta = doc["meta"]
    # 单票上限 8% × €10000 = €800，价 €102.6 → 7 股
    assert meta["shares"] == 7
    assert meta["clampedFrom"] > 7 and meta["clampedBy"] == "single"
    assert "单票上限" in doc["rationale"] and "per-name cap" in doc["rationaleEn"]


def test_buy_signal_blocked_when_no_headroom():
    # 有持仓（组合值撑得起单元计算）但现金为 0 —— 正是现实处境：钱全在仓里
    store = make_store(watch=("BRK.MI",),
                       positions=[{"ticker": "HELD.MI", "shares": 100, "avgCost": 100.0}],
                       cash=0.0)
    store.seed_meta({"cash": 0.0, "currency": "EUR"})
    store.seed_policy_config({**LOOSE_POLICY, "cashFloorPct": 5})
    run_scan(store, {"strategy": "turtle"}, "2026-08-01",
             fetch_bars=fake_bars_factory({"BRK.MI": BREAKOUT_CLOSES,
                                           "HELD.MI": QUIET_CLOSES}),
             fetch_quote=quotes_factory({"BRK.MI": 102.6, "HELD.MI": 100.0}))
    (doc,) = [d for d in store._suggestions.values() if d["ticker"] == "BRK.MI"]
    assert doc["meta"]["blocked"] is True
    assert doc["meta"]["blockedBy"] == "cash"
    assert "⚠️" in doc["rationale"]


def test_sell_signals_are_never_gated():
    """减风险的动作不设闸——现金为 0 也照常发止损。"""
    store = make_store(watch=(), positions=[{"ticker": "HELD.MI", "shares": 10,
                                             "avgCost": 105.0}], cash=0.0)
    store.seed_meta({"cash": 0.0, "currency": "EUR"})
    store.seed_policy_config({"cashFloorPct": 50})
    closes = [110.0] * 70 + [102.0]      # 触发种子单元止损
    run_scan(store, {"strategy": "turtle", "scope": "positions"}, "2026-08-01",
             fetch_bars=fake_bars_factory({"HELD.MI": closes}),
             fetch_quote=quotes_factory({"HELD.MI": 102.0}))
    (doc,) = store._suggestions.values()
    assert doc["action"] == "sell"
    assert "blocked" not in doc["meta"]


def test_blocked_card_does_not_dedup_away_a_later_signal():
    """blocked 卡不参与去重：额度腾出后新信号照样能落库。"""
    store = make_store(watch=("BRK.MI",),
                       positions=[{"ticker": "HELD.MI", "shares": 100, "avgCost": 100.0}],
                       cash=0.0)
    store.seed_meta({"cash": 0.0, "currency": "EUR"})
    store.seed_policy_config({**LOOSE_POLICY, "cashFloorPct": 5})
    bars = fake_bars_factory({"BRK.MI": BREAKOUT_CLOSES, "HELD.MI": QUIET_CLOSES})
    quote = quotes_factory({"BRK.MI": 102.6, "HELD.MI": 100.0})
    run_scan(store, {"strategy": "turtle"}, "2026-08-01", fetch_bars=bars, fetch_quote=quote)
    blocked = [d for d in store._suggestions.values()
               if (d["meta"] or {}).get("blocked")]
    assert len(blocked) == 1
    # 现金到位后再扫：旧的 blocked 卡不该挡住新信号
    store.seed_meta({"cash": 50_000.0, "currency": "EUR"})
    store.seed_policy_config(LOOSE_POLICY)
    run_scan(store, {"strategy": "turtle"}, "2026-08-02", fetch_bars=bars, fetch_quote=quote)
    fresh = [d for d in store._suggestions.values()
             if d["ticker"] == "BRK.MI" and not (d["meta"] or {}).get("blocked")]
    assert len(fresh) == 1 and fresh[0]["meta"]["shares"] >= 1


def test_portfolio_value_is_passed_in_the_tickers_own_currency():
    """单元公式是 组合值 ÷ 2N，N 是原币 → 组合值必须折成原币，否则差一个汇率。"""
    seen = {}

    from assistant.strategies import REGISTRY, Strategy, register

    def spy_scan(ctx):
        seen[ctx.ticker] = ctx.portfolio_value
        return []

    register(Strategy(name="spy", label="spy", defaults={}, scan=spy_scan))
    try:
        store = make_store(watch=("USD.X", "EUR.MI"), cash=10_000.0)
        store.seed_meta({"cash": 10_000.0, "currency": "EUR"})
        run_scan(store, {"strategy": "spy"}, "2026-08-01",
                 fetch_bars=fake_bars_factory({"USD.X": QUIET_CLOSES,
                                               "EUR.MI": QUIET_CLOSES}),
                 fetch_quote=quotes_factory({"USD.X": 100.0, "EUR.MI": 100.0}))
        # 组合是纯现金 €10000：欧元标的看到 €10000，美元标的看到 $12500
        assert seen["EUR.MI"] == pytest.approx(10_000)
        assert seen["USD.X"] == pytest.approx(12_500)
    finally:
        REGISTRY.pop("spy", None)


def test_gates_skipped_without_fx_but_signals_still_fire():
    """缺汇率时不给错数：跳过闸门，信号照发（退回币种直加估值）。"""
    store = make_store(watch=("BRK",), cash=100_000.0)
    store.seed_policy_config({"cashFloorPct": 5})

    def no_fx(ticker, **kw):
        if ticker == "EURUSD=X":
            raise RuntimeError("rate unavailable")
        return {"ticker": ticker, "close": 102.6, "prevClose": 102.6, "pctChange": 0.0}

    run_scan(store, {"strategy": "turtle"}, "2026-08-01",
             fetch_bars=fake_bars_factory({"BRK": BREAKOUT_CLOSES}), fetch_quote=no_fx)
    (doc,) = store._suggestions.values()
    assert doc["action"] == "buy"
    assert "blocked" not in doc["meta"] and "clampedBy" not in doc["meta"]

