from assistant.review import review_due_suggestions
from assistant.store import MemoryStore


def seeded_store():
    s = MemoryStore()
    s.save_suggestion({"ticker": "NVDA", "action": "trim", "status": "accepted",
                       "createdAt": "2026-07-10T12:00:00+00:00"})
    s.save_suggestion({"ticker": "AAPL", "action": "buy", "status": "pending",   # 不复盘
                       "createdAt": "2026-07-10T12:00:00+00:00"})
    return s


def test_due_suggestions_get_outcome_pct():
    store = seeded_store()
    calls = []

    def fake_return(ticker, start, end):
        calls.append((ticker, start, end))
        return -4.2

    n = review_due_suggestions(store, "2026-08-01", fetch_return=fake_return)
    assert n == 1
    assert calls == [("NVDA", "2026-07-10", "2026-08-01")]
    reviewed = [s for s in store._suggestions.values() if "outcomePct" in s]
    assert reviewed[0]["outcomePct"] == -4.2 and reviewed[0]["reviewedAt"]


def test_single_failure_does_not_abort():
    store = seeded_store()
    store.save_suggestion({"ticker": "BROKEN", "action": "sell", "status": "dismissed",
                           "createdAt": "2026-07-05T00:00:00+00:00"})

    def flaky(ticker, start, end):
        if ticker == "BROKEN":
            raise RuntimeError("no data")
        return 1.0

    assert review_due_suggestions(store, "2026-08-01", fetch_return=flaky) == 1


def test_malformed_suggestion_does_not_abort():
    store = MemoryStore()
    # Healthy suggestion
    store.save_suggestion({"ticker": "AAPL", "action": "buy", "status": "accepted",
                           "createdAt": "2026-07-10T12:00:00+00:00"})
    # Malformed: missing createdAt, but still matches due-review filter (missing createdAt defaults to "")
    store.save_suggestion({"ticker": "BROKEN", "action": "sell", "status": "accepted"})

    def fake_return(ticker, start, end):
        return 3.5

    n = review_due_suggestions(store, "2026-08-01", fetch_return=fake_return)
    assert n == 1
    reviewed = [s for s in store._suggestions.values() if "outcomePct" in s]
    assert len(reviewed) == 1
    assert reviewed[0]["ticker"] == "AAPL"
