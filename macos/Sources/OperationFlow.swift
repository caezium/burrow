//
//  OperationFlow.swift
//  Burrow
//
//  The run-a-tool lifecycle, owned once: Full Disk Access gate → optional
//  elevation → spawn → stream → reduce → report → OperationCenter
//  begin/detail/end → done/failed/cancelled. Operation views shrink to
//  layout + localized copy; per-tool variation is DATA in a ToolOperation
//  descriptor (args, stdin, gate, elevation, a pure reduce closure) —
//  never a subclass.
//
//  The process boundary is one method behind ProcessPort. Production takes its
//  streaming port from the MoEngine facade (MoEngine.shared.streamPort, the real
//  SystemProcessPort) so "how do I run mo?" has one answer; tests still script a
//  fake by injecting `process:` directly. SystemProcessPort streams long-running
//  ops (Clean/Optimize); MoleProcess (the #29 capture-spawn runner) captures
//  one-shot output — both now hang off MoEngine, coexisting by use-case.
//

import Foundation
import SwiftUI

// MARK: - Process port

struct ProcessSpec: Sendable, Equatable {
    var executable: String
    var arguments: [String]
    var stdin: String?
    var elevated: Bool
    var timeout: TimeInterval?
    var invokingUser: InvokingUserIdentity? = nil
    var requiresCurrentBundle: Bool = false
    var cleanupPlan: CleanupExecutionPlan? = nil
}

enum ProcessEvent: Sendable {
    case line(String)        // ANSI-stripped, newline-split
    case exited(Int32)
    /// The elevated run's auth prompt was dismissed: osascript exited
    /// nonzero having produced nothing. Classified by the RUNNER (issue
    /// #48's one error taxonomy), not by view-level heuristics.
    case authCancelled
}

/// The one process boundary the flow needs: spawn per the spec, stream
/// stripped lines, then a single `.exited`. Cancelling the consuming task
/// terminates the child (via the stream's onTermination).
protocol ProcessPort: Sendable {
    func events(_ spec: ProcessSpec) -> AsyncStream<ProcessEvent>
}

// MARK: - Tool descriptor

/// All per-tool variation as data. `reduce` is a pure function from the
/// accumulated output lines to whatever the view renders (a TaskReport
/// tuple, a transcript, parsed JSON) — tested separately, never inside
/// the view.
struct ToolOperation<Report: Sendable> {
    enum Executable { case mo, path(String) }
    enum Gate { case none, fullDiskAccess(adminBypass: Bool) }

    /// OperationCenter HUD label; nil = the run isn't surfaced there.
    var label: String?
    var executable: Executable = .mo
    var arguments: [String]
    var stdin: String? = nil
    var gate: Gate = .none
    var elevated: Bool = false
    var timeout: TimeInterval? = nil
    var cleanupPlan: CleanupExecutionPlan? = nil
    var reduce: @Sendable ([String]) -> Report
    /// Optional line → HUD detail mapping (clean/optimize use
    /// TaskReportText.line); nil shows the raw line.
    var hudLine: (@Sendable (String) -> String)? = nil
    /// Post a user notification when this run finishes — real cleans /
    /// optimize / uninstalls, never previews. The post itself lives in
    /// OperationCenter.end → BurrowNotifier.
    var notifyOnEnd: Bool = false
    /// Final OperationCenter detail derived from the finished report —
    /// the result line a completion notification carries (freed bytes
    /// etc.). nil keeps the last streamed line.
    var finalDetail: (@Sendable (Report) -> String)? = nil

    /// "Scan with admin": the same operation, elevated — root bypasses TCC
    /// so the gate no longer applies.
    func elevated(_ on: Bool = true) -> Self {
        var c = self
        c.elevated = on
        return c
    }
}

// MARK: - The flow

