"""回测模拟器测试：用合成行情驱动海龟 scan，验证成交/账本/指标口径。"""
from assistant.strategies.backtest import max_drawdown_pct, simulate
from assistant.strategies.turtle import DEFAULTS, scan


def bars_from_closes(closes, spread=1.0, iso=False):
    def date(i):
        if not iso:
            return f"d{i:03d}"
        from datetime import date as d, timedelta
        return (d(2024, 1, 1) + timedelta(days=i)).isoformat()
    return [
        {"date": date(i), "high": c + spread / 2, "low": c - spread / 2, "close": c}
        for i, c in enumerate(closes)
    ]


# 赢的剧本：idx5 的 116 尖峰把 55 日通道抬到 116.5（让后面的突破只触发 S1 而非 S2）
# → 横盘 → 103 突破 S1 入场（限 1 单元）→ 涨到 110 → 回落 104 跌破 10 日低点退出
# （止损位从未触及）→ 落袋 +1 元/股。
WIN_CLOSES = ([100.0] * 5 + [116.0] + [100.0] * 54
              + [103, 104, 105, 106, 107, 108, 109, 110, 108, 107, 106, 105, 104])
# 输的剧本：突破 103 后次日 100，跌破 entry−2N≈100.75 止损。
LOSS_CLOSES = [100.0] * 60 + [103, 100, 100, 100]


def test_winning_round_trip_and_metrics():
    r = simulate("T", bars_from_closes(WIN_CLOSES), scan,
                 {**DEFAULTS, "maxUnits": 1}, initial_cash=100_000)
    assert len(r.trades) == 1
    t = r.trades[0]
    assert not t.is_open and t.n_units == 1
    assert t.pnl > 0 and abs(t.proceeds / t.shares - 104.0) < 1e-9
    assert r.win_rate_pct == 100.0
    assert r.final_equity == 100_000 + t.pnl
    assert r.total_return_pct > 0
    assert 0 < r.exposure_pct < 100
    assert r.buy_hold_pct > 0  # 100 → 104


def test_losing_stop_out():
    r = simulate("T", bars_from_closes(LOSS_CLOSES), scan, DEFAULTS)
    assert len(r.trades) == 1
    t = r.trades[0]
    assert not t.is_open and t.pnl < 0
    assert r.win_rate_pct == 0.0
    assert r.final_equity < 100_000


def test_open_position_at_end_excluded_from_win_rate():
    closes = [100.0] * 60 + [103, 103.2, 103.4]  # 入场后一直持有到期末
    r = simulate("T", bars_from_closes(closes), scan, {**DEFAULTS, "maxUnits": 1})
    assert len(r.trades) == 1
    assert r.trades[0].is_open
    assert r.win_rate_pct is None          # 没有已平仓回合
    assert r.days_in_market >= 1
    # 期末权益 = 现金 + 持仓按最后收盘计价
    assert abs(r.final_equity - (100_000 + r.trades[0].shares * 0.4)) < 1e-6


def test_flat_market_no_trades():
    r = simulate("T", bars_from_closes([100.0] * 90), scan, DEFAULTS)
    assert r.trades == []
    assert r.total_return_pct == 0.0
    assert r.max_drawdown_pct == 0.0
    assert r.exposure_pct == 0.0
    assert abs(r.buy_hold_pct) < 1e-9


def test_cash_caps_position_no_leverage():
    # riskPct=100% 时策略想买 200+ 股，但现金只够 4 股
    r = simulate("T", bars_from_closes(WIN_CLOSES), scan,
                 {**DEFAULTS, "riskPct": 100.0, "maxUnits": 1}, initial_cash=500.0)
    assert r.trades and r.trades[0].shares == 4  # floor(500/103)
    assert min(r.equity) > 0  # 全程无负现金/负权益


def test_start_date_skips_warmup_history():
    closes = [100.0] * 60 + [103, 104, 105, 106, 107, 108, 109, 110, 108, 107, 106, 105, 104]
    bars = bars_from_closes(closes, iso=True)
    cutoff = bars[65]["date"]
    r = simulate("T", bars, scan, {**DEFAULTS, "maxUnits": 1}, start_date=cutoff)
    assert r.start_date == cutoff
    # 105 之前的突破发生在回测窗口外：窗口内首日 106 已高于通道 → 仍会入场，
    # 但 buy&hold 基准从 106（cutoff 当日收盘）起算
    assert abs(r.buy_hold_pct - (104 / closes[65] - 1) * 100) < 1e-9


def test_max_drawdown_math():
    assert max_drawdown_pct([100, 120, 90, 130, 65]) == 50.0
    assert max_drawdown_pct([1, 2, 3]) == 0.0
    assert max_drawdown_pct([]) == 0.0
