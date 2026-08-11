from assistant.income import (TAX_PCT_IT, TAX_PCT_US_TOTAL, default_tax_pct,
                              income_id, opened_floor, sync_dividends)
from assistant.quotes import get_dividends
from assistant.store import MemoryStore


def make_store(positions=None):
    s = MemoryStore()
    s.seed_positions(positions if positions is not None else [
        {"ticker": "MSFT", "shares": 15, "avgCost": 385.0, "updatedAt": "x"},
    ])
    return s


def test_records_dividend_as_per_share_times_current_shares():
    store = make_store()
    divs = {"MSFT": [("2026-07-15", 0.83)]}
    added = sync_dividends(store, "2026-08-03",
                           fetch_dividends=lambda t, a, b: divs.get(t, []))
    assert added == 1
    row = store.list_income()[0]
    assert row["ticker"] == "MSFT"
    assert row["date"] == "2026-07-15"
    assert row["perShare"] == 0.83
    assert row["shares"] == 15
    assert row["amount"] == 12.45          # 0.83 × 15（税前毛额）
    assert row["taxPct"] == TAX_PCT_US_TOTAL   # 美股 15% 预扣 + 意 26% 叠加
    assert row["taxAmount"] == round(12.45 * TAX_PCT_US_TOTAL / 100, 4)
    assert row["creditedCash"] is False        # 自动入账不动现金
    assert row["source"] == "auto"
    assert row["id"] == income_id("MSFT", "2026-07-15")


def test_rerun_is_idempotent():
    store = make_store()
    divs = {"MSFT": [("2026-07-15", 0.83)]}
    fetch = lambda t, a, b: divs.get(t, [])          # noqa: E731
    assert sync_dividends(store, "2026-08-03", fetch_dividends=fetch) == 1
    assert sync_dividends(store, "2026-08-03", fetch_dividends=fetch) == 0
    assert len(store.list_income()) == 1


def test_isin_positions_are_skipped():
    store = make_store([
        {"ticker": "IT0005696320", "shares": 1, "avgCost": 45000.0, "updatedAt": "x"},
    ])
    calls = []

    def fetch(t, a, b):
        calls.append(t)
        return [("2026-07-15", 100.0)]

    assert sync_dividends(store, "2026-08-03", fetch_dividends=fetch) == 0
    assert calls == []                     # 单券不去问 Yahoo，等手工补录


def test_at_cost_positions_are_skipped():
    store = make_store([
        {"ticker": "CASHACC", "shares": 1, "avgCost": 5000.0, "updatedAt": "x",
         "atCost": True},
    ])
    calls = []

    def fetch(t, a, b):
        calls.append(t)
        return [("2026-07-15", 100.0)]

    assert sync_dividends(store, "2026-08-03", fetch_dividends=fetch) == 0
    assert calls == []                     # 无行情资产，不去问 Yahoo


def test_zero_share_positions_are_skipped():
    store = make_store([{"ticker": "KO", "shares": 0, "avgCost": 80.0, "updatedAt": "x"}])
    assert sync_dividends(store, "2026-08-03",
                          fetch_dividends=lambda t, a, b: [("2026-07-15", 0.5)]) == 0


def test_lookback_window_is_passed_to_the_fetcher():
    store = make_store()
    seen = {}

    def fetch(ticker, start, end):
        seen[ticker] = (start, end)
        return []

    sync_dividends(store, "2026-08-03", fetch_dividends=fetch, lookback_days=30)
    assert seen["MSFT"] == ("2026-07-04", "2026-08-03")


def test_fetch_failure_for_one_ticker_does_not_abort_the_rest():
    store = make_store([
        {"ticker": "BOOM", "shares": 1, "avgCost": 1.0, "updatedAt": "x"},
        {"ticker": "KO", "shares": 10, "avgCost": 80.0, "updatedAt": "x"},
    ])

    def fetch(ticker, start, end):
        if ticker == "BOOM":
            raise RuntimeError("network down")
        return [("2026-07-20", 0.51)]

    assert sync_dividends(store, "2026-08-03", fetch_dividends=fetch) == 1
    assert store.list_income()[0]["ticker"] == "KO"


def test_get_dividends_filters_window_and_skips_isins():
    rows = [("2026-06-01", 0.5), ("2026-07-15", 0.83), ("2026-09-01", 0.9)]
    got = get_dividends("MSFT", "2026-07-01", "2026-08-03",
                        _dividends=lambda t, a, b: [r for r in rows if a <= r[0] <= b])
    assert got == [("2026-07-15", 0.83)]
    assert get_dividends("IT0005696320", "2026-07-01", "2026-08-03",
                         _dividends=lambda t, a, b: rows) == []