@MainActor
final class OperationFlow<Report: Sendable>: ObservableObject {
    enum Outcome {
        case done(exit: Int32)
        case failed(String)
        case cancelled
    }
    enum State {
        case idle
        /// FDA missing; the pending operation rides along — resolution is
        /// just `start(pending)` (recheck) or `start(pending.elevated())`.
        case gated(pending: ToolOperation<Report>)
        case running
        case finished(Outcome)
    }

    @Published private(set) var state: State = .idle
    /// Live during the run (recomputed per streamed line), final at exit.
    @Published private(set) var report: Report?
    /// The full ANSI-stripped transcript, set once at exit — the demoted
    /// "View Log" disclosure on the result screen. Built only at the
    /// terminal event (not per line) to stay O(n), and empty for a run
    /// that never reached an exit (cancelled).
    @Published private(set) var rawLog: String = ""

    /// Stop only works for un-elevated runs: the root `mo` is a child of
    /// the privileged shell, and SIGTERMing our osascript messenger would
    /// just orphan it mid-delete while the UI claims "Stopped."
    var canCancel: Bool {
        if case .running = state { return !currentElevated }
        return false
    }

    /// Stable across runs on purpose (dry-run → real run): OperationCenter
    /// folds re-begun ids into one HUD row.
    let opID = UUID()

    private let process: any ProcessPort
    private let hasFullDiskAccess: () -> Bool
    /// Resolves the mo executable; elevated runs use trusted locations only
    /// (never a PATH lookup a user-writable directory could shadow).
    private let resolveMo: (_ elevated: Bool) -> String?
    private let resolveInvokingUser: () throws -> InvokingUserIdentity
    private let center: OperationCenter

    private var task: Task<Void, Never>?
    private var currentElevated = false
    private var currentLabel: String?
    private var telemetryFeature: String?
    private var telemetryStartedAt: Date?
    private var cancelRequested = false
    /// One-shot per run: Burrow has already reclaimed focus from the auth
    /// dialog, don't keep stealing it.
    private var reactivated = false
    /// Last time the live `report` was recomputed. `reduce()` re-parses the
    /// whole accumulated transcript, so reducing on every streamed line is
    /// O(n²) on the main actor — it stalled long clean/optimize runs (Sentry
    /// BURROW-1G / BURROW-1F). The live re-parse is throttled to ~4×/s;
    /// terminal events still do a final, authoritative reduce.
    private var lastReportAt = Date.distantPast

    /// Pull key focus back to Burrow after an elevated run's auth dialog
    /// relinquished it elsewhere. No-op for un-elevated runs (no dialog) and
    /// after the first call.
    private func reactivateIfElevated(_ op: ToolOperation<Report>) {
        guard op.elevated, !reactivated else { return }
        reactivated = true
        NSApp.activate(ignoringOtherApps: true)
    }

    init(process: any ProcessPort = MoEngine.shared.streamPort,
         hasFullDiskAccess: @escaping () -> Bool = Privacy.hasFullDiskAccess,
         resolveMo: @escaping (_ elevated: Bool) -> String? = {
             $0 ? MoleCLI.trustedExecutable() : MoleCLI.findExecutable()
         },
         resolveInvokingUser: @escaping () throws -> InvokingUserIdentity = InvokingUserIdentity.current,
         center: OperationCenter = .shared) {
        self.process = process
        self.hasFullDiskAccess = hasFullDiskAccess
        self.resolveMo = resolveMo
        self.resolveInvokingUser = resolveInvokingUser
        self.center = center
    }

