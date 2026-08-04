"""组合级仓位管理策略层（纯函数）。

设计见 docs/superpowers/specs/2026-08-02-position-management-policy.md。所有
买入建议——不论来自 advisor 还是规则策略——都要过这里的闸，避免单只标的、
卫星总量、美元敞口或现金缓冲被某一路信号单独突破。

口径统一在 EUR：`snapshot()` 把持仓折成一张 EUR 快照，闸门全部按 EUR 判定；
返回给调用方的股数上限再折回标的原币。汇率取日报 quotes 的 `EURUSD=X`，
缺汇率且组合里有美元标的时快照为 None（调用方据此跳过闸门而不是给错数）。

这一层只做算术与规则，不读写 Firestore、不调 LLM，便于单测。
"""
from __future__ import annotations

import logging
import math
from dataclasses import dataclass, field

from assistant.quotes import is_isin

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# 缺省参数（可被 Firestore meta/policy 覆盖）
# ---------------------------------------------------------------------------

DEFAULTS: dict = {
    "cashFloorPct": 5.0,          # 成交后现金不得低于组合的这个比例
    "riskPerTradePct": 1.0,       # 单笔风险预算（用于风险定股数）
    "riskBase": "total",          # total | liquid（liquid 剔除持有到期资产）
    "maxSingleStockPct": 8.0,     # 单只个股上限
    "maxSingleFundPct": 25.0,     # 单只 ETF/基金上限
    "maxSatellitePct": 15.0,      # 个股（卫星层）合计上限
    "maxUsdExposurePct": 25.0,    # 美元敞口上限（经济口径，穿透底层）
    "maxSingleIssuerPct": 40.0,   # 直接持券单一发行人上限
    "issuerWhitelist": ["IT0005696320"],   # 存量豁免（只约束新买入）
    "maxTotalRiskPct": 5.0,       # 在场风险头寸的理论止损损失合计上限
    "defaultStopPct": 8.0,        # 无 N 时的兜底止损（-8%）
    "layers": {"defensive": [60.0, 85.0], "core": [10.0, 25.0],
               "satellite": [0.0, 15.0]},
    # 底层美元资产比例（%）。EUR 上市但底层是美股的宽基要写在这里，
    # 否则货币口径会漏算（VUAA.MI 是欧元计价的标普 500）。
    "usdLookthrough": {"VUAA.MI": 100.0, "VUSA.MI": 100.0, "VUAA.L": 100.0},
    # 资产分层与持有到期标记的缺省推断补丁（持仓文档里的 layer/holdToMaturity 优先）
    "layerMap": {"VUAA.MI": "core", "VUSA.MI": "core", "PST.MI": "defensive",
                 "IT0003110886": "defensive"},
    "holdToMaturity": ["IT0005696320"],
}

LAYERS = ("defensive", "core", "satellite")


def merged(config: dict | None) -> dict:
    """meta/policy ⊕ 代码缺省（顶层浅合并，dict 值逐键合并）。"""
    out = {**DEFAULTS, **(config or {})}
    for key in ("layers", "usdLookthrough", "layerMap"):
        out[key] = {**DEFAULTS[key], **((config or {}).get(key) or {})}
    return out


# ---------------------------------------------------------------------------
# 分类
# ---------------------------------------------------------------------------

def is_eur_listing(ticker: str) -> bool:
    """.MI 上市与 IT 开头的 ISIN 按欧元计价（与 App 侧 isEurListing 同义）。"""
    return ticker.endswith(".MI") or (ticker.startswith("IT") and is_isin(ticker))


def layer_of(ticker: str, position: dict | None, p: dict) -> str:
    """持仓文档的 layer 优先；否则查 layerMap；再否则 ISIN→防守、其余→卫星。

    自动推断只能做到这个程度——现有数据没有资产类型字段，`.MI` 后缀既可能是
    个股也可能是 ETF。分错了在 App 里改持仓的 layer 即可（会被优先采纳）。
    """
    if position and position.get("layer") in LAYERS:
        return position["layer"]
    mapped = (p.get("layerMap") or {}).get(ticker)
    if mapped in LAYERS:
        return mapped
    return "defensive" if is_isin(ticker) else "satellite"


