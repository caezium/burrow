//
//  EngineRunnerTests.swift
//  BurrowTests
//
//  Boundary tests for the unified runner facade (issue #48). The capture +
//  discovery entry points delegate to injected ports, so they're driven here
//  with scripted fakes — same seam style as MoleProcessTests (capture port).
//  (The one-shot elevated path is NOT on the facade; its pure pieces are
//  covered by PrivilegeBrokerTests.)
//
//  The point of these tests is the WIRING: that a `MoCommand` lands on the
//  capture runner as the exact argv/stdin/env/timeout it described, and that a
//  `.mo` target resolves through the locator (and degrades to a clean nonzero
//  exit when `mo` is missing). The streaming and PTY shapes are wired the same
//  way: the exposed `streamPort` forwards the spec to the injected
//  `ProcessPort` and returns its events untouched, and `interactive()` vends a
//  FRESH session from the injected PTY factory each call — so two hosts can
//  never share one stateful pty.
//

import XCTest
@testable import Burrow

final class EngineRunnerTests: XCTestCase {
    private enum FakeError: Error { case launchFailed }

    // MARK: - Scripted ports

    /// Records the capture call and replays a canned result (or throws).
    private final class FakeCapturePort: MoleProcessPort {
        var result = MoleProcessResult(stdout: "", stderr: "", exitCode: 0)
        var error: Error?

        private(set) var receivedExecutable: String?
        private(set) var receivedArgs: [String]?
        private(set) var receivedStdin: String?
        private(set) var receivedEnvironment: [String: String]?
        private(set) var receivedTimeout: TimeInterval?

        func capture(executable: String,
                     args: [String],
                     stdin: String?,
                     environment: [String: String]?,
                     timeout: TimeInterval) throws -> MoleProcessResult {
            receivedExecutable = executable
            receivedArgs = args
            receivedStdin = stdin
            receivedEnvironment = environment
            receivedTimeout = timeout
            if let error { throw error }
            return result
        }
    }

    /// Canned discovery: the normal lookup is settable so a test can drive
    /// resolution deterministically.
    private struct FakeLocator: MoLocator {
        var located: String?
        func locate() -> String? { located }
    }

    /// Records the streamed spec and replays a canned event script — no real
    /// process, no pipes. Same seam as OperationFlowTests.FakeProcessPort.
    private final class FakeStreamPort: ProcessPort, @unchecked Sendable {
        var script: [ProcessEvent]
        private(set) var specs: [ProcessSpec] = []
        init(script: [ProcessEvent]) { self.script = script }
        func events(_ spec: ProcessSpec) -> AsyncStream<ProcessEvent> {
            specs.append(spec)
            let s = script
            return AsyncStream { cont in
                for e in s { cont.yield(e) }
                cont.finish()
            }
        }
    }

    /// A throwaway PTY session that records nothing but its own identity — the
    /// interactive() test only needs to prove each call returns a DISTINCT
    /// instance (a shared one would let two hosts stomp each other).
    private final class FakePTY: PTYPort {
        var onOutput: ((String) -> Void)?
        var onExit: ((Int32) -> Void)?
        func launch(_ executable: String, _ args: [String]) throws {}
        func send(_ bytes: [UInt8]) {}
        func terminate() {}
    }

    // MARK: - capture: command → port wiring

    func testCapture_resolvesMoTargetThroughLocatorAndForwardsTheCommand() throws {
        let port = FakeCapturePort()
        port.result = MoleProcessResult(stdout: "out", stderr: "err", exitCode: 0)
        let engine = EngineRunner(processPort: port,
                              locator: FakeLocator(located: "/fake/bin/mo"))

        let captured = try engine.capture(MoCommand(
            target: .mo,
            args: ["status", "--json"],
            stdin: "y\n",
            environment: ["PATH": "/tmp"],
            timeout: 8))

        // The result maps field-for-field from the port's MoleProcessResult.
        XCTAssertEqual(captured.stdout, "out")
        XCTAssertEqual(captured.stderr, "err")
        XCTAssertEqual(captured.exitCode, 0)
        // The discovered path, args, stdin, env, and timeout reach the runner
        // unchanged — behavior-preserving translation of the old EngineCLI.run.
        XCTAssertEqual(port.receivedExecutable, "/fake/bin/mo")
        XCTAssertEqual(port.receivedArgs, ["status", "--json"])
        XCTAssertEqual(port.receivedStdin, "y\n")
        XCTAssertEqual(port.receivedEnvironment, ["PATH": "/tmp"])
        XCTAssertEqual(port.receivedTimeout, 8)
    }

