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

TAX_PCT_IT_GOV = 12.5   # 意大利国债/政府债票息优惠税率（≠26%）


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


def backfill_income_tax(store) -> int:
    """给缺税额的历史 income 行补上（按标的缺省税率）。返回补齐的行数。

    税字段是后加的，早先入库的行没有 ``taxAmount``；而 :func:`sync_dividends`
    靠 ``has_income`` 去重，永远不会回头改它们。所以每轮同步顺带扫一遍自愈，
    schema 以后再扩字段也走同一条路。已有税额（包括手工填的 0）不动。
    """
    fixed = 0
    for row in store.list_income():
        if row.get("taxAmount") is not None:
            continue
        ticker = row.get("ticker") or ""
        amount = float(row.get("amount") or 0)
        pct = default_tax_pct(ticker)
        store.merge_income_fields(row["id"], {
            "taxAmount": round(amount * pct / 100, 4),
            "taxPct": pct,
            # 早先的自动行没记这个标记；自动入账从不动现金
            "creditedCash": bool(row.get("creditedCash")),
        })
        fixed += 1
        logger.info("income tax backfilled: %s %s %s × %s%%",
                    ticker, row.get("date"), amount, pct)
    return fixed


def sync_dividends(store, today: str, *, fetch_dividends=get_dividends,
                   lookback_days: int = LOOKBACK_DAYS) -> int:
    """Record any newly-reported dividends for held tickers. Returns rows added."""
    start = (datetime.strptime(today, "%Y-%m-%d")
             - timedelta(days=lookback_days)).strftime("%Y-%m-%d")
    added = 0
    for pos in store.get_positions():
        ticker = pos["ticker"]
        if is_isin(ticker) or pos.get("atCost"):
            continue  # 单券付息 Yahoo 无数据靠手工补录；atCost 无行情资产同理没有分红
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


def _coupon_dates(maturity: str, per_year: int, floor: str, today: str) -> list[str]:
    """付息日历：从到期日按频率倒推，取 (floor, today] 区间内的日期（升序）。

    锚定到期日是国债惯例（BTP 半年付 = 到期月/日 ±6 个月）。锚定**日号**
    单独保存、每期对目标月重新夹紧——若先夹紧再倒推，8-31 夹到 2-28 后
    下一期会错成 8-28。floor 是买入日，严格大于——买入当天的付息属于前手。
    """
    from calendar import monthrange
    step = 12 // per_year
    y, m, anchor_day = (int(x) for x in maturity.split("-"))
    dates = []
    while True:
        d = min(anchor_day, monthrange(y, m)[1])
        cur = f"{y:04d}-{m:02d}-{d:02d}"
        if cur <= floor:
            break
        if cur <= today:
            dates.append(cur)
        m -= step
        while m <= 0:
            m += 12
            y -= 1
    return sorted(dates)


def sync_bond_coupons(store, today: str) -> int:
    """国债票息自动入账：按付息日历补齐 (买入日, 今天] 的利息记录。

    幂等（income id = ticker_日期，与分红同一套路）；单券异常只跳过该券。
    利息按投入金额近似面值（spec 写死的简化），税 12.5%。
    """
    added = 0
    for pos in store.get_positions():
        try:
            if pos.get("assetType") != "bond":
                continue
            coupon = pos.get("couponPct")
            maturity = pos.get("maturity")
            freq = pos.get("payFreq")
            if not coupon or not maturity or freq not in ("annual", "semiannual"):
                continue
            ticker = pos["ticker"]
            floor = pos.get("openedAt") or opened_floor(store, ticker)
            if not floor:
                continue    # 不知道从哪天起算，宁可不记
            per_year = 2 if freq == "semiannual" else 1
            base = float(pos.get("avgCost") or 0.0)
            if base <= 0:
                continue
            for d in _coupon_dates(maturity, per_year, floor, today):
                # 写入/查重与 sync_dividends 完全同套路（income id、字段形状）
                income_id_str = f"{ticker}_{d}"
                if store.has_income(ticker, d):
                    continue
                amount = round(base * float(coupon) / 100 / per_year, 2)
                store.add_income({
                    "id": income_id_str,
                    "ticker": ticker, "date": d, "amount": amount,
                    "taxPct": TAX_PCT_IT_GOV,
                    "taxAmount": round(amount * TAX_PCT_IT_GOV / 100, 2),
                    "source": "auto", "note": "国债票息",
                    "creditedCash": False, "createdAt": utc_now_iso(),
                })
                added += 1
        except Exception:
            logger.exception("bond coupon sync failed for %s", pos.get("ticker"))
    return added