    func start(_ op: ToolOperation<Report>) {
        if case .running = state { return }

        if case .fullDiskAccess = op.gate, !op.elevated, !hasFullDiskAccess() {
            state = .gated(pending: op)
            return
        }

        let exe: String?
        var arguments = op.arguments
        switch op.executable {
        case .mo:
            // Opt-in: route non-elevated streaming clean/optimize through the bundled conductor
            // (`burrow … --stream`), which forwards the engine's live output line-by-line. When the
            // switch is off / no conductor is bundled, `streamOverride` returns nil and the direct
            // `mo` path below is byte-identical to before.
            if let conductorRun = BurrowConductor.streamOverride(moArgs: op.arguments, elevated: op.elevated) {
                exe = conductorRun.executable
                arguments = conductorRun.arguments
            } else {
                exe = resolveMo(op.elevated)
            }
        case .path(let p): exe = p
        }
        guard let executable = exe else {
            // Elevation resolves ONLY the sealed copy inside the app bundle —
            // trustedExecutable() deliberately dropped the Homebrew fallback,
            // so naming Homebrew here sent people to the one location that
            // could never satisfy this. A missing bundled engine is fixed by
            // reinstalling the app, which is what installCommand documents.
            state = .finished(.failed(op.elevated
                ? "The bundled engine is missing. Reinstall Burrow to restore it: \(MoleCLI.installCommand)"
                : "mo not found"))
            return
        }

        let invokingUser: InvokingUserIdentity?
        if op.elevated {
            do { invokingUser = try resolveInvokingUser() }
            catch {
                state = .finished(.failed(error.localizedDescription))
                return
            }
        } else {
            invokingUser = nil
        }
        let requiresCurrentBundle: Bool
        if case .mo = op.executable { requiresCurrentBundle = op.elevated }
        else { requiresCurrentBundle = false }
        let spec = ProcessSpec(executable: executable, arguments: arguments,
                               stdin: op.stdin, elevated: op.elevated, timeout: op.timeout,
                               invokingUser: invokingUser,
                               requiresCurrentBundle: requiresCurrentBundle,
                               cleanupPlan: op.cleanupPlan)
        state = .running
        report = nil
        lastReportAt = .distantPast
        rawLog = ""
        currentElevated = op.elevated
        currentLabel = op.label
        telemetryFeature = Self.telemetryFeature(for: op)
        telemetryStartedAt = Date()
        cancelRequested = false
        reactivated = false
        if let label = op.label { center.begin(opID, label: label, notifiesOnEnd: op.notifyOnEnd) }
        if let telemetryFeature {
            Telemetry.capture("feature_operation_started", [
                "feature": telemetryFeature,
                "dry_run": op.arguments.contains("--dry-run"),
                "elevated": op.elevated,
            ])
        }

        let stream = process.events(spec)
        let id = opID
        task = Task { [weak self] in
            var lines: [String] = []
            for await event in stream {
                guard let self, !Task.isCancelled else { return }
                switch event {
                case .line(let l):
                    // The macOS auth dialog (osascript) takes key focus and
                    // hands it back to whatever, not us — so the first output
                    // of an elevated run (auth just cleared) is the cue to pull
                    // focus back to Burrow, instead of making the user ⌘-tab.
                    self.reactivateIfElevated(op)
                    lines.append(l)
                    // Throttled live re-parse (see `lastReportAt`): recompute
                    // at most ~4×/s instead of on every streamed line. The
                    // terminal events below always do a final, authoritative
                    // reduce, so the result screen is never left stale.
                    let now = Date()
                    if now.timeIntervalSince(self.lastReportAt) > 0.25 {
                        self.lastReportAt = now
                        self.report = op.reduce(lines)
                    }
                    if op.label != nil, !l.trimmingCharacters(in: .whitespaces).isEmpty {
                        self.center.detail(id, (op.hudLine ?? { $0 })(l))
                    }
                case .exited(let code):
                    guard !self.cancelRequested else { return }
                    self.reactivateIfElevated(op)   // backstop: no-output runs
                    self.rawLog = lines.joined(separator: "\n")
                    if code == 0 {
                        self.report = op.reduce(lines)
                        self.state = .finished(.done(exit: code))
                        if op.label != nil {
                            // Replace the last streamed line with the parsed
                            // result line where the op provides one — that's
                            // what a completion notification shows.
                            let detail = self.report.map { op.finalDetail?($0) ?? "" } ?? ""
                            self.center.end(id, success: true, detail: detail)
                        }
                        self.captureTelemetryCompletion(result: "succeeded")
                    } else {
                        // A cleanup report may contain the preview's optimistic
                        // summary even though the exact-tree guard stopped the
                        // deletion. Do not render or notify with that summary.
                        self.report = op.cleanupPlan == nil ? op.reduce(lines) : nil
                        let message = Self.failureMessage(exitCode: code,
                                                          isCleanup: op.cleanupPlan != nil)
                        self.state = .finished(.failed(message))
                        if op.label != nil { self.center.end(id, success: false, detail: message) }
                        self.captureTelemetryCompletion(result: "failed")
                    }
                case .authCancelled:
                    // Auth-cancel is classified by the runner now (#48 taxonomy),
                    // not by a view-level "elevated + nonzero + no output" guess.
                    guard !self.cancelRequested else { return }
                    self.reactivateIfElevated(op)
                    self.report = op.reduce(lines)
                    self.rawLog = lines.joined(separator: "\n")
                    self.state = .finished(.failed(NSLocalizedString("authorization cancelled", comment: "")))
                    if op.label != nil { self.center.end(id, success: false) }
                    self.captureTelemetryCompletion(result: "authorization_cancelled")
                }
            }
        }
    }

