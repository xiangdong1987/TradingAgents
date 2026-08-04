"""Policy 层纯函数测试：EUR 快照、六道买入闸、钳制与风险定股数。"""
import pytest

from assistant.policy import (
    DEFAULTS,
    check_buy,
    clamp_target_weight,
    funding_candidates,
    is_eur_listing,
    layer_of,
    merged,
    risk_shares,
    snapshot,
    usd_exposure_pct_of,
)

RATE = 1.25   # 1 EUR = 1.25 USD

# 简化组合：欧股 €4000（卫星）+ 美股 $2500→€2000（卫星）+ 现金 €4000 = €10000
POSITIONS = [
    {"ticker": "ENEL.MI", "shares": 400, "avgCost": 9.0},
    {"ticker": "MSFT", "shares": 10, "avgCost": 200.0},
]
QUOTES = {
    "ENEL.MI": {"close": 10.0},
    "MSFT": {"close": 250.0},
    "EURUSD=X": {"close": RATE},
}


def snap(positions=None, cash=4000.0, currency="EUR", quotes=None, cfg=None):
    return snapshot(positions if positions is not None else POSITIONS,
                    cash, currency, quotes or QUOTES, cfg)


# --- 分类与配置 ---------------------------------------------------------------

def test_merged_deep_merges_nested_dicts():
    p = merged({"cashFloorPct": 10, "layers": {"core": [20, 40]}})
    assert p["cashFloorPct"] == 10
    assert p["layers"]["core"] == [20, 40]
    assert p["layers"]["satellite"] == DEFAULTS["layers"]["satellite"]  # 未覆盖的保留


def test_eur_listing_and_layer_inference():
    assert is_eur_listing("ENEL.MI") and is_eur_listing("IT0005696320")
    assert not is_eur_listing("MSFT")
    p = merged(None)
    assert layer_of("IT0005696320", None, p) == "defensive"   # ISIN → 防守
    assert layer_of("VUAA.MI", None, p) == "core"             # layerMap
    assert layer_of("MSFT", None, p) == "satellite"           # 缺省个股
    # 持仓文档里的 layer 优先
    assert layer_of("MSFT", {"layer": "core"}, p) == "core"


def test_usd_lookthrough_catches_eur_listed_us_index():
    p = merged(None)
    assert usd_exposure_pct_of("VUAA.MI", p) == 100.0   # 欧元计价但底层美股
    assert usd_exposure_pct_of("ENEL.MI", p) == 0.0
    assert usd_exposure_pct_of("MSFT", p) == 100.0


# --- 快照 --------------------------------------------------------------------

def test_snapshot_converts_to_eur():
    s = snap()
    assert s.cash_eur == 4000
    assert s.value_of("ENEL.MI") == pytest.approx(4000)
    assert s.value_of("MSFT") == pytest.approx(2000)     # $2500 / 1.25
    assert s.total_eur == pytest.approx(10000)
    assert s.usd_exposure_eur() == pytest.approx(2000)   # 只有 MSFT
    assert s.layer_eur("satellite") == pytest.approx(6000)


def test_snapshot_none_without_fx_when_usd_present():
    assert snap(quotes={"ENEL.MI": {"close": 10.0}}) is None
    # 纯欧元组合缺汇率也能算
    s = snap(positions=[POSITIONS[0]], quotes={"ENEL.MI": {"close": 10.0}})
    assert s is not None and s.total_eur == pytest.approx(8000)


def test_liquid_base_excludes_hold_to_maturity():
    s = snap(positions=POSITIONS + [{"ticker": "IT0005696320", "shares": 1,
                                     "avgCost": 45000.0}],
             cfg={"riskBase": "liquid"})
    assert s.total_eur == pytest.approx(55000)
    assert s.liquid_eur == pytest.approx(10000)      # BTP 被剔除
    assert s.risk_base_eur() == pytest.approx(10000)


def test_native_conversion_roundtrip():
    s = snap()
    assert s.to_native("ENEL.MI", 100) == pytest.approx(100)
    assert s.to_native("MSFT", 100) == pytest.approx(125)


# --- 买入闸 ------------------------------------------------------------------

def test_single_stock_cap_clamps_shares():
    # 总值 €10000，单票上限 8% = €800；ENEL 已有 €4000 → 无额度
    v = check_buy(snap(), "ENEL.MI", shares=100, price_native=10.0)
    assert v.blocked and v.binding in ("single", "satellite")


def test_fresh_satellite_buy_is_clamped_to_the_per_name_cap():
    # 空仓起步：现金 €10000 全部可用，单票上限 8% = €800 → 80 股 @ €10
    s = snap(positions=[], cash=10000.0)
    v = check_buy(s, "KO.MI", shares=500, price_native=10.0)
    assert v.binding == "single"
    assert v.allowed_shares == 80
    assert v.clamped and not v.blocked
    assert "单票上限" in v.reason and "per-name cap" in v.reason_en


# 放开其余五道闸，用来隔离出单独一道进行断言（基准组合的卫星层本身已超限，
# 不放开的话 min() 永远选中它）。
LOOSE = {"cashFloorPct": 0, "maxSingleStockPct": 100, "maxSingleFundPct": 100,
         "maxSatellitePct": 100, "maxUsdExposurePct": 100, "maxTotalRiskPct": 100,
         "maxSingleIssuerPct": 100}


