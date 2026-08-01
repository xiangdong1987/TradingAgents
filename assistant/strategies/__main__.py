"""直跑入口（runner 离线时的兜底）：python -m assistant.strategies turtle [scope]

与 runner 消费 strategy_scan job 调的是同一个 run_scan。注意：runner 在线且已有
排队中的 scan job 时别并发直跑（去重兜底，最坏也只是多一条重复建议）。
"""
from __future__ import annotations

import logging
import sys
from datetime import datetime
from zoneinfo import ZoneInfo


def main(argv: list[str]) -> int:
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    from assistant.store import FirestoreStore
    from assistant.strategies import REGISTRY
    from assistant.strategies.engine import run_scan

    if not argv or argv[0] in ("-h", "--help"):
        names = ", ".join(sorted(REGISTRY)) or "(none)"
        print(f"usage: python -m assistant.strategies <strategy> [scope]\n"
              f"strategies: {names}\nscope: positions | positions+watchlist")
        return 0

    job = {"strategy": argv[0]}
    if len(argv) > 1:
        job["scope"] = argv[1]
    today = datetime.now(ZoneInfo("America/New_York")).strftime("%Y-%m-%d")
    result = run_scan(FirestoreStore.connect(), job, today)
    print(f"scanned {result['scanned']} ticker(s), created {result['created']} suggestion(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