    func cancel() {
        guard canCancel else { return }
        cancelRequested = true
        task?.cancel()            // stream onTermination terminates the child
        state = .finished(.cancelled)
        if currentLabel != nil { center.end(opID, success: false) }
        captureTelemetryCompletion(result: "cancelled")
    }

    /// Back to the idle hero — the report screen's "Back" button.
    func reset() {
        state = .idle
        report = nil
        rawLog = ""
    }

    private static func telemetryFeature(for operation: ToolOperation<Report>) -> String? {
        guard case .mo = operation.executable,
              let command = operation.arguments.first,
              ["clean", "optimize"].contains(command) else { return nil }
        return command
    }

    /// Turn an exit status into something a person can act on. The wrapper's
    /// own refusals (124–127) all mean NOTHING ran, which is the opposite of a
    /// partial delete, so they must never share wording with a command that
    /// ran and failed partway.
    private static func failureMessage(exitCode: Int32, isCleanup: Bool) -> String {
        switch exitCode {
        case ElevatedExitCode.boundaryCheckFailed:
            return isCleanup
                ? NSLocalizedString(
                    "Nothing was cleaned: the reviewed items changed before the run started. Rescan before trying again.",
                    comment: "")
                : NSLocalizedString(
                    "Nothing ran: the files Burrow verified changed before the operation started.",
                    comment: "")
        case ElevatedExitCode.logSinkUnavailable,
             ElevatedExitCode.executableRefused,
             ElevatedExitCode.launchFailed:
            return NSLocalizedString(
                "Nothing ran: Burrow could not verify the program it was about to run as an administrator.",
                comment: "")
        default:
            return isCleanup
                ? String(format: NSLocalizedString(
                    "Some reviewed items could not be removed (exit %d). The run log lists each one.",
                    comment: ""), exitCode)
                : String(format: NSLocalizedString("Operation failed with exit status %d.", comment: ""),
                         exitCode)
        }
    }

    private func captureTelemetryCompletion(result: String) {
        guard let telemetryFeature else { return }
        let duration = telemetryStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        Telemetry.capture("feature_operation_completed", [
            "feature": telemetryFeature,
            "result": result,
            "duration_bucket": Telemetry.secondsBucket(duration),
        ])
        self.telemetryFeature = nil
        telemetryStartedAt = nil
    }
}

// MARK: - The mo report shape

/// What clean/optimize render: themed task groups + the run summary.
typealias TaskRunReport = (groups: [TaskGroup], summary: TaskSummary?)