def test_cash_floor_blocks_when_no_buffer_left():
    # 现金 0：只留现金闸生效，任何买入都过不了
    s = snap(cash=0.0, cfg={**LOOSE, "cashFloorPct": 5})
    v = check_buy(s, "KO", shares=1, price_native=10.0)
    assert v.blocked and v.binding == "cash"
    assert "腾挪" in v.reason or "存量重排" in v.reason


def test_usd_exposure_binds_for_eur_listed_us_index():
    # 组合 €10000，美元敞口上限 25% = €2500，已用 €2000（MSFT）→ 还剩 €500。
    # VUAA.MI 是欧元计价但底层 100% 美股，正是货币口径会漏、经济口径才拦得住的情形。
    s = snap(cfg={**LOOSE, "maxUsdExposurePct": 25})
    v = check_buy(s, "VUAA.MI", shares=1000, price_native=1.0)
    assert v.binding == "usd"
    assert v.allowed_shares == 500      # €500 / €1


def test_issuer_cap_applies_to_new_bonds_but_whitelist_is_exempt():
    p = {"cashFloorPct": 0, "maxSingleIssuerPct": 10}
    s = snap(cash=10000.0, positions=[], cfg=p)
    # 新券：上限 10% × €10000 = €1000
    v = check_buy(s, "IT0009999999", shares=100, price_native=50.0)
    assert v.binding == "issuer" and v.allowed_shares == 20
    # 白名单存量豁免 → 不受发行人闸约束（改由其他闸决定）
    v2 = check_buy(s, "IT0005696320", shares=1, price_native=100.0)
    assert v2.binding != "issuer"


def test_risk_budget_binds_when_satellite_already_loaded():
    # 卫星 €6000 × 8% 兜底止损 = €480 已用；上限 5% × €10000 = €500 → 剩 €20。
    # 这笔止损 10% → 允许名义 €200 = 200 股 @ €1
    s = snap(cfg={**LOOSE, "maxTotalRiskPct": 5})
    v = check_buy(s, "NEW.MI", shares=1000, price_native=1.0, stop_native=0.9)
    assert v.binding == "risk"
    assert v.allowed_shares == 200


def test_tightest_gate_wins_when_several_bind():
    """基准组合里卫星层 60% 超 15% 上限，是最紧的一道——不放开时它必须胜出。"""
    v = check_buy(snap(), "KO.MI", shares=10, price_native=10.0)
    assert v.blocked and v.binding == "satellite"


def test_unconstrained_buy_passes_clean():
    p = {"cashFloorPct": 0, "maxSingleStockPct": 100, "maxSatellitePct": 100,
         "maxUsdExposurePct": 100, "maxTotalRiskPct": 100}
    s = snap(cash=10000.0, positions=[], cfg=p)
    v = check_buy(s, "KO.MI", shares=10, price_native=10.0)
    assert not v.blocked and not v.clamped
    assert v.allowed_shares == 10 and v.binding is None and v.reason == ""


def test_invalid_input_is_blocked():
    assert check_buy(snap(), "KO", shares=0, price_native=10.0).blocked
    assert check_buy(snap(), "KO", shares=10, price_native=0).blocked


# --- 资金来源梯队 -------------------------------------------------------------

def test_funding_candidates_prefers_over_cap_holdings():
    # ENEL €4000 = 40% 远超单票 8% → 第一梯队
    assert "ENEL.MI" in funding_candidates(snap())


def test_funding_candidates_falls_back_to_heavy_layers():
    # 都在上限内，但防守层占比高于区间中值 → 给出该层最大的一只
    s = snap(positions=[{"ticker": "IT0005696320", "shares": 1, "avgCost": 8000.0}],
             cash=2000.0, cfg={"maxSingleFundPct": 100})
    assert funding_candidates(s) == ["IT0005696320"]


# --- advisor 侧 --------------------------------------------------------------

def test_clamp_target_weight_to_layer_cap():
    s = snap()
    assert clamp_target_weight(s, "MSFT", 30) == 8.0        # 个股上限
    assert clamp_target_weight(s, "VUAA.MI", 30) == 25.0    # 基金上限
    assert clamp_target_weight(s, "MSFT", 5) == 5.0         # 界内不动
    assert clamp_target_weight(s, "MSFT", None) is None
    assert clamp_target_weight(s, "MSFT", -3) == 0.0


def test_risk_shares_uses_native_currency_dimensions():
    s = snap()
    # 预算 = €10000 × 1% = €100 → 折 $125；每股风险 $250−$225 = $25 → 5 股
    assert risk_shares(s, "MSFT", 250.0, 225.0) == 5
    # 欧元标的不折算：€100 ÷ €1 = 100 股
    assert risk_shares(s, "ENEL.MI", 10.0, 9.0) == 100


def test_risk_shares_falls_back_to_default_stop():
    s = snap()
    # 无止损 → 用 8% 兜底：每股风险 €0.8，预算 €100 → 125 股
    assert risk_shares(s, "ENEL.MI", 10.0, None) == 125
    # 止损高于入场（录错）同样走兜底
    assert risk_shares(s, "ENEL.MI", 10.0, 11.0) == 125
