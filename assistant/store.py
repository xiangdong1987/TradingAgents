"""Storage layer for the wealth assistant.

``Store`` is the protocol every business module programs against.
``MemoryStore`` is the in-memory fake used by tests (and the reference
semantics for the real ``FirestoreStore`` added in Task 2).
"""
from __future__ import annotations

import itertools
import os
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
    def merge_brief_quotes(self, date_str: str, quotes: dict) -> None: ...
    def get_calendar(self) -> dict | None: ...
    def save_calendar(self, data: dict) -> None: ...
    def get_chat(self, cid: str) -> dict | None: ...
    def update_chat(self, cid: str, fields: dict) -> None: ...
    def recent_analyses(self, limit: int = 6) -> list[dict]: ...
    def save_analysis(self, data: dict) -> str: ...
    def has_analysis_since(self, ticker: str, since_iso: str) -> bool: ...
    def save_suggestion(self, data: dict) -> str: ...
    def update_suggestion(self, sid: str, fields: dict) -> None: ...
    def suggestions_due_review(self, cutoff_iso: str) -> list[dict]: ...
    def add_job(self, data: dict) -> str: ...
    def claim_queued_jobs(self) -> list[dict]: ...
    def update_job(self, jid: str, fields: dict) -> None: ...
    def fail_zombie_jobs(self, cutoff_iso: str) -> int: ...
    def requeue_running_jobs(self) -> int: ...


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

    def merge_brief_quotes(self, date_str: str, quotes: dict) -> None:
        doc = self._briefs.get(date_str)
        if doc is None:
            return
        doc.setdefault("quotes", {}).update(quotes)

    def get_calendar(self) -> dict | None:
        return dict(self._calendar) if getattr(self, "_calendar", None) else None

    def save_calendar(self, data: dict) -> None:
        self._calendar = dict(data)

    def get_chat(self, cid: str) -> dict | None:
        doc = getattr(self, "_chats", {}).get(cid)
        return dict(doc) if doc else None

    def add_chat(self, data: dict) -> str:
        if not hasattr(self, "_chats"):
            self._chats = {}
        cid = self._next_id()
        self._chats[cid] = dict(data)
        return cid

    def update_chat(self, cid: str, fields: dict) -> None:
        self._chats[cid].update(fields)

    def recent_analyses(self, limit: int = 6) -> list[dict]:
        docs = sorted(self._analyses.values(),
                      key=lambda a: a.get("createdAt", ""), reverse=True)
        return [dict(d) for d in docs[:limit]]

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

    def requeue_running_jobs(self) -> int:
        n = 0
        for job in self._jobs.values():
            if job.get("status") == "running":
                job["status"] = "queued"
                n += 1
        return n


def resolve_credentials_path(env: dict | None = None) -> str:
    env = os.environ if env is None else env
    return env.get(
        "TRADINGAGENTS_FIREBASE_CREDENTIALS",
        os.path.join(os.path.expanduser("~"), ".tradingagents", "firebase-service-account.json"),
    )


class FirestoreStore:
    """firebase-admin backed implementation. Semantics mirror MemoryStore."""

    def __init__(self, db):
        self._db = db

    @classmethod
    def connect(cls, cred_path: str | None = None) -> "FirestoreStore":
        # Lazy import: keep test collection light (repo convention, see factory.py)
        import firebase_admin
        from firebase_admin import credentials, firestore

        if not firebase_admin._apps:
            cred = credentials.Certificate(cred_path or resolve_credentials_path())
            firebase_admin.initialize_app(cred)
        return cls(firestore.client())

    # --- watchlist / portfolio ---
    def get_watchlist(self) -> list[dict]:
        return [d.to_dict() for d in self._db.collection("watchlist").stream()]

    def get_positions(self) -> list[dict]:
        return [d.to_dict() for d in self._db.collection("positions").stream()]

    def get_portfolio_meta(self) -> dict:
        snap = self._db.collection("meta").document("portfolio").get()
        return snap.to_dict() if snap.exists else {"cash": 0.0, "currency": "USD"}

    # --- briefs ---
    def get_brief(self, date_str: str) -> dict | None:
        snap = self._db.collection("briefs").document(date_str).get()
        return snap.to_dict() if snap.exists else None

    def save_brief(self, date_str: str, data: dict) -> None:
        self._db.collection("briefs").document(date_str).set(data)

    def merge_brief_quotes(self, date_str: str, quotes: dict) -> None:
        # set(merge=True) deep-merges the nested quotes map, preserving
        # existing tickers' entries.
        self._db.collection("briefs").document(date_str).set(
            {"quotes": quotes}, merge=True
        )

    def get_calendar(self) -> dict | None:
        snap = self._db.collection("meta").document("calendar").get()
        return snap.to_dict() if snap.exists else None

    def save_calendar(self, data: dict) -> None:
        self._db.collection("meta").document("calendar").set(data)

    def get_chat(self, cid: str) -> dict | None:
        snap = self._db.collection("chats").document(cid).get()
        return snap.to_dict() if snap.exists else None

    def update_chat(self, cid: str, fields: dict) -> None:
        self._db.collection("chats").document(cid).update(fields)

    def recent_analyses(self, limit: int = 6) -> list[dict]:
        q = (self._db.collection("analyses")
             .order_by("createdAt", direction="DESCENDING").limit(limit))
        return [d.to_dict() for d in q.stream()]

    # --- analyses ---
    def save_analysis(self, data: dict) -> str:
        ref = self._db.collection("analyses").document()
        ref.set(data)
        return ref.id

    def has_analysis_since(self, ticker: str, since_iso: str) -> bool:
        q = (
            self._db.collection("analyses")
            .where("ticker", "==", ticker)
            .where("createdAt", ">=", since_iso)
            .limit(1)
        )
        return len(list(q.stream())) > 0

    # --- suggestions ---
    def save_suggestion(self, data: dict) -> str:
        ref = self._db.collection("suggestions").document()
        ref.set(data)
        return ref.id

    def update_suggestion(self, sid: str, fields: dict) -> None:
        self._db.collection("suggestions").document(sid).update(fields)

    def suggestions_due_review(self, cutoff_iso: str) -> list[dict]:
        out = []
        q = self._db.collection("suggestions").where("status", "in", ["accepted", "dismissed"])
        for snap in q.stream():
            s = snap.to_dict()
            if s.get("createdAt", "") <= cutoff_iso and "outcomePct" not in s:
                out.append({"id": snap.id, **s})
        return out

    # --- jobs ---
    def add_job(self, data: dict) -> str:
        ref = self._db.collection("jobs").document()
        ref.set(data)
        return ref.id

    def claim_queued_jobs(self) -> list[dict]:
        claimed = []
        q = self._db.collection("jobs").where("status", "==", "queued")
        for snap in q.stream():
            fields = {"status": "running", "startedAt": utc_now_iso()}
            snap.reference.update(fields)
            claimed.append({"id": snap.id, **snap.to_dict(), **fields})
        return claimed

    def update_job(self, jid: str, fields: dict) -> None:
        self._db.collection("jobs").document(jid).update(fields)

    def fail_zombie_jobs(self, cutoff_iso: str) -> int:
        n = 0
        q = self._db.collection("jobs").where("status", "==", "running")
        for snap in q.stream():
            if snap.to_dict().get("startedAt", "") < cutoff_iso:
                snap.reference.update({"status": "failed", "error": "runner killed"})
                n += 1
        return n

    def requeue_running_jobs(self) -> int:
        n = 0
        q = self._db.collection("jobs").where("status", "==", "running")
        for snap in q.stream():
            snap.reference.update({"status": "queued"})
            n += 1
        return n
