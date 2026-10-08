#!/usr/bin/env python3
"""Decide which sentry-labelled GitHub issues to close or reopen.

Sentry decides. An issue closes once every Sentry short-id it carries is
confirmed resolved or ignored there, and reopens only when Sentry reports one
of them regressed after the issue was closed. Issues a person closed as not
planned (duplicates, won't-fix) never reopen.

Two passes keep the network out of the decision logic:

  candidates  short-ids whose status must be confirmed with Sentry
  actions     close/reopen lines, given those confirmed statuses

Absence from the unresolved list is never enough to close anything: a partial
or empty Sentry response would read as "everything resolved". Only an
explicit per-issue status from Sentry closes an issue.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime
from pathlib import Path
from typing import Any


SHORT_ID = re.compile(r"^(?=.{3,80}$)[A-Z0-9]+(?:-[A-Z0-9]+)+$")
MARKER = re.compile(r"sentry-id: ([^ <\s]+)")
CLOSED_STATUSES = {"resolved", "ignored"}


def load_json(path: Path) -> Any:
    if path.stat().st_size > 50 * 1024 * 1024:
        raise ValueError(f"input is unexpectedly large: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def load_json_lines(path: Path) -> list[dict[str, Any]]:
    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.strip():
            value = json.loads(line)
            if isinstance(value, dict):
                rows.append(value)
    return rows


def parse_time(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def project_of(short_id: str) -> str:
    """BURROW-WINDOWS-3 -> burrow-windows; BURROW-AK -> burrow."""
    return short_id.rsplit("-", 1)[0].lower()


def markers(body: Any) -> list[str]:
    if not isinstance(body, str):
        return []
    return sorted({m for m in MARKER.findall(body) if SHORT_ID.fullmatch(m)})


def unresolved_last_seen(rows: list[dict[str, Any]]) -> dict[str, datetime | None]:
    seen: dict[str, datetime | None] = {}
    for row in rows:
        short_id = row.get("shortId")
        if isinstance(short_id, str) and SHORT_ID.fullmatch(short_id):
            seen[short_id] = parse_time(row.get("lastSeen"))
    return seen


def close_candidates(issue: dict[str, Any], unresolved: dict[str, Any],
                     complete: set[str]) -> list[str]:
    if issue.get("state") != "OPEN":
        return []
    ids = markers(issue.get("body"))
    if not ids or any(project_of(i) not in complete for i in ids):
        return []
    if any(i in unresolved for i in ids):
        return []
    return ids


def reopen_candidates(issue: dict[str, Any],
                      unresolved: dict[str, datetime | None]) -> list[str]:
    if issue.get("state") != "CLOSED" or issue.get("stateReason") != "COMPLETED":
        return []
    closed_at = parse_time(issue.get("closedAt"))
    if closed_at is None:
        return []
    out = []
    for short_id in markers(issue.get("body")):
        last_seen = unresolved.get(short_id)
        if last_seen is not None and last_seen > closed_at:
            out.append(short_id)
    return out


def candidates(issues: list[dict[str, Any]], unresolved_rows: list[dict[str, Any]],
               complete: set[str]) -> list[str]:
    unresolved = unresolved_last_seen(unresolved_rows)
    wanted: set[str] = set()
    for issue in issues:
        wanted.update(close_candidates(issue, unresolved, complete))
        wanted.update(reopen_candidates(issue, unresolved))
    return sorted(wanted)


def actions(issues: list[dict[str, Any]], unresolved_rows: list[dict[str, Any]],
            complete: set[str], statuses: dict[str, dict[str, str]],
            limit: int) -> list[tuple[str, int, str, list[str]]]:
    unresolved = unresolved_last_seen(unresolved_rows)
    out: list[tuple[str, int, str, list[str]]] = []
    for issue in sorted(issues, key=lambda i: i.get("number", 0)):
        number = issue.get("number")
        if not isinstance(number, int):
            continue

        ids = close_candidates(issue, unresolved, complete)
        found = [statuses.get(i, {}).get("status") for i in ids]
        if ids and all(s in CLOSED_STATUSES for s in found):
            reason = "not_planned" if all(s == "ignored" for s in found) else "completed"
            out.append(("close", number, reason, ids))
            continue

        regressed = [i for i in reopen_candidates(issue, unresolved)
                     if statuses.get(i, {}).get("substatus") == "regressed"]
        if regressed:
            out.append(("reopen", number, "regressed", regressed))

    return out[:limit]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["candidates", "actions"])
    parser.add_argument("--issues", type=Path, required=True,
                        help="gh issue list --json number,state,stateReason,closedAt,body")
    parser.add_argument("--unresolved", type=Path, required=True,
                        help="JSON lines of {shortId, lastSeen} Sentry listed as unresolved")
    parser.add_argument("--complete", default="",
                        help="space-separated projects whose unresolved list was fully fetched")
    parser.add_argument("--statuses", type=Path,
                        help="JSON lines of {shortId, status, substatus} confirmed with Sentry")
    parser.add_argument("--limit", type=int, default=50)
    args = parser.parse_args()

    issues = load_json(args.issues)
    if not isinstance(issues, list):
        raise ValueError("issues input is not a JSON array")
    unresolved_rows = load_json_lines(args.unresolved)
    complete = set(args.complete.split())

    if args.mode == "candidates":
        for short_id in candidates(issues, unresolved_rows, complete):
            print(short_id)
        return 0

    statuses: dict[str, dict[str, str]] = {}
    if args.statuses is not None:
        for row in load_json_lines(args.statuses):
            short_id = row.get("shortId")
            if isinstance(short_id, str) and SHORT_ID.fullmatch(short_id):
                statuses[short_id] = {
                    "status": str(row.get("status") or ""),
                    "substatus": str(row.get("substatus") or ""),
                }
    for action, number, reason, ids in actions(
            issues, unresolved_rows, complete, statuses, args.limit):
        print(f"{action}\t{number}\t{reason}\t{','.join(ids)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
