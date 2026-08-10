//
//  OperationFlowTests.swift
//  BurrowTests
//
//  Boundary tests for the operation flow shell — the run-a-tool lifecycle
//  (FDA gate → optional elevation → spawn → stream → reduce → report →
//  OperationCenter) that CleanView/OptimizeView previously each owned as
//  view plumbing. The process boundary is a scripted fake; no real
//  processes, no TCC, no wall-clock.
//

import XCTest
@testable import Burrow

@MainActor
final class OperationFlowTests: XCTestCase {

    // MARK: Test adapter

    final class FakeProcessPort: ProcessPort, @unchecked Sendable {
        var script: [ProcessEvent]
        /// Keep the stream open after the script (for cancel tests).
        var holdOpen = false
        private(set) var specs: [ProcessSpec] = []
        private(set) var terminated = false

        init(script: [ProcessEvent]) { self.script = script }

        func events(_ spec: ProcessSpec) -> AsyncStream<ProcessEvent> {
            specs.append(spec)
            let s = script, hold = holdOpen
            return AsyncStream { cont in
                cont.onTermination = { @Sendable _ in self.terminated = true }
                for e in s { cont.yield(e) }
                if !hold { cont.finish() }
            }
        }
    }

    /// Canned dry-run output in mo's report shape (parseTaskReport-compatible).
    // The human-text output the `cleanOp()` fixture's `parseTaskReport` reducer consumes.
    static let cannedClean: [ProcessEvent] = [
        .line("➤ Developer tools"),
        .line("  → npm cache, 191.8MB"),
        .line("Potential space: 383.8MB | Items: 372 | Categories: 20"),
        .exited(0),
    ]

