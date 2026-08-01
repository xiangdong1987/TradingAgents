"""Assembly entry point: launchd wakes this every 15 minutes.

Order per wake-up: zombie cleanup -> claim queued jobs -> plan scheduled
jobs (and run them) -> review due suggestions. All state lives in
Firestore; this process exits when done.
"""
from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

logger = logging.getLogger(__name__)

ZOMBIE_AFTER_HOURS = 2


def main() -> int:
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    # Heavy/real deps are imported here, not at module top (keeps tests light).
    from tradingagents.default_config import DEFAULT_CONFIG
    from tradingagents.llm_clients.factory import create_llm_client

    from assistant import quotes
    from assistant.daily_brief import generate_daily_brief
    from assistant.deep_analysis import run_deep_analysis
    from assistant.advisor import generate_suggestion
    from assistant.jobs import execute_job
    from assistant.review import review_due_suggestions
    from assistant.scheduler import plan_scheduled_jobs
    from assistant.store import FirestoreStore

    config = DEFAULT_CONFIG.copy()
    store = FirestoreStore.connect()
    llm = create_llm_client(
        config["llm_provider"], config["quick_think_llm"], config.get("backend_url")
    ).get_llm()

    def brief_fn(today: str) -> str:
        return generate_daily_brief(store, llm, today)

    def deep_fn(ticker: str, today: str) -> tuple[str, str]:
        analysis_id, decision = run_deep_analysis(store, ticker, today, config)
        generate_suggestion(store, llm, ticker, decision, analysis_id)
        return analysis_id, decision

    # 1. zombie cleanup
    cutoff = (datetime.now(timezone.utc) - timedelta(hours=ZOMBIE_AFTER_HOURS)).isoformat()
    zombies = store.fail_zombie_jobs(cutoff)
    if zombies:
        logger.warning("marked %d zombie job(s) failed", zombies)

    # 2. user-requested jobs first, then 3. newly planned scheduled jobs
    for job in store.claim_queued_jobs():
        execute_job(store, job, brief_fn=brief_fn, deep_fn=deep_fn)

    now_et = datetime.now(ZoneInfo("America/New_York"))
    plan_scheduled_jobs(store, now_et, is_trading_day=quotes.is_trading_day_now)
    for job in store.claim_queued_jobs():
        execute_job(store, job, brief_fn=brief_fn, deep_fn=deep_fn)

    # 4. review
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    reviewed = review_due_suggestions(store, today)
    logger.info("wake-up complete (reviewed %d suggestion(s))", reviewed)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
