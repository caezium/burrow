//
//  EngineCLI.swift
//  Burrow
//
//  Wrapper around Burrow's bundled engine, with a system-installed `mo` as
//  the development/source-build fallback when the bundle has no engine.
//
//  Three commands matter to Burrow today:
//    * `mo status --json` — periodic sampling (SnapshotProducer uses this).
//      Emits the full system snapshot as JSON in ~3 KB. Auto-emits JSON
//      when stdout is not a TTY, but we pass `--json` explicitly so the
//      contract is visible in the args.
//    * `mo clean` / `mo optimize` — CleanView / OptimizeView (streamed).
//    * `mo analyze --json` — Analyze treemap (DiskScanner).
//    * `mo uninstall --list` — Software tab app list (JSON).
//
//  Everything routes through `run(args:)` so subprocess plumbing
//  (timeout, env, NSPipe management) lives in one place.
//

import Foundation
import AppKit  // NSAlert
import os

enum EngineCLI {
    enum EngineUpdatePolicy: Equatable {
        /// The engine is inside Burrow.app and must stay immutable so the
        /// Developer ID resource seal remains valid. It updates with Burrow.
        case bundledWithApp
        /// Source/development build using an external executable. The engine
        /// can keep using its own updater because it is outside Burrow.app.
        case external
        case unavailable
    }

    /// Test seam: when set, discovery checks ONLY these paths (no trusted
    /// list, no `which` fallback) so cache semantics are deterministic.
    internal static var discoveryCandidates: [String]?

    /// Cached positive discovery (issue #48). Call sites hit
    /// `findExecutable()` on every sampler tick and tool run; without this
    /// each call re-stats three paths and may shell out to `which`.
    private static let discoveryCache = OSAllocatedUnfairLock<String?>(initialState: nil)

    static func resetDiscoveryCache() {
        discoveryCache.withLock { $0 = nil }
    }

    /// Locate the `mo` executable. Checks PATH plus a few known install
    /// locations because GUI apps inherit a stripped-down PATH that often
    /// doesn't include Homebrew's bin directory.
    ///
    /// Positive hits are cached and REVALIDATED with one stat per call (a
    /// vanished binary must not keep being served); misses are never cached
    /// (the user installs mo mid-session and the installer view rechecks).
    static func findExecutable() -> String? {
        if let cached = discoveryCache.withLock({ $0 }) {
            if FileManager.default.isExecutableFile(atPath: cached) { return cached }
            discoveryCache.withLock { $0 = nil }
        }
        let found = discover()
        if let found { discoveryCache.withLock { $0 = found } }
        return found
    }

    private static func discover() -> String? {
        if let candidates = discoveryCandidates {
            return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        }
        // Hardcoded locations first — fastest path and works in the
        // GUI-launched case where PATH is `/usr/bin:/bin:/usr/sbin:/sbin`
        // and Homebrew is invisible.
        if let trusted = trustedExecutable() { return trusted }
        // Last resort: ask the shell. Will work if the user launched Burrow
        // from a terminal with their PATH set up, but not from Finder.
        if let viaShell = try? run(args: ["which", "mo"], executable: "/usr/bin/env").stdout,
           let first = viaShell.split(separator: "\n").first {
            let trimmed = String(first).trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, FileManager.default.isExecutableFile(atPath: trimmed) {
                return trimmed
            }
        }
        return nil
    }

    /// Test seam: when set, `bundledExecutable()` returns this instead of doing a real
    /// `Bundle.main` lookup. The xctest host ships no "burrow" resource, so without this,
    /// nothing can exercise the "did we resolve the bundled engine" check `OperationFlow`
    /// does before translating argv on the non-conductor path. Reset in `tearDown`.
    internal static var bundledExecutableOverride: String?

