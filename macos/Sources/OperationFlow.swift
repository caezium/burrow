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
//  streaming port from the EngineRunner facade (EngineRunner.shared.streamPort, the real
//  SystemProcessPort) so "how do I run mo?" has one answer; tests still script a
//  fake by injecting `process:` directly. SystemProcessPort streams long-running
//  ops (Clean/Optimize); MoleProcess (the #29 capture-spawn runner) captures
//  one-shot output — both now hang off EngineRunner, coexisting by use-case.
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

enum FeatureOperationFailureCategory: String, Equatable {
    case boundaryChanged = "boundary_changed"
    case privilegedLaunchRefused = "privileged_launch_refused"
    /// The helper daemon refused the request before authorization. Its own
    /// category because a run of these is a helper problem, not an engine or
    /// launch one — the failure rate issue #425 describes would have shown up
    /// here.
    case privilegedRequestRefused = "privileged_request_refused"
    case engineNonzero = "engine_nonzero"
}

enum FeatureOperationFailurePolicy {
    static func category(
        forExitCode exitCode: Int32,
        elevated: Bool,
        isCleanup: Bool
    ) -> FeatureOperationFailureCategory {
        guard elevated else { return .engineNonzero }
        switch exitCode {
        case ElevatedExitCode.boundaryCheckFailed where isCleanup:
            return .boundaryChanged
        case ElevatedExitCode.logSinkUnavailable,
             ElevatedExitCode.executableRefused,
             ElevatedExitCode.launchFailed:
            return .privilegedLaunchRefused
        case ElevatedExitCode.requestRefused:
            return .privilegedRequestRefused
        default:
            return .engineNonzero
        }
    }
}

enum FeatureOperationTelemetry {
    static func feature<Report: Sendable>(for operation: ToolOperation<Report>) -> String? {
        if operation.cleanupPlan != nil, operation.arguments.first == "clean" { return "clean" }
        guard case .mo = operation.executable,
              let command = operation.arguments.first,
              ["clean", "optimize"].contains(command) else { return nil }
        return command
    }

