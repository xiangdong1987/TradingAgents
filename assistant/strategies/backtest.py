"""策略回测：把历史日线逐日重放给策略的 scan()，模拟纪律执行。

与实盘扫描共用同一套策略代码（turtle.scan 等），所以回测的就是线上会跑的逻辑。

模拟假设（保持与实盘扫描一致的口径，结果偏保守口径）：
- 信号当日收盘价成交（实盘也是收盘触发）；无滑点、无手续费
- 每条信号都立即执行（回测衡量的是「纪律执行」的策略本身）
- buy/add 股数按策略给的 1% 风险单元，但以可用现金封顶（不加杠杆）
- 每只标的独立一份初始资金，互不占用（单标的视角，非组合级回测）

用法::

    python -m assistant.strategies.backtest turtle AAPL MSFT --start 2023-01-01
    python -m assistant.strategies.backtest turtle watchlist --cash 50000
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field

from assistant.strategies import REGISTRY, ScanContext

WARMUP_EXTRA_CALENDAR_DAYS = 150  # start 前多取的历史，喂饱 55 日通道 + ATR


@dataclass
class Trade:
    """一个回合（首个 buy 到 sell 清仓；exit_date=None 表示期末仍持仓）。"""
    entry_date: str
    exit_date: str | None
    n_units: int
    shares: float
    cost: float
    proceeds: float  # 未平仓时为期末市值

    @property
    def pnl(self) -> float:
        return self.proceeds - self.cost

    @property
    def pnl_pct(self) -> float:
        return self.pnl / self.cost * 100 if self.cost else 0.0

    @property
    def is_open(self) -> bool:
        return self.exit_date is None


@dataclass
class BacktestResult:
    ticker: str
    start_date: str
    end_date: str
    initial_cash: float
    dates: list[str] = field(default_factory=list)
    equity: list[float] = field(default_factory=list)
    trades: list[Trade] = field(default_factory=list)
    days_in_market: int = 0
    buy_hold_pct: float = 0.0

    @property
    def final_equity(self) -> float:
        return self.equity[-1] if self.equity else self.initial_cash

    @property
    def total_return_pct(self) -> float:
        return (self.final_equity / self.initial_cash - 1) * 100

    @property
    def cagr_pct(self) -> float:
        n = len(self.equity)
        if n < 2 or self.final_equity <= 0:
            return 0.0
        return ((self.final_equity / self.initial_cash) ** (252 / n) - 1) * 100

    @property
    def max_drawdown_pct(self) -> float:
        return max_drawdown_pct(self.equity)

    @property
    def exposure_pct(self) -> float:
        return self.days_in_market / len(self.equity) * 100 if self.equity else 0.0

    @property
    def closed_trades(self) -> list[Trade]:
        return [t for t in self.trades if not t.is_open]

    @property
    def win_rate_pct(self) -> float | None:
        closed = self.closed_trades
        if not closed:
            return None
        return sum(1 for t in closed if t.pnl > 0) / len(closed) * 100


def max_drawdown_pct(equity: list[float]) -> float:
    """峰值回撤（正数百分比）；空/单点曲线为 0。"""
    peak, worst = float("-inf"), 0.0
    for v in equity:
        peak = max(peak, v)
        if peak > 0:
            worst = max(worst, (peak - v) / peak * 100)
    return worst


def default_warmup_bars(params: dict) -> int:
    s2 = (params.get("s2") or {}).get("entry", 55)
    atr = params.get("atrPeriod", 20)
    return max(s2, atr + 1) + 2


def simulate(ticker: str, bars: list[dict], scan, params: dict, *,
             initial_cash: float = 100_000.0, start_date: str | None = None) -> BacktestResult:
    """逐日重放 ``scan``。bars 升序 OHLC；start_date 之前的 bars 只作暖机数据。"""
    warmup = default_warmup_bars(params)
    start_index = warmup
    if start_date:
        first_at_or_after = next(
            (i for i, b in enumerate(bars) if b["date"] >= start_date), len(bars))
        start_index = max(warmup, first_at_or_after)
    if start_index >= len(bars):
        return BacktestResult(ticker=ticker, start_date=start_date or "", end_date="",
                              initial_cash=initial_cash)

    result = BacktestResult(
        ticker=ticker,
        start_date=bars[start_index]["date"],
        end_date=bars[-1]["date"],
        initial_cash=initial_cash,
        buy_hold_pct=(bars[-1]["close"] / bars[start_index]["close"] - 1) * 100,
    )

    cash = initial_cash
    units: list[dict] = []
    entry_date: str | None = None
    open_cost = 0.0

    for i in range(start_index, len(bars)):
        today = bars[i]
        close, date = today["close"], today["date"]
        held_shares = sum(u["shares"] for u in units)
        ctx = ScanContext(ticker=ticker, bars=bars[: i + 1], position=None,
                          units=list(units), portfolio_value=cash + held_shares * close,
                          cash=cash, params=params)
        for sig in scan(ctx):
            if sig.action in ("buy", "add"):
                shares = min(sig.shares or 0, math.floor(cash / close) if close > 0 else 0)
                if shares < 1:
                    continue
                cash -= shares * close
                units.append({"entry": close, "shares": shares,
                              "system": sig.meta.get("system", "s1"),
                              "n": sig.meta.get("n")})
                open_cost += shares * close
                entry_date = entry_date or date
            elif sig.action in ("sell", "trim") and units:
                held = sum(u["shares"] for u in units)
                proceeds = held * close
                cash += proceeds
                result.trades.append(Trade(entry_date=entry_date or date, exit_date=date,
                                           n_units=len(units), shares=held,
                                           cost=open_cost, proceeds=proceeds))
                units, open_cost, entry_date = [], 0.0, None

        held_shares = sum(u["shares"] for u in units)
        if held_shares:
            result.days_in_market += 1
        result.dates.append(date)
        result.equity.append(cash + held_shares * close)

    if units:  # 期末未平仓：按最后收盘计市值，标记为 open
        held = sum(u["shares"] for u in units)
        result.trades.append(Trade(entry_date=entry_date or result.end_date, exit_date=None,
                                   n_units=len(units), shares=held, cost=open_cost,
                                   proceeds=held * bars[-1]["close"]))
    return result


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _expand_tickers(words: list[str]) -> list[str]:
    """AAPL MSFT / watchlist / positions → 具体 ticker 列表（跳过 ISIN）。"""
    from assistant.quotes import is_isin

    out: list[str] = []
    for w in words:
        if w in ("watchlist", "positions"):
            from assistant.store import FirestoreStore
            store = FirestoreStore.connect()
            docs = store.get_watchlist() if w == "watchlist" else store.get_positions()
            out += [d["ticker"] for d in docs]
        else:
            out.append(w.upper() if w.islower() else w)
    return [t for t in dict.fromkeys(out) if not is_isin(t)]


def _live_params(strategy: str) -> dict:
    """尽力读线上 meta/strategies 的参数（读不到就用策略缺省）。"""
    try:
        from assistant.store import FirestoreStore
        cfg = FirestoreStore.connect().get_strategy_config()
        return (cfg.get(strategy) or {}).get("params") or {}
    except Exception:
        return {}


def _fmt_pct(v: float | None) -> str:
    return "—" if v is None else f"{v:+.1f}%"


def report(r: BacktestResult) -> str:
    lines = [
        f"== {r.ticker}  {r.start_date} → {r.end_date}  初始资金 {r.initial_cash:,.0f}",
        f"   策略收益 {_fmt_pct(r.total_return_pct)}（年化 {_fmt_pct(r.cagr_pct)}）"
        f"   买入持有 {_fmt_pct(r.buy_hold_pct)}",
        f"   最大回撤 -{r.max_drawdown_pct:.1f}%   在场比例 {r.exposure_pct:.0f}%"
        f"   交易 {len(r.closed_trades)} 回合   胜率 "
        + ("—" if r.win_rate_pct is None else f"{r.win_rate_pct:.0f}%"),
    ]
    for t in r.trades:
        tag = "未平仓" if t.is_open else t.exit_date
        lines.append(f"     {t.entry_date} → {tag}  {_fmt_pct(t.pnl_pct)}"
                     f"  （{t.n_units} 单元 {t.shares:.0f} 股）")
    if not r.trades:
        lines.append("     （区间内无交易信号）")
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    import argparse
    from datetime import datetime, timedelta

    parser = argparse.ArgumentParser(
        prog="assistant.strategies.backtest",
        description="逐日重放策略信号的历史回测（与实盘扫描共用策略代码）")
    parser.add_argument("strategy", help=f"策略名：{', '.join(sorted(REGISTRY))}")
    parser.add_argument("tickers", nargs="+",
                        help="ticker 列表，或 watchlist / positions（读 Firestore）")
    parser.add_argument("--start", default=None, help="回测起始日 YYYY-MM-DD（默认 3 年前）")
    parser.add_argument("--end", default=None, help="回测截止日（默认今天）")
    parser.add_argument("--cash", type=float, default=100_000.0, help="每只标的的初始资金")
    args = parser.parse_args(argv)

    if args.strategy not in REGISTRY:
        parser.error(f"unknown strategy: {args.strategy}")
    strat = REGISTRY[args.strategy]
    params = {**strat.defaults, **_live_params(args.strategy)}

    end = args.end or datetime.utcnow().strftime("%Y-%m-%d")
    start = args.start or (datetime.strptime(end, "%Y-%m-%d")
                           - timedelta(days=3 * 365)).strftime("%Y-%m-%d")
    fetch_days = (datetime.strptime(end, "%Y-%m-%d")
                  - datetime.strptime(start, "%Y-%m-%d")).days + WARMUP_EXTRA_CALENDAR_DAYS

    from assistant.quotes import get_ohlc_history

    tickers = _expand_tickers(args.tickers)
    if not tickers:
        print("没有可回测的标的")
        return 1

    print(f"策略 {args.strategy}（{strat.label}）  参数覆盖: {_live_params(args.strategy) or '无（全缺省）'}")
    results: list[BacktestResult] = []
    for t in tickers:
        try:
            bars = get_ohlc_history(t, end, days=fetch_days)
        except Exception as exc:
            print(f"== {t}  行情获取失败：{exc}")
            continue
        if len(bars) <= default_warmup_bars(params):
            print(f"== {t}  历史数据不足（{len(bars)} 根），跳过")
            continue
        r = simulate(t, bars, strat.scan, params,
                     initial_cash=args.cash, start_date=start)
        results.append(r)
        print(report(r))

    if len(results) > 1:
        avg = sum(r.total_return_pct for r in results) / len(results)
        avg_bh = sum(r.buy_hold_pct for r in results) / len(results)
        beat = sum(1 for r in results if r.total_return_pct > r.buy_hold_pct)
        print(f"\n共 {len(results)} 只：平均策略收益 {_fmt_pct(avg)} vs 买入持有 {_fmt_pct(avg_bh)}，"
              f"跑赢 {beat}/{len(results)} 只")
    return 0


if __name__ == "__main__":
    import sys

    raise SystemExit(main(sys.argv[1:]))
