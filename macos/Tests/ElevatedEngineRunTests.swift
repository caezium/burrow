//
//  ElevatedEngineRunTests.swift
//  BurrowTests
//
//  The elevated uninstall apply (GitHub #253, BUR-139) drives the streaming elevation port and
//  collects the engine's transcript into a `Captured`. These pin that reduction against a
//  scripted port — no prompt, no root — and the three outcomes the GUI branches on.
//

import XCTest
@testable import Burrow

final class ElevatedEngineRunTests: XCTestCase {

    private func stream(_ events: [ProcessEvent]) -> AsyncStream<ProcessEvent> {
        AsyncStream { cont in
            for e in events { cont.yield(e) }
            cont.finish()
        }
    }

    func testCollect_joinsTheTranscriptAndKeepsTheExitStatus() {
        let envelope = #"{"ok":true,"burrow_cli":"0.1.0","command":"uninstall","data":{"apps":[]}}"#
        let outcome = ElevatedEngineRun.collect(stream([.line(envelope), .exited(0)]))
        XCTAssertEqual(outcome, .captured(Captured(stdout: envelope, stderr: "", exitCode: 0)))
    }

    func testCollect_aMultiLineTranscriptSurvivesLineByLineDelivery() {
        let outcome = ElevatedEngineRun.collect(stream([.line("{"), .line("  \"ok\": true"), .line("}"), .exited(1)]))
        guard case .captured(let captured) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(captured.stdout, "{\n  \"ok\": true\n}")
        XCTAssertEqual(captured.exitCode, 1, "a partial outcome exits non-zero with an ok:true envelope; keep it")
    }

    func testCollect_dismissedPromptIsAuthCancelled_notAFailedEngineRun() {
        XCTAssertEqual(ElevatedEngineRun.collect(stream([.authCancelled])), .authCancelled)
    }

    func testCollect_launchRefusalCarriesTheRunnersReason() {
        // The runner explains a refused elevation as transcript lines before its sentinel exit;
        // that is not engine output and must not be decoded as one.
        let outcome = ElevatedEngineRun.collect(stream([
            .line("executable failed the bundle seal check"), .exited(ElevatedExitCode.executableRefused),
        ]))
        XCTAssertEqual(outcome, .launchFailed(reason: "executable failed the bundle seal check"))
    }

    func testCollect_aHelperRefusalIsALaunchFailureWithTheDaemonsReason() {
        // The helper route explains a refused request the same way — reason
        // lines, then its own sentinel exit — and it too never ran the engine.
        let reason = HelperRequestRejection.buildMismatch.userExplanation
        let outcome = ElevatedEngineRun.collect(stream([.line(reason), .exited(ElevatedExitCode.requestRefused)]))
        XCTAssertEqual(outcome, .launchFailed(reason: reason))
    }

    func testCollect_aStreamThatEndsWithoutAnExit_isALaunchFailure() {
        guard case .launchFailed = ElevatedEngineRun.collect(stream([.line("half")])) else {
            return XCTFail("no exit status must never read as a run that happened")
        }
    }

    /// `capture` refuses before touching the port when there is no invoking identity to bind the
    /// elevation to; with one, the spec it hands the port is the elevated, bundle-sealed shape.
    func testCapture_buildsAnElevatedBundleSealedSpec() {
        final class RecordingPort: ProcessPort, @unchecked Sendable {
            var spec: ProcessSpec?
            func events(_ spec: ProcessSpec) -> AsyncStream<ProcessEvent> {
                self.spec = spec
                return AsyncStream { $0.yield(.exited(0)); $0.finish() }
            }
        }
        let port = RecordingPort()
        let user = InvokingUserIdentity(uid: 501, username: "test", canonicalHome: "/Users/test")
        _ = ElevatedEngineRun.capture(executable: "/Applications/Burrow.app/Contents/Resources/burrow",
                                      args: ["uninstall", "--apply", "com.x.Y"], timeout: 600,
                                      port: port, invokingUser: user)
        let spec = port.spec
        XCTAssertEqual(spec?.elevated, true)
        XCTAssertEqual(spec?.requiresCurrentBundle, true, "only the sealed engine may run as root")
        XCTAssertNil(spec?.stdin, "the osascript route has no stdin channel; the engine needs none")
        XCTAssertEqual(spec?.arguments, ["uninstall", "--apply", "com.x.Y"])
        XCTAssertEqual(spec?.invokingUser?.canonicalHome, "/Users/test")
        XCTAssertEqual(spec?.timeout, 600)
    }
}
