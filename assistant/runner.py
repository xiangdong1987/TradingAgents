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
             trading_day_resolver=None, fetch_calendar=None,
             fetch_dividends=None, watch_interval=None) -> int:
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
    from assistant.events import refresh_calendar
    from assistant.chat import answer_chat
    from assistant.strategies import engine as strategy_engine
    from assistant.income import backfill_income_tax, sync_dividends
    from assistant.store import utc_now_iso

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

    def _calendar_kwargs():
        return {} if fetch_calendar is None else {"fetch_calendar": fetch_calendar}

    def refresh_fn(today: str) -> None:
        kwargs = {} if fetch_quote is None else {"fetch_quote": fetch_quote}
        refreshed = top_up_quotes(store, today, force=True, **kwargs)
        logger.info("force-refreshed quotes for %d ticker(s)", refreshed)
        refresh_calendar(store, **_calendar_kwargs())

    def chat_fn(chat_id: str, today: str) -> None:
        answer_chat(store, llm, chat_id, today)

    def strategy_fn(job: dict, today: str) -> dict:
        kwargs = {} if fetch_quote is None else {"fetch_quote": fetch_quote}
        return strategy_engine.run_scan(store, job, today, **kwargs)

    def translate_fn(analysis_id: str, sections: list) -> None:
        from assistant.translate import translate_sections
        translate_sections(store, llm, analysis_id, sections)

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
                        refresh_fn=refresh_fn, chat_fn=chat_fn,
                        strategy_fn=strategy_fn, translate_fn=translate_fn)
    except Exception:
        logger.exception("user job execution stage failed")

    # 3. plan and run newly scheduled jobs
    try:
        plan_scheduled_jobs(store, now_et, is_trading_day=is_trading_day)
        for job in store.claim_queued_jobs():
            execute_job(store, job, brief_fn=brief_fn, deep_fn=deep_fn,
                        refresh_fn=refresh_fn, chat_fn=chat_fn,
                        strategy_fn=strategy_fn, translate_fn=translate_fn)
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

    # 3.6 calendar refresh: once per day — earnings/dividend agenda for the app
    try:
        cal = store.get_calendar()
        if cal is None or cal.get("updatedAt", "")[:10] != now_et.strftime("%Y-%m-%d"):
            n = refresh_calendar(store, **_calendar_kwargs())
            logger.info("calendar refreshed: %d event(s)", n)
    except Exception:
        logger.exception("calendar refresh stage failed")

    # 3.7 dividend sync: once per day — 每股分红 × 当前持股，落 income 供累计收益统计。
    # 不动现金（现金由用户按券商对账维护，避免重复计入）；ISIN 单券 Yahoo 无数据，靠 App 手录。
    try:
        today_str = now_et.strftime("%Y-%m-%d")
        marker = store.get_meta_doc("income_sync") if hasattr(store, "get_meta_doc") else None
        if marker is None or marker.get("date") != today_str:
            healed = backfill_income_tax(store)   # 老记录缺税额时自愈
            if healed:
                logger.info("dividend sync: backfilled tax on %d row(s)", healed)
            kwargs = {} if fetch_dividends is None else {"fetch_dividends": fetch_dividends}
            n = sync_dividends(store, today_str, **kwargs)
            if n:
                logger.info("dividend sync: %d new income row(s)", n)
            if hasattr(store, "save_meta_doc"):
                store.save_meta_doc("income_sync", {"date": today_str,
                                                    "updatedAt": utc_now_iso()})
    except Exception:
        logger.exception("dividend sync stage failed")

    # 4. review
    reviewed = 0
    try:
        today = now_et.strftime("%Y-%m-%d")
        reviewed = review_due_suggestions(store, today)
        logger.info("wake-up complete (reviewed %d suggestion(s))", reviewed)
    except Exception:
        logger.exception("review stage failed")

    # 心跳：App 首页据此显示 runner 在线/离线
    _write_heartbeat(store, "watch" if watch_interval else "once",
                     watch_interval or 0)

    return 0


def _write_heartbeat(store, mode: str, interval: int) -> None:
    try:
        store.save_heartbeat({"lastSeenAt": datetime.now(timezone.utc).isoformat(),
                              "mode": mode, "intervalSeconds": interval})
    except Exception:
        logger.exception("heartbeat write failed")


def _start_heartbeat_thread(store, interval: int):
    """独立心跳线程：主循环跑长分析时首页仍能看到 Runner 在线。"""
    import threading
    import time as _time

    beat_every = min(60, max(15, interval))

    def _beat():
        while True:
            _write_heartbeat(store, "watch", interval)
            _time.sleep(beat_every)

    t = threading.Thread(target=_beat, daemon=True, name="heartbeat")
    t.start()
    return t


def _parse_args(argv=None):
    import argparse

    parser = argparse.ArgumentParser(prog="assistant.runner")
    parser.add_argument(
        "--watch", nargs="?", const=120, type=int, default=None, metavar="SECONDS",
        help="常驻拉任务模式：每 N 秒醒一次消费队列（默认 120），Ctrl-C 退出",
    )
    return parser.parse_args(argv)


def main(argv=None) -> int:
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    args = _parse_args(argv)
    # Heavy/real deps are imported here, not at module top (keeps tests light).
    from tradingagents.default_config import DEFAULT_CONFIG
    from tradingagents.llm_clients.factory import create_llm_client

    from assistant.store import FirestoreStore

    config = DEFAULT_CONFIG.copy()
    store = FirestoreStore.connect()
    llm = create_llm_client(
        config["llm_provider"], config["quick_think_llm"], config.get("backend_url")
    ).get_llm()

    if args.watch is None:
        return run_once(store, llm, config)

    import time

    logger.info("watch mode: pulling jobs every %d s (Ctrl-C to stop)", args.watch)
    _start_heartbeat_thread(store, args.watch)
    # 单机单消费者：本进程启动即意味着旧 runner 已死，遗留的 running 任务
    # 全部是被杀进程的遗孤，直接回收重排（否则要等 2 小时僵尸清理）。
    try:
        orphans = store.requeue_running_jobs()
        if orphans:
            logger.warning("requeued %d orphaned running job(s)", orphans)
    except Exception:
        logger.exception("orphan requeue failed")
    while True:
        try:
            run_once(store, llm, config, watch_interval=args.watch)
        except Exception:
            logger.exception("wake-up crashed; watch loop continues")
        time.sleep(args.watch)


if __name__ == "__main__":
    raise SystemExit(main())
