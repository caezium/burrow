import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SYNC = ROOT / "scripts" / "sentry_issue_sync.py"


def load_sync():
    spec = importlib.util.spec_from_file_location("sentry_issue_sync", SYNC)
    assert spec and spec.loader, f"cannot import {SYNC}"
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


sync = load_sync()
BOTH = {"burrow", "burrow-windows"}


def issue(number, *ids, state="OPEN", reason=None, closed_at=None):
    body = "summary\n" + "\n".join(
        f"<sub>sentry-id: {i} — managed marker, do not edit or remove.</sub>" for i in ids)
    return {"number": number, "state": state, "stateReason": reason,
            "closedAt": closed_at, "body": body}


def status(short_id, status, substatus=""):
    return {short_id: {"status": status, "substatus": substatus}}


class SentryIssueSyncTests(unittest.TestCase):
    def test_project_comes_from_the_short_id_prefix(self) -> None:
        self.assertEqual(sync.project_of("BURROW-WINDOWS-3"), "burrow-windows")
        self.assertEqual(sync.project_of("BURROW-AK"), "burrow")

    def test_open_issue_absent_from_unresolved_is_only_a_candidate(self) -> None:
        issues = [issue(428, "BURROW-AK")]
        self.assertEqual(sync.candidates(issues, [], BOTH), ["BURROW-AK"])
        # Absence alone closes nothing: no confirmed status, no action.
        self.assertEqual(sync.actions(issues, [], BOTH, {}, 50), [])

    def test_confirmed_resolved_closes_as_completed(self) -> None:
        issues = [issue(428, "BURROW-AK")]
        self.assertEqual(
            sync.actions(issues, [], BOTH, status("BURROW-AK", "resolved"), 50),
            [("close", 428, "completed", ["BURROW-AK"])],
        )

    def test_confirmed_ignored_closes_as_not_planned(self) -> None:
        issues = [issue(405, "BURROW-AJ")]
        self.assertEqual(
            sync.actions(issues, [], BOTH, status("BURROW-AJ", "ignored"), 50),
            [("close", 405, "not_planned", ["BURROW-AJ"])],
        )

    def test_status_that_is_still_unresolved_keeps_issue_open(self) -> None:
        # Missing from the list (partial response) but Sentry says unresolved.
        issues = [issue(428, "BURROW-AK")]
        self.assertEqual(
            sync.actions(issues, [], BOTH, status("BURROW-AK", "unresolved"), 50), [])

    def test_listed_unresolved_issue_is_not_even_looked_up(self) -> None:
        issues = [issue(428, "BURROW-AK")]
        rows = [{"shortId": "BURROW-AK", "lastSeen": "2026-09-11T22:29:59Z"}]
        self.assertEqual(sync.candidates(issues, rows, BOTH), [])

    def test_incomplete_project_fetch_skips_its_issues(self) -> None:
        issues = [issue(453, "BURROW-WINDOWS-3"), issue(428, "BURROW-AK")]
        self.assertEqual(sync.candidates(issues, [], {"burrow"}), ["BURROW-AK"])
        statuses = {**status("BURROW-WINDOWS-3", "resolved"), **status("BURROW-AK", "resolved")}
        self.assertEqual(
            sync.actions(issues, [], {"burrow"}, statuses, 50),
            [("close", 428, "completed", ["BURROW-AK"])],
        )

    def test_digest_closes_only_when_every_group_is_confirmed(self) -> None:
        digest = [issue(429, "BURROW-AM", "BURROW-AN")]
        one = status("BURROW-AM", "resolved")
        self.assertEqual(sync.actions(digest, [], BOTH, one, 50), [])
        both = {**one, **status("BURROW-AN", "ignored")}
        self.assertEqual(
            sync.actions(digest, [], BOTH, both, 50),
            [("close", 429, "completed", ["BURROW-AM", "BURROW-AN"])],
        )

    def test_digest_with_a_still_unresolved_group_stays_open(self) -> None:
        digest = [issue(447, "BURROW-AR", "BURROW-AS")]
        rows = [{"shortId": "BURROW-AS", "lastSeen": "2026-09-29T16:26:47Z"}]
        self.assertEqual(sync.candidates(digest, rows, BOTH), [])

    def test_regression_after_close_reopens(self) -> None:
        closed = [issue(374, "BURROW-A5", state="CLOSED", reason="COMPLETED",
                        closed_at="2026-08-19T09:54:03Z")]
        rows = [{"shortId": "BURROW-A5", "lastSeen": "2026-10-01T00:00:00Z"}]
        self.assertEqual(sync.candidates(closed, rows, BOTH), ["BURROW-A5"])
        self.assertEqual(
            sync.actions(closed, rows, BOTH, status("BURROW-A5", "unresolved", "regressed"), 50),
            [("reopen", 374, "regressed", ["BURROW-A5"])],
        )

    def test_unresolved_without_regression_leaves_a_manual_close_alone(self) -> None:
        closed = [issue(374, "BURROW-A5", state="CLOSED", reason="COMPLETED",
                        closed_at="2026-08-19T09:54:03Z")]
        rows = [{"shortId": "BURROW-A5", "lastSeen": "2026-10-01T00:00:00Z"}]
        self.assertEqual(
            sync.actions(closed, rows, BOTH, status("BURROW-A5", "unresolved", "ongoing"), 50), [])

    def test_events_from_before_the_close_do_not_reopen(self) -> None:
        closed = [issue(374, "BURROW-A5", state="CLOSED", reason="COMPLETED",
                        closed_at="2026-08-19T09:54:03Z")]
        rows = [{"shortId": "BURROW-A5", "lastSeen": "2026-08-18T00:00:00Z"}]
        self.assertEqual(sync.candidates(closed, rows, BOTH), [])

    def test_not_planned_closes_never_reopen(self) -> None:
        duplicate = [issue(453, "BURROW-WINDOWS-3", state="CLOSED", reason="NOT_PLANNED",
                           closed_at="2026-10-06T00:00:00Z")]
        rows = [{"shortId": "BURROW-WINDOWS-3", "lastSeen": "2026-10-07T00:00:00Z"}]
        self.assertEqual(sync.candidates(duplicate, rows, BOTH), [])

    def test_issue_without_markers_is_untouched(self) -> None:
        bare = [{"number": 1, "state": "OPEN", "body": "no marker here"}]
        self.assertEqual(sync.candidates(bare, [], BOTH), [])

    def test_malformed_markers_are_ignored(self) -> None:
        self.assertEqual(sync.markers("sentry-id: ../../etc <sub>sentry-id: BURROW-AK</sub>"),
                         ["BURROW-AK"])

    def test_actions_are_capped_per_run(self) -> None:
        issues = [issue(n, f"BURROW-X{n}") for n in range(1, 6)]
        statuses = {}
        for n in range(1, 6):
            statuses.update(status(f"BURROW-X{n}", "resolved"))
        self.assertEqual(len(sync.actions(issues, [], BOTH, statuses, 3)), 3)


if __name__ == "__main__":
    unittest.main()