extension ToolOperation where Report == TaskRunReport {
    /// A streaming `mo` run rendered through TaskReportView — the shape
    /// clean and optimize share. `notifyOnEnd` rides through to the
    /// completion notification, with the parsed summary (freed bytes)
    /// as the final detail line.
    static func moleStream(_ args: [String], gate: Gate = .none,
                           elevated: Bool = false, label: String?,
                           notifyOnEnd: Bool = false) -> ToolOperation {
        // The bundled engine streams NDJSON (clean/optimize --stream); reduce those events into the
        // same (groups, summary) shape the human-text parser produced. See BurrowStreamReport.
        ToolOperation(label: label, arguments: args, gate: gate, elevated: elevated,
                      reduce: { BurrowStreamReport.reduce($0) },
                      hudLine: { BurrowStreamReport.hudLine($0) },
                      notifyOnEnd: notifyOnEnd,
                      finalDetail: { $0.summary?.completionLine ?? "" })
    }
}

// MARK: - Production adapter

/// Why an elevated run never reached the authentication prompt. Distinct from
/// `ValidatedElevatedCommand.ValidationError` because these two are decided by
/// the caller's own state rather than by the filesystem.
enum ElevatedSetupError: LocalizedError, Equatable {
    case noInvokingUser
    case staleCleanupPlan

    var errorDescription: String? {
        switch self {
        case .noInvokingUser:
            return "Burrow could not confirm which signed-in account started this operation."
        case .staleCleanupPlan:
            return "The reviewed items changed before the run started, so nothing was cleaned."
        }
    }
}

