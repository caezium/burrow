//
//  BurrowEngine.swift
//  Burrow
//
//  Runs the bundled `burrow` binary (Resources/burrow, from bundle-burrow.sh — the new
//  `caezium/burrow-engine` Rust crate; see that script's header for the naming story) and returns
//  parsed envelopes. One JSON envelope per command, NDJSON streaming for progress — so the GUI
//  parses ONE shape instead of each call site re-implementing "spawn the engine → parse its
//  output".
//
//  Resolution: the engine is entirely self-contained (it looks for nothing else — no sibling
//  digger directory, unlike the old conductor this file used to front). Spawning reuses the
//  tested capture stack (EngineRunner + MoleProcess) via a `.executable(path)` target — no new
//  process plumbing. When it isn't bundled (dev/CI builds without the vendor/burrow-engine
//  submodule) `isAvailable` is false and callers fall back to the direct engine resolution in
//  `EngineCLI`.
//
//  mo/engine argv are NOT the same wire format: `mo` runs a command LIVE by default and
//  `--dry-run` previews it; the engine inverts that (dry-run by default, `--apply` to execute).
//  `engineArgv(fromMo:)` is the one pure mapping between them, shared by every caller that still
//  speaks mo-style argv (`MoActions`'s catalog, and this file's own streaming path) — see its doc
//  for why a run reaching the engine with the wrong half of this translation is destructive in one
//  direction and merely silent in the other.
//

import Foundation

enum BurrowEngine {

    // MARK: - Resolution

    /// Where the bundled sidecars are looked up. Production reads the app bundle; tests point it
    /// at a directory they control.
    ///
    /// This is a seam rather than a direct `Bundle.main` read because the "no conductor bundled"
    /// behaviour has to be *chosen* by a test, not inherited from whatever the build happened to
    /// stage. Resources/burrow only exists when the vendor/burrow-engine submodule is checked out —
    /// which a developer must do for the Network, Orphans and Photos panes to work at all — so
    /// tests that simply assumed it was absent went red on a correctly-configured checkout while
    /// passing on CI, where actions/checkout fetches no submodules.
    static var resourceDirectory: () -> URL? = { Bundle.main.resourceURL }

    /// The bundled engine binary, or nil if this build didn't ship one — callers then fall
    /// back to the direct engine (EngineRunner).
    ///
    /// This is the ONE resolver for that file: `EngineCLI.bundledExecutable()` delegates here
    /// rather than doing its own `Bundle.main.url(forResource:)` lookup. Two resolvers for the
    /// same file is exactly the kind of thing that can silently disagree — and if it ever did,
    /// `streamOverride` would fire on one answer while `resolveEngine`'s fallback (via
    /// `trustedExecutable()`) fell through to a Homebrew `mo` on the other, on an ELEVATED run.
    /// One implementation makes that impossible instead of merely unlikely — and putting it on
    /// this side of the call means the `resourceDirectory` seam governs both.
    static func executableURL() -> URL? {
        guard let res = resourceDirectory() else { return nil }
        let burrow = res.appendingPathComponent("burrow")
        return FileManager.default.isExecutableFile(atPath: burrow.path) ? burrow : nil
    }

    /// The bundled `fclones` sidecar (Resources/fclones, from bundle-fclones.sh), or nil if this
    /// build didn't ship one. `burrow dupes` shells out to fclones; without a bundled copy it falls
    /// back to a `$BURROW_FCLONES`/PATH fclones, and if none exists the Duplicates pane shows
    /// "fclones not found".
    static func fclonesURL() -> URL? {
        guard let res = resourceDirectory() else { return nil }
        let fclones = res.appendingPathComponent("fclones")
        return FileManager.default.isExecutableFile(atPath: fclones.path) ? fclones : nil
    }

    /// True when a bundled conductor is present. Call sites branch on this to decide between the
    /// conductor path and the legacy direct-engine path.
    static var isAvailable: Bool { executableURL() != nil }

    // MARK: - Pure command shaping (unit-tested)