    /// The single engine binary bundled inside the app at Contents/Resources/burrow. Preferred
    /// over any system `mo`: users run our engine with zero install and never touch upstream
    /// (GPL-relicensed) mo. It's part of the signed app bundle, so it's a trusted location.
    static func bundledExecutable() -> String? {
        if let override = bundledExecutableOverride { return override }
        // The single bundled `burrow-engine` binary, staged as Resources/burrow (bundle-burrow.sh).
        // It replaced the old Resources/engine/mole digger — one binary that does the work AND
        // speaks the envelope.
        //
        // Deliberately delegated rather than re-derived here with a second `Bundle` API: this and
        // `BurrowEngine.executableURL()` name the SAME file, and two lookups for one file can
        // silently disagree — see that function's doc for the elevated-run hazard if they ever do.
        // Delegating also means `BurrowEngine.resourceDirectory` governs both, so a test can
        // choose "conductor bundled / not bundled" once instead of per resolver.
        return BurrowEngine.executableURL()?.path
    }

    /// The only engine Burrow may run as root. Homebrew prefixes are normally
    /// owned by the signed-in user, and `mo` is a shell program that sources
    /// adjacent files; checking `/opt/homebrew/bin/mo` once and executing it
    /// later would elevate replaceable code. Unprivileged discovery retains
    /// the external fallbacks, but elevation requires the sealed bundle.
    static func trustedExecutable() -> String? {
        bundledExecutable()
    }

    /// Build the `do shell script` source for one elevated invocation:
    /// every argv element single-quoted for the shell, the whole command
    /// then escaped for embedding in an AppleScript string literal, and an
    /// optional output redirect to a (quoted) log file. The ONE builder
    /// shared by every elevated path, so the two escaping passes can't
    /// drift apart again (one runner had them, the other didn't).
    ///
    /// Prompt model (audited against mo 1.42, June 2026). One elevated run
    /// = one osascript invocation = exactly ONE admin password prompt:
    ///   * `mo` never adds prompts under us. Running as root, its
    ///     `ensure_sudo_session` / `request_sudo_access` short-circuit on
    ///     `sudo -n true`; its per-stage prompts (osascript password
    ///     dialogs in lib/clean/dev.sh etc.) only fire in UN-elevated real
    ///     runs, and every one sits behind a `DRY_RUN` early-return, so
    ///     scans never auth at all.
    ///   * What CAN'T be consolidated: prompts across separate runs (an
    ///     elevated scan, then the real clean). macOS defines the
    ///     `system.privilege.admin` right with shared=false, so the
    ///     credential from one osascript process never carries to the
    ///     next — re-prompting per run is OS policy, not a Burrow bug.
    ///     Pooling them would take a resident privileged helper
    ///     (SMAppService daemon + XPC), a deliberate non-goal for now.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Compose a root command from values already captured before elevation.
    /// The preamble rechecks every pinned inode and the app's resource seal at
    /// the execution boundary, then supplies the invoking user's canonical
    /// identity explicitly instead of inheriting root's HOME/USER.
    static func elevatedScript(command: ValidatedElevatedCommand, args: [String],
                               logSink: PrivilegedLogSink? = nil,
                               cleanupPlan: CleanupExecutionPlan? = nil) -> String {
        func identityCheck(_ identity: PinnedFileIdentity) -> String {
            let stat = "/usr/bin/stat -f '%d:%i:%u:%p' -- \(shellQuote(identity.path)) 2>/dev/null"
            return "[ \"$(\(stat))\" = \(shellQuote(identity.shellStatToken)) ] || exit \(ElevatedExitCode.executableRefused)"
        }

        var statements = command.components.map(identityCheck)
        statements.append(identityCheck(command.executable))
        if let bundle = command.signedBundlePath {
            statements.append("/usr/bin/codesign --verify --strict -- \(shellQuote(bundle)) >/dev/null 2>&1 || exit \(ElevatedExitCode.executableRefused)")
        }

        let user = command.invokingUser
        // The same variables the privileged helper gives its root child — including the engine's
        // BURROW_HOME / BURROW_PRIVILEGED contract — so both elevation routes agree.
        let environment = PrivilegedEngineEnvironment.variables(
            home: user.canonicalHome, username: user.username, uid: UInt32(user.uid))
            .map { "\($0.key)=\($0.value)" }
        let isolatedEnvironment = ["/usr/bin/env", "-i"] + environment
        // `do shell script … with administrator privileges` inherits the
        // caller's PATH on current macOS releases. Start from an empty
        // environment so no user-writable tool can be resolved by the
        // root engine or one of its child scripts.
        let engine = (isolatedEnvironment + [command.executable.path] + args)
            .map(shellQuote).joined(separator: " ")
        let run: String
        if let cleanupPlan {
            run = cleanupPlan.guardedEngineShell(
                commandPrefix: isolatedEnvironment + [command.executable.path])
        } else {
            run = engine
        }

        if let sink = logSink {
            let dir = shellQuote(sink.directoryPath), file = shellQuote(sink.filePath)
            statements.append("umask 022")
            statements.append("/bin/mkdir -m 0755 -- \(dir) || exit \(ElevatedExitCode.logSinkUnavailable)")
            statements.append("cleanup_burrow_log() { /bin/rm -f -- \(file); /bin/rmdir -- \(dir); }")
            statements.append("trap cleanup_burrow_log EXIT HUP INT TERM")
            statements.append("( set -C; : > \(file) ) || exit \(ElevatedExitCode.logSinkUnavailable)")
            statements.append("( \(run) ) > \(file) 2>&1")
            statements.append("burrow_status=$?")
            // Let the app obtain a no-follow descriptor. The root shell then
            // unlinks the sink; an open descriptor remains readable.
            statements.append("/bin/sleep 0.35")
            statements.append("exit $burrow_status")
        } else {
            statements.append(cleanupPlan == nil ? "exec \(run)" : run)
        }
        let raw = statements.joined(separator: "; ")
        let inner = raw.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(inner)\" with administrator privileges"
    }