def test_default_tax_pct_by_market():
    assert default_tax_pct("ENEL.MI") == TAX_PCT_IT
    assert default_tax_pct("IT0005696320") == TAX_PCT_IT
    assert default_tax_pct("MSFT") == TAX_PCT_US_TOTAL
    # 综合税率 = 1 − 0.85 × 0.74 = 37.1%
    assert TAX_PCT_US_TOTAL == 37.1


def test_dividends_before_the_open_date_are_skipped():
    store = make_store([
        {"ticker": "KO", "shares": 10, "avgCost": 80.0, "openedAt": "2026-07-01",
         "updatedAt": "x"},
    ])
    divs = [("2026-06-20", 0.5), ("2026-07-15", 0.51)]   # 一笔建仓前、一笔建仓后
    added = sync_dividends(store, "2026-08-03",
                           fetch_dividends=lambda t, a, b: [d for d in divs if a <= d[0] <= b])
    assert added == 1
    assert store.list_income()[0]["date"] == "2026-07-15"


def test_open_floor_falls_back_to_earliest_buy_trade():
    store = make_store([{"ticker": "KO", "shares": 10, "avgCost": 80.0, "updatedAt": "x"}])
    store.seed_trades([
        {"ticker": "KO", "side": "buy", "date": "2026-07-10"},
        {"ticker": "KO", "side": "buy", "date": "2026-07-25"},
        {"ticker": "KO", "side": "sell", "date": "2026-05-01"},   # 卖出不算建仓
    ])
    assert opened_floor(store, "KO") == "2026-07-10"
    divs = [("2026-07-05", 0.5), ("2026-07-20", 0.51)]
    assert sync_dividends(store, "2026-08-03",
                          fetch_dividends=lambda t, a, b: [d for d in divs if a <= d[0] <= b]) == 1
    assert store.list_income()[0]["date"] == "2026-07-20"


def test_open_date_takes_precedence_over_trades():
    store = make_store([
        {"ticker": "KO", "shares": 10, "avgCost": 80.0, "openedAt": "2026-07-20",
         "updatedAt": "x"},
    ])
    store.seed_trades([{"ticker": "KO", "side": "buy", "date": "2026-07-01"}])
    assert opened_floor(store, "KO") == "2026-07-20"


def test_no_open_date_and_no_trades_keeps_the_lookback_window():
    store = make_store([{"ticker": "KO", "shares": 10, "avgCost": 80.0, "updatedAt": "x"}])
    assert opened_floor(store, "KO") is None
    assert sync_dividends(store, "2026-08-03",
                          fetch_dividends=lambda t, a, b: [("2026-07-20", 0.5)]) == 1


def test_open_date_in_the_future_records_nothing():
    store = make_store([
        {"ticker": "KO", "shares": 10, "avgCost": 80.0, "openedAt": "2027-01-01",
         "updatedAt": "x"},
    ])
    assert sync_dividends(store, "2026-08-03",
                          fetch_dividends=lambda t, a, b: [("2026-07-20", 0.5)]) == 0


def test_backfill_fills_missing_tax_by_market():
    from assistant.income import backfill_income_tax
    store = MemoryStore()
    store.add_income({"id": "ENEL.MI_2026-07-20", "ticker": "ENEL.MI",
                      "date": "2026-07-20", "amount": 65.0, "source": "auto"})
    store.add_income({"id": "MSFT_2026-05-21", "ticker": "MSFT",
                      "date": "2026-05-21", "amount": 12.45, "source": "auto"})
    assert backfill_income_tax(store) == 2
    rows = {r["ticker"]: r for r in store.list_income()}
    assert rows["ENEL.MI"]["taxPct"] == TAX_PCT_IT
    assert rows["ENEL.MI"]["taxAmount"] == round(65.0 * 26 / 100, 4)
    assert rows["MSFT"]["taxPct"] == TAX_PCT_US_TOTAL
    assert rows["MSFT"]["taxAmount"] == round(12.45 * TAX_PCT_US_TOTAL / 100, 4)
    assert rows["ENEL.MI"]["creditedCash"] is False


def test_backfill_is_idempotent_and_respects_a_manual_zero():
    from assistant.income import backfill_income_tax
    store = MemoryStore()
    store.add_income({"id": "a", "ticker": "ENEL.MI", "date": "d", "amount": 100.0,
                      "taxAmount": 0.0, "source": "manual"})   # 用户明确填了 0
    assert backfill_income_tax(store) == 0
    assert store.list_income()[0]["taxAmount"] == 0.0

    store.add_income({"id": "b", "ticker": "ENEL.MI", "date": "d2", "amount": 50.0})
    assert backfill_income_tax(store) == 1
    assert backfill_income_tax(store) == 0        # 再跑一次不重复改


