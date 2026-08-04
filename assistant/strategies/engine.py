"""策略框架编排层：配置合并、取数、单元账本、去重、落建议。

被两处调用（同一入口，行为一致）：
- runner 的 ``strategy_scan`` job（手动排队或 scheduler 每日排队）
- ``python -m assistant.strategies <name> [scope]`` 直跑（runner 离线时的兜底）
"""
from __future__ import annotations

import logging

from assistant import policy
from assistant.quotes import get_ohlc_history, get_quote, is_isin
from assistant.store import utc_now_iso
from assistant.strategies import REGISTRY, ScanContext

logger = logging.getLogger(__name__)

DISMISS_COOLDOWN_DAYS = 7   # 忽略后 N 天不再生成同 ticker+动作的建议
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


def _quotes_map(positions: dict[str, dict], fetch_quote) -> dict:
    """取一遍行情（含 EURUSD=X），失败的标的退回成本价。Policy 快照要用。"""
    quotes: dict[str, dict] = {}
    for ticker, pos in positions.items():
        try:
            quotes[ticker] = {"close": fetch_quote(ticker)["close"]}
        except Exception:
            quotes[ticker] = {"close": pos.get("avgCost", 0.0)}
    try:
        quotes["EURUSD=X"] = {"close": fetch_quote("EURUSD=X")["close"]}
    except Exception:
        logger.warning("EURUSD rate unavailable; policy gates will be skipped")
    return quotes


def _fallback_value(positions: dict[str, dict], cash: float, quotes: dict) -> float:
    """缺汇率时的退路：各币种直加（不准，但比不出信号好）。"""
    total = cash
    for ticker, p in positions.items():
        price = (quotes.get(ticker) or {}).get("close") or p.get("avgCost", 0.0)
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
        # seeded=True：这个仓不是海龟在突破点建的。策略侧据此跳过金字塔加仓
        # （avgCost 当参照会让所有浮盈老仓永远处于"加仓窗口"），只做止损/退出监控。
        units = [{"entry": position.get("avgCost", 0.0),
                  "shares": position.get("shares"), "system": "s1", "n": None,
                  "seeded": True}]
    return [u for u in units if u["entry"]]


def run_scan(store, job: dict, today: str, *,
             fetch_bars=get_ohlc_history, fetch_quote=get_quote) -> dict:
    """执行一次策略扫描，返回 {"scanned": n, "created": k} 供 job 文档记录。"""
    from datetime import datetime, timedelta
    cfg = store.get_strategy_config()
    names = resolve_strategies(job, cfg)
    if not names:
        logger.info("no strategy enabled and none named; nothing to scan")
        return {"scanned": 0, "created": 0}

    positions = {p["ticker"]: p for p in store.get_positions()}
    watch = [w["ticker"] for w in store.get_watchlist()]
    meta = store.get_portfolio_meta()
    cash = meta.get("cash", 0.0)
    quotes = _quotes_map(positions, fetch_quote)
    # Policy 快照统一 EUR 口径；缺汇率（含美元标的）时为 None → 跳过闸门但照常出信号
    snap = policy.snapshot(list(positions.values()), cash,
                           meta.get("currency", "EUR"), quotes,
                           store.get_policy_config())
    if snap is None:
        logger.warning("policy snapshot unavailable (missing FX?); gates skipped")
    pending = store.pending_suggestions()
    # 忽略冷却：同 ticker+策略+动作在 N 天内被 dismissed 过就不再生成，
    # 否则条件仍成立时每次扫描都会把用户刚忽略的建议原样端回来。
    cooldown_cutoff = (datetime.strptime(today, "%Y-%m-%d")
                       - timedelta(days=DISMISS_COOLDOWN_DAYS)).strftime("%Y-%m-%d")

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
            history = store.suggestions_for_ticker(ticker)
            units = rebuild_units(history, name, position)
            # 单元公式是 组合值 ÷ 2N，而 N 永远是标的原币 → 组合值也要折成原币，
            # 否则 EUR 总值除以 USD 的 N 会差一个汇率（约 8~15%）。
            pv = (snap.to_native(ticker, snap.total_eur) if snap
                  else _fallback_value(positions, cash, quotes))
            ctx = ScanContext(ticker=ticker, bars=bars, position=position,
                              units=units, portfolio_value=pv,
                              cash=cash, params=params)
            try:
                signals = strat.scan(ctx)
            except Exception:
                logger.exception("%s scan failed for %s", name, ticker)
                continue
            for sig in signals:
                if any(p.get("ticker") == ticker and p.get("source") == name
                       and p.get("action") == sig.action
                       and not (p.get("meta") or {}).get("blocked")
                       for p in pending):
                    logger.info("dedup: pending %s/%s for %s exists",
                                name, sig.action, ticker)
                    continue
                if any(h.get("source") == name and h.get("action") == sig.action
                       and h.get("status") == "dismissed"
                       and str(h.get("resolvedAt") or h.get("createdAt") or "")[:10]
                           >= cooldown_cutoff
                       for h in history):
                    logger.info("cooldown: %s/%s for %s dismissed within %dd",
                                name, sig.action, ticker, DISMISS_COOLDOWN_DAYS)
                    continue
                meta = dict(sig.meta)
                if sig.shares is not None:
                    meta["shares"] = sig.shares
                if sig.stop is not None:
                    meta["stop"] = round(sig.stop, 4)
                rationale, rationale_en = sig.reason, sig.reason_en

                # 买入类过组合级闸：钳股数或整条降级为 blocked（卖出类不设闸——
                # 减风险的动作永远允许）
                if snap is not None and sig.action in ("buy", "add"):
                    verdict = policy.check_buy(
                        snap, ticker, sig.shares or 0, sig.price, stop_native=sig.stop)
                    if verdict.blocked:
                        meta["blocked"] = True
                        meta["blockedBy"] = verdict.binding
                        if verdict.funding_candidates:
                            meta["fundingCandidates"] = verdict.funding_candidates
                        rationale = f"{sig.reason}\n\n⚠️ {verdict.reason}"
                        rationale_en = f"{sig.reason_en}\n\n⚠️ {verdict.reason_en}"
                    elif verdict.clamped:
                        meta["shares"] = verdict.allowed_shares
                        meta["clampedFrom"] = verdict.requested_shares
                        meta["clampedBy"] = verdict.binding
                        rationale = f"{sig.reason}\n\n⚠️ {verdict.reason}"
                        rationale_en = f"{sig.reason_en}\n\n⚠️ {verdict.reason_en}"

                doc = {
                    "ticker": ticker, "action": sig.action,
                    "targetWeightPct": None, "rationale": rationale,
                    "rationaleEn": rationale_en,
                    "analysisId": "", "source": name, "meta": meta,
                    "status": "pending", "createdAt": utc_now_iso(),
                }
                store.save_suggestion(doc)
                pending.append(doc)  # 同次扫描内也去重
                created += 1
                logger.info("%s: %s %s @ %s", name, sig.action, ticker, sig.price)
    return {"scanned": scanned, "created": created}
