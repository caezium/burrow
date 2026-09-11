//
//  PrivilegeBroker.swift
//  Burrow
//
//  The elevated-execution seam (issue #48). One elevated `mo` run = one
//  osascript `do shell script … with administrator privileges` = one
//  macOS auth prompt. That spawn was previously hand-rolled inline in
//  `EngineCLI.runElevated` against a raw `Process`, so the riskiest code in
//  the app — the path that runs as ROOT — was the path no test could reach.
//
//  This is the sibling of `MoleProcessPort` (the #29 capture-spawn runner):
//  `PrivilegeBroker` owns the one-shot elevated invocation behind a port so
//  production keeps spawning real osascript via `SystemPrivilegeBroker`,
//  while tests inject a fake to drive the build-the-osascript-spec quoting
//  and the auth-cancel classification IN MEMORY — no auth dialog, no sudo.
//
//  Streamed elevated runs stay in OperationFlow's SystemProcessPort (output
//  tailed from a temp log); this seam covers one-shot commands where the only
//  signal is the exit status.
//
//  Live caller: `Connectivity.run` (flush DNS / renew DHCP), which constructs
//  `SystemPrivilegeBroker` directly. The `EngineCLI.runElevated` wrapper that
//  used to sit in front of this was deleted along with the `mo touchid`
//  setting, its only user.
//

import Foundation

// MARK: - Outcome

/// What a one-shot elevated run produced. Richer than the raw exit code the
/// old `runElevated` returned: the auth-cancel case is classified ONCE, by
/// the shared engine rule (`AuthCancel`), instead of every caller re-deriving
/// "nonzero ⇒ maybe the prompt was dismissed".
enum ElevatedOutcome: Equatable {
    /// The command ran and exited with this status (0 = success).
    case exited(Int32)
    /// The macOS auth prompt was dismissed before the command ran — osascript
    /// returns the user-cancelled error (-128) and the command never executed.
    case authCancelled
    /// The osascript spawn itself failed to launch (no usable `mo`, Process
    /// threw). Distinct from a command that ran and failed.
    case launchFailed
    /// The privileged helper refused the request before authorization, and
    /// named why. Only the helper route produces this — osascript has no
    /// request to refuse — but it lives in the shared taxonomy so the GUI
    /// renders a refusal as a refusal instead of folding it into
    /// `launchFailed` and blaming program verification (issue #425).
    case refused(HelperRequestRejection)
}

extension ElevatedOutcome {
    /// Back-compat shim for call sites that still branch on an `Int32`. Both
    /// failure shapes collapse to a nonzero code, preserving the exact
    /// behaviour of the old `runElevated -> Int32` contract.
    var exitCode: Int32 {
        switch self {
        case .exited(let code): return code
        case .authCancelled: return 1
        case .launchFailed: return 127
        case .refused: return ElevatedExitCode.requestRefused
        }
    }
}

// MARK: - Port

/// The one elevated-spawn boundary. `openElevated` builds the osascript
/// invocation (via `EngineCLI.elevatedScript`, the one shared two-pass quoter),
/// runs it once, and classifies the result. Production spawns real osascript;
/// tests script the outcome without touching the GUI.
protocol PrivilegeBroker: Sendable {
    /// Run `executable` + `args` once with administrator rights. `executable`
    /// MUST come from a trusted location (never a PATH lookup) — running an
    /// attacker-shadowed binary as root is the whole threat model here.
    func openElevated(executable: String, args: [String]) -> ElevatedOutcome
}

// MARK: - Production witness

/// Spawns the real `/usr/bin/osascript` with the `do shell script …` source
/// and waits for it. Mechanically identical to the old inline `runElevated`
/// body — only the result classification is new (auth-cancel is now named,
/// not folded into a bare nonzero exit).
struct SystemPrivilegeBroker: PrivilegeBroker {
    func openElevated(executable: String, args: [String]) -> ElevatedOutcome {
        let command: ValidatedElevatedCommand
        do {
            let user = try InvokingUserIdentity.current()
            let bundle = InvokingUserIdentity.canonicalPath(Bundle.main.bundleURL.path)
            let canonicalExecutable = InvokingUserIdentity.canonicalPath(executable)
            let isBundled = bundle.flatMap { root in
                canonicalExecutable.map { $0.hasPrefix(root + "/") }
            } ?? false
            command = try ValidatedElevatedCommand.prepare(
                executable: executable, invokingUser: user, requireCurrentBundle: isBundled)
        } catch {
            return .launchFailed
        }
        let script = EngineCLI.elevatedScript(command: command, args: args)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        let outPipe = Pipe(), errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        do {
            try task.run()
            // Drain both pipes to EOF before reaping so neither can fill and wedge osascript.
            // stderr goes on its own queue because draining it AFTER stdout does not deliver
            // that promise: a child filling stderr's ~64KB buffer while stdout is still open
            // deadlocks — we block reading stdout, it blocks writing stderr, and neither moves.
            // osascript's output is small enough that this has never bitten, but the ordering
            // was the hazard, not the volume. Same shape as SystemMoleProcess.capture.
            //
            // stdout is read but discarded: the auth-cancel rule below classifies on the -128
            // in stderr, not on whether anything was printed. The `errQueue.sync {}` barrier
            // after `waitUntilExit` is what makes reading `err` safe — it cannot run until the
            // enqueued read has returned, so the drain being concurrent never races the use.
            var err = Data()
            let errQueue = DispatchQueue(label: "dev.caezium.burrow.broker.err")
            errQueue.async { err = errPipe.fileHandleForReading.readDataToEndOfFile() }
            _ = outPipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            errQueue.sync {}
            let code = task.terminationStatus
            let stderr = String(decoding: err, as: UTF8.self)
            return AuthCancel.outcome(exitCode: code, appleScriptStderr: stderr)
        } catch {
            return .launchFailed
        }
    }
}

