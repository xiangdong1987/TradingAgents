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
    assert units == [{"entry": 55.0, "shares": 8, "system": "s1", "n": None}]


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
