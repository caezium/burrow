import unittest
import json
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "sentry-issues.yml"
SUMMARY = ROOT / "scripts" / "sentry_public_summary.py"
FIXTURES = ROOT / "scripts" / "tests" / "fixtures"


class SentryIssuesWorkflowTests(unittest.TestCase):
    def test_sensitive_event_fixture_emits_only_reviewed_public_fields(self) -> None:
        result = subprocess.run(
            [
                "python3",
                str(SUMMARY),
                "--issue-file",
                str(FIXTURES / "sentry-sensitive-issue.json"),
                "--event-file",
                str(FIXTURES / "sentry-sensitive-event.json"),
                "--org",
                "henry-zhang-r7",
                "--project",
                "burrow-windows",
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        summary = json.loads(result.stdout)
        serialized = json.dumps(summary, sort_keys=True)

        self.assertEqual(summary["shortId"], "BURROW-WINDOWS-2")
        self.assertEqual(summary["release"], "dev.caezium.Burrow@0.11.2+23")
        self.assertEqual(
            summary["sentryUrl"],
            "https://sentry.io/organizations/henry-zhang-r7/issues/7639318005/",
        )
        for sensitive in (
            "sk-live-SECRET",
            "alice",
            "/Users/",
            "customer.txt",
            "--upload",
            "argv",
            "evil.example",
            "frames",
        ):
            self.assertNotIn(sensitive, serialized)

    def test_workflow_never_copies_raw_sentry_payloads_to_public_issues(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")

        self.assertIn("scripts/sentry_public_summary.py", workflow)
        self.assertIn("Detailed diagnostics stay in restricted Sentry", workflow)
        self.assertNotIn("TRACE_JQ", workflow)
        self.assertNotIn("latest stack trace", workflow)
        self.assertNotIn("Stack trace (most recent event)", workflow)
        self.assertNotIn("${title}", workflow)
        self.assertNotIn("<<<\"$issue\"", workflow)
        self.assertEqual(
            workflow.count("firstSeen=$(jq -r '.firstSeen' \"$summary_json\")"),
            1,
        )

    def test_app_hangs_are_aggregated_instead_of_silently_skipped(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")

        self.assertNotIn("Skipping App-Hang issue", workflow)
        self.assertIn("[Sentry] App-Hang digest", workflow)
        self.assertIn("gh issue edit", workflow)
        self.assertIn("sentry-id: ${shortId}", workflow)

    def test_hang_digests_are_bounded_and_roll_into_numbered_parts(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")

        self.assertIn('MAX_HANG_GROUPS_PER_RUN: "20"', workflow)
        self.assertIn('MAX_ISSUE_BODY_BYTES: "60000"', workflow)
        self.assertNotIn("MAX_HANG_TRACE_CHARS", workflow)
        self.assertIn('digest_title="${digest_base_title} — part ${digest_part}"', workflow)
        self.assertIn("existing_bytes + section_bytes", workflow)

    def test_unreadable_dedup_list_stops_the_run_instead_of_refiling(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")

        # The 2026-10-03 duplicates: stderr hidden and `|| true` turned a
        # failed read into an empty seen-list.
        self.assertNotIn("--json body --jq '.[].body' 2>/dev/null", workflow)
        self.assertNotIn('sort -u > "$seen" || true', workflow)
        self.assertIn("filing nothing this run", workflow)
        self.assertIn('if [ ! -s "$seen" ]; then', workflow)

    def test_state_sync_is_guarded_and_confirms_each_issue(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")

        self.assertIn("scripts/sentry_issue_sync.py candidates", workflow)
        self.assertIn("scripts/sentry_issue_sync.py actions", workflow)
        self.assertIn('if [ "$SENTRY_QUERY" != "is:unresolved" ]; then', workflow)
        self.assertIn("/shortids/${sid}/", workflow)
        self.assertIn('complete_projects="${complete_projects} ${project}"', workflow)
        self.assertEqual(workflow.count("fetch_complete=0"), 3)
        self.assertIn('MAX_SYNC_ACTIONS_PER_RUN: "50"', workflow)

    def test_sentry_issue_poll_follows_cursor_pagination(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")

        self.assertIn('MAX_SENTRY_PAGES_PER_PROJECT: "100"', workflow)
        self.assertIn('-D "$headers" -o "$page"', workflow)
        self.assertIn("'rel=\"next\"'", workflow)
        self.assertIn("'results=\"true\"'", workflow)
        self.assertIn('done < "$response_rows"', workflow)

    def test_hang_digest_carries_bounded_release_and_launch_context(self) -> None:
        summary_filter = SUMMARY.read_text(encoding="utf-8")

        self.assertIn('event_tag(event, "os_build")', summary_filter)
        self.assertIn('event_tag(event, "launch_phase")', summary_filter)
        self.assertIn('event_tag(event, "status_item_state")', summary_filter)
        self.assertIn("release.get(\"version\")", summary_filter)

    def test_regular_issues_carry_the_same_launch_context(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")

        self.assertIn(r'| **Release** | \`${release}\` |', workflow)
        self.assertIn(r'| **OS build** | \`${osBuild}\` |', workflow)
        self.assertIn(r'| **Launch phase** | \`${launchPhase}\` |', workflow)
        self.assertIn(r'| **Status item** | \`${statusItem}\` |', workflow)

    def test_release_shape_is_checked_before_reading_its_version(self) -> None:
        summary_filter = SUMMARY.read_text(encoding="utf-8")

        self.assertIn("if isinstance(release, dict)", summary_filter)
        self.assertIn("return bounded(release)", summary_filter)


if __name__ == "__main__":
    unittest.main()