    func testCapture_explicitExecutableTargetBypassesDiscovery() throws {
        let port = FakeCapturePort()
        // A locator that would resolve a different mo — proving the explicit
        // path (the brew straggler's shape) wins.
        let engine = EngineRunner(processPort: port,
                              locator: FakeLocator(located: "/fake/bin/mo"))

        _ = try engine.capture(MoCommand(
            target: .executable("/opt/homebrew/bin/brew"),
            args: ["outdated", "--json=v2"],
            timeout: 120))

        XCTAssertEqual(port.receivedExecutable, "/opt/homebrew/bin/brew")
        XCTAssertEqual(port.receivedArgs, ["outdated", "--json=v2"])
    }

    func testCapture_unresolvedMoFallsBackToFalseForACleanNonzeroExit() throws {
        // The locator misses (mo not installed). The facade must NOT throw —
        // it runs /usr/bin/false so the run degrades to a nonzero exit, exactly
        // the way EngineCLI.run did. Uses the REAL capture port for the actual
        // exit code.
        let engine = EngineRunner(locator: FakeLocator(located: nil))

        let captured = try engine.capture(MoCommand(target: .mo, args: ["status"], timeout: 5))

        XCTAssertNotEqual(captured.exitCode, 0, "a missing mo degrades to a nonzero exit, not a crash")
    }

    func testCapture_propagatesLaunchFailureFromPort() {
        let port = FakeCapturePort()
        port.error = FakeError.launchFailed
        let engine = EngineRunner(processPort: port,
                              locator: FakeLocator(located: "/fake/bin/mo"))

        XCTAssertThrowsError(try engine.capture(MoCommand(target: .mo, args: [])))
    }

    func testCapture_carriesTimedOutFlagThrough() throws {
        let port = FakeCapturePort()
        port.result = MoleProcessResult(stdout: "", stderr: "", exitCode: 15, timedOut: true)
        let engine = EngineRunner(processPort: port,
                              locator: FakeLocator(located: "/fake/bin/mo"))

        let captured = try engine.capture(MoCommand(target: .mo, args: ["analyze"], timeout: 1))

        // Issue #48: a timeout says so — the flag rides through the facade so a
        // caller can tell a kill apart from a genuine nonzero exit.
        XCTAssertTrue(captured.timedOut)
        XCTAssertEqual(captured.exitCode, 15)
    }

    func testCapture_defaultTimeoutMatchesTheOldTenSecondDefault() throws {
        let port = FakeCapturePort()
        let engine = EngineRunner(processPort: port,
                              locator: FakeLocator(located: "/fake/bin/mo"))

        _ = try engine.capture(MoCommand(target: .mo, args: []))

        XCTAssertEqual(port.receivedTimeout, 10, "unspecified timeout preserves EngineCLI.run's 10s default")
    }

    func testBundledCapture_rejectsFailedExitEvenWithSuccessOutput() throws {
        try ConductorBundleFixture.withConductor(present: true) {
            let port = FakeCapturePort()
            port.result = MoleProcessResult(
                stdout: #"{"ok":true,"command":"clean","data":{}}"#,
                stderr: "cleanup failed after producing its report", exitCode: 1)
            XCTAssertThrowsError(try BurrowEngine.capture("clean", engine: EngineRunner(processPort: port))) {
                XCTAssertTrue($0.localizedDescription.contains("exit 1"))
            }
        }
    }

    func testBundledCapture_reportsTimeoutEvenAfterOutputWasWritten() throws {
        try ConductorBundleFixture.withConductor(present: true) {
            let port = FakeCapturePort()
            port.result = MoleProcessResult(
                stdout: #"{"ok":true,"command":"status","data":{}}"#,
                stderr: "", exitCode: 15, timedOut: true)
            XCTAssertThrowsError(try BurrowEngine.capture("status", engine: EngineRunner(processPort: port))) {
                XCTAssertTrue($0.localizedDescription.contains("timed out"))
            }
        }
    }

