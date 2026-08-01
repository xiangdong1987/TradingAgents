"""Assembly entry point: launchd wakes this every 15 minutes.

Order per wake-up: zombie cleanup -> claim queued jobs -> plan scheduled
jobs (and run them) -> review due suggestions. All state lives in
Firestore; this process exits when done.

Each stage is isolated: a stage that raises is logged and the remaining
stages still run, so a transient error (e.g. a network hiccup inside
quotes.is_trading_day_now) never prevents the review stage from running.
"""
from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from assistant.jobs import execute_job
from assistant.review import review_due_suggestions
from assistant.scheduler import plan_scheduled_jobs

logger = logging.getLogger(__name__)

ZOMBIE_AFTER_HOURS = 2


def run_once(store, llm, config, *, now_et=None, is_trading_day=None,
             graph_factory=None, fetch_quote=None, fetch_news=None,
             trading_day_resolver=None) -> int:
    """One wake-up: zombie cleanup -> user jobs -> scheduled jobs -> review.

    Each stage is isolated in its own try/except; a stage failure is logged
    and the next stage still runs.
    """
    # Light imports only; heavy/real deps (tradingagents.*, FirestoreStore,
    # create_llm_client) are wired by main(), not here, to keep this module
    # importable without any of that machinery installed.
    from assistant.daily_brief import generate_daily_brief, top_up_quotes
    from assistant.deep_analysis import run_deep_analysis
    from assistant.advisor import generate_suggestion

    if now_et is None:
        now_et = datetime.now(ZoneInfo("America/New_York"))
    if is_trading_day is None:
        from assistant import quotes
        is_trading_day = quotes.is_trading_day_now
    if trading_day_resolver is None:
        from assistant import quotes
        trading_day_resolver = quotes.last_trading_day

    def brief_fn(today: str) -> str:
        kwargs = {}
        if fetch_quote is not None:
            kwargs["fetch_quote"] = fetch_quote
        if fetch_news is not None:
            kwargs["fetch_news"] = fetch_news
        return generate_daily_brief(store, llm, today, **kwargs)

    def deep_fn(ticker: str, today: str) -> tuple[str, str]:
        # A user can trigger analysis on a weekend/holiday; the engine needs
        # a date with market data, so resolve to the last trading day.
        try:
            trade_date = trading_day_resolver(today)
        except Exception:
            logger.exception("trading-day resolution failed; using %s as-is", today)
            trade_date = today
        if trade_date != today:
            logger.info("%s: %s is not a trading day, analyzing %s instead",
                        ticker, today, trade_date)
        analysis_id, decision = run_deep_analysis(
            store, ticker, trade_date, config, graph_factory=graph_factory
        )
        try:
            generate_suggestion(store, llm, ticker, decision, analysis_id)
        except Exception:
            logger.exception("suggestion generation failed for %s (analysis %s)",
                             ticker, analysis_id)
        return analysis_id, decision

    def refresh_fn(today: str) -> None:
        kwargs = {} if fetch_quote is None else {"fetch_quote": fetch_quote}
        refreshed = top_up_quotes(store, today, force=True, **kwargs)
        logger.info("force-refreshed quotes for %d ticker(s)", refreshed)

    # 1. zombie cleanup
    try:
        cutoff = (datetime.now(timezone.utc) - timedelta(hours=ZOMBIE_AFTER_HOURS)).isoformat()
        zombies = store.fail_zombie_jobs(cutoff)
        if zombies:
            logger.warning("marked %d zombie job(s) failed", zombies)
    except Exception:
        logger.exception("zombie cleanup stage failed")

    # 2. user-requested jobs first
    try:
        for job in store.claim_queued_jobs():
            execute_job(store, job, brief_fn=brief_fn, deep_fn=deep_fn,
                        refresh_fn=refresh_fn)
    except Exception:
        logger.exception("user job execution stage failed")

    # 3. plan and run newly scheduled jobs
    try:
        plan_scheduled_jobs(store, now_et, is_trading_day=is_trading_day)
        for job in store.claim_queued_jobs():
            execute_job(store, job, brief_fn=brief_fn, deep_fn=deep_fn,
                        refresh_fn=refresh_fn)
    except Exception:
        logger.exception("scheduled job planning/execution stage failed")

    # 3.5 quotes top-up: tickers added after the last brief get prices now
    # (the client reads prices from brief.quotes), no LLM cost involved.
    try:
        kwargs = {} if fetch_quote is None else {"fetch_quote": fetch_quote}
        topped = top_up_quotes(store, now_et.strftime("%Y-%m-%d"), **kwargs)
        if topped:
            logger.info("topped up quotes for %d ticker(s)", topped)
    except Exception:
        logger.exception("quotes top-up stage failed")

    # 4. review
    reviewed = 0
    try:
        today = now_et.strftime("%Y-%m-%d")
        reviewed = review_due_suggestions(store, today)
        logger.info("wake-up complete (reviewed %d suggestion(s))", reviewed)
    except Exception:
        logger.exception("review stage failed")

    return 0


def main() -> int:
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    # Heavy/real deps are imported here, not at module top (keeps tests light).
    from tradingagents.default_config import DEFAULT_CONFIG
    from tradingagents.llm_clients.factory import create_llm_client

    from assistant.store import FirestoreStore

    config = DEFAULT_CONFIG.copy()
    store = FirestoreStore.connect()
    llm = create_llm_client(
        config["llm_provider"], config["quick_think_llm"], config.get("backend_url")
    ).get_llm()

    return run_once(store, llm, config)


if __name__ == "__main__":
    raise SystemExit(main())
