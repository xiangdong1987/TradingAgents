"""海龟策略（完整双系统），纯函数实现。

经典规则到「手动持仓」的映射见 docs/superpowers/specs/2026-08-01-strategy-framework-turtle-design.md：

- N = 20 日 Wilder ATR；通道用前 n 根的最高/最低价，触发用当日收盘
- S1: 20 日突破入场（受「上次盈利跳过」过滤器约束）/ 10 日反向突破退出
- S2: 55 日突破入场（无过滤器）/ 20 日反向突破退出
- 单元 = riskPct% × 组合值 ÷ 2N 股；½N 顺势加仓至 maxUnits；收盘破最新单元
  entry−2N 止损清仓
- 同一标的单次扫描只出最高优先级一条：止损 > 退出 > 加仓 > 入场
"""
from __future__ import annotations

import math

from assistant.strategies import ScanContext, Signal, Strategy, register

DEFAULTS = {
    "riskPct": 1.0,
    "maxUnits": 4,
    "atrPeriod": 20,
    "s1": {"entry": 20, "exit": 10, "filter": True},
    "s2": {"entry": 55, "exit": 20},
}


# ---------------------------------------------------------------------------
# 指标
# ---------------------------------------------------------------------------

def wilder_atr(bars: list[dict], period: int = 20) -> float | None:
    """Wilder 平滑 ATR；bars 不足 period+1 根时返回 None。"""
    if len(bars) < period + 1:
        return None
    trs = []
    for i in range(1, len(bars)):
        h, low, prev_close = bars[i]["high"], bars[i]["low"], bars[i - 1]["close"]
        trs.append(max(h - low, abs(h - prev_close), abs(low - prev_close)))
    atr = sum(trs[:period]) / period
    for tr in trs[period:]:
        atr = (atr * (period - 1) + tr) / period
    return atr


def channel_high(bars: list[dict], n: int, end: int) -> float | None:
    """bars[end] 之前 n 根的最高价（不含 bars[end] 自身）。"""
    lo = end - n
    if lo < 0:
        return None
    return max(b["high"] for b in bars[lo:end])


def channel_low(bars: list[dict], n: int, end: int) -> float | None:
    lo = end - n
    if lo < 0:
        return None
    return min(b["low"] for b in bars[lo:end])


# ---------------------------------------------------------------------------
# S1 盈利过滤器：上一次 S1 突破信号是赢是输（纯历史推演，与是否实际交易无关）
# ---------------------------------------------------------------------------

def last_s1_breakout_won(bars: list[dict], *, entry_n: int, exit_n: int,
                         atr_period: int, before: int) -> bool | None:
    """向前找 bars[before] 之前最近一次 S1 突破，模拟其结局。

    输（可入场下一次 S1）：入场后收盘先触 entry−2N。
    赢（跳过下一次 S1）：先走到 10 日反向突破退出而未触 2N 止损。
    找不到历史突破或结局未走完 → None（视作无过滤，允许入场）。

    「突破信号」指首次上穿：当日收盘 > 通道且前一日收盘 ≤ 前一日通道——
    趋势延续中每天都高于通道，但那是同一笔交易，不是新信号。
    """
    for i in range(before - 1, atr_period, -1):
        ch = channel_high(bars, entry_n, i)
        if ch is None:
            return None
        if bars[i]["close"] <= ch:
            continue
        prev_ch = channel_high(bars, entry_n, i - 1)
        if prev_ch is not None and bars[i - 1]["close"] > prev_ch:
            continue  # 前一日已在通道上方：趋势延续日，不是新信号
        # bars[i] 是上一次 S1 突破信号日
        n = wilder_atr(bars[: i + 1], atr_period)
        if n is None:
            return None
        entry = bars[i]["close"]
        stop = entry - 2 * n
        for j in range(i + 1, before):
            if bars[j]["close"] <= stop:
                return False  # 先止损 → 输
            exit_ch = channel_low(bars, exit_n, j)
            if exit_ch is not None and bars[j]["close"] < exit_ch:
                return True  # 先到反向突破退出 → 赢
        return None  # 到今天还没走完结局
    return None


# ---------------------------------------------------------------------------
# 信号扫描
# ---------------------------------------------------------------------------

def _merged(params: dict) -> dict:
    out = {**DEFAULTS, **params}
    out["s1"] = {**DEFAULTS["s1"], **(params.get("s1") or {})}
    out["s2"] = {**DEFAULTS["s2"], **(params.get("s2") or {})}
    return out


def unit_shares(portfolio_value: float, risk_pct: float, n: float) -> int:
    """1 个单元的股数 = 组合值 × riskPct% ÷ 2N，向下取整。"""
    if n <= 0 or portfolio_value <= 0:
        return 0
    return math.floor(portfolio_value * risk_pct / 100 / (2 * n))


def _fmt(v: float) -> str:
    return f"{v:.2f}" if v >= 1 else f"{v:.4f}"


def scan(ctx: ScanContext) -> list[Signal]:
    p = _merged(ctx.params)
    bars = ctx.bars
    warmup = max(p["s2"]["entry"], p["atrPeriod"] + 1)
    if len(bars) < warmup + 1:
        return []
    n = wilder_atr(bars, p["atrPeriod"])
    if n is None or n <= 0:
        return []
    last = len(bars) - 1
    close = bars[last]["close"]

    if ctx.units:
        return _scan_held(ctx, p, n, close, last)
    return _scan_entry(ctx, p, n, close, last)


