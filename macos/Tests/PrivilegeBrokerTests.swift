//
//  PrivilegeBrokerTests.swift
//  BurrowTests
//
//  Boundary tests for the elevated path (issue #48) — the code that runs
//  commands as ROOT, and that no test could previously reach because it
//  spawned a real osascript auth dialog inline.
//
//  Two pure pieces are exercised in memory, with NO osascript, NO sudo, NO GUI:
//    * `AuthCancel` — the rule that decides a dismissed auth prompt vs a
//      command that ran and failed. Shared by the streaming runner
//      (SystemProcessPort.finalEvent) and the one-shot broker, so it's
//      table-tested exhaustively here.
//    * `EngineCLI.elevatedScript` — the two-pass quoter whose output runs as
//      root inside `do shell script`. The injection cases at the bottom are
//      the quoting that, if it broke, would delete the wrong files.
//
//  The scripted-fake broker tests that used to live here went with
//  `EngineCLI.runElevated`/`runElevatedClassified`, deleted once the
//  `mo touchid` setting (their only caller) was removed. `PrivilegeBroker`
//  itself is still live — Connectivity's flush-DNS / renew-DHCP fixes use
//  `SystemPrivilegeBroker.openElevated` — but it is constructed directly at
//  that call site, so there is no injection seam left to drive a fake through.
//

import XCTest
import Darwin
@testable import Burrow

final class PrivilegeBrokerTests: XCTestCase {

    override func tearDown() {
        EngineCLI.discoveryCandidates = nil
        EngineCLI.resetDiscoveryCache()
        super.tearDown()
    }

    // MARK: - Auth-cancel rule (the one engine taxonomy, exhaustive table)
    //
    private static let cancelError = "execution error: User canceled. (-128)\n"

    func testAuthCancel_classifiesDismissedPrompt() {
        XCTAssertTrue(AuthCancel.isAuthCancelled(elevated: true, exitCode: 1,
                                                 appleScriptStderr: Self.cancelError))
        XCTAssertTrue(AuthCancel.isAuthCancelled(elevated: true, exitCode: 1,
                                                 appleScriptStderr: "执行错误：用户已取消。 (-128)"))
    }

    func testAuthCancel_silentFailureIsNotCancellation() {
        XCTAssertFalse(AuthCancel.isAuthCancelled(elevated: true, exitCode: 1,
                                                  appleScriptStderr: ""))
        XCTAssertFalse(AuthCancel.isAuthCancelled(elevated: true, exitCode: 1,
                                                  appleScriptStderr: "execution error: failed (1)"))
    }

    func testAuthCancel_unelevatedNeverCancels() {
        // No elevation = no auth prompt to dismiss.
        XCTAssertFalse(AuthCancel.isAuthCancelled(elevated: false, exitCode: 1,
                                                  appleScriptStderr: Self.cancelError))
    }

    func testAuthCancel_successIsNeverCancel() {
        // Exit 0 is success even when silent.
        XCTAssertFalse(AuthCancel.isAuthCancelled(elevated: true, exitCode: 0,
                                                  appleScriptStderr: Self.cancelError))
    }

    func testAuthCancel_outcomeMapsThePredicate() {
        // The one-shot helper folds the predicate into the named outcome.
        XCTAssertEqual(AuthCancel.outcome(exitCode: 1, appleScriptStderr: Self.cancelError), .authCancelled)
        XCTAssertEqual(AuthCancel.outcome(exitCode: 1, appleScriptStderr: ""), .exited(1))
        XCTAssertEqual(AuthCancel.outcome(exitCode: 0, appleScriptStderr: Self.cancelError), .exited(0))
    }

    /// The streaming runner and the one-shot broker must agree on the rule —
    /// they share `AuthCancel`, so the same inputs land the same way through
    /// both surfaces. Guards against the two paths drifting apart again.
    func testAuthCancel_streamingAndOneShotAgree() {
        for (code, error) in [(Int32(1), Self.cancelError), (Int32(1), ""),
                              (Int32(0), Self.cancelError), (Int32(2), "failure")] {
            let stream = SystemProcessPort.finalEvent(exitCode: code, elevated: true,
                                                      appleScriptStderr: error)
            let oneShot = AuthCancel.outcome(exitCode: code, appleScriptStderr: error)
            switch (stream, oneShot) {
            case (.authCancelled, .authCancelled):
                break
            case (.exited(let a), .exited(let b)):
                XCTAssertEqual(a, b)
            default:
                XCTFail("streaming and one-shot disagreed for exit \(code)")
            }
        }
    }

