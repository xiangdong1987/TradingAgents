"""Dividend / interest income tracking so cumulative return includes payouts.

The runner syncs dividends daily: for every non-ISIN position it pulls the
per-share amounts Yahoo reports in a lookback window and records one
``income`` doc per (ticker, ex-date). Doc ids are ``{ticker}_{date}`` so
re-running is idempotent.

Only dividends on or after the position was opened are recorded — the floor
is ``positions.openedAt`` when set, otherwise the earliest recorded buy for
that ticker. With neither (a holding typed in by hand, no trade history) the
lookback window is the only bound, and the row stays editable in the app.

Withholding tax is estimated per market (US 15%, Italy 26%) and stored as an
absolute amount so the app can show gross and net; every row is editable, so
the broker's actual withholding wins.

Two deliberate approximations, both visible in the stored doc:

- ``shares`` is the **current** holding, not the holding on the ex-date
  (there is no historical position ledger). The short lookback window keeps
  the drift small, and ``source: "auto"`` marks the row as an estimate.
- ``perShare`` is Yahoo's **gross** amount, before withholding tax.

Auto-synced income never touches cash — cash stays user-maintained, so a
broker-reconciled balance can't be double counted. Manually entered income
from the app credits cash, because that is a user-initiated bookkeeping act.

Single bonds (ISIN) have no Yahoo coverage: their coupons must be entered
by hand in the app.
"""
from __future__ import annotations

import logging
from datetime import datetime, timedelta

from assistant.quotes import get_dividends, is_isin
from assistant.store import utc_now_iso

logger = logging.getLogger(__name__)

LOOKBACK_DAYS = 30

# 分红税缺省。每笔都可在 App 里改，以券商实际扣缴为准；Dart 侧
# app/lib/logic/tax.dart 有一份同样的常量，改动要两边一起改。
#
# 意大利标的：只有本国 26% 替代税。
# 美股：先被美国按协定预扣 15%，剩下的再由意大利按 26% 征
#   → 综合 1 − 0.85 × 0.74 = 37.1%（意大利法定口径：26% 征在扣净额上）。
#   若券商单据是把两道税直接相加（15 + 26 = 41%），把下面的综合值改成 41.0。
TAX_PCT_US_WITHHOLDING = 15.0   # 美国预扣（协定税率）
TAX_PCT_IT = 26.0               # 意大利 imposta sostitutiva
TAX_PCT_US_TOTAL = round(
    (1 - (1 - TAX_PCT_US_WITHHOLDING / 100) * (1 - TAX_PCT_IT / 100)) * 100, 2)  # 37.1

# 卖出资本利得：意大利税务居民全球所得按 26%（亏损不计税）。
TAX_PCT_CAPITAL_GAINS = TAX_PCT_IT


def income_id(ticker: str, date: str) -> str:
    return f"{ticker}_{date}"


def default_tax_pct(ticker: str) -> float:
    """.MI 上市与 IT 开头的 ISIN 只交意大利 26%；美股是 15% 预扣 + 26% 叠加。"""
    if ticker.endswith(".MI") or (ticker.startswith("IT") and is_isin(ticker)):
        return TAX_PCT_IT
    return TAX_PCT_US_TOTAL


def opened_floor(store, ticker: str) -> str | None:
    """建仓日下限：positions.openedAt 优先，否则该标的最早的买入成交日。"""
    for pos in store.get_positions():
        if pos["ticker"] == ticker and pos.get("openedAt"):
            return str(pos["openedAt"])[:10]
    if not hasattr(store, "list_trades"):
        return None
    buys = [t.get("date") for t in store.list_trades()
            if t.get("ticker") == ticker and t.get("side") == "buy" and t.get("date")]
    return min(buys) if buys else None


def sync_dividends(store, today: str, *, fetch_dividends=get_dividends,
                   lookback_days: int = LOOKBACK_DAYS) -> int:
    """Record any newly-reported dividends for held tickers. Returns rows added."""
    start = (datetime.strptime(today, "%Y-%m-%d")
             - timedelta(days=lookback_days)).strftime("%Y-%m-%d")
    added = 0
    for pos in store.get_positions():
        ticker = pos["ticker"]
        if is_isin(ticker):
            continue  # 单券付息 Yahoo 无数据，靠 App 手工补录
        shares = float(pos.get("shares") or 0)
        if shares <= 0:
            continue
        floor = opened_floor(store, ticker)
        window_start = max(start, floor) if floor else start
        if window_start > today:
            continue  # 建仓日晚于今天（录错了），不产生记录
        try:
            divs = fetch_dividends(ticker, window_start, today)
        except Exception:
            logger.exception("dividend fetch failed for %s", ticker)
            continue
        for date, per_share in divs:
            if floor and date < floor:
                continue  # 建仓前的分红不属于你（取数源若不严格按区间过滤，这里兜住）
            if store.has_income(ticker, date):
                continue
            amount = round(per_share * shares, 4)
            tax_pct = default_tax_pct(ticker)
            store.add_income({
                "id": income_id(ticker, date),
                "ticker": ticker,
                "date": date,
                "perShare": per_share,
                "shares": shares,
                "amount": amount,                          # 税前毛额
                "taxAmount": round(amount * tax_pct / 100, 4),
                "taxPct": tax_pct,
                "source": "auto",
                "creditedCash": False,                     # 自动入账不动现金
                "createdAt": utc_now_iso(),
            })
            added += 1
            logger.info("income: %s %s %s/share × %s = %s (tax %s%%)",
                        ticker, date, per_share, shares, amount, tax_pct)
    return added