def test_german_dividend_defaults_to_us_style_tax():
    from assistant.income import default_tax_pct, TAX_PCT_US_TOTAL, TAX_PCT_IT
    assert default_tax_pct("SAP.DE") == TAX_PCT_US_TOTAL   # 37.1，非 26
    assert default_tax_pct("ENEL.MI") == TAX_PCT_IT


# ---------- 国债票息引擎 ----------

def _bond_store(**overrides):
    from assistant.store import MemoryStore
    s = MemoryStore()
    pos = {"ticker": "BTP2030", "shares": 1, "avgCost": 45000.0,
           "updatedAt": "x", "atCost": True, "assetType": "bond",
           "couponPct": 4.0, "payFreq": "semiannual",
           "maturity": "2030-03-15", "openedAt": "2026-02-01", **overrides}
    s.seed_positions([pos])
    return s


def test_coupon_dates_semiannual_backwards_from_maturity():
    from assistant.income import _coupon_dates
    # 锚点 2030-03-15 半年倒推 → …-03-15 / -09-15；区间 (2026-02-01, 2026-09-30]
    assert _coupon_dates("2030-03-15", 2, "2026-02-01", "2026-09-30") == [
        "2026-03-15", "2026-09-15"]


def test_coupon_dates_annual_and_floor_exclusive():
    from assistant.income import _coupon_dates
    # 年付；floor 恰为付息日当天 → 当天不算（严格大于）
    assert _coupon_dates("2030-03-15", 1, "2026-03-15", "2027-12-31") == [
        "2027-03-15"]


def test_coupon_dates_clamp_month_end():
    from assistant.income import _coupon_dates
    # 锚点 8-31 半年倒推到 2 月 → 夹到 2-28（平年）
    assert _coupon_dates("2027-08-31", 2, "2026-01-01", "2027-03-01") == [
        "2026-02-28", "2026-08-31", "2027-02-28"]


def test_sync_bond_coupons_creates_income_with_gov_tax():
    from assistant.income import sync_bond_coupons, TAX_PCT_IT_GOV
    s = _bond_store()
    n = sync_bond_coupons(s, "2026-09-30")
    assert n == 2                                  # 03-15 与 09-15
    rows = {r["date"]: r for r in s.list_income()}
    r = rows["2026-03-15"]
    assert r["amount"] == 900.0                    # 45000×4%÷2
    assert r["taxPct"] == TAX_PCT_IT_GOV == 12.5
    assert r["taxAmount"] == 112.5                 # 900×12.5%
    assert r["source"] == "auto" and r["creditedCash"] is False


def test_sync_bond_coupons_idempotent():
    from assistant.income import sync_bond_coupons
    s = _bond_store()
    assert sync_bond_coupons(s, "2026-09-30") == 2
    assert sync_bond_coupons(s, "2026-09-30") == 0   # 再跑不重复


def test_sync_bond_coupons_skips_incomplete_or_unknown_start():
    from assistant.income import sync_bond_coupons
    assert sync_bond_coupons(_bond_store(couponPct=None), "2026-09-30") == 0
    assert sync_bond_coupons(_bond_store(payFreq="quarterly"), "2026-09-30") == 0
    # 无 openedAt 且无买入成交 → 不猜，跳过
    assert sync_bond_coupons(_bond_store(openedAt=None), "2026-09-30") == 0


def test_sync_bond_coupons_falls_back_to_first_buy_trade():
    from assistant.income import sync_bond_coupons
    s = _bond_store(openedAt=None)
    s.seed_trades([{"ticker": "BTP2030", "side": "buy", "shares": 1,
                    "price": 45000.0, "date": "2026-02-01"}])
    assert sync_bond_coupons(s, "2026-09-30") == 2


def test_sync_bond_coupons_isolates_per_position_errors():
    from assistant.income import sync_bond_coupons
    s = MemoryStore()
    # 一次性 seed 两条位置：一条坏数据、一条好数据
    s.seed_positions([
        {"ticker": "BAD", "shares": 1, "avgCost": 1000.0, "updatedAt": "x",
         "atCost": True, "assetType": "bond", "couponPct": 3.0,
         "payFreq": "annual", "maturity": "not-a-date", "openedAt": "2026-01-01"},
        {"ticker": "BTP2030", "shares": 1, "avgCost": 45000.0,
         "updatedAt": "x", "atCost": True, "assetType": "bond",
         "couponPct": 4.0, "payFreq": "semiannual",
         "maturity": "2030-03-15", "openedAt": "2026-02-01"},
    ])
    assert sync_bond_coupons(s, "2026-09-30") == 2

    # 股票持仓完全不受影响
    s2 = _bond_store(assetType=None)
    assert sync_bond_coupons(s2, "2026-09-30") == 0
