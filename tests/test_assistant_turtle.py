"""海龟策略纯函数测试：指标、过滤器、双系统信号与优先级。"""
from assistant.strategies import ScanContext
from assistant.strategies.turtle import (
    channel_high,
    channel_low,
    last_s1_breakout_won,
    scan,
    unit_shares,
    wilder_atr,
)


def bars_from_closes(closes, spread=1.0):
    """收盘序列 → OHLC bars：high/low = close ± spread/2。"""
    return [
        {"date": f"d{i}", "high": c + spread / 2, "low": c - spread / 2, "close": c}
        for i, c in enumerate(closes)
    ]


def ctx(closes, *, units=(), portfolio_value=100_000.0, params=None, position=None):
    return ScanContext(
        ticker="TEST", bars=bars_from_closes(closes), position=position,
        units=list(units), portfolio_value=portfolio_value, cash=0.0,
        params=params or {},
    )


# --- 行情剧本 -----------------------------------------------------------------
# 「上次 S1 赢了」：55 根横盘 → idx55 突破 103 → 涨到 108 → 回落经 10 日低点
# 退出（未触 2N 止损）→ 20 根 104 横盘 → 今天 105 再破 20 日高（但低于 55 日高 108.5）。
WON_CLOSES = (
    [100.0] * 55
    + [103, 104, 105, 106, 107, 108, 107.5, 107, 106.5, 106, 102]
    + [104.0] * 20
    + [105]
)
# 「上次 S1 输了」：突破 103 后立刻跌破 entry−2N ≈ 100.75 → 止损。
LOST_CLOSES = [100.0] * 55 + [103, 100.5] + [101.5] * 29 + [102.6]


def test_wilder_atr_constant_range():
    bars = bars_from_closes([100.0] * 30)  # TR 恒等于 spread=1
    assert abs(wilder_atr(bars, 20) - 1.0) < 1e-9
    assert wilder_atr(bars[:20], 20) is None  # 根数不足


def test_channels_exclude_current_bar():
    bars = bars_from_closes([100, 101, 102, 103])
    assert channel_high(bars, 3, 3) == 102.5  # 前 3 根最高价
    assert channel_low(bars, 3, 3) == 99.5
    assert channel_high(bars, 5, 3) is None  # 根数不足


def test_unit_shares_floor_and_zero():
    assert unit_shares(100_000, 1.0, 2.0) == 250  # 1000 / 4
    assert unit_shares(10, 1.0, 2.0) == 0
    assert unit_shares(100_000, 1.0, 0) == 0


def test_s1_filter_detects_winner_and_loser():
    won_bars = bars_from_closes(WON_CLOSES)
    assert last_s1_breakout_won(
        won_bars, entry_n=20, exit_n=10, atr_period=20, before=len(won_bars) - 1
    ) is True
    lost_bars = bars_from_closes(LOST_CLOSES)
    assert last_s1_breakout_won(
        lost_bars, entry_n=20, exit_n=10, atr_period=20, before=len(lost_bars) - 1
    ) is False


def test_entry_skipped_after_winning_breakout():
    assert scan(ctx(WON_CLOSES)) == []


def test_entry_fires_after_losing_breakout():
    sigs = scan(ctx(LOST_CLOSES))
    assert len(sigs) == 1
    s = sigs[0]
    assert s.action == "buy" and s.meta["system"] == "s1"
    n = wilder_atr(bars_from_closes(LOST_CLOSES), 20)
    assert s.shares == unit_shares(100_000, 1.0, n)
    assert abs(s.stop - (102.6 - 2 * n)) < 1e-9
    assert "突破" in s.reason and str(s.shares) in s.reason


def test_filter_can_be_disabled_via_params():
    sigs = scan(ctx(WON_CLOSES, params={"s1": {"filter": False}}))
    assert len(sigs) == 1 and sigs[0].meta["system"] == "s1"


def test_s2_breakout_ignores_filter():
    # 55 日高 108.5，收盘 109 直接触发 S2（即使上次 S1 是赢的）
    closes = WON_CLOSES[:-1] + [109]
    sigs = scan(ctx(closes))
    assert len(sigs) == 1
    assert sigs[0].action == "buy" and sigs[0].meta["system"] == "s2"


def test_tiny_portfolio_yields_no_entry():
    assert scan(ctx(LOST_CLOSES, portfolio_value=10.0)) == []


def test_warmup_insufficient_returns_empty():
    assert scan(ctx([100.0] * 40)) == []


# --- 持仓侧 -------------------------------------------------------------------