    // MARK: - ElevatedOutcome back-compat (the preserved Int32 contract)
    //
    // The Int32 shim still backs `Connectivity.run`; both failure
    // shapes must collapse to a nonzero code, exactly as the old inline
    // spawn did (catch → 1, no trusted mo → 127).

    func testElevatedOutcome_exitCodeShim() {
        XCTAssertEqual(ElevatedOutcome.exited(0).exitCode, 0)
        XCTAssertEqual(ElevatedOutcome.exited(3).exitCode, 3)
        XCTAssertNotEqual(ElevatedOutcome.authCancelled.exitCode, 0, "a dismissed prompt is a failure to callers")
        XCTAssertEqual(ElevatedOutcome.launchFailed.exitCode, 127, "matches the old 'no trusted mo' sentinel")
        XCTAssertEqual(ElevatedOutcome.refused(.invalidInvokingUser).exitCode, ElevatedExitCode.requestRefused)
        XCTAssertNotEqual(ElevatedOutcome.refused(.buildMismatch).exitCode, 0, "a refusal is a failure to callers")
        XCTAssertNotEqual(ElevatedOutcome.refused(.buildMismatch).exitCode, ElevatedExitCode.launchFailed,
                          "a refused request must not be rendered as a program that failed verification")
    }

    // MARK: - osascript spec quoting through the broker (injection cases)
    //
    // The string the broker builds runs as ROOT inside `do shell script …`.
    // `SystemPrivilegeBroker` composes it via `EngineCLI.elevatedScript`; these
    // assert the dangerous inputs ride INERT — the quoting that, if it broke,
    // would delete the wrong files. (The builder itself is unit-tested in
    // EngineCLITests; here we pin the broker→builder wiring for real argv.)

    func testElevatedScript_brokerComposesInertRootInvocation() {
        // A path with spaces + args with shell metacharacters: every element
        // single-quoted, the whole thing AppleScript-escaped.
        let command = fakeCommand(path: "/opt/home brew/bin/mo")
        let script = EngineCLI.elevatedScript(command: command,
                                            args: ["clean", "path with 'quotes'", "$(rm -rf /)"])
        XCTAssertTrue(script.hasPrefix("do shell script \""))
        XCTAssertTrue(script.hasSuffix("\" with administrator privileges"))
        // Command substitution stays a literal string, never executes.
        XCTAssertTrue(script.contains("'$(rm -rf /)'"),
                      "metacharacters must ride inert inside single quotes")
        // A single quote in an arg goes through the shell's '\'' dance, whose
        // backslash is then AppleScript-escaped (\\).
        XCTAssertTrue(script.contains(#"'path with '\\''quotes'\\'''"#))
    }

    func testElevatedScript_neutralizesNewlineAndBacktick() {
        let script = EngineCLI.elevatedScript(command: fakeCommand(path: "/usr/local/bin/mo"),
                                            args: ["uninstall", "a\nb", "`whoami`"])
        XCTAssertTrue(script.contains("'`whoami`'"), "backticks inert in single quotes")
        // A newline survives inside the single-quoted arg (no statement break).
        XCTAssertTrue(script.contains("'a\nb'"))
    }

    private func fakeCommand(path: String) -> ValidatedElevatedCommand {
        let identity = PinnedFileIdentity(path: path, device: 1, inode: 2,
                                          owner: 0, mode: UInt16(S_IFREG | 0o755))
        let user = InvokingUserIdentity(uid: 501, username: "test user",
                                        canonicalHome: "/Users/test user")
        return ValidatedElevatedCommand(executable: identity, components: [],
                                        invokingUser: user, signedBundlePath: nil)
    }
}
