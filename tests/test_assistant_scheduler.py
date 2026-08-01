from datetime import datetime
from zoneinfo import ZoneInfo

from assistant.scheduler import plan_scheduled_jobs
from assistant.store import MemoryStore

ET = ZoneInfo("America/New_York")
FRI_EVENING = datetime(2026, 7, 31, 17, 0, tzinfo=ET)   # 2026-07-31 是周五
WED_EVENING = datetime(2026, 7, 29, 17, 0, tzinfo=ET)
FRI_NOON = datetime(2026, 7, 31, 12, 0, tzinfo=ET)


def store_with_watchlist():
    s = MemoryStore()
    s.seed_watchlist([
        {"ticker": "NVDA", "deepFreq": "weekly", "note": "", "addedAt": "x"},
        {"ticker": "AAPL", "deepFreq": "manual", "note": "", "addedAt": "x"},
    ])
    return s


def test_after_close_on_trading_day_schedules_brief():
    s = store_with_watchlist()
    ids = plan_scheduled_jobs(s, WED_EVENING, is_trading_day=lambda now: True)
    jobs = [s.get_job(i) for i in ids]
    assert [j["type"] for j in jobs] == ["daily_brief"]
    assert jobs[0]["status"] == "queued" and jobs[0]["requestedBy"] == "schedule"


def test_no_brief_before_close_or_on_holiday_or_when_done():
    s = store_with_watchlist()
    assert plan_scheduled_jobs(s, FRI_NOON, is_trading_day=lambda n: True) == []       # 未收盘
    assert plan_scheduled_jobs(s, WED_EVENING, is_trading_day=lambda n: False) == []   # 休市
    s.save_brief("2026-07-29", {"date": "2026-07-29"})                                  # 已有日报
    assert plan_scheduled_jobs(s, WED_EVENING, is_trading_day=lambda n: True) == []


def test_friday_evening_schedules_weekly_deep_analysis():
    s = store_with_watchlist()
    s.save_brief("2026-07-31", {"date": "2026-07-31"})    # 日报已生成，只看深度
    ids = plan_scheduled_jobs(s, FRI_EVENING, is_trading_day=lambda n: True)
    jobs = [s.get_job(i) for i in ids]
    assert [(j["type"], j.get("ticker")) for j in jobs] == [("deep_analysis", "NVDA")]  # manual 的 AAPL 不排


def test_weekly_deep_skipped_if_already_analyzed_this_week():
    s = store_with_watchlist()
    s.save_brief("2026-07-31", {"date": "2026-07-31"})
    s.save_analysis({"ticker": "NVDA", "tradeDate": "2026-07-29",
                     "createdAt": "2026-07-29T21:00:00+00:00", "decision": "HOLD", "sections": {}})
    assert plan_scheduled_jobs(s, FRI_EVENING, is_trading_day=lambda n: True) == []


def test_non_friday_does_not_schedule_deep_analysis():
    s = store_with_watchlist()
    s.save_brief("2026-07-29", {"date": "2026-07-29"})
    assert plan_scheduled_jobs(s, WED_EVENING, is_trading_day=lambda n: True) == []


def test_friday_late_wakeup_schedules_both_brief_and_deep_with_et_date():
    # 21:00 ET on a Friday, well after ET midnight has already ticked over to UTC
    # "tomorrow" for part of the evening — job docs must carry the ET date, not
    # whatever datetime.now(timezone.utc) would compute.
    s = store_with_watchlist()
    fri_late = datetime(2026, 7, 31, 21, 0, tzinfo=ET)
    ids = plan_scheduled_jobs(s, fri_late, is_trading_day=lambda n: True)
    jobs = [s.get_job(i) for i in ids]
    assert sorted(j["type"] for j in jobs) == ["daily_brief", "deep_analysis"]
    assert all(j["date"] == "2026-07-31" for j in jobs)