def test_stop_loss_beats_exit():
    # 收盘 100 同时低于止损位(105−2=103)和 10 日低点 → 应报止损而非退出
    closes = [110.0] * 70 + [100.0]
    sigs = scan(ctx(closes, units=[{"entry": 105.0, "shares": 10, "system": "s1", "n": 1.0}]))
    assert len(sigs) == 1
    assert sigs[0].action == "sell" and sigs[0].meta["trigger"] == "stop"


def test_exit_on_reverse_breakout():
    # 未触止损（entry 95 − 2N），但收盘 99 跌破 10 日低点 99.5
    closes = [100.0] * 70 + [99.0]
    sigs = scan(ctx(closes, units=[{"entry": 95.0, "shares": 10, "system": "s1", "n": 1.0}]))
    assert len(sigs) == 1
    assert sigs[0].action == "sell" and sigs[0].meta["trigger"] == "exit"


def test_s2_unit_uses_20day_exit():
    # S2 仓位用 20 日低点退出：收盘 99 未破 20 日低点（99.5-0.5? 均为 99.5）→
    # 破 10 日低不算；构造 20 日低 = 99.5，收盘 99 破位 → 退出
    closes = [100.0] * 70 + [99.0]
    sigs = scan(ctx(closes, units=[{"entry": 95.0, "shares": 10, "system": "s2", "n": 1.0}]))
    assert len(sigs) == 1 and sigs[0].meta["trigger"] == "exit"


def test_pyramid_add_at_half_n():
    closes = [100.0] * 70 + [100.2]
    sigs = scan(ctx(closes, units=[{"entry": 99.5, "shares": 10, "system": "s1", "n": 1.0}]))
    assert len(sigs) == 1
    s = sigs[0]
    assert s.action == "add" and s.meta["trigger"] == "pyramid"
    assert s.shares >= 1 and "2/4" in s.reason


def test_no_pyramid_at_max_units():
    closes = [100.0] * 70 + [100.2]
    unit = {"entry": 99.5, "shares": 10, "system": "s1", "n": 1.0}
    assert scan(ctx(closes, units=[unit] * 4)) == []


def test_seed_unit_without_n_uses_current_atr():
    # 种子单元（老持仓）没有入场 N → 用当前 ATR：大跌当天 TR=8.5 把 N 抬到
    # (19+8.5)/20=1.375，止损位 105−2N=102.25，收盘 102 触发止损
    closes = [110.0] * 70 + [102.0]
    sigs = scan(ctx(closes, units=[{"entry": 105.0, "shares": 10, "system": "s1", "n": None}]))
    assert len(sigs) == 1 and sigs[0].meta["trigger"] == "stop"


def test_held_quiet_market_no_signal():
    closes = [100.0] * 70 + [100.1]
    assert scan(ctx(closes, units=[{"entry": 100.0, "shares": 10, "system": "s1", "n": 1.0}])) == []


def test_seed_unit_never_pyramids():
    """老持仓种子单元（seeded）浮盈再多也不发加仓——不存在"入场战役"。"""
    closes = [100.0] * 70 + [130.0]   # 现价远超 entry+½N
    seed = {"entry": 62.0, "shares": 100, "system": "s1", "n": None, "seeded": True}
    assert scan(ctx(closes, units=[seed])) == []


def test_seed_unit_still_monitors_stop_and_exit():
    # 止损仍生效（大跌把当前 N 抬高后触发 entry−2N）
    closes = [110.0] * 70 + [102.0]
    seed = {"entry": 105.0, "shares": 10, "system": "s1", "n": None, "seeded": True}
    sigs = scan(ctx(closes, units=[seed]))
    assert len(sigs) == 1 and sigs[0].meta["trigger"] == "stop"
    # 反向突破退出仍生效
    closes2 = [100.0] * 60 + [104.0] * 10 + [99.4]
    seed2 = {"entry": 60.0, "shares": 10, "system": "s1", "n": 1.0, "seeded": True}
    sigs2 = scan(ctx(closes2, units=[seed2]))
    assert len(sigs2) == 1 and sigs2[0].meta["trigger"] == "exit"


def test_real_unit_still_pyramids():
    """真·海龟单元（无 seeded 标记）加仓行为不受影响——回归保护。"""
    closes = [100.0] * 70 + [100.2]
    real = {"entry": 99.5, "shares": 10, "system": "s1", "n": 1.0}
    sigs = scan(ctx(closes, units=[real]))
    assert len(sigs) == 1 and sigs[0].meta["trigger"] == "pyramid"