    // MARK: - Install / version

    static func engineUpdatePolicy(executable: String?, bundledExecutable: String?) -> EngineUpdatePolicy {
        guard let executable else { return .unavailable }
        guard let bundledExecutable else { return .external }
        let selected = URL(fileURLWithPath: executable).resolvingSymlinksInPath().standardizedFileURL
        let bundled = URL(fileURLWithPath: bundledExecutable).resolvingSymlinksInPath().standardizedFileURL
        return selected == bundled ? .bundledWithApp : .external
    }

    static var currentEngineUpdatePolicy: EngineUpdatePolicy {
        let bundled = bundledExecutable()
        return engineUpdatePolicy(executable: findExecutable(), bundledExecutable: bundled)
    }

    static func engineUpdateInstruction(for policy: EngineUpdatePolicy) -> String {
        switch policy {
        case .bundledWithApp:
            return "Update Burrow to get the current bundled engine."
        case .external:
            return "Use Settings › Engine › Update external engine, then try again."
        case .unavailable:
            return "Reinstall Burrow to restore the bundled engine."
        }
    }

    static var currentEngineUpdateInstruction: String {
        engineUpdateInstruction(for: currentEngineUpdatePolicy)
    }

    /// The engine ships BUNDLED inside the app (zero install). This is only the fallback hint
    /// shown if the bundled copy is somehow unavailable — reinstalling the app restores it.
    /// `caezium/tap/burrow` is the cask `release.yml` bumps in caezium/homebrew-tap.
    static let installCommand = "brew reinstall --cask caezium/tap/burrow"
    /// The bundled engine's source: `caezium/burrow-engine` (FSL-1.1-ALv2, the crate the
    /// vendor/burrow-engine submodule tracks). Not the retired burrow-digger fork.
    static let repoURL = URL(string: "https://github.com/caezium/burrow-engine")!