def is_hold_to_maturity(ticker: str, position: dict | None, p: dict) -> bool:
    if position and "holdToMaturity" in position:
        return bool(position["holdToMaturity"])
    return ticker in (p.get("holdToMaturity") or [])


def usd_exposure_pct_of(ticker: str, p: dict) -> float:
    """该标的底层美元资产占比（%）。EUR 上市的宽基靠 usdLookthrough 补。"""
    look = (p.get("usdLookthrough") or {}).get(ticker)
    if look is not None:
        return float(look)
    return 0.0 if is_eur_listing(ticker) else 100.0


# ---------------------------------------------------------------------------
# EUR 快照
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class Holding:
    ticker: str
    shares: float
    price_native: float
    value_eur: float
    layer: str
    usd_pct: float
    hold_to_maturity: bool


@dataclass(frozen=True)
class Snapshot:
    """一张按 EUR 折算的组合快照，闸门全部基于它判定。"""
    holdings: list[Holding]
    cash_eur: float
    rate: float                     # 1 EUR 兑多少 USD
    p: dict = field(default_factory=dict)

    @property
    def stock_eur(self) -> float:
        return sum(h.value_eur for h in self.holdings)

    @property
    def total_eur(self) -> float:
        return self.cash_eur + self.stock_eur

    @property
    def liquid_eur(self) -> float:
        """剔除持有到期资产后的组合值（riskBase=liquid 用）。"""
        return self.total_eur - sum(
            h.value_eur for h in self.holdings if h.hold_to_maturity)

    def risk_base_eur(self) -> float:
        return (self.liquid_eur if self.p.get("riskBase") == "liquid"
                else self.total_eur)

    def value_of(self, ticker: str) -> float:
        return sum(h.value_eur for h in self.holdings if h.ticker == ticker)

    def layer_eur(self, layer: str) -> float:
        return sum(h.value_eur for h in self.holdings if h.layer == layer)

    def usd_exposure_eur(self) -> float:
        """经济口径美元敞口：按每只的底层美元比例加权（现金不计）。"""
        return sum(h.value_eur * h.usd_pct / 100 for h in self.holdings)

    def to_native(self, ticker: str, eur: float) -> float:
        """EUR 金额折回标的计价货币。"""
        return eur if is_eur_listing(ticker) else eur * self.rate


def snapshot(positions: list[dict], cash: float, cash_currency: str,
             quotes: dict, config: dict | None = None) -> Snapshot | None:
    """把持仓与现金折成 EUR 快照；缺汇率且存在美元标的时返回 None。"""
    p = merged(config)
    rate = (quotes.get("EURUSD=X") or {}).get("close")

    def to_eur(ticker: str, native: float) -> float | None:
        if is_eur_listing(ticker):
            return native
        if not rate:
            return None
        return native / rate

    holdings: list[Holding] = []
    for pos in positions:
        ticker = pos["ticker"]
        shares = float(pos.get("shares") or 0)
        if shares <= 0:
            continue
        price = (quotes.get(ticker) or {}).get("close") or pos.get("avgCost") or 0.0
        v = to_eur(ticker, shares * float(price))
        if v is None:
            return None            # 有美元标的但没汇率 → 不给错数
        holdings.append(Holding(
            ticker=ticker, shares=shares, price_native=float(price), value_eur=v,
            layer=layer_of(ticker, pos, p),
            usd_pct=usd_exposure_pct_of(ticker, p),
            hold_to_maturity=is_hold_to_maturity(ticker, pos, p),
        ))

    cash_eur = cash if cash_currency == "EUR" else to_eur("MSFT", cash)
    if cash_eur is None:
        return None
    return Snapshot(holdings=holdings, cash_eur=cash_eur, rate=rate or 0.0, p=p)


