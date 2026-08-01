"""Storage layer for the wealth assistant.

``Store`` is the protocol every business module programs against.
``MemoryStore`` is the in-memory fake used by tests (and the reference
semantics for the real ``FirestoreStore`` added in Task 2).
"""
from __future__ import annotations

import itertools
from datetime import datetime, timezone
from typing import Protocol


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


class Store(Protocol):
    def get_watchlist(self) -> list[dict]: ...
    def get_positions(self) -> list[dict]: ...
    def get_portfolio_meta(self) -> dict: ...
    def get_brief(self, date_str: str) -> dict | None: ...
    def save_brief(self, date_str: str, data: dict) -> None: ...
    def save_analysis(self, data: dict) -> str: ...
    def has_analysis_since(self, ticker: str, since_iso: str) -> bool: ...
    def save_suggestion(self, data: dict) -> str: ...
    def update_suggestion(self, sid: str, fields: dict) -> None: ...
    def suggestions_due_review(self, cutoff_iso: str) -> list[dict]: ...
    def add_job(self, data: dict) -> str: ...
    def claim_queued_jobs(self) -> list[dict]: ...
    def update_job(self, jid: str, fields: dict) -> None: ...
    def fail_zombie_jobs(self, cutoff_iso: str) -> int: ...


class MemoryStore:
    """Dict-backed fake with FirestoreStore-identical semantics."""

    def __init__(self):
        self._watchlist: list[dict] = []
        self._positions: list[dict] = []
        self._meta: dict | None = None
        self._briefs: dict[str, dict] = {}
        self._analyses: dict[str, dict] = {}
        self._suggestions: dict[str, dict] = {}
        self._jobs: dict[str, dict] = {}
        self._ids = itertools.count(1)

    def _next_id(self) -> str:
        return f"id{next(self._ids)}"

    # --- seeding helpers (tests only) ---
    def seed_watchlist(self, items: list[dict]) -> None:
        self._watchlist = list(items)

    def seed_positions(self, items: list[dict]) -> None:
        self._positions = list(items)

    def seed_meta(self, meta: dict) -> None:
        self._meta = dict(meta)

    # --- watchlist / portfolio ---
    def get_watchlist(self) -> list[dict]:
        return list(self._watchlist)

    def get_positions(self) -> list[dict]:
        return list(self._positions)

    def get_portfolio_meta(self) -> dict:
        return dict(self._meta) if self._meta else {"cash": 0.0, "currency": "USD"}

    # --- briefs ---
    def get_brief(self, date_str: str) -> dict | None:
        doc = self._briefs.get(date_str)
        return dict(doc) if doc else None

    def save_brief(self, date_str: str, data: dict) -> None:
        self._briefs[date_str] = dict(data)

    # --- analyses ---
    def save_analysis(self, data: dict) -> str:
        aid = self._next_id()
        self._analyses[aid] = dict(data)
        return aid

    def has_analysis_since(self, ticker: str, since_iso: str) -> bool:
        return any(
            a["ticker"] == ticker and a["createdAt"] >= since_iso
            for a in self._analyses.values()
        )

    # --- suggestions ---
    def save_suggestion(self, data: dict) -> str:
        sid = self._next_id()
        self._suggestions[sid] = dict(data)
        return sid

    def update_suggestion(self, sid: str, fields: dict) -> None:
        self._suggestions[sid].update(fields)

    def suggestions_due_review(self, cutoff_iso: str) -> list[dict]:
        out = []
        for sid, s in self._suggestions.items():
            if (
                s.get("status") in ("accepted", "dismissed")
                and s.get("createdAt", "") <= cutoff_iso
                and "outcomePct" not in s
            ):
                out.append({"id": sid, **s})
        return out

    # --- jobs ---
    def add_job(self, data: dict) -> str:
        jid = self._next_id()
        self._jobs[jid] = dict(data)
        return jid

    def get_job(self, jid: str) -> dict:
        return dict(self._jobs[jid])

    def claim_queued_jobs(self) -> list[dict]:
        claimed = []
        for jid, job in self._jobs.items():
            if job.get("status") == "queued":
                job["status"] = "running"
                job["startedAt"] = utc_now_iso()
                claimed.append({"id": jid, **job})
        return claimed

    def update_job(self, jid: str, fields: dict) -> None:
        self._jobs[jid].update(fields)

    def fail_zombie_jobs(self, cutoff_iso: str) -> int:
        n = 0
        for job in self._jobs.values():
            if job.get("status") == "running" and job.get("startedAt", "") < cutoff_iso:
                job["status"] = "failed"
                job["error"] = "runner killed"
                n += 1
        return n