    /// What the resolved engine binary answered when asked for its version.
    ///
    /// Two unrelated programs can end up behind `findExecutable()`, and they number
    /// themselves on scales that have nothing to do with each other:
    ///
    ///   * the Rust `burrow-engine` this app bundles — a 0.x line, answers in the JSON
    ///     envelope (`{"ok":true,…,"data":{"version":"0.1.0","engine":"burrow-engine"}}`);
    ///   * a mo-family binary — upstream `mo`, or the Go digger fork — a 1.4x line that
    ///     answers with a plain-text banner.
    ///
    /// So a bare version string is not a fact anything can be decided on: 0.1.0 and 1.42.0
    /// are not comparable. `kind` records WHICH program answered, and every decision hangs
    /// off that rather than off the number alone.
    struct EngineVersion: Equatable {
        enum Kind: Equatable {
            /// Answered with a Burrow JSON envelope — the Rust `burrow-engine`.
            case envelope
            /// Answered with mo's plain-text banner — upstream `mo`, or the Go digger fork.
            case moBanner
        }

        /// The dotted version the binary reports for ITSELF. On its own scale.
        let version: String
        /// What the binary calls itself ("burrow-engine", "Mole"). NOTE: the Go digger fork
        /// also calls itself "burrow-engine", so this does NOT identify the Rust engine —
        /// only `kind` does.
        let name: String
        let kind: Kind

        /// What a human should be shown. Always names the product, because the bare number
        /// sits next to Burrow's own version in Settings and the About panel, and "0.1.0"
        /// beside an app on 0.11.x reads like the app is broken rather than like a different
        /// component reporting itself.
        var display: String { "\(name) \(version)" }
    }

    /// Ask the resolved engine what it is. nil when nothing is installed, the command
    /// failed, or the answer carried no version.
    ///
    /// Spawns a subprocess — call OFF the main thread.
    static func versionReport() -> EngineVersion? {
        guard let res = try? run(args: ["--version"], timeout: 5) else { return nil }
        return parseVersionReport(res)
    }