    // The engine's `clean --stream` NDJSON preview, which the `moleStream(...)` op's
    // BurrowStreamReport reducer consumes. A dry-run done carries `would_free_human` →
    // summary.space (no freeChange), so the completion line reads "Cleaned 383.8MB · 372 items"
    // — same summary the old human-text "Potential space" preview produced.
    static let cannedCleanStream: [ProcessEvent] = [
        .line(#"{"event":"would_remove","path":"/Users/x/Library/Caches/npm cache","bytes":201129000}"#),
        .line(#"{"event":"done","dry_run":true,"would_free_bytes":402438000,"would_free_human":"383.8MB","count":372}"#),
        .exited(0),
    ]

    typealias CleanReport = (groups: [TaskGroup], summary: TaskSummary?)

    static func cleanOp(gate: ToolOperation<CleanReport>.Gate = .none,
                        elevated: Bool = false) -> ToolOperation<CleanReport> {
        ToolOperation(label: "Scanning caches",
                      arguments: ["clean", "--dry-run"],
                      gate: gate,
                      elevated: elevated,
                      reduce: { parseTaskReport($0) },
                      hudLine: { TaskReportText.line($0) })
    }

    private func makeFlow(_ port: FakeProcessPort, fda: @escaping () -> Bool = { true },
                          center: OperationCenter? = nil) -> OperationFlow<CleanReport> {
        OperationFlow(process: port, hasFullDiskAccess: fda,
                      resolveMo: { _ in "/usr/local/bin/mo" }, center: center ?? OperationCenter())
    }

    private func settle<R>(_ flow: OperationFlow<R>) async {
        for _ in 0..<1000 {
            if case .finished = flow.state { return }
            await Task.yield()
        }
        XCTFail("flow never finished")
    }

    // MARK: Tests

    func testGate_blocksWithoutFDAThenGrantRuns() async throws {
        let port = FakeProcessPort(script: Self.cannedClean)
        var fda = false
        let flow = makeFlow(port, fda: { fda })

        flow.start(Self.cleanOp(gate: .fullDiskAccess(adminBypass: true)))
        guard case .gated(let pending) = flow.state else { return XCTFail("expected FDA gate") }
        XCTAssertTrue(port.specs.isEmpty, "nothing spawns while gated")

        fda = true
        flow.start(pending)                       // "I've granted it" = start again
        await settle(flow)

        XCTAssertEqual(port.specs.last?.elevated, false)
        XCTAssertEqual(flow.report?.summary?.space, "383.8MB")
        XCTAssertEqual(flow.report?.groups.count, 1)
        guard case .finished(.done(exit: 0)) = flow.state else { return XCTFail("expected done(0)") }
    }

    func testGate_adminBypassRunsElevatedWithoutGate() async throws {
        let port = FakeProcessPort(script: Self.cannedClean)
        let flow = makeFlow(port, fda: { false })

        flow.start(Self.cleanOp(gate: .fullDiskAccess(adminBypass: true)))
        guard case .gated(let pending) = flow.state else { return XCTFail("expected gate") }

        flow.start(pending.elevated())            // "Scan with admin" — root dodges TCC
        await settle(flow)
        XCTAssertEqual(port.specs.last?.elevated, true)
        guard case .finished(.done) = flow.state else { return XCTFail("expected done") }
    }

    func testCancel_terminatesChildAndMarksCancelled() async throws {
        let port = FakeProcessPort(script: [.line("➤ Working")])
        port.holdOpen = true                      // process never exits on its own
        let flow = makeFlow(port)

        flow.start(Self.cleanOp())
        XCTAssertTrue(flow.canCancel)
        flow.cancel()

        guard case .finished(.cancelled) = flow.state else { return XCTFail("expected cancelled") }
        for _ in 0..<1000 { if port.terminated { break }; await Task.yield() }
        XCTAssertTrue(port.terminated, "cancelling the flow terminates the child")
    }

    func testElevatedRunCannotCancel() {
        let port = FakeProcessPort(script: [.line("x")])
        port.holdOpen = true
        let flow = makeFlow(port)
        flow.start(Self.cleanOp(elevated: true))
        XCTAssertFalse(flow.canCancel,
                       "SIGTERMing the osascript messenger would orphan the root child")
    }

    func testStdinTimeoutAndPathExecutableReachSpec() async throws {
        let port = FakeProcessPort(script: [.exited(0)])
        let flow = OperationFlow<String>(process: port, hasFullDiskAccess: { true },
                                         resolveMo: { _ in nil }, center: OperationCenter())
        // Uninstall-style blocking run: canned confirmations + long timeout.
        let answers = String(repeating: "y\n", count: 16)
        flow.start(ToolOperation(label: nil,
                                 executable: .path("/opt/homebrew/bin/brew"),
                                 arguments: ["upgrade", "wget"],
                                 stdin: answers,
                                 timeout: 300,
                                 reduce: { $0.joined(separator: "\n") }))
        await settle(flow)
        let spec = try XCTUnwrap(port.specs.first)
        XCTAssertEqual(spec.executable, "/opt/homebrew/bin/brew")
        XCTAssertEqual(spec.stdin, answers)
        XCTAssertEqual(spec.timeout, 300)
    }

    func testOperationCenter_beginDetailEnd() async throws {
        let port = FakeProcessPort(script: Self.cannedClean)
        let center = OperationCenter()
        let flow = makeFlow(port, center: center)

        flow.start(Self.cleanOp())
        await settle(flow)

        let op = try XCTUnwrap(center.ops.first)
        XCTAssertEqual(op.label, "Scanning caches")
        XCTAssertEqual(op.phase, .done)
        XCTAssertFalse(op.detail.isEmpty, "HUD detail fed from the stream")
        XCTAssertFalse(op.notifiesOnEnd, "preview-style ops never notify")
    }

    // The real-clean shape: notifyOnEnd rides into the OperationCenter op
    // and the parsed summary replaces the last streamed line as the final
    // detail — that's the body a completion notification carries.
    func testNotifyOnEnd_andFinalDetail_reachOperationCenter() async throws {
        let port = FakeProcessPort(script: Self.cannedCleanStream)
        let center = OperationCenter()
        let flow = OperationFlow<TaskRunReport>(process: port, hasFullDiskAccess: { true },
                                                resolveMo: { _ in "/usr/local/bin/mo" }, center: center)

        flow.start(.moleStream(["clean"], label: "Cleaning caches", notifyOnEnd: true))
        await settle(flow)

        let op = try XCTUnwrap(center.ops.first)
        XCTAssertTrue(op.notifiesOnEnd)
        XCTAssertEqual(op.phase, .done)
        XCTAssertEqual(op.detail, "Cleaned 383.8MB · 372 items",
                       "final detail is the parsed summary, not the last raw line")
    }

    func testAuthCancelledFromThePort_failsTheFlow() async throws {
        // Auth-cancel is classified by the RUNNER now (issue #48) — the flow
        // just renders the failure.
        let port = FakeProcessPort(script: [.authCancelled])
        let flow = makeFlow(port)
        flow.start(Self.cleanOp(elevated: true))
        await settle(flow)
        guard case .finished(.failed) = flow.state else { return XCTFail("expected failed") }
    }

    func testNonzeroPrivilegedCleanupFailsVisiblyAndNeverCompletesTheHUD() async throws {
        var parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-operation-flow-cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        parent = URL(fileURLWithPath: try XCTUnwrap(
            InvokingUserIdentity.canonicalPath(parent.path)), isDirectory: true)
        let item = parent.appendingPathComponent("reviewed-cache")
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let snapshot = try CleanupSnapshot.capture(
            list: CleanList(categories: [
                .init(name: "Test", items: [
                    .init(path: item.path, sizeBytes: 1, sizeText: "1B", itemCount: nil),
                ]),
            ], summaryTotalText: "1B", summaryItemCount: 1),
            approvedRootURLs: [parent])
        let plan = try snapshot.plan(selectedPaths: [item.path])

        let port = FakeProcessPort(script: [.exited(ElevatedExitCode.boundaryCheckFailed)])
        let center = OperationCenter()
        let flow = makeFlow(port, center: center)
        var operation = Self.cleanOp(elevated: true)
        operation.cleanupPlan = plan
        flow.start(operation)
        await settle(flow)

        guard case .finished(.failed(let message)) = flow.state else {
            return XCTFail("a fail-closed cleanup exit must not become done")
        }
        // A refused boundary check means NOTHING was deleted, so the message
        // must say so rather than implying a partial run.
        XCTAssertTrue(message.contains("Nothing was cleaned"), message)
        XCTAssertTrue(message.contains("Rescan"), message)
        XCTAssertNil(flow.report, "a refused cleanup must not render the preview's summary")
        XCTAssertEqual(center.ops.first?.phase, .failed)
    }

    /// A cleanup that ran and could not remove everything is a DIFFERENT
    /// outcome from one that was refused before it started, and the two must
    /// not share wording — one leaves the caches in place, the other doesn't.
    func testPartialCleanupFailureReadsAsPartialNotRefused() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-flow-partial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let canonicalParent = URL(fileURLWithPath: try XCTUnwrap(
            InvokingUserIdentity.canonicalPath(parent.path)))
        let item = canonicalParent.appendingPathComponent("reviewed-cache")
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false)
        let snapshot = try CleanupSnapshot.capture(
            list: CleanList(categories: [
                .init(name: "Test", items: [
                    .init(path: item.path, sizeBytes: 1, sizeText: "1B", itemCount: nil),
                ]),
            ], summaryTotalText: "1B", summaryItemCount: 1),
            approvedRootURLs: [canonicalParent])
        let plan = try snapshot.plan(selectedPaths: [item.path])

        let flow = makeFlow(FakeProcessPort(script: [.exited(1)]))
        var operation = Self.cleanOp(elevated: true)
        operation.cleanupPlan = plan
        flow.start(operation)
        await settle(flow)

        guard case .finished(.failed(let message)) = flow.state else {
            return XCTFail("a nonzero cleanup exit must not become done")
        }
        XCTAssertTrue(message.contains("could not be removed"), message)
        XCTAssertFalse(message.contains("Nothing was cleaned"), message)
    }