// MARK: - One-shot elevated ENGINE run with its transcript

/// An elevated engine command whose OUTPUT matters — the uninstall apply, which answers with a
/// per-app outcome envelope on stdout. `openElevated` above discards stdout; the streaming
/// runner (`OperationFlow`'s port) does not, but it reduces lines into a report as it goes.
/// This drives that same port — helper daemon when it is usable, osascript otherwise, exactly
/// the elevation Clean/Optimize use — and simply collects the transcript into a `Captured`,
/// so the caller decodes it with the parsers it already has for the un-elevated run.
///
/// The environment is the port's: `PrivilegedEngineEnvironment` (BURROW_HOME +
/// BURROW_PRIVILEGED) on both routes, so the elevated engine looks under the invoking user's
/// home for leftovers and refuses user-writable sidecar overrides.
enum ElevatedEngineRun {
    enum Outcome: Equatable {
        /// The engine ran; `stdout` is its transcript (the elevated routes merge stderr into
        /// it — the engine writes nothing there) and `exitCode` its status.
        case captured(Captured)
        /// The administrator prompt was dismissed. Nothing ran.
        case authCancelled
        /// Elevation could not be set up (no invoking identity, the executable failed the
        /// bundle-seal check, the helper could not spawn); nothing ran. `reason` is the
        /// runner's own explanation when it gave one.
        case launchFailed(reason: String)
    }

    /// Blocking — call off the main thread; it waits at the prompt and for the whole run.
    ///
    /// `requiresCurrentBundle` is true: only the engine sealed inside Burrow.app may run as
    /// root — the same rule the streaming path applies to every elevated `.mo` operation — so
    /// a dev build that resolved an external engine is refused here (exit 126 with the
    /// reason in the transcript) rather than elevated.
    static func capture(executable: String, args: [String], timeout: TimeInterval,
                        port: ProcessPort = EngineRunner.shared.streamPort,
                        invokingUser: InvokingUserIdentity? = nil) -> Outcome {
        let user: InvokingUserIdentity
        do { user = try invokingUser ?? InvokingUserIdentity.current() }
        catch { return .launchFailed(reason: error.localizedDescription) }
        let spec = ProcessSpec(executable: executable, arguments: args, stdin: nil,
                               elevated: true, timeout: timeout, invokingUser: user,
                               requiresCurrentBundle: true)
        return collect(port.events(spec))
    }

    /// Reduce one event stream to an outcome. Split out so the reduction is testable with a
    /// scripted port and no elevation at all.
    static func collect(_ events: AsyncStream<ProcessEvent>) -> Outcome {
        let done = DispatchSemaphore(value: 0)
        let box = OutcomeBox()
        Task.detached {
            var lines: [String] = []
            var outcome: Outcome?
            for await event in events {
                switch event {
                case .line(let line): lines.append(line)
                case .authCancelled: outcome = .authCancelled
                case .exited(let code):
                    let transcript = lines.joined(separator: "\n")
                    // The elevated routes carry a refusal reason as transcript lines before a
                    // launch-refused exit; surface it as the failure rather than as engine output.
                    if code == ElevatedExitCode.executableRefused
                        || code == ElevatedExitCode.logSinkUnavailable
                        || code == ElevatedExitCode.launchFailed
                        || code == ElevatedExitCode.requestRefused {
                        outcome = .launchFailed(reason: transcript)
                    } else {
                        outcome = .captured(Captured(stdout: transcript, stderr: "", exitCode: code))
                    }
                }
            }
            box.value = outcome ?? .launchFailed(reason: "the elevated run ended without an exit status")
            done.signal()
        }
        done.wait()
        return box.value ?? .launchFailed(reason: "the elevated run produced no outcome")
    }

    private final class OutcomeBox: @unchecked Sendable {
        var value: Outcome?
    }
}

// MARK: - Auth-cancel classification (the one engine rule)

/// The single auth-cancel rule, shared by every elevated path.  osascript's
/// process status is only `1`; the canonical AppleScript signal is the
/// `userCanceledErr` number -128 in its diagnostic.  Silence is not evidence
/// of cancellation: a root command can fail without printing anything.
///
/// `SystemProcessPort.finalEvent` (the streaming runner) and
/// `SystemPrivilegeBroker.openElevated` (the one-shot runner) both route
/// through `isAuthCancelled` so the two can't drift apart.
enum AuthCancel {
    /// The primitive: does this elevated result look like a dismissed prompt?
    /// `elevated` is always true at the one-shot call site (every run here is
    /// elevated) but kept as a parameter so the streaming path — which spawns
    /// plain runs too — shares the exact same predicate.
    static func isAuthCancelled(elevated: Bool, exitCode: Int32,
                                appleScriptStderr: String) -> Bool {
        guard elevated, exitCode != 0 else { return false }
        return appleScriptStderr
            .components(separatedBy: .newlines)
            .contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasSuffix("(-128)")
            }
    }

    /// Classify a one-shot elevated result (always elevated here).
    static func outcome(exitCode: Int32, appleScriptStderr: String) -> ElevatedOutcome {
        if isAuthCancelled(elevated: true, exitCode: exitCode,
                           appleScriptStderr: appleScriptStderr) {
            return .authCancelled
        }
        return .exited(exitCode)
    }
}