def _scan_held(ctx: ScanContext, p: dict, n: float, close: float, last: int) -> list[Signal]:
    unit = ctx.units[-1]
    entry = unit["entry"]
    unit_n = unit.get("n") or n  # 老持仓种子单元没有入场时的 N，用当前 N 近似
    system = unit.get("system") or "s1"
    sys_cfg = p["s2"] if system == "s2" else p["s1"]

    # 1) 2N 止损
    stop_level = entry - 2 * unit_n
    if close <= stop_level:
        return [Signal(
            action="sell", price=close,
            reason=f"海龟止损：收盘 {_fmt(close)} 跌破最新单元入场价 {_fmt(entry)} − 2N"
                   f"（N={_fmt(unit_n)}，止损位 {_fmt(stop_level)}），建议清仓。",
            reason_en=f"Turtle stop: close {_fmt(close)} fell below latest unit entry "
                      f"{_fmt(entry)} − 2N (N={_fmt(unit_n)}, stop {_fmt(stop_level)}); "
                      f"exit the full position.",
            meta={"system": system, "n": round(n, 4), "trigger": "stop"},
        )]

    # 2) 反向突破退出
    exit_ch = channel_low(ctx.bars, sys_cfg["exit"], last)
    if exit_ch is not None and close < exit_ch:
        return [Signal(
            action="sell", price=close,
            reason=f"海龟退出（{system.upper()}）：收盘 {_fmt(close)} 跌破 "
                   f"{sys_cfg['exit']} 日低点 {_fmt(exit_ch)}，趋势结束，建议清仓。",
            reason_en=f"Turtle exit ({system.upper()}): close {_fmt(close)} broke below the "
                      f"{sys_cfg['exit']}-day low {_fmt(exit_ch)}; trend over, exit the position.",
            meta={"system": system, "n": round(n, 4), "trigger": "exit",
                  "channel": round(exit_ch, 4)},
        )]

    # 3) ½N 金字塔加仓
    if len(ctx.units) < p["maxUnits"] and close >= entry + 0.5 * unit_n:
        shares = unit_shares(ctx.portfolio_value, p["riskPct"], n)
        if shares >= 1:
            stop = close - 2 * n
            return [Signal(
                action="add", price=close, shares=shares, stop=stop,
                reason=f"海龟加仓（第 {len(ctx.units) + 1}/{p['maxUnits']} 单元）：价格自上一"
                       f"单元 {_fmt(entry)} 上行超 ½N，按 {p['riskPct']}% 风险建议加"
                       f" {shares} 股，止损上移至 {_fmt(stop)}（本单元 entry−2N）。",
                reason_en=f"Turtle pyramid (unit {len(ctx.units) + 1}/{p['maxUnits']}): price up "
                          f"over ½N from last unit {_fmt(entry)}; add {shares} shares at "
                          f"{p['riskPct']}% risk, stop raised to {_fmt(stop)} (unit entry − 2N).",
                meta={"system": system, "n": round(n, 4), "trigger": "pyramid",
                      "entry": round(close, 4)},
            )]
    return []


def _scan_entry(ctx: ScanContext, p: dict, n: float, close: float, last: int) -> list[Signal]:
    shares = unit_shares(ctx.portfolio_value, p["riskPct"], n)
    if shares < 1:
        return []  # 组合太小，1% 风险买不起 1 股
    stop = close - 2 * n

    def buy(system: str, entry_n: int, ch: float) -> Signal:
        return Signal(
            action="buy", price=close, shares=shares, stop=stop,
            reason=f"海龟入场（{system.upper()}）：收盘 {_fmt(close)} 突破 {entry_n} 日"
                   f"高点 {_fmt(ch)}。N={_fmt(n)}，按 {p['riskPct']}% 风险建议买入"
                   f" {shares} 股，止损 {_fmt(stop)}（entry−2N）。",
            reason_en=f"Turtle entry ({system.upper()}): close {_fmt(close)} broke above the "
                      f"{entry_n}-day high {_fmt(ch)}. N={_fmt(n)}; buy {shares} shares at "
                      f"{p['riskPct']}% risk, stop {_fmt(stop)} (entry − 2N).",
            meta={"system": system, "n": round(n, 4), "trigger": "breakout",
                  "channel": round(ch, 4), "entry": round(close, 4)},
        )

    ch55 = channel_high(ctx.bars, p["s2"]["entry"], last)
    if ch55 is not None and close > ch55:
        return [buy("s2", p["s2"]["entry"], ch55)]

    ch20 = channel_high(ctx.bars, p["s1"]["entry"], last)
    if ch20 is not None and close > ch20:
        if p["s1"].get("filter", True):
            won = last_s1_breakout_won(
                ctx.bars, entry_n=p["s1"]["entry"], exit_n=p["s1"]["exit"],
                atr_period=p["atrPeriod"], before=last)
            if won is True:
                return []  # 上一次 S1 是赢的 → 本次跳过（等 55 日保险突破）
        return [buy("s1", p["s1"]["entry"], ch20)]
    return []


register(Strategy(name="turtle", label="海龟(双系统)", defaults=DEFAULTS, scan=scan))