/// The streaming-op spawn mechanics: plain runs stream
/// stdout+stderr through pipes; elevated runs go through ONE osascript auth
/// prompt with output tailed from a temp log (`do shell script` doesn't
/// stream); stdin is fed then closed; a timeout kills the child. All output
/// is ANSI-stripped and newline-split before it reaches the flow.
struct SystemProcessPort: ProcessPort {
    func events(_ spec: ProcessSpec) -> AsyncStream<ProcessEvent> {
        AsyncStream { cont in
            let splitter = LineSplitter()
            let t = Process()
            // One serial queue owns every splitter access, line yield, and the
            // final finish — so `cont.finish()` can never overtake a still-
            // pending `.line` from a reader. (The old readabilityHandler yielded
            // on a background queue while the termination handler finished on
            // main; with no ordering between them, finish() could land first and
            // silently drop lines — an intermittent CI failure that surfaced as
            // [] or ["a"] instead of ["a","b"].)
            let streamQ = DispatchQueue(label: "dev.caezium.burrow.opflow.stream")
            var tailTimer: DispatchSourceTimer?
            var killTimer: DispatchSourceTimer?
            // Both of these belong to streamQ ALONE. The tail timer fires on
            // the main run loop, so if it opened, read, or closed the handle
            // itself it would be racing the termination handler doing the same
            // three things — including a read against a descriptor the other
            // side had already closed. The timer therefore only schedules work
            // onto streamQ; ownership never leaves it.
            var logHandle: FileHandle?      // streamQ only
            var tailFinished = false        // streamQ only

            func emit(_ s: String) {                       // streamQ only
                for line in splitter.ingest(Ansi.strip(s)) { cont.yield(.line(line)) }
            }
            func finish(_ code: Int32, appleScriptStderr: String = "") { // streamQ only
                for line in splitter.flush() { cont.yield(.line(line)) }
                cont.yield(Self.finalEvent(exitCode: code, elevated: spec.elevated,
                                           appleScriptStderr: appleScriptStderr))
                cont.finish()
            }

            let outPipe = Pipe(), errPipe = Pipe()

            if spec.elevated {
                // The osascript `do shell script` wrapper has no stdin channel,
                // so elevated + stdin is unsupported. No caller pairs them today
                // (stdin-fed flows like uninstall run un-elevated via MoleCLI.run);
                // assert so the unsupported combo fails loudly rather than
                // silently dropping the input if someone wires it up later.
                assert(spec.stdin == nil, "elevated runs don't support stdin")
                // A refusal here is the single most confusing failure Burrow
                // can produce — nothing runs, no prompt appears, and the exit
                // status alone ("126") tells the user nothing about which
                // check said no. Carry the reason into the transcript.
                let command: ValidatedElevatedCommand
                let logSink: PrivilegedLogSink
                do {
                    guard let invokingUser = spec.invokingUser else {
                        throw ElevatedSetupError.noInvokingUser
                    }
                    command = try ValidatedElevatedCommand.prepare(
                        executable: spec.executable, invokingUser: invokingUser,
                        requireCurrentBundle: spec.requiresCurrentBundle)
                    guard spec.cleanupPlan?.validateForLaunch() != false else {
                        throw ElevatedSetupError.staleCleanupPlan
                    }
                    logSink = try PrivilegedLogSink.make()
                } catch {
                    let reason = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                    // A stale plan is a changed review, not a program we
                    // couldn't verify; reporting it as the latter would send
                    // the user looking for a signing problem they don't have.
                    let code = (error as? ElevatedSetupError) == .staleCleanupPlan
                        ? ElevatedExitCode.boundaryCheckFailed
                        : ElevatedExitCode.executableRefused
                    streamQ.async {
                        emit(reason + "\n")
                        finish(code)
                    }
                    return
                }
                let script = MoleCLI.elevatedScript(command: command,
                                                    args: spec.arguments,
                                                    logSink: logSink,
                                                    cleanupPlan: spec.cleanupPlan)
                t.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                t.arguments = ["-e", script]
                t.standardOutput = outPipe
                t.standardError = errPipe

                // The tail poll runs on streamQ, NOT the main run loop.
                //
                // The root shell unlinks its sink from a trap on exit and only
                // gives the app a short fixed window to get a descriptor first.
                // Polling from the main run loop meant a busy or modal UI could
                // miss that window entirely and lose the whole transcript — and
                // a clean whose output vanished used to render as a successful
                // run that freed nothing. A background queue cannot be starved
                // by the UI, and it puts every access to `logHandle` on the one
                // queue that owns it.
                let tail = DispatchSource.makeTimerSource(queue: streamQ)
                tail.schedule(deadline: .now(), repeating: .milliseconds(50))
                tail.setEventHandler {
                    // A tick can still be in flight after the final tail has
                    // been read and the handle closed; serving it would read a
                    // closed descriptor.
                    guard !tailFinished else { return }
                    if logHandle == nil { logHandle = logSink.openForReading() }
                    guard let h = logHandle else { return }
                    let data = h.readDataToEndOfFile()
                    guard !data.isEmpty else { return }
                    // Lossy decode, never the failable initializer: a read can
                    // end mid-UTF-8-sequence, and `String(data:encoding:)`
                    // returning nil there used to discard the whole chunk —
                    // losing entire lines of a privileged run's transcript.
                    emit(String(decoding: data, as: UTF8.self))
                }
                tail.resume()
                tailTimer = tail

                t.terminationHandler = { proc in
                    killTimer?.cancel()
                    streamQ.async {
                        tail.cancel()
                        // Claim the handle before the final read so a timer
                        // tick queued behind this block cannot touch it.
                        tailFinished = true
                        if logHandle == nil { logHandle = logSink.openForReading() }
                        if let h = logHandle {                  // last tail of the log
                            let data = h.readDataToEndOfFile()
                            if !data.isEmpty { emit(String(decoding: data, as: UTF8.self)) }
                            try? h.close()
                            logHandle = nil
                        }
                        let stderr = String(
                            decoding: errPipe.fileHandleForReading.readDataToEndOfFile(),
                            as: UTF8.self)
                        _ = outPipe.fileHandleForReading.readDataToEndOfFile()
                        finish(proc.terminationStatus, appleScriptStderr: stderr)
                    }
                }
            } else {
                t.executableURL = URL(fileURLWithPath: spec.executable)
                t.arguments = spec.arguments
                t.standardOutput = outPipe
                t.standardError = errPipe
                if let stdin = spec.stdin {
                    let inPipe = Pipe()
                    t.standardInput = inPipe
                    inPipe.fileHandleForWriting.write(Data(stdin.utf8))
                    inPipe.fileHandleForWriting.closeFile()
                }
            }

            cont.onTermination = { @Sendable _ in
                tailTimer?.cancel()
                if t.isRunning { t.terminate() }
            }

            do {
                try t.run()
                // Process inherits duplicated write descriptors during spawn;
                // the parent must close its copies so the readers observe EOF
                // after the child exits. Keeping these handles open can strand
                // the stream forever after a timeout even though terminate()
                // successfully killed the child.
                //
                // Both routes, not just the unelevated one: the elevated branch
                // hands the SAME two pipes to osascript, and its termination
                // handler ends with readDataToEndOfFile on each — a read that
                // only returns once every write descriptor is gone, this
                // parent's included.
                try? outPipe.fileHandleForWriting.close()
                try? errPipe.fileHandleForWriting.close()
                // Armed only after a successful spawn (a suspended source
                // must never be cancelled/deallocated).
                if let timeout = spec.timeout {
                    let k = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                    k.schedule(deadline: .now() + timeout, repeating: .never)
                    k.setEventHandler { if t.isRunning { t.terminate() } }
                    k.resume()
                    killTimer = k
                }
                if !spec.elevated {
                    // Dedicated blocking reader per pipe, started only after a
                    // successful spawn (so a failed launch can't leak them).
                    // Each drains its pipe to EOF; ingest+yield hop synchronously
                    // onto streamQ; completion fires via the group ONLY once both
                    // pipes are at EOF — so finish() is strictly last and no line
                    // is lost (see streamQ note above).
                    let group = DispatchGroup()
                    for fh in [outPipe.fileHandleForReading, errPipe.fileHandleForReading] {
                        group.enter()
                        DispatchQueue.global(qos: .utility).async {
                            while case let d = fh.availableData, !d.isEmpty {
                                let s = String(decoding: d, as: UTF8.self)
                                streamQ.sync { emit(s) }
                            }
                            group.leave()
                        }
                    }
                    group.notify(queue: streamQ) {
                        killTimer?.cancel()
                        t.waitUntilExit()
                        finish(t.terminationStatus)
                    }
                }
            } catch {
                streamQ.async { finish(127) }
            }
        }
    }