    static func completionProperties(
        feature: String,
        result: String,
        duration: TimeInterval,
        failureCategory: FeatureOperationFailureCategory?
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "feature": feature,
            "result": result,
            "duration_bucket": Telemetry.secondsBucket(duration),
        ]
        if let failureCategory {
            properties["failure_category"] = failureCategory.rawValue
        }
        return properties
    }
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
    /// Runs exactly once when the operation is over, however it ended —
    /// exit, auth cancelled, stopped, or refused before it spawned. The
    /// reviewed clean deletes its plan file here.
    var finally: (@Sendable () -> Void)? = nil

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
    private let resolveEngine: (_ elevated: Bool) -> String?
    private let resolveInvokingUser: () throws -> InvokingUserIdentity
    private let center: OperationCenter

    private var task: Task<Void, Never>?
    private var currentElevated = false
    private var currentLabel: String?
    private var currentFinally: (@Sendable () -> Void)?
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

    init(process: any ProcessPort = EngineRunner.shared.streamPort,
         hasFullDiskAccess: @escaping () -> Bool = Privacy.hasFullDiskAccess,
         resolveEngine: @escaping (_ elevated: Bool) -> String? = {
             $0 ? EngineCLI.trustedExecutable() : EngineCLI.findExecutable()
         },
         resolveInvokingUser: @escaping () throws -> InvokingUserIdentity = InvokingUserIdentity.current,
         center: OperationCenter = .shared) {
        self.process = process
        self.hasFullDiskAccess = hasFullDiskAccess
        self.resolveEngine = resolveEngine
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
            // Opt-in TRANSPORT choice only: prefer streaming clean/optimize through the bundled
            // conductor (`burrow … --stream`), which forwards the engine's live output
            // line-by-line. Elevated runs go through this exactly like non-elevated ones — every
            // real (non-preview) GUI clean/optimize call is elevated, so excluding elevated runs
            // here would mean the app's actual Clean/Optimize buttons never stream at all.
            //
            // The mo→engine argv TRANSLATION is a separate concern from which of these two
            // branches runs, and it must not depend on that choice: `resolveEngine` below resolves
            // the SAME bundled engine binary this branch would have used (EngineCLI.bundledExecutable(),
            // the file `streamOverride`/`BurrowEngine.executableURL()` also targets) whenever
            // one is bundled — which it will be in a shipped build regardless of the streaming
            // switch. So when only the conductor branch translated, turning that switch off
            // (`defaults write … BurrowStreamViaConductor -bool NO`) silently handed the SAME
            // bundled engine mo's own untranslated argv, which it reads with the OPPOSITE meaning
            // (`["clean"]` is mo's LIVE run and the engine's DRY RUN) — a transport kill switch
            // that could turn a real clean into a silent no-op. Not "byte-identical to before":
            // `EngineCLI.bundledExecutable()` is new in this same diff, so what `resolveEngine` finds
            // changed underneath this fallback even though the fallback's own code didn't.
            if let conductorRun = BurrowEngine.streamOverride(moArgs: op.arguments) {
                exe = conductorRun.executable
                arguments = conductorRun.arguments
            } else {
                let resolved = resolveEngine(op.elevated)
                exe = resolved
                // Translate only when we can tell this IS the bundled engine — a genuine
                // external mo/burrow-engine(MIT-fork) Homebrew fallback (reachable only when the
                // bundle itself is missing) speaks mo's own convention, and translating that one
                // unconditionally would turn an elevated preview ("Scan with admin") into a live
                // delete on it instead.
                if let resolved, resolved == EngineCLI.bundledExecutable() {
                    arguments = BurrowEngine.engineArgv(fromMo: op.arguments)
                }
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
                ? "The bundled engine is missing. Reinstall Burrow to restore it: \(EngineCLI.installCommand)"
                : "mo not found"))
            op.finally?()
            return
        }

        let invokingUser: InvokingUserIdentity?
        if op.elevated {
            do { invokingUser = try resolveInvokingUser() }
            catch {
                state = .finished(.failed(error.localizedDescription))
                op.finally?()
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
        telemetryFeature = FeatureOperationTelemetry.feature(for: op)
        telemetryStartedAt = Date()
        cancelRequested = false
        reactivated = false
        currentFinally = op.finally
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
                    defer { self.runFinally() }
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
                        // A reviewed clean refused at the boundary never ran
                        // the engine, so there is nothing to report — the
                        // failure message says so. Every other nonzero exit is
                        // reduced from the engine's own lines (what it removed,
                        // what it refused and why), never from the preview.
                        let refusedBeforeRunning = op.cleanupPlan != nil
                            && code == ElevatedExitCode.boundaryCheckFailed
                        self.report = refusedBeforeRunning ? nil : op.reduce(lines)
                        let message = Self.failureMessage(exitCode: code,
                                                          isCleanup: op.cleanupPlan != nil)
                        self.state = .finished(.failed(message))
                        if op.label != nil { self.center.end(id, success: false, detail: message) }
                        self.captureTelemetryCompletion(
                            result: "failed",
                            failureCategory: FeatureOperationFailurePolicy.category(
                                forExitCode: code,
                                elevated: op.elevated,
                                isCleanup: op.cleanupPlan != nil
                            )
                        )
                    }
                case .authCancelled:
                    // Auth-cancel is classified by the runner now (#48 taxonomy),
                    // not by a view-level "elevated + nonzero + no output" guess.
                    guard !self.cancelRequested else { return }
                    self.reactivateIfElevated(op)
                    defer { self.runFinally() }
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
        runFinally()
    }

    /// The operation's `finally`, once. Cleared as it runs so no terminal path
    /// can fire it twice.
    private func runFinally() {
        let body = currentFinally
        currentFinally = nil
        body?()
    }

    /// Back to the idle hero — the report screen's "Back" button.
    func reset() {
        state = .idle
        report = nil
        rawLog = ""
    }

    /// Turn an exit status into something a person can act on. The wrapper's
    /// own refusals (124–127) all mean NOTHING ran, which is the opposite of a
    /// partial delete, so they must never share wording with a command that
    /// ran and failed partway.
    private static func failureMessage(exitCode: Int32, isCleanup: Bool) -> String {
        switch exitCode {
        case ElevatedExitCode.boundaryCheckFailed where isCleanup:
            return NSLocalizedString(
                "Nothing was cleaned: the reviewed items changed before the run started. Rescan before trying again.",
                comment: "")
        case ElevatedExitCode.logSinkUnavailable,
             ElevatedExitCode.executableRefused,
             ElevatedExitCode.launchFailed:
            return NSLocalizedString(
                "Nothing ran: Burrow could not verify the program it was about to run as an administrator.",
                comment: "")
        case ElevatedExitCode.requestRefused:
            // The helper named its reason and the transcript carries it
            // (`HelperRequestRejection.userExplanation`); this line points
            // there rather than guessing.
            return NSLocalizedString(
                "Nothing ran: the privileged helper refused the request. The run log says why.",
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

    private func captureTelemetryCompletion(
        result: String,
        failureCategory: FeatureOperationFailureCategory? = nil
    ) {
        guard let telemetryFeature else { return }
        let duration = telemetryStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let properties = FeatureOperationTelemetry.completionProperties(
            feature: telemetryFeature,
            result: result,
            duration: duration,
            failureCategory: failureCategory
        )
        Telemetry.capture("feature_operation_completed", properties)
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
        //
        // The group title comes from THIS operation's argv, so the same factory titles a
        // `["clean"]` run "Cleanup" and TuneUp's `["optimize"]` run "Maintenance" — the reduce sees
        // only the events, which is the wrong place to decide what tool ran.
        let title = BurrowStreamReport.groupTitle(forMo: args)
        return ToolOperation(label: label, arguments: args, gate: gate, elevated: elevated,
                             reduce: { BurrowStreamReport.reduce($0, title: title) },
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
/// stream); stdin is fed then closed; a timeout kills the child — SIGTERM
/// escalating to SIGKILL, and the readers stop waiting on a pipe the dead
/// child's descendants left open (see ChildGuard). All output is ANSI-stripped
/// and newline-split before it reaches the flow.
struct SystemProcessPort: ProcessPort {
    func events(_ spec: ProcessSpec) -> AsyncStream<ProcessEvent> {
        AsyncStream { cont in
            let splitter = LineSplitter()
            let t = Process()
            // Kill-and-reap state shared by the timeout timer, the pipe readers
            // and the stream's teardown — and the thing that guarantees this
            // stream always finishes (see ChildGuard).
            let child = ChildGuard(name: (spec.executable as NSString).lastPathComponent)
            // One serial queue owns every splitter access, line yield, and the
            // final finish — so `cont.finish()` can never overtake a still-
            // pending `.line` from a reader. (The old readabilityHandler yielded
            // on a background queue while the termination handler finished on
            // main; with no ordering between them, finish() could land first and
            // silently drop lines — an intermittent CI failure that surfaced as
            // [] or ["a"] instead of ["a","b"].)
            let streamQ = DispatchQueue(label: "dev.caezium.burrow.opflow.stream")
            // The kill timer and its escalation get a queue of their own instead
            // of a shared global one. Work submitted to a global concurrent
            // queue waits on that pool's threads, and the code that kills a
            // wedged child is the last thing that should ever queue behind
            // somebody else's blocking read.
            let killQ = DispatchQueue(label: "dev.caezium.burrow.opflow.kill")
            var tailTimer: DispatchSourceTimer?
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
                // Exactly once. Three paths reach here (the elevated
                // termination handler, the readers' group, a spawn failure) and
                // `onTermination` can run concurrently with any of them; an
                // AsyncStream continuation must be finished a single time.
                guard child.claimFinish() else { return }
                for line in splitter.flush() { cont.yield(.line(line)) }
                cont.yield(Self.finalEvent(exitCode: code, elevated: spec.elevated,
                                           appleScriptStderr: appleScriptStderr))
                cont.finish()
            }

            let outPipe = Pipe(), errPipe = Pipe()

            if spec.elevated {
                // The osascript `do shell script` wrapper has no stdin channel,
                // so elevated + stdin is unsupported. No caller pairs them today
                // (stdin-fed flows like uninstall run un-elevated via EngineCLI.run);
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
                let script = EngineCLI.elevatedScript(command: command,
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
                    child.reaped(status: proc.terminationStatus)
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
                // The plain path had no termination handler: it learned the exit
                // status by blocking in `waitUntilExit()`, and that call is what
                // hung this stream (see the note on the group's completion
                // below). Taking the status where Foundation hands it to us
                // means the finish can wait for it with a DEADLINE instead
                // (ChildGuard.awaitStatus), and gives the readers the "the child
                // is dead" edge they need to stop waiting on a pipe nobody will
                // ever close. Set before run(): a handler installed afterwards
                // races the exit it wants to hear about.
                t.terminationHandler = { proc in child.reaped(status: proc.terminationStatus) }
            }

            cont.onTermination = { @Sendable _ in
                tailTimer?.cancel()
                // The consumer is gone (cancelled, or the stream just finished);
                // the child must not outlive it. A no-op once the child has been
                // reaped, so a normal finish costs nothing and says nothing.
                child.killEscalating(on: killQ, because: "the stream was torn down")
            }

            do {
                try t.run()
                child.spawned(t)
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
                    child.armTimeout(timeout, on: killQ)
                    // One breadcrumb up front: if a run ever wedges again, a log
                    // that says "timeout armed" and nothing else means the timer
                    // itself never fired, which is a very different bug from a
                    // child that survived the signal.
                    child.note("timeout armed: \(timeout)s")
                }
                if !spec.elevated {
                    // Dedicated blocking reader per pipe, started only after a
                    // successful spawn (so a failed launch can't leak them).
                    // Each drains its pipe to EOF; ingest+yield hop synchronously
                    // onto streamQ; completion fires via the group ONLY once both
                    // pipes are done — so finish() is strictly last and no line
                    // is lost (see streamQ note above). The group stays the ONE
                    // completion path for the plain runs: the readers' own escape
                    // hatch (drain) makes them leave the group rather than
                    // finishing behind its back.
                    //
                    // Each reader gets its own queue, not a slot in the shared
                    // global pool: a thread parked in read() is a thread that
                    // pool can't give to anyone else.
                    let group = DispatchGroup()
                    for (pipe, fh) in [("stdout", outPipe.fileHandleForReading),
                                       ("stderr", errPipe.fileHandleForReading)] {
                        group.enter()
                        DispatchQueue(label: "dev.caezium.burrow.opflow.read.\(pipe)").async {
                            Self.drain(fh, pipe: pipe, child: child) { chunk in
                                streamQ.sync { emit(chunk) }
                            }
                            group.leave()
                        }
                    }
                    group.notify(queue: streamQ) {
                        child.cancelTimeout()
                        // This used to be `t.waitUntilExit()` then
                        // `t.terminationStatus`, and THAT is what hung the
                        // 29-minute CI run: with both pipes at EOF and
                        // `isRunning` already false — the child dead and reaped
                        // — waitUntilExit never returned. Measured on macOS
                        // 26.5: 24 of 150 runs of the `sleep 10` + 0.3s timeout
                        // test, and 40 of 400 runs of a plain 600-line child
                        // that exits on its own, wedged here forever. Foundation
                        // hands the status to the termination handler instead,
                        // and awaitStatus waits for it with a deadline, so the
                        // worst case is a wrong exit code rather than a stream
                        // that never ends.
                        finish(child.awaitStatus())
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

    /// One pipe's reader: wait for bytes, hand whole chunks to `onChunk`
    /// synchronously, stop at EOF.
    ///
    /// It waits in `poll` on a tick rather than in `FileHandle.availableData`
    /// because `availableData` has no way out — it returns on data or on EOF and
    /// on nothing else. Pipe EOF needs EVERY write end closed, so a child that
    /// dies leaving a descendant holding one open parks this thread, and with it
    /// the whole stream, forever. The tick is only an escape hatch: bytes still
    /// arrive through a blocking read on a dedicated thread and the reader still
    /// reports completion by leaving the DispatchGroup, so finish() stays
    /// strictly last. (Deliberately NOT readabilityHandler — that is the design
    /// whose unordered yields dropped lines.)
    private static func drain(_ handle: FileHandle, pipe: String, child: ChildGuard,
                              onChunk: (String) -> Void) {
        let fd = handle.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        // Bytes held back because the read ended mid-UTF-8-sequence. A 64KB read
        // boundary lands wherever the kernel put it, so it can split a multi-byte
        // character — and lossy decoding each read INDEPENDENTLY would turn that one
        // character into U+FFFD on both sides of the seam. Engine output carries file
        // paths, which are routinely non-ASCII, so this is reachable rather than
        // theoretical. Carrying the partial sequence to the next read makes the seam
        // invisible; the lossy decode below then only ever sees whole characters.
        var carry: [UInt8] = []
        while true {
            var fds = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&fds, 1, ChildGuard.pollTickMs)
            if ready < 0 {
                if errno == EINTR { continue }
                child.note("\(pipe): poll failed (errno \(errno)) — giving up on this pipe")
                return
            }
            if ready == 0 {                                  // tick: nothing to read yet
                if child.shouldStopReading(pipe) { return }
                continue
            }
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                child.note("\(pipe): read failed (errno \(errno)) — giving up on this pipe")
                return
            }
            if n == 0 {                                      // EOF: every write end is closed
                // Whatever is still held back is genuinely truncated output, not a
                // seam — emit it lossily rather than swallowing it.
                if !carry.isEmpty { onChunk(String(decoding: carry, as: UTF8.self)) }
                return
            }
            child.sawData()
            // Lossy decode, never the failable initializer: `String(data:encoding:)`
            // returning nil on a split sequence used to discard the whole 64KB chunk,
            // losing entire lines of a run's transcript. Same rule the elevated tail
            // follows. The split itself is handled by `carry` rather than by the
            // decoder, so what reaches it is always a whole number of characters.
            var bytes = carry
            bytes.append(contentsOf: buffer[0..<n])
            carry = Self.splitTrailingPartialSequence(&bytes)
            if !bytes.isEmpty { onChunk(String(decoding: bytes, as: UTF8.self)) }
        }
    }

    /// Removes and returns a trailing INCOMPLETE UTF-8 sequence from `bytes`, leaving
    /// `bytes` ending on a character boundary. Returns empty when the buffer already
    /// ends cleanly, which is the overwhelmingly common case.
    ///
    /// A sequence is at most 4 bytes, so at most the last 3 can be incomplete — scan
    /// back that far for a lead byte and compare its declared width against what
    /// actually arrived. A malformed lead (or none within 3 bytes) is NOT held back:
    /// waiting for a continuation that is never coming would stall the stream, and the
    /// lossy decode below renders it as U+FFFD, which is the honest answer for bytes
    /// that are not UTF-8 in the first place.
    static func splitTrailingPartialSequence(_ bytes: inout [UInt8]) -> [UInt8] {
        let maxSequence = 4
        for back in 1..<maxSequence where bytes.count >= back {
            let byte = bytes[bytes.count - back]
            if byte & 0b1100_0000 == 0b1000_0000 { continue }   // continuation — keep scanning
            let width: Int
            switch byte {
            case 0x00...0x7F: width = 1
            case 0xC2...0xDF: width = 2
            case 0xE0...0xEF: width = 3
            case 0xF0...0xF4: width = 4
            default: return []                                  // malformed lead: let it decode
            }
            guard width > back else { return [] }               // complete: nothing to hold back
            let tail = Array(bytes.suffix(back))
            bytes.removeLast(back)
            return tail
        }
        return []
    }

    /// The kill-and-reap state one spawned child needs, shared by the timeout
    /// timer, the pipe readers and the stream's teardown. It exists so that this
    /// stream cannot hang — the GUI runs on it, so a path that can block forever
    /// is a stuck progress HUD, not just a stuck test.
    ///
    /// The kill actually kills. SIGTERM first, then SIGKILL after a grace
    /// period, both addressed straight at the pid rather than routed through
    /// `Process.terminate()` — SIGKILL can't be caught, blocked or ignored, so
    /// the child dies and the descriptors it holds on our pipes close.
    /// `Process.isRunning` deliberately gates nothing here: it reports whether
    /// Foundation has OBSERVED the exit, so a `guard isRunning` around the kill
    /// skips the kill in exactly the window where the child is alive and the
    /// stream is waiting on it to die. Signals do stop once the child is reaped,
    /// because from then on the pid could be recycled and killing a stranger is
    /// worse than leaving a corpse.
    ///
    /// And the readers stop waiting for an EOF that may never come. One
    /// descendant that outlives the child — a shell's backgrounded job, a helper
    /// the engine spawned — holds the write end open and EOF never arrives. Once
    /// the child is known dead (reaped, or SIGKILLed, which is the same thing
    /// within milliseconds) the readers give the pipe a grace period of SILENCE
    /// and then stop of their own accord. The grace restarts on every byte, so a
    /// descendant that is still producing real output gets drained rather than
    /// truncated.
    private final class ChildGuard: @unchecked Sendable {
        /// How long the child gets to honour SIGTERM before SIGKILL.
        static let killGrace: TimeInterval = 1
        /// How long a pipe may stay silent, after the child is dead, before its
        /// reader gives up on EOF.
        static let readerGrace: TimeInterval = 2
        /// How long the finish waits for an exit status once both pipes are done.
        static let statusGrace: TimeInterval = 5
        /// Reader poll tick in ms — also the resolution of `readerGrace`.
        static let pollTickMs: Int32 = 200

        /// Guards every stored property AND wakes `awaitStatus`.
        private let cond = NSCondition()
        private let name: String
        /// Held for the child's lifetime: once `events()` returns nothing else
        /// retains the Process, and a deallocated Process never delivers its
        /// terminationHandler. Dropped on reap, which also breaks the cycle
        /// (process → handler → self → process).
        private var process: Process?
        private var pid: pid_t = 0
        private var didReap = false
        private var status: Int32?
        private var lastSignal: Int32?
        private var stopReadingAt: DispatchTime?
        private var stopReason = ""
        private var didFinish = false
        private var killTimer: DispatchSourceTimer?

        init(name: String) { self.name = name }

        /// Installation and cancellation share the child lifecycle lock: an
        /// instant exit must not race a timer assigned after the reap callback.
        func armTimeout(_ timeout: TimeInterval, on queue: DispatchQueue) {
            cond.lock(); defer { cond.unlock() }
            guard !didReap, !didFinish else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + timeout, repeating: .never)
            timer.setEventHandler { [weak self] in
                self?.killEscalating(on: queue, because: "it outlived its \(timeout)s timeout")
            }
            timer.resume()
            killTimer = timer
        }

        func cancelTimeout() {
            cond.lock(); defer { cond.unlock() }
            killTimer?.cancel()
            killTimer = nil
        }

        func spawned(_ process: Process) {
            cond.lock(); defer { cond.unlock() }
            pid = process.processIdentifier
            // A child can be reaped before this line runs (`/bin/sh -c printf`
            // is finished long before). Retaining it then would re-form the
            // cycle that `reaped` just broke, for a Process nobody needs.
            guard !didReap else { return }
            self.process = process
        }

        /// Foundation observed the exit: the status is final, the pid is now off
        /// limits, and the readers are on the clock.
        func reaped(status: Int32) {
            cond.lock()
            didReap = true
            self.status = status
            process = nil
            killTimer?.cancel()
            killTimer = nil
            armReadDeadline(reason: "exited")
            cond.broadcast()
            cond.unlock()
        }

        /// SIGTERM now; SIGKILL after `killGrace` if that didn't take.
        func killEscalating(on queue: DispatchQueue, because reason: String) {
            guard send(SIGTERM, saying: "\(reason) — SIGTERM") else { return }
            queue.asyncAfter(deadline: .now() + Self.killGrace) { [self] in
                guard send(SIGKILL, saying: "still alive \(Self.killGrace)s after SIGTERM — SIGKILL")
                else { return }
                // SIGKILL isn't negotiable: the child is gone within
                // milliseconds whether or not Foundation gets around to
                // noticing. Start the readers' clock from here as well, so a
                // reap notification that never lands can't strand them.
                cond.lock(); armReadDeadline(reason: "was SIGKILLed"); cond.unlock()
            }
        }

        /// Signal the child unless it never started, or has already been reaped
        /// and its pid could belong to someone else by now.
        private func send(_ signal: Int32, saying reason: String) -> Bool {
            cond.lock()
            guard !didReap, pid > 0 else { cond.unlock(); return false }
            lastSignal = signal
            let sent = kill(pid, signal) == 0
            let failure = errno
            cond.unlock()
            note(sent ? reason : "\(reason) failed (errno \(failure))")
            return sent
        }

        /// Caller holds `cond`.
        private func armReadDeadline(reason: String) {
            guard stopReadingAt == nil else { return }
            stopReason = reason
            stopReadingAt = .now() + Self.readerGrace
        }

        /// Bytes arrived: if the child is already dead, restart the silence
        /// grace so a descendant still writing real output is drained, not cut.
        func sawData() {
            cond.lock(); defer { cond.unlock() }
            if stopReadingAt != nil { stopReadingAt = .now() + Self.readerGrace }
        }

        /// Asked on every reader tick: is this pipe waiting on an EOF that is
        /// never coming?
        func shouldStopReading(_ pipe: String) -> Bool {
            cond.lock()
            guard let deadline = stopReadingAt, DispatchTime.now() >= deadline else {
                cond.unlock()
                return false
            }
            let reason = stopReason
            cond.unlock()
            note("\(pipe) has no EOF: the child \(reason) and the pipe has been silent for " +
                 "\(Self.readerGrace)s, so something it spawned still holds the write end. " +
                 "Abandoning \(pipe) so the run can finish.")
            return true
        }

        /// The exit status, waiting up to `statusGrace` for the reap to land.
        /// Both pipes reaching EOF normally means the child is already gone, so
        /// this returns at once; the deadline is there so that a reap that never
        /// arrives costs seconds instead of forever.
        func awaitStatus() -> Int32 {
            cond.lock()
            let deadline = Date().addingTimeInterval(Self.statusGrace)
            while status == nil, cond.wait(until: deadline) {}
            if let status {
                cond.unlock()
                return status
            }
            let signal = lastSignal
            cond.unlock()
            // Nothing to report, but something to say: 128 + signal is the
            // shell's convention for "killed by", and any nonzero code is truer
            // than claiming the run succeeded.
            let code = signal.map { 128 + $0 } ?? -1
            note("no exit status \(Self.statusGrace)s after both pipes finished — reporting \(code)")
            return code
        }

        /// True exactly once — the stream's single-shot finish latch.
        func claimFinish() -> Bool {
            cond.lock(); defer { cond.unlock() }
            if didFinish { return false }
            didFinish = true
            return true
        }

        /// A breadcrumb for a run that misbehaved, on stderr because that is
        /// what `xcodebuild test` captures in a CI log (an os.Logger line would
        /// not show up there at all). Every caller is on an abnormal path, so a
        /// healthy run without a timeout says nothing.
        func note(_ message: String) {
            cond.lock()
            let id = pid
            cond.unlock()
            fputs("[SystemProcessPort] \(name)[\(id)]: \(message)\n", stderr)
            fflush(stderr)
        }
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