    /// Turn one `--version` run into an `EngineVersion`. Pure → unit-tested against real
    /// captured output from both engines.
    ///
    /// The exit-code guard is the whole reason the ORIGINAL bug stayed invisible for so
    /// long: before the engine had a `version` command at all, `--version` returned an
    /// ERROR envelope with a nonzero exit, and the old code scraped the first semver out of
    /// it anyway — landing on the envelope's own `"burrow_cli":"0.1.0"` field and handing
    /// five call sites a number that described the envelope format, not the engine. A run
    /// that failed has no version to report; say nil.
    static func parseVersionReport(_ res: Captured) -> EngineVersion? {
        guard res.exitCode == 0 else { return nil }
        let stdout = res.stdout, stderr = res.stderr

        // The engine declares its version in a named field. Read the field. Do NOT scrape:
        // the envelope also carries `burrow_cli` (the format version) and, on other
        // commands, whatever dotted numbers the payload happens to contain.
        if let envelope = try? BurrowEnvelope.parse(stdout) {
            guard envelope.ok,
                  let payload = envelope.data,
                  let obj = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
                  let version = obj["version"] as? String, !version.isEmpty
            else { return nil }
            let name = (obj["engine"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "burrow-engine"
            return EngineVersion(version: version, name: name, kind: .envelope)
        }

        // Not JSON → the mo-family text banner. mo writes it to stdout; keep the stderr
        // fallback for anything that banners on the error stream.
        return parseMoBanner(stdout.isEmpty ? stderr : stdout)
    }

    /// Pull the product + version out of a mo-family `--version` banner.
    ///
    /// LOAD-BEARING, and the reason this is anchored instead of scraped. The real banner
    /// (captured from the Go digger fork) is:
    ///
    ///     burrow-engine version 1.42.0 (fork of mole @ 9daf936, last MIT)
    ///     macOS: 26.5.2
    ///     Kernel: 25.5.0
    ///     Disk Free: 10.84GB
    ///
    /// Every one of those trailing lines is dotted-numeric, and `parseVersion` takes the
    /// first semver-shaped token ANYWHERE in the blob — so it returns 1.42.0 only because
    /// the product line happens to be printed first. One field reorder upstream and it
    /// returns 26.5.2, which clears every `minimum*Version` in this file and would arm the
    /// streaming gate on a binary that cannot stream. So: find the line that SAYS it is the
    /// version and read only that line. The first-semver-anywhere scan survives solely as a
    /// last-ditch fallback for a banner with no "version" word in it.
    static func parseMoBanner(_ output: String) -> EngineVersion? {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        for line in lines where line.range(of: "version", options: .caseInsensitive) != nil {
            if let found = parseBannerLine(line) { return found }
        }
        for line in lines {
            if let found = parseBannerLine(line) { return found }
        }
        return nil
    }

    /// One banner line → product + version. The product is the words before the number,
    /// minus a trailing connector ("mole version 1.41.0" and "mole v1.41.0" both name
    /// "mole"); an unnamed banner ("v1.41.0") falls back to "mo". Word-wise rather than
    /// substring-wise so a product whose name merely CONTAINS the connector survives intact.
    private static func parseBannerLine(_ line: String) -> EngineVersion? {
        guard let version = parseVersion(line),
              let span = line.range(of: version) else { return nil }
        var words = line[line.startIndex..<span.lowerBound]
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        if let last = words.last,
           last.caseInsensitiveCompare("version") == .orderedSame || last.caseInsensitiveCompare("v") == .orderedSame {
            words.removeLast()
        }
        let name = words.joined(separator: " ")
        return EngineVersion(version: version, name: name.isEmpty ? "mo" : name, kind: .moBanner)
    }

    /// Pull a semver out of one line of `mo --version` output, whatever decoration it
    /// wraps it in ("mole 1.41.0", "v1.41.0", …). Pure → unit-tested.
    ///
    /// Positional: it returns the FIRST semver-shaped token it sees, so it must only ever
    /// be handed a single line already known to be the version line — see `parseMoBanner`
    /// for what happens when it is handed a whole banner instead.
    static func parseVersion(_ output: String) -> String? {
        for token in output.split(whereSeparator: { !($0.isNumber || $0 == ".") }) {
            let parts = token.split(separator: ".")
            if parts.count >= 2, parts.allSatisfy({ Int($0) != nil }) {
                return String(token)
            }
        }
        return nil
    }

    /// Oldest Mole whose `analyze` knows `--json` (added in V1.29.0,
    /// explicitly "for non-TTY environments"). Older versions launch the
    /// TUI instead, which opens /dev/tty and dies when the parent is a
    /// GUI app with no controlling terminal (#35).
    ///
    /// mo's scale — it gates `DiskScanError.moTooOld`, which is only ever reached from a
    /// mo-family binary (see `DiskScanner.scan`).
    static let minimumAnalyzeJSONVersion = "1.29.0"

    /// Oldest UPSTREAM `mo` whose `status --watch` streams NDJSON (V1.44.0, "Signal").
    static let minimumWatchVersion = "1.44.0"

    /// The Go digger fork's own name, as printed in its banner
    /// (`burrow-engine version 1.42.0 (fork of mole @ 9daf936, last MIT)`).
    static let diggerForkName = "burrow-engine"

    /// The fork back-ported `--watch` onto its 1.42.0 base (a clean-room reimplementation of
    /// upstream's V1.44 NDJSON contract, digger commit d7fe549), so gating it at upstream's
    /// 1.44.0 excluded a binary that streams perfectly well. Keyed to the fork's NAME so a
    /// genuine upstream mo 1.42/1.43 — which has no `--watch` — is still excluded.
    static let minimumDiggerForkWatchVersion = "1.42.0"

    /// Whether `engine` can serve `status --watch` as an NDJSON stream. Pure → unit-tested.
    ///
    /// Keyed to what answered, not to how big its number is:
    ///
    ///   * `.envelope` — the bundled `burrow-engine` streams (`status --watch [--interval s]`,
    ///     one NDJSON line per tick, each line the same object `status` puts in its envelope's
    ///     `data`; exits 0 when the reader closes the pipe — BUR-132). The engine ships INSIDE
    ///     the app and has no version drift the app could be behind, so the answer for an
    ///     envelope-speaking engine is simply yes: there is no older envelope engine this build
    ///     can be paired with. Note it is a capability answer, not a version compare — the
    ///     engine numbers itself on a 0.x line that has nothing to do with mo's, and a compare
    ///     against `minimumWatchVersion` here would be meaningless (it used to be, and it
    ///     said "no" for the wrong reason).
    ///   * `.moBanner` — mo-family, so mo's scale applies and the version compare is
    ///     meaningful. Note the digger fork shares the Rust engine's product name; only `kind`
    ///     tells them apart, which is why this switches on `kind` first.
    static func supportsWatch(_ engine: EngineVersion) -> Bool {
        switch engine.kind {
        case .envelope:
            return true
        case .moBanner:
            let minimum = engine.name.caseInsensitiveCompare(diggerForkName) == .orderedSame
                ? minimumDiggerForkWatchVersion
                : minimumWatchVersion
            return versionAtLeast(engine.version, minimum)
        }
    }

    /// Whether the resolved engine supports `status --watch`. Spawns `--version` — call OFF
    /// the main thread. Resolves through the same `findExecutable()` that
    /// `EngineRunner.statusWatch()` spawns, so the binary asked is the binary streamed.
    static func supportsWatch() -> Bool {
        guard let engine = versionReport() else { return false }
        return supportsWatch(engine)
    }

    /// True if `version` ≥ `minimum`, compared numerically component-by-
    /// component (missing components count as 0). Pure → unit-tested.
    static func versionAtLeast(_ version: String, _ minimum: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let v = parts(version), m = parts(minimum)
        for i in 0..<max(v.count, m.count) {
            let a = i < v.count ? v[i] : 0, b = i < m.count ? m[i] : 0
            if a != b { return a > b }
        }
        return true
    }

    /// The subprocess runner. Production uses `SystemMoleProcess`; tests inject
    /// a fake (reset in `tearDown`). Test-only seam — not a configuration point.
    internal static var processPort: MoleProcessPort = SystemMoleProcess()

    /// Run an executable with the given args, capturing stdout + stderr.
    /// Blocks until the process exits — callers are responsible for
    /// running this on a background queue. Times out after `timeout`
    /// seconds; on timeout the process is terminated and the call returns a
    /// non-zero `exitCode` (it does NOT throw). Callers treat any non-zero
    /// exit as failure rather than distinguishing timeout from other errors.
    ///
    /// `stdin` feeds the child's standard input then closes it (EOF). This
    /// is how the uninstall flow answers Mole's `Proceed? [y/N]` and
    /// `Enter confirm` prompts — a GUI app's inherited stdin is closed, so
    /// without this `mo uninstall <app>` blocks forever on the prompt.
    @discardableResult
    static func run(args: [String],
                    executable: String? = nil,
                    stdin: String? = nil,
                    timeout: TimeInterval = 10) throws -> Captured {
        let resolvedExecutable = executable ?? (findExecutable() ?? "/usr/bin/false")
        let processResult = try MoleProcess.capture(
            executable: resolvedExecutable,
            args: args,
            stdin: stdin,
            timeout: timeout,
            port: processPort
        )
        // `Captured` — the one capture result type (EngineRunner's) — rather than a private twin.
        return Captured(
            stdout: processResult.stdout,
            stderr: processResult.stderr,
            exitCode: processResult.exitCode,
            timedOut: processResult.timedOut
        )
    }

    // NOTE: `runElevated` / `runElevatedClassified` used to live here — a
    // one-shot "run `mo` as root with these args" entry point. Their only
    // caller was the `mo touchid enable/disable` setting, and they were
    // deleted with it: an unused function that takes arbitrary argv and runs
    // it as root is exactly the kind of thing that shouldn't sit around
    // waiting for a caller.
    //
    // The elevation machinery itself is still very much alive — the streaming
    // path (`OperationFlow.SystemProcessPort`) uses `elevatedScript` above,
    // and Connectivity's flush-DNS / renew-DHCP fixes call
    // `SystemPrivilegeBroker.openElevated` directly.
}