    /// Both streaming and one-shot elevation require AppleScript's canonical
    /// -128 diagnostic. A silent nonzero root command remains a real failure.
    static func finalEvent(exitCode: Int32, elevated: Bool,
                           appleScriptStderr: String) -> ProcessEvent {
        if AuthCancel.isAuthCancelled(elevated: elevated, exitCode: exitCode,
                                      appleScriptStderr: appleScriptStderr) {
            return .authCancelled
        }
        return .exited(exitCode)
    }

    /// Buffers partial chunks and emits whole lines; thread-confined to
    /// whichever handler feeds it (pipe readability or the log tail timer).
    private final class LineSplitter: @unchecked Sendable {
        private var buffer = ""
        private var emitted = false
        private let lock = NSLock()
        /// Whether any line has been emitted — the auth-cancel classifier's
        /// "did the run produce output" input, tracked where lines are made.
        var sawAnyLine: Bool {
            lock.lock(); defer { lock.unlock() }
            return emitted
        }
        func ingest(_ s: String) -> [String] {
            lock.lock(); defer { lock.unlock() }
            buffer += s
            var parts = buffer.components(separatedBy: "\n")
            buffer = parts.removeLast()
            if !parts.isEmpty { emitted = true }
            return parts
        }
        func flush() -> [String] {
            lock.lock(); defer { lock.unlock() }
            let rest = buffer
            buffer = ""
            if !rest.isEmpty { emitted = true }
            return rest.isEmpty ? [] : [rest]
        }
    }
}
