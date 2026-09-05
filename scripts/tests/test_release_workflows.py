import unittest
import json
import plistlib
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"


class ReleaseWorkflowTests(unittest.TestCase):
    def test_app_version_has_one_source_and_generated_metadata_is_checked(self) -> None:
        project = (ROOT / "macos" / "project.yml").read_text(encoding="utf-8")
        with (ROOT / "macos" / "Resources" / "Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        ci = (WORKFLOWS / "ci.yml").read_text(encoding="utf-8")
        mcp = (ROOT / "macos" / "Sources" / "MCP.swift").read_text(encoding="utf-8")

        self.assertEqual(
            len(re.findall(r'^\s+MARKETING_VERSION: "[0-9]+\.[0-9]+\.[0-9]+"$', project, re.MULTILINE)),
            1,
        )
        self.assertEqual(
            len(re.findall(r'^\s+CURRENT_PROJECT_VERSION: "[1-9][0-9]*"$', project, re.MULTILINE)),
            1,
        )
        self.assertIn('CFBundleShortVersionString: "$(MARKETING_VERSION)"', project)
        self.assertIn('CFBundleVersion: "$(CURRENT_PROJECT_VERSION)"', project)
        self.assertEqual(info["CFBundleShortVersionString"], "$(MARKETING_VERSION)")
        self.assertEqual(info["CFBundleVersion"], "$(CURRENT_PROJECT_VERSION)")
        self.assertIn("verify-project-generation.py", ci)
        self.assertIn("--check-git", ci)
        self.assertNotIn('"version": "0.3.0"', mcp)

    def test_release_sources_and_tools_are_content_locked(self) -> None:
        lock = json.loads(
            (ROOT / "scripts" / "release-inputs.json").read_text(encoding="utf-8")
        )
        ci = (WORKFLOWS / "ci.yml").read_text(encoding="utf-8")
        release = (WORKFLOWS / "release.yml").read_text(encoding="utf-8")

        self.assertEqual(lock["swiftPackages"], [])
        for group in ("frameworks", "tools"):
            for dependency in lock[group].values():
                self.assertRegex(dependency["version"], r"^[0-9]+\.[0-9]+\.[0-9]+$")
                self.assertRegex(dependency["sha256"], r"^[0-9a-f]{64}$")
                self.assertTrue(dependency["url"].startswith("https://github.com/"))

        self.assertNotIn("brew install xcodegen", ci)
        self.assertNotIn("brew install xcodegen", release)
        self.assertNotIn("brew install sentry-cli", release)
        self.assertIn("fetch-xcodegen.sh", ci)
        self.assertIn("fetch-xcodegen.sh", release)
        self.assertIn("fetch-sentry-cli.sh", release)

    def test_exact_tag_runs_required_tests_before_release_build_and_publish(self) -> None:
        workflow = (WORKFLOWS / "release.yml").read_text(encoding="utf-8")

        test_gate = workflow.index("- name: Test exact tagged commit")
        release_build = workflow.index("- name: Build (Release)")
        publish = workflow.index("- name: Publish verified GitHub release")
        gate = workflow[test_gate:release_build]

        self.assertLess(test_gate, release_build)
        self.assertLess(release_build, publish)
        self.assertIn('git rev-parse HEAD', gate)
        self.assertIn('"$GITHUB_SHA"', gate)
        self.assertIn("verify-project-generation.py", gate)
        self.assertIn("--check-git", gate)
        self.assertIn("python3 -m unittest discover", gate)
        self.assertIn("node --test scripts/tests/test_site_analytics.mjs", gate)
        self.assertIn("xcodebuild test", gate)

    def test_symbols_are_required_and_match_the_distributed_binary(self) -> None:
        workflow = (WORKFLOWS / "release.yml").read_text(encoding="utf-8")

        credentials = workflow.index("- name: Require release credentials")
        upload = workflow.index("- name: Verify and upload release dSYM")
        download = workflow.index("- name: Verify downloaded release artifact")
        publish = workflow.index("- name: Publish verified GitHub release")

        self.assertIn("SENTRY_AUTH_TOKEN", workflow[credentials:upload])
        self.assertNotIn("skipped if no token", workflow)
        self.assertIn("verify-dsym-uuids.sh", workflow[upload:publish])
        self.assertIn("debug-files check", workflow[upload:download])
        self.assertIn("debug-files upload", workflow[upload:download])
        self.assertLess(upload, download)
        self.assertLess(download, publish)

    def test_windows_release_tests_checked_out_commit_before_publishing(self) -> None:
        workflow = (WORKFLOWS / "windows-release.yml").read_text(encoding="utf-8")
        gate_start = workflow.index("- name: Test release commit")
        publish_start = workflow.index("- name: Publish (telemetry keys baked from secrets)")
        upload_start = workflow.index("- name: Upload published app")
        gate = workflow[gate_start:publish_start]

        self.assertLess(gate_start, publish_start)
        self.assertLess(publish_start, upload_start)
        self.assertIn(r"dotnet test .\Tests\BurrowWin.Tests\BurrowWin.Tests.csproj", gate)
        self.assertNotIn("--no-build", gate)
        self.assertNotIn("continue-on-error", gate)
        self.assertNotIn("if:", gate)
        self.assertIn('"$env:BUILD_CONFIGURATION"', gate)

    def test_release_stays_draft_until_downloaded_artifact_passes_trust_checks(self) -> None:
        workflow = (WORKFLOWS / "release.yml").read_text(encoding="utf-8")

        upload = workflow.index("- name: Upload GitHub release draft")
        verify = workflow.index("- name: Verify downloaded release artifact")
        publish = workflow.index("- name: Publish verified GitHub release")
        homebrew = workflow.index("- name: Bump Homebrew cask")
        verification = workflow[verify:publish]

        self.assertLess(upload, verify)
        self.assertLess(verify, publish)
        self.assertLess(publish, homebrew)
        self.assertIn('if [ "$IS_DRAFT" != "true" ]', workflow[upload:verify])
        self.assertIn("gh release download", verification)
        self.assertIn('steps.pkg.outputs.sha', verification)
        self.assertIn("verify-macos-release.sh", verification)
        self.assertIn("verify-dsym-uuids.sh", verification)
        self.assertIn('"$EXPECTED_TEAM_ID"', verification)
        self.assertIn('gh release edit "$GITHUB_REF_NAME" --draft=false', workflow[publish:homebrew])

    def test_macos_release_verifier_pins_the_designated_requirement(self) -> None:
        verifier = (ROOT / "scripts" / "verify-macos-release.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn("codesign --verify --deep --strict", verifier)
        self.assertIn("codesign -d -r-", verifier)
        self.assertIn("anchor apple generic", verifier)
        self.assertIn("subject\\.OU", verifier)
        self.assertIn("xcrun stapler validate", verifier)
        self.assertIn("spctl --assess --type execute", verifier)

    def test_tap_permission_check_runs_before_the_release_build(self) -> None:
        workflow = (WORKFLOWS / "release.yml").read_text(encoding="utf-8")

        require_credentials = workflow.index("- name: Require release credentials")
        verify_tap = workflow.index("- name: Verify Homebrew tap write access")
        build_release = workflow.index("- name: Build (Release)")

        self.assertLess(require_credentials, verify_tap)
        self.assertLess(verify_tap, build_release)
        self.assertIn(
            "run: bash scripts/verify-homebrew-tap-access.sh",
            workflow[verify_tap:build_release],
        )

    def test_manual_tap_check_uses_the_same_isolated_verifier(self) -> None:
        workflow = (WORKFLOWS / "homebrew-tap-credential-check.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn("workflow_dispatch:", workflow)
        self.assertIn("permissions:\n  contents: read", workflow)
        self.assertIn(
            "run: bash scripts/verify-homebrew-tap-access.sh",
            workflow,
        )
        self.assertIn("persist-credentials: false", workflow)

    def test_tap_verifier_pushes_and_removes_a_temporary_ref(self) -> None:
        verifier = (ROOT / "scripts" / "verify-homebrew-tap-access.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn("burrow-release-access-probe-", verifier)
        self.assertIn('push --quiet origin "HEAD:$probe_ref"', verifier)
        self.assertIn('push --quiet origin ":$probe_ref"', verifier)
        self.assertNotIn('push --dry-run origin "HEAD:$probe_ref"', verifier)

    def test_release_does_not_leak_engine_credentials_into_tap_push(self) -> None:
        workflow = (WORKFLOWS / "release.yml").read_text(encoding="utf-8")
        tap_start = workflow.index(
            "- name: Bump Homebrew cask in caezium/homebrew-tap"
        )
        tap_step = workflow[tap_start:]

        # `persist-credentials: false` has to be on the CHECKOUT, not merely somewhere in the
        # file — a bare `assertIn` over the whole workflow passes even if the flag drifts onto
        # an unrelated step and the checkout starts leaving GITHUB_TOKEN in .git/config for the
        # tap push to reuse. Pin it to the one `actions/checkout` step this job runs.
        checkout_start = workflow.index("- uses: actions/checkout@")
        checkout_step = workflow[checkout_start : workflow.index("- name:", checkout_start)]
        self.assertIn("persist-credentials: false", checkout_step)
        self.assertEqual(
            workflow.count("- uses: actions/checkout@"),
            1,
            "a second checkout step would need its own persist-credentials assertion",
        )
        # The tap is `git clone`d rather than checked out, so it never inherits the runner's
        # credentials; what it must not do is install a global rewrite that would.
        self.assertNotIn("git config --global url.", workflow)
        self.assertNotIn("actions/checkout@", tap_step)

        # This used to assert `export GIT_CONFIG_COUNT=1` in the build step: a
        # process-scoped URL rewrite, so ENGINE_PAT could reach the private
        # burrow-engine crate during the conductor's cargo build without becoming
        # the credential the later Homebrew push used. The repoint deleted the
        # conductor, and burrow-engine's own Cargo.toml has no git dependencies,
        # so there is nothing left in the build that needs to authenticate to
        # GitHub. Not having the token in the step at all is strictly stronger
        # than scoping the rewrite, so that is what gets pinned now.
        build_start = workflow.index("- name: Build (Release)")
        build_end = workflow.index(
            "- name: Verify the bundled engine made it into the app"
        )
        build_step = workflow[build_start:build_end]
        self.assertNotIn(
            "ENGINE_PAT: ${{ secrets.ENGINE_PAT }}",
            build_step,
            "the release build must not receive the engine token at all",
        )
        self.assertNotIn("CARGO_NET_GIT_FETCH_WITH_CLI", build_step)

        # Neither the checkout nor the tap push may receive the engine token — INCLUDING by
        # inheritance, which a per-step search cannot see. A workflow- or job-level `env:` block
        # is handed to every step in the job, so ENGINE_PAT declared there would reach the tap
        # push while each step's own text stayed clean. Step-level `env:` sits at 8 spaces here;
        # anything shallower is an outer block.
        for name, step in (("checkout", checkout_step), ("tap push", tap_step)):
            self.assertNotIn(
                "ENGINE_PAT", step, f"the {name} step must not see the engine token"
            )
        self.assertEqual(
            workflow.count("ENGINE_PAT: ${{ secrets.ENGINE_PAT }}"),
            1,
            "the engine token belongs to the fetch step alone",
        )
        lines = workflow.splitlines()
        for i, line in enumerate(lines):
            stripped = line.lstrip()
            indent = len(line) - len(stripped)
            if stripped != "env:" or indent >= 8:
                continue  # step-scoped: reaches only its own step
            # An outer `env:` IS inherited by every step in the job, so what matters is
            # whether it carries the token — not that it exists. A job-level block of
            # ordinary config (EXPECTED_TEAM_ID) is fine and release.yml has one.
            body = []
            for nxt in lines[i + 1 :]:
                if nxt.strip() and (len(nxt) - len(nxt.lstrip())) <= indent:
                    break
                body.append(nxt)
            self.assertNotIn(
                "ENGINE_PAT",
                "\n".join(body),
                "an inherited workflow- or job-level `env:` reaches every step, including "
                f"the tap push — keep the engine token step-scoped: {body!r}",
            )

        # ENGINE_PAT survives only in the fetch step, where every use is scoped
        # to one `git -c` invocation that writes no config anywhere.
        for line in workflow.splitlines():
            if "insteadOf" in line:
                self.assertIn('git -c "url.', line)
        self.assertIn(
            'export GIT_CONFIG_GLOBAL="$RUNNER_TEMP/burrow-tap-gitconfig"',
            tap_step,
        )
        self.assertIn('(cd "$RUNNER_TEMP" && git clone', tap_step)
        self.assertIn('cd "$TAP_DIR"', tap_step)

    def test_windows_release_scopes_engine_credentials_and_pins_actions(self) -> None:
        workflow = (WORKFLOWS / "windows-release.yml").read_text(encoding="utf-8")
        windows_ci = (WORKFLOWS / "windows-ci.yml").read_text(encoding="utf-8")

        # The engine token may never be written to persistent git config: a `--global`
        # rewrite outlives the step that set it and becomes the credential every later
        # step (and every later `git` invocation) silently uses.
        for text in (workflow, windows_ci):
            self.assertNotIn("git config --global", text)
        # ENGINE_PAT is used exactly two ways, both process-scoped: a `git -c` on the one
        # clone, and the GIT_CONFIG_* environment for the one cargo build — removed again in
        # `finally` so nothing after the build inherits it.
        for line in workflow.splitlines():
            if "insteadOf" in line and not line.strip().startswith("#"):
                self.assertTrue(
                    'git -c "url.' in line or "GIT_CONFIG_KEY_0" in line,
                    f"unscoped credential rewrite: {line.strip()}",
                )
        build_start = workflow.index("- name: Build + stage burrow conductor")
        build_end = workflow.index("- name: Telemetry key presence")
        build_step = workflow[build_start:build_end]
        self.assertIn("$env:GIT_CONFIG_COUNT = '1'", build_step)
        self.assertIn("Remove-Item Env:GIT_CONFIG_COUNT, Env:GIT_CONFIG_KEY_0, Env:GIT_CONFIG_VALUE_0", build_step)
        self.assertEqual(
            workflow.count("ENGINE_PAT: ${{ secrets.ENGINE_PAT }}"),
            1,
            "the engine token belongs to the conductor build step alone",
        )
        # burrow-cli is private: exactly one clone, authenticated, and the run fails closed
        # when the token is absent — no unauthenticated first attempt to mask a 403.
        self.assertEqual(build_step.count("clone --quiet https://github.com/caezium/burrow-cli.git"), 1)
        self.assertIn("if (-not $env:ENGINE_PAT)", build_step)
        self.assertIn("exit 1", build_step)
        # The publish output is hard-asserted, never warned about.
        self.assertIn('verify-mole-runtime.ps1', workflow)
        self.assertIn(r'-Conductor .\artifacts\release-publish\Assets\burrow.exe', workflow)
        verifier = (ROOT / 'windows' / 'scripts' / 'verify-mole-runtime.ps1').read_text(encoding='utf-8')
        self.assertIn('throw "Bundled conductor is missing:', verifier)

        # Every action in both Windows workflows is pinned to a commit SHA with a version
        # comment, like ci.yml — a floating major tag is whatever the publisher pushes next.
        for name, text in (("windows-release.yml", workflow), ("windows-ci.yml", windows_ci)):
            for line in text.splitlines():
                stripped = line.strip()
                if not stripped.startswith(("uses:", "- uses:")):
                    continue
                self.assertRegex(
                    stripped,
                    r"uses: [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+$",
                    f"{name}: unpinned action: {stripped}",
                )

    def test_windows_maintenance_sources_and_imports_are_checked_before_upload(self) -> None:
        release = (WORKFLOWS / "windows-release.yml").read_text(encoding="utf-8")
        ci = (WORKFLOWS / "windows-ci.yml").read_text(encoding="utf-8")
        verifier = (ROOT / "windows/scripts/verify-mole-runtime.ps1").read_text(encoding="utf-8")
        for command in ("clean", "optimize"):
            path = f"bin/{command}.ps1"
            self.assertTrue((ROOT / "windows/Assets/Mole" / path).is_file())
            self.assertIn(path, verifier)
        self.assertIn("Parser]::ParseFile", verifier)
        for workflow in (release, ci):
            self.assertIn("test-mole-runtime.ps1", workflow)
            self.assertIn("verify-mole-runtime.ps1", workflow)
        self.assertLess(release.index("test-mole-runtime.ps1"), release.index("- name: Publish ("))
        self.assertLess(release.index("verify-mole-runtime.ps1"), release.index("- name: Upload published app"))

    def test_release_notes_are_validated_before_sparkle_embeds_them(self) -> None:
        workflow = (WORKFLOWS / "release.yml").read_text(encoding="utf-8")

        validate = workflow.index("scripts/validate-release-notes.py")
        embed = workflow.index('cp RELEASES.md "dist/Burrow-${VERSION}.md"')

        self.assertLess(validate, embed)

    def test_manual_notes_repair_is_narrow_and_fail_closed(self) -> None:
        workflow = (WORKFLOWS / "repair-sparkle-release-notes.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn("workflow_dispatch:", workflow)
        self.assertNotIn("push:", workflow)
        self.assertIn("contents: write", workflow)
        self.assertIn("group: release", workflow)
        self.assertIn("persist-credentials: false", workflow)
        self.assertIn('if [ "$GITHUB_REF" != "refs/heads/$DEFAULT_BRANCH" ]', workflow)
        self.assertIn("scripts/validate-release-notes.py", workflow)
        self.assertIn("scripts/verify-sparkle-appcast.py", workflow)
        self.assertIn("SPARKLE_ED_PRIVATE_KEY", workflow)
        self.assertIn('gh release upload "$TAG" "$APPCAST"', workflow)
        self.assertIn("--clobber", workflow)
        self.assertIn('gh release edit "$TAG"', workflow)
        self.assertIn("--notes-file RELEASES.md", workflow)
        self.assertNotIn('gh release upload "$TAG" "$ZIP"', workflow)
        self.assertIn('sign_update" --verify', workflow)

        verify_start = workflow.index("- name: Verify the published repair")
        verify_step = workflow[verify_start:]
        self.assertIn(
            "ASSET_NAME: ${{ steps.target.outputs.asset_name }}", verify_step
        )
        self.assertIn(
            "EXPECTED_DIGEST: ${{ steps.target.outputs.asset_digest }}", verify_step
        )
        self.assertIn(
            'if [ "$PUBLISHED_DIGEST" != "$EXPECTED_DIGEST" ]', verify_step
        )

    def test_xcode_27_preview_lane_is_advisory_and_runs_the_full_suite(self) -> None:
        workflow = (WORKFLOWS / "ci.yml").read_text(encoding="utf-8")
        start = workflow.index("  xcode-27-compatibility:")
        end = workflow.index("  fclones-sidecar:", start)
        job = workflow[start:end]

        self.assertIn("runs-on: xcode-27", job)
        self.assertIn("continue-on-error: true", job)
        self.assertIn("bash ../scripts/fetch-sentry.sh", job)
        self.assertIn("bash ../scripts/fetch-sparkle.sh", job)
        self.assertIn("xcodegen generate", job)
        self.assertIn("xcodebuild test", job)


if __name__ == "__main__":
    unittest.main()