# ---------------------------------------------------------------------------
# 买入闸
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class BuyVerdict:
    """一次买入闸的结论。

    `allowed_shares` = 0 表示完全买不了（`blocked=True`）；小于请求股数表示
    被钳制。`binding` 是最紧的那道闸，`reason`/`reason_en` 是给建议卡的说明。
    """
    allowed_shares: float
    requested_shares: float
    binding: str | None
    reason: str
    reason_en: str
    funding_candidates: list[str] = field(default_factory=list)

    @property
    def blocked(self) -> bool:
        return self.allowed_shares <= 0

    @property
    def clamped(self) -> bool:
        return not self.blocked and self.allowed_shares < self.requested_shares


_LIMIT_LABELS = {
    "cash": ("现金缓冲", "cash floor"),
    "single": ("单票上限", "per-name cap"),
    "satellite": ("卫星总量", "satellite cap"),
    "usd": ("美元敞口", "USD exposure"),
    "issuer": ("单一发行人", "single issuer"),
    "risk": ("总风险预算", "total risk budget"),
}


def _headroom_eur(snap: Snapshot, ticker: str, *, stop_pct: float | None) -> dict:
    """各道闸还允许买入多少 EUR（可为负，表示已越界）。"""
    p = snap.p
    total = snap.total_eur
    layer = layer_of(ticker, None, p)
    # 买入会同时抬高分母（总值不变：现金变股票），所以上限按现值直接算
    out: dict[str, float] = {}

    # 1) 现金缓冲：成交后现金 ≥ cashFloorPct × 总值
    floor = total * float(p["cashFloorPct"]) / 100
    out["cash"] = snap.cash_eur - floor

    # 2) 单票上限：个股 / ETF 基金分开
    cap_pct = (float(p["maxSingleStockPct"]) if layer == "satellite"
               else float(p["maxSingleFundPct"]))
    out["single"] = total * cap_pct / 100 - snap.value_of(ticker)

    # 3) 卫星总量（只约束个股）
    if layer == "satellite":
        out["satellite"] = (total * float(p["maxSatellitePct"]) / 100
                            - snap.layer_eur("satellite"))

    # 4) 美元敞口（经济口径）
    usd_pct = usd_exposure_pct_of(ticker, p)
    if usd_pct > 0:
        room = total * float(p["maxUsdExposurePct"]) / 100 - snap.usd_exposure_eur()
        out["usd"] = room / (usd_pct / 100)

    # 5) 单一发行人（只约束直接持券，白名单存量豁免）
    if is_isin(ticker) and ticker not in (p.get("issuerWhitelist") or []):
        out["issuer"] = (total * float(p["maxSingleIssuerPct"]) / 100
                         - snap.value_of(ticker))

    # 6) 总风险预算：这笔的理论止损损失不得让在场风险超上限
    if stop_pct and stop_pct > 0:
        used = _risk_used_eur(snap)
        budget = total * float(p["maxTotalRiskPct"]) / 100 - used
        out["risk"] = budget / (stop_pct / 100)
    return out


def _risk_used_eur(snap: Snapshot) -> float:
    """在场风险：卫星层持仓按兜底止损折算的理论损失（核心/防守层不占预算）。"""
    stop_pct = float(snap.p["defaultStopPct"]) / 100
    return sum(h.value_eur * stop_pct
               for h in snap.holdings if h.layer == "satellite")


def funding_candidates(snap: Snapshot) -> list[str]:
    """腾挪资金的候选，按梯队：先超上限的持仓，再区间内偏上的层。"""
    p = snap.p
    total = snap.total_eur
    if total <= 0:
        return []
    over: list[str] = []
    for h in snap.holdings:
        cap_pct = (float(p["maxSingleStockPct"]) if h.layer == "satellite"
                   else float(p["maxSingleFundPct"]))
        if h.value_eur / total * 100 > cap_pct:
            over.append(h.ticker)
    if over:
        return over
    # 梯队②：处于目标区间中值以上的层里，权重最大的那只
    for layer in LAYERS:
        lo, hi = p["layers"].get(layer, [0, 100])
        pct = snap.layer_eur(layer) / total * 100
        if pct > (float(lo) + float(hi)) / 2:
            in_layer = [h for h in snap.holdings if h.layer == layer]
            if in_layer:
                over.append(max(in_layer, key=lambda h: h.value_eur).ticker)
    return over