    /// This is about the DIRECT engine path, so it has to pin the no-conductor world: with a
    /// conductor staged, `streamOverride` supplies an executable for a non-elevated `clean`
    /// before `resolveMo` is ever consulted, and the unresolvable-engine branch under test is
    /// never reached. It previously relied on the test host happening not to bundle one.
    func testMissingExecutableFailsBeforeSpawn() {
        ConductorBundleFixture.withConductor(present: false) {
            let port = FakeProcessPort(script: [])
            let flow = OperationFlow<CleanReport>(process: port, hasFullDiskAccess: { true },
                                                  resolveMo: { _ in nil }, center: OperationCenter())
            flow.start(Self.cleanOp())
            guard case .finished(.failed) = flow.state else { return XCTFail("expected failed") }
            XCTAssertTrue(port.specs.isEmpty)
        }
    }

    func testElevatedRunFailsBeforeSpawnWhenInvokingAccountCannotBeResolved() {
        let port = FakeProcessPort(script: [.exited(0)])
        let flow = OperationFlow<CleanReport>(
            process: port, hasFullDiskAccess: { true }, resolveMo: { _ in "/usr/bin/true" },
            resolveInvokingUser: {
                throw InvokingUserIdentity.ResolutionError.missingAccount(501)
            }, center: OperationCenter())
        flow.start(Self.cleanOp(elevated: true))
        guard case .finished(.failed) = flow.state else { return XCTFail("expected fail closed") }
        XCTAssertTrue(port.specs.isEmpty, "identity targets are derived before elevation")
    }
}