    /// End-to-end through the REAL capture port with a tiny system binary, the
    /// same local-substitutable style EngineCLITests uses for the runner.
    func testCapture_capturesEchoThroughTheRealPort() throws {
        let engine = EngineRunner()
        let captured = try engine.capture(MoCommand(
            target: .executable("/bin/echo"), args: ["hello world"]))

        XCTAssertEqual(captured.exitCode, 0)
        XCTAssertEqual(captured.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello world")
    }

    // MARK: - Discovery availability

    func testAvailability_installedReportsTheLocatedPath() {
        let engine = EngineRunner(locator: FakeLocator(located: "/fake/bin/mo"))
        XCTAssertEqual(engine.availability(), .installed(path: "/fake/bin/mo"))
    }

    func testAvailability_missingWhenLocatorFindsNothing() {
        let engine = EngineRunner(locator: FakeLocator(located: nil))
        XCTAssertEqual(engine.availability(), .missing)
    }

    // MARK: - Streaming (clean / optimize)

    func testStream_forwardsTheSpecToThePortUntouched() {
        let port = FakeStreamPort(script: [.exited(0)])
        let engine = EngineRunner(streamPort: port)

        let spec = ProcessSpec(executable: "/usr/local/bin/mo",
                               arguments: ["clean", "--dry-run"],
                               stdin: nil, elevated: false, timeout: 30)
        _ = engine.streamPort.events(spec)

        // The facade is a pass-through: the port sees the exact spec, never a
        // rewritten one. (Argv/elevation are destructive-path inputs — they
        // must reach SystemProcessPort byte-for-byte.)
        XCTAssertEqual(port.specs.count, 1)
        XCTAssertEqual(port.specs.first, spec)
    }

    func testStream_replaysThePortsEventsInOrder() async {
        let port = FakeStreamPort(script: [
            .line("➤ Developer tools"),
            .line("  → npm cache, 191.8MB"),
            .exited(0),
        ])
        let engine = EngineRunner(streamPort: port)

        var lines: [String] = []
        var exit: Int32?
        for await event in engine.streamPort.events(ProcessSpec(executable: "/usr/local/bin/mo",
                                                     arguments: ["clean"], stdin: nil,
                                                     elevated: false, timeout: nil)) {
            switch event {
            case .line(let l): lines.append(l)
            case .exited(let c): exit = c
            case .authCancelled: XCTFail("the fake never emits auth-cancel")
            }
        }

        // The stream the facade returns IS the port's — same events, same order.
        XCTAssertEqual(lines, ["➤ Developer tools", "  → npm cache, 191.8MB"])
        XCTAssertEqual(exit, 0)
    }

    func testStream_carriesElevatedAuthCancelClassificationThrough() async {
        // The runner classifies auth-cancel; the facade just relays the event.
        let port = FakeStreamPort(script: [.authCancelled])
        let engine = EngineRunner(streamPort: port)

        var sawAuthCancel = false
        for await event in engine.streamPort.events(ProcessSpec(executable: "/usr/local/bin/mo",
                                                     arguments: ["clean"], stdin: nil,
                                                     elevated: true, timeout: nil)) {
            if case .authCancelled = event { sawAuthCancel = true }
        }
        XCTAssertTrue(sawAuthCancel)
    }

    func testStream_productionDefaultIsTheRealSystemPort() async {
        // Default-constructed facade streams through SystemProcessPort, against a
        // tiny system binary — the same local-substitutable style the capture
        // echo test uses. Proves the production wiring spawns for real.
        let engine = EngineRunner()
        var lines: [String] = []
        var exit: Int32?
        for await event in engine.streamPort.events(ProcessSpec(executable: "/bin/sh",
                                                     arguments: ["-c", "printf 'a\\nb\\n'; exit 0"],
                                                     stdin: nil, elevated: false, timeout: nil)) {
            switch event {
            case .line(let l): lines.append(l)
            case .exited(let c): exit = c
            case .authCancelled: XCTFail("un-elevated runs never classify as auth-cancel")
            }
        }
        XCTAssertEqual(lines, ["a", "b"])
        XCTAssertEqual(exit, 0)
    }

    // MARK: - Interactive PTY (purge / installer)

    func testInteractive_vendsTheInjectedFactorysSession() {
        let made = FakePTY()
        let engine = EngineRunner(makePTY: { made })
        XCTAssertTrue(engine.interactive() === made, "interactive() returns the factory's session")
    }

    func testInteractive_vendsAFreshSessionEachCall() {
        // A counter-backed factory: two calls must yield two DISTINCT sessions.
        // A shared pty would let the purge and installer hosts stomp each other's
        // child and keystrokes — the safety reason interactive() is a factory.
        let engine = EngineRunner(makePTY: { FakePTY() })
        let first = engine.interactive()
        let second = engine.interactive()
        XCTAssertFalse(first === second, "each interactive() call owns its own pty session")
    }

    func testInteractive_productionDefaultIsARealPTYTask() {
        // The default factory builds the real PTYTask — the session the purge /
        // installer hosts drive. (Behavioral PTY coverage lives in
        // MoInteractiveHostTests; here we only assert the production type.)
        let engine = EngineRunner()
        XCTAssertTrue(engine.interactive() is PTYTask)
    }
}