def check_buy(snap: Snapshot, ticker: str, shares: float, price_native: float,
              *, stop_native: float | None = None) -> BuyVerdict:
    """对一笔买入过闸，返回允许的股数（0 = 拦住）与最紧的那道闸。"""
    p = snap.p
    requested = float(shares)
    if requested <= 0 or price_native <= 0:
        return BuyVerdict(0, requested, None, "股数或价格无效",
                          "invalid shares or price")

    stop_pct = None
    if stop_native and stop_native > 0 and stop_native < price_native:
        stop_pct = (price_native - stop_native) / price_native * 100
    else:
        stop_pct = float(p["defaultStopPct"])

    rooms = _headroom_eur(snap, ticker, stop_pct=stop_pct)
    binding = min(rooms, key=lambda k: rooms[k]) if rooms else None
    room_eur = rooms[binding] if binding else float("inf")

    price_eur = price_native if is_eur_listing(ticker) else (
        price_native / snap.rate if snap.rate else None)
    if price_eur is None or price_eur <= 0:
        return BuyVerdict(0, requested, None, "缺汇率，无法折算",
                          "no FX rate available")

    allowed = min(requested, math.floor(max(room_eur, 0) / price_eur))
    zh_label, en_label = _LIMIT_LABELS.get(binding or "", (binding or "", binding or ""))

    if allowed <= 0:
        cands = funding_candidates(snap)
        zh = f"被{zh_label}拦住：当前无可用额度。"
        en = f"Blocked by the {en_label}: no headroom left."
        if cands:
            zh += f"要买需先腾挪资金，候选：{'、'.join(cands)}。"
            en += f" Free up funds first — candidates: {', '.join(cands)}."
        else:
            zh += "当前处于存量重排状态，等待资金到位。"
            en += " The portfolio is in reshuffle-only mode until funds free up."
        return BuyVerdict(0, requested, binding, zh, en, cands)

    if allowed < requested:
        zh = (f"受{zh_label}约束，股数由 {requested:g} 钳到 {allowed:g}"
              f"（该闸剩余额度约 €{max(room_eur, 0):,.0f}）。")
        en = (f"Clamped by the {en_label}: {requested:g} → {allowed:g} shares "
              f"(about €{max(room_eur, 0):,.0f} of headroom).")
        return BuyVerdict(allowed, requested, binding, zh, en)

    return BuyVerdict(allowed, requested, None, "", "")


# ---------------------------------------------------------------------------
# 给 advisor 用：目标权重钳制 + 风险定股数
# ---------------------------------------------------------------------------

def clamp_target_weight(snap: Snapshot, ticker: str, target_pct: float | None) -> float | None:
    """把 LLM 给的目标仓位钳到单票上限内（None 原样返回）。"""
    if target_pct is None:
        return None
    p = snap.p
    layer = layer_of(ticker, None, p)
    cap = (float(p["maxSingleStockPct"]) if layer == "satellite"
           else float(p["maxSingleFundPct"]))
    return max(0.0, min(float(target_pct), cap))


def risk_shares(snap: Snapshot, ticker: str, price_native: float,
                stop_native: float | None) -> int:
    """风险定股数：(风险基数 × riskPerTradePct%) ÷ (入场 − 止损)。

    量纲：分子折成标的计价货币再除以原币的每股风险，避免 EUR ÷ USD。
    """
    p = snap.p
    if price_native <= 0:
        return 0
    if not stop_native or stop_native <= 0 or stop_native >= price_native:
        per_share_risk = price_native * float(p["defaultStopPct"]) / 100
    else:
        per_share_risk = price_native - stop_native
    if per_share_risk <= 0:
        return 0
    budget_eur = snap.risk_base_eur() * float(p["riskPerTradePct"]) / 100
    budget_native = snap.to_native(ticker, budget_eur)
    return math.floor(budget_native / per_share_risk)