    /// The argv a JSON one-shot is invoked with: `<command> [args…] --json`. `--json` forces the
    /// stable envelope even when stdout is a TTY.
    static func argv(command: String, args: [String]) -> [String] {
        [command] + args + ["--json"]
    }

    /// The environment for a conductor run: the inherited environment, plus the bundled fclones
    /// path and an augmented PATH. There used to be a third thing here — BURROW_ENGINE_DIR,
    /// pointing the OLD conductor at a sibling digger directory it would otherwise walk up
    /// looking for. The engine looks for nothing: it does the work itself, so that variable is
    /// gone along with the digger it existed to locate.
    static func environment() -> [String: String] {
        // Fully qualified: the Burrow module has its own `ProcessInfo` (a status model), which
        // would otherwise shadow Foundation's here.
        var env = Foundation.ProcessInfo.processInfo.environment
        // Point the conductor at the bundled fclones for `dupes` — but don't OVERRIDE a user's
        // own $BURROW_FCLONES if they set one (they may prefer a newer/system fclones).
        if env["BURROW_FCLONES"] == nil, let fclones = fclonesURL() {
            env["BURROW_FCLONES"] = fclones.path
        }
        env["PATH"] = augmentedPATH(env["PATH"])
        return env
    }

    /// A Finder/LaunchServices launch strips PATH to `/usr/bin:/bin:/usr/sbin:/sbin` — no
    /// `/opt/homebrew/bin` or `/usr/local/bin`. Absolute-path tools (the bundled engine/conductor/
    /// fclones, `/usr/bin/nettop`, `/usr/bin/brctl`) don't care, but a user-installed fallback
    /// sidecar AND the engine's own shell-outs to brew tools would silently vanish. Prepend the
    /// Homebrew bins (idempotent) so PATH resolution matches what the user sees in a terminal.
    /// Pure — unit-tested.
    static func augmentedPATH(_ current: String?) -> String {
        let base = (current?.isEmpty == false) ? current! : "/usr/bin:/bin:/usr/sbin:/sbin"
        let brew = ["/opt/homebrew/bin", "/usr/local/bin"]
        let entries = base.split(separator: ":").map(String.init)
        let missing = brew.filter { !entries.contains($0) }
        return missing.isEmpty ? base : (missing.joined(separator: ":") + ":" + base)
    }

    // MARK: - Capture (one-shot JSON commands)

    /// Run `burrow <command> [args…] --json` and return the parsed success envelope. Reuses the
    /// tested capture runner (timeout + Captured result) by targeting the conductor's exact path.
    /// Throws `BurrowEngineError.notBundled` when no conductor is bundled, or `.engine(kind:
    /// message:)` on a timeout, an empty/garbled response, or an `ok:false` envelope — carrying
    /// the conductor's classified error kind so the UI can react (permissions vs unavailable vs …).
    static func capture(_ command: String,
                        _ args: [String] = [],
                        timeout: TimeInterval = 300,
                        engine: EngineRunner = .shared) throws -> BurrowEnvelope {
        guard let exe = executableURL() else { throw BurrowEngineError.notBundled }
        let cmd = MoCommand(
            target: .executable(exe.path),
            args: argv(command: command, args: args),
            environment: environment(),
            timeout: timeout)
        let result = try engine.capture(cmd)

        guard !result.timedOut else {
            throw BurrowEngineError.engine(kind: ErrorKind.processFailed.rawValue,
                                           message: "burrow \(command) timed out")
        }

        // A timeout or missing binary degrades to a nonzero exit with no stdout (the capture
        // runner never throws for those) — surface it before we try to parse an empty string.
        guard !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BurrowEngineError.engine(kind: ErrorKind.processFailed.rawValue,
                                           message: "burrow \(command) produced no output (exit \(result.exitCode))")
        }