// MARK: - Production adapter against real (tiny) processes

final class SystemProcessPortTests: XCTestCase {
    private func run(_ spec: ProcessSpec) async -> (lines: [String], exit: Int32?) {
        var lines: [String] = []
        var exit: Int32?
        for await e in SystemProcessPort().events(spec) {
            switch e {
            case .line(let l): lines.append(l)
            case .exited(let c): exit = c
            case .authCancelled: XCTFail("un-elevated specs never classify as auth-cancel")
            }
        }
        return (lines, exit)
    }

    func testStreamsLinesAndExitCode() async {
        let r = await run(ProcessSpec(executable: "/bin/sh",
                                      arguments: ["-c", "printf 'a\\nb\\n'; exit 3"],
                                      stdin: nil, elevated: false, timeout: nil))
        XCTAssertEqual(r.lines, ["a", "b"])
        XCTAssertEqual(r.exit, 3)
    }

    func testStdinIsFedAndClosed() async {
        let r = await run(ProcessSpec(executable: "/bin/cat", arguments: [],
                                      stdin: "hello\n", elevated: false, timeout: nil))
        XCTAssertEqual(r.lines, ["hello"])
        XCTAssertEqual(r.exit, 0)
    }

    func testTimeoutKillsTheChild() async {
        let started = Date()
        let r = await run(ProcessSpec(executable: "/bin/sleep", arguments: ["10"],
                                      stdin: nil, elevated: false, timeout: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5,
                          "the kill timer must fire, not the 10 s sleep")
        XCTAssertNotEqual(r.exit, 0)
    }

    func testSpawnFailureYieldsExit127() async {
        let r = await run(ProcessSpec(executable: "/nonexistent/binary", arguments: [],
                                      stdin: nil, elevated: false, timeout: nil))
        XCTAssertEqual(r.exit, 127)
    }

    // MARK: Auth-cancel classification — an engine rule, not view folklore

    /// Only AppleScript's canonical userCanceledErr is a cancellation.
    func testFinalEvent_classifiesAuthCancel() {
        guard case .authCancelled = SystemProcessPort.finalEvent(
            exitCode: 1, elevated: true,
            appleScriptStderr: "execution error: User canceled. (-128)") else {
            return XCTFail("canonical -128 diagnostic = dismissed auth prompt")
        }
        guard case .exited(1) = SystemProcessPort.finalEvent(
            exitCode: 1, elevated: true, appleScriptStderr: "") else {
            return XCTFail("silent root command failures remain failures")
        }
        // Un-elevated runs have no auth prompt to cancel.
        guard case .exited(2) = SystemProcessPort.finalEvent(
            exitCode: 2, elevated: false,
            appleScriptStderr: "execution error: User canceled. (-128)") else {
            return XCTFail("no elevation, no auth-cancel")
        }
        // Success is success even when silent.
        guard case .exited(0) = SystemProcessPort.finalEvent(
            exitCode: 0, elevated: true,
            appleScriptStderr: "execution error: User canceled. (-128)") else {
            return XCTFail("exit 0 is never a cancel")
        }
    }
}
