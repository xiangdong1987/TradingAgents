"""策略框架编排层：配置合并、取数、单元账本、去重、落建议。

被两处调用（同一入口，行为一致）：
- runner 的 ``strategy_scan`` job（手动排队或 scheduler 每日排队）
- ``python -m assistant.strategies <name> [scope]`` 直跑（runner 离线时的兜底）
"""
from __future__ import annotations

import logging

from assistant.quotes import get_ohlc_history, get_quote, is_isin
from assistant.store import utc_now_iso
from assistant.strategies import REGISTRY, ScanContext

logger = logging.getLogger(__name__)

BARS_CALENDAR_DAYS = 200  # ≈135 根日线，覆盖 55 日通道 + 20 日 ATR 暖机


def resolve_strategies(job: dict, cfg: dict) -> list[str]:
    """job 点名的策略无视 enabled（用户指名就跑）；否则跑全部 enabled。"""
    name = job.get("strategy")
    if name:
        if name not in REGISTRY:
            raise ValueError(f"unknown strategy: {name}")
        return [name]
    return [n for n, c in cfg.items() if n in REGISTRY and c.get("enabled")]


def resolve_scope(job: dict, cfg_entry: dict) -> str:
    return job.get("scope") or cfg_entry.get("scope") or "positions+watchlist"


def _tickers_for(scope: str, positions: dict[str, dict], watch: list[str]) -> list[str]:
    tickers = list(positions)
    if scope != "positions":
        tickers += [t for t in watch if t not in positions]
    return [t for t in tickers if not is_isin(t)]  # 债券无 OHLC 语义，跳过


def _portfolio_value(positions: dict[str, dict], cash: float, fetch_quote) -> float:
    """advisor 同款简化：各币种直加，行情失败退回成本价。"""
    total = cash
    for p in positions.values():
        try:
            price = fetch_quote(p["ticker"])["close"]
        except Exception:
            price = p.get("avgCost", 0.0)
        total += p.get("shares", 0.0) * price
    return total


def rebuild_units(suggestions: list[dict], strategy: str, position: dict | None) -> list[dict]:
    """从「已采纳的本策略建议」重建单元账本；sell 清空。

    没有任何本策略买入记录但确有持仓 → 老持仓当 1 个种子单元
    （entry=avgCost，入场 N 未知，策略侧用当前 N 近似）。
    """
    units: list[dict] = []
    for s in sorted(suggestions, key=lambda x: x.get("createdAt", "")):
        if s.get("source") != strategy or s.get("status") != "accepted":
            continue
        meta = s.get("meta") or {}
        if s.get("action") in ("buy", "add"):
            units.append({
                "entry": meta.get("entry") or 0.0,
                "shares": meta.get("shares"),
                "system": meta.get("system") or "s1",
                "n": meta.get("n"),
            })
        elif s.get("action") in ("sell", "trim"):
            units = []
    if not units and position is not None:
        units = [{"entry": position.get("avgCost", 0.0),
                  "shares": position.get("shares"), "system": "s1", "n": None}]
    return [u for u in units if u["entry"]]


def run_scan(store, job: dict, today: str, *,
             fetch_bars=get_ohlc_history, fetch_quote=get_quote) -> dict:
    """执行一次策略扫描，返回 {"scanned": n, "created": k} 供 job 文档记录。"""
    cfg = store.get_strategy_config()
    names = resolve_strategies(job, cfg)
    if not names:
        logger.info("no strategy enabled and none named; nothing to scan")
        return {"scanned": 0, "created": 0}

    positions = {p["ticker"]: p for p in store.get_positions()}
    watch = [w["ticker"] for w in store.get_watchlist()]
    cash = store.get_portfolio_meta().get("cash", 0.0)
    portfolio_value = _portfolio_value(positions, cash, fetch_quote)
    pending = store.pending_suggestions()

    scanned = created = 0
    for name in names:
        strat = REGISTRY[name]
        cfg_entry = cfg.get(name) or {}
        params = {**strat.defaults, **(cfg_entry.get("params") or {})}
        scope = resolve_scope(job, cfg_entry)
        bars_cache: dict[str, list[dict]] = {}

        for ticker in _tickers_for(scope, positions, watch):
            if ticker not in bars_cache:
                try:
                    bars_cache[ticker] = fetch_bars(ticker, today, days=BARS_CALENDAR_DAYS)
                except Exception:
                    logger.warning("bars fetch failed for %s", ticker, exc_info=True)
                    bars_cache[ticker] = []
            bars = bars_cache[ticker]
            if not bars:
                continue
            scanned += 1
            position = positions.get(ticker)
            units = rebuild_units(store.suggestions_for_ticker(ticker), name, position)
            ctx = ScanContext(ticker=ticker, bars=bars, position=position,
                              units=units, portfolio_value=portfolio_value,
                              cash=cash, params=params)
            try:
                signals = strat.scan(ctx)
            except Exception:
                logger.exception("%s scan failed for %s", name, ticker)
                continue
            for sig in signals:
                if any(p.get("ticker") == ticker and p.get("source") == name
                       and p.get("action") == sig.action for p in pending):
                    logger.info("dedup: pending %s/%s for %s exists",
                                name, sig.action, ticker)
                    continue
                meta = dict(sig.meta)
                if sig.shares is not None:
                    meta["shares"] = sig.shares
                if sig.stop is not None:
                    meta["stop"] = round(sig.stop, 4)
                doc = {
                    "ticker": ticker, "action": sig.action,
                    "targetWeightPct": None, "rationale": sig.reason,
                    "rationaleEn": sig.reason_en,
                    "analysisId": "", "source": name, "meta": meta,
                    "status": "pending", "createdAt": utc_now_iso(),
                }
                store.save_suggestion(doc)
                pending.append(doc)  # 同次扫描内也去重
                created += 1
                logger.info("%s: %s %s @ %s", name, sig.action, ticker, sig.price)
    return {"scanned": scanned, "created": created}