        let envelope = try BurrowEnvelope.parse(result.stdout)
        if !envelope.ok {
            throw BurrowEngineError.engine(
                kind: envelope.error?.kind ?? ErrorKind.error.rawValue,
                message: envelope.error?.message ?? "burrow \(command) failed")
        }
        guard result.exitCode == 0 else {
            throw BurrowEngineError.engine(kind: ErrorKind.processFailed.rawValue,
                                           message: "burrow \(command) failed (exit \(result.exitCode))")
        }
        return envelope
    }

    // MARK: - Streaming clean/optimize (opt-in)

    /// The kill-switch key, read through `Store.d` like every other preference rather than
    /// `UserDefaults.standard` directly. In production the two are the same object; the
    /// difference is that a test can point `Store.d` at a scratch suite and flip this switch
    /// without writing to the developer's live `dev.caezium.Burrow` domain — which is what the
    /// suite used to do, and what made it non-hermetic on a bare runner.
    static let streamingKey = "BurrowStreamViaConductor"

    /// Default ON (hand-validated on a real build): streaming clean/optimize route through the
    /// bundled conductor (`burrow <cmd> --stream`), falling back to the direct engine on any
    /// miss. Kill-switch:
    ///   `defaults write dev.caezium.Burrow BurrowStreamViaConductor -bool NO`
    static var streamingEnabled: Bool {
        (Store.d.object(forKey: streamingKey) as? Bool) ?? true
    }

    /// The analyze kill-switch key (`BurrowStreamAnalyze`), read through `Store.d` like
    /// `streamingKey`.
    static let streamingAnalyzeKey = "BurrowStreamAnalyze"

    /// Default ON: the treemap scan streams `analyze --progress <path>` — the engine's one
    /// concurrent walk, reporting its live file/dir/byte counters and the path it is on per tick,
    /// then the full analyze payload as the terminal `result` line (BUR-132) — instead of one
    /// `analyze` spawn per child directory. Any miss (no bundled engine, a stream that ends
    /// without a result, the 30 s cap) still falls through to the per-child walk. Kill-switch:
    ///   `defaults write dev.caezium.Burrow BurrowStreamAnalyze -bool NO`
    static var streamingAnalyzeEnabled: Bool {
        (Store.d.object(forKey: streamingAnalyzeKey) as? Bool) ?? true
    }

    /// The engine commands that take `--stream` and are forwarded with it: clean, optimize and
    /// purge speak one NDJSON vocabulary (`BurrowStreamReport`). installer has no `--stream` in
    /// the engine and runs buffered (its one envelope line is reduced by the same reducer), and
    /// uninstall is irreversible + matcher-gated — both stay direct.
    private static let streamableCommands: Set<String> = ["clean", "optimize", "purge"]

    /// The pure mo→engine *semantic* mapping: `mo` runs a command LIVE by default and `--dry-run`
    /// previews it; the engine inverts that (dry-run by default, `--apply` to execute). So this
    /// drops `--dry-run` (preview → the engine's own default) or adds `--apply` (live) — nothing
    /// else. No `--stream`: that flag is a transport concern for this file's own streaming path,
    /// not part of what "mo-style" argv means, so `MoActions` (whose action catalog also speaks
    /// mo-style argv, for the non-streaming capture path MCP and the Software tab's uninstall use)
    /// shares exactly this function rather than a copy that also knows about streaming.
    ///
    /// Safety-critical, so it's directly unit-tested, not just through `streamArgv`: get the
    /// direction backwards and a preview turns into a live destructive run (see `streamArgv`'s
    /// doc), or a live run silently no-ops (the §2 bug this whole mapping exists to close).
    ///
    /// `assertDryRun` makes a run's read-only-ness a FACT ON THE WIRE instead of an inherited
    /// default, and forces the preview regardless of what `moArgs` said. Callers that only want a
    /// preview don't need it — dropping `--dry-run` already lands on the engine's own default, and
    /// that is what every preview here has always relied on. The uninstall PRE-FLIGHT is different
    /// in kind: it is the probe that runs BEFORE consent is acted on, against a command that (since
    /// burrow-engine `df9ea3f`) deletes applications and not merely their `~/Library` leftovers. A
    /// flagless `["uninstall", <ids>]` is read-only only for as long as the engine keeps defaulting
    /// that way, and "safe because of a default" is not a property this file can check. With the
    /// flag on, `wants_apply` (`cli.rs`) reads an explicit `--dry-run` as beating `--apply` even on
    /// the seams that skip argv validation, so the probe cannot delete however the default moves.
    ///
    /// It can never produce `--dry-run` alongside `--apply` — the engine refuses that pair outright
    /// (`reject_contradictory_flags`, exit 2, "cannot take both") — because the two appends are the
    /// two arms of one `if`, mutually exclusive by control flow rather than by caller discipline.
    /// That structure is the point: the engine's own doc for that refusal names this function as
    /// half of why no real caller can construct the pair, so the guarantee has to survive reading,
    /// not just testing.
    static func engineArgv(fromMo moArgs: [String], assertDryRun: Bool = false) -> [String] {
        let isPreview = assertDryRun || moArgs.contains("--dry-run")
        var out = moArgs.filter { $0 != "--dry-run" }
        if !isPreview {
            out.append("--apply")     // mo-live → the engine needs --apply
        } else if assertDryRun {
            out.append("--dry-run")   // read-only, stated rather than inferred from the default
        }
        return out
    }

    /// `engineArgv`, plus `--stream` so the engine's output flows line-by-line through the pipe
    /// instead of one buffered envelope. Pure + unit-tested.
    static func streamArgv(fromMo moArgs: [String]) -> [String] {
        engineArgv(fromMo: moArgs) + ["--stream"]
    }

    /// Whether a streaming run should be hand routed through the bundled conductor (`burrow <cmd>
    /// --stream`) instead of spawning `mo`/the direct engine — pure, and independent of whether a
    /// conductor binary actually resolves (that needs a real app bundle; see `streamOverride`).
    ///
    /// Deliberately takes no `elevated` parameter. It used to: a `!elevated` guard sent every
    /// elevated run around this translation entirely, on the theory that an osascript-spawned
    /// process wouldn't inherit BURROW_ENGINE_DIR (which told the OLD conductor where to find the
    /// digger). That variable is gone — the engine looks for nothing — and with it the guard's
    /// only stated reason. Removing the guard closes the §2 gap: EVERY real (non-preview) GUI
    /// clean/optimize run is elevated — `CleanView`'s two `.moleStream` sites, `TuneUpView`'s two,
    /// and `OptimizeView`'s own `operation(...)` call (a fifth `elevated: true` site, built the
    /// same way but not through the `.moleStream` factory) all pass `elevated: true` — so a
    /// `!elevated` guard here meant NONE of the app's actual Clean/Optimize buttons ever received
    /// this translation: they always fell through to the direct-engine path with untranslated
    /// mo-style argv, which after the repoint the engine reads with inverted meaning (`["clean"]`
    /// is mo's LIVE run and the engine's DRY RUN). Elevation still matters downstream —
    /// `ProcessSpec.elevated` still decides osascript vs a plain spawn in `SystemProcessPort` —
    /// it just isn't a reason to skip translating the argv.
    static func shouldStreamViaConductor(command: String) -> Bool {
        streamingEnabled && streamableCommands.contains(command)
    }

    /// When `shouldStreamViaConductor` and a conductor is bundled, the (burrow path, translated
    /// argv) to spawn instead of `mo` — elevated or not. Otherwise nil, so the caller keeps the
    /// direct-engine path UNCHANGED.
    static func streamOverride(moArgs: [String]) -> (executable: String, arguments: [String])? {
        guard let command = moArgs.first,
              shouldStreamViaConductor(command: command),
              let burrow = executableURL()?.path else { return nil }
        return (burrow, streamArgv(fromMo: moArgs))
    }
}

/// Why a conductor run couldn't produce a usable success envelope.
enum BurrowEngineError: Error, LocalizedError {
    /// No `burrow` binary is bundled — the caller should fall back to the direct engine.
    case notBundled
    /// The conductor ran but reported (or amounted to) a failure; `kind` is the classified
    /// reason from the envelope (permission_denied | unsupported | not_found | process_failed | error).
    case engine(kind: String, message: String)

    var errorDescription: String? {
        switch self {
        case .notBundled:
            return "the bundled burrow conductor is unavailable"
        case .engine(let kind, let message):
            return "\(message) [\(kind)]"
        }
    }
}
