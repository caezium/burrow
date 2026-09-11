//
//  BrewClient.swift
//  Burrow
//
//  Shared Homebrew invocation seam. The Updates pane shells `brew` for
//  outdated/update/upgrade; the Services + Snapshot features reuse the same
//  resolution (known Homebrew prefixes, never a PATH lookup a user-writable
//  dir could shadow), the same environment, and the same EngineRunner capture
//  path. Pure parsers live alongside their callers and are unit-tested; this
//  is just the spawn seam.
//

import Foundation

enum BrewClient {
    struct Result {
        let out: String
        let err: String
        let code: Int32
        var timedOut: Bool = false
    }

    /// The Homebrew binary, or nil if Homebrew isn't installed.
    static func path() -> String? {
        for p in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }

    /// The environment every brew child gets: the app's own, a PATH that
    /// starts at brew's prefix (brew shells out to git, curl, ruby), the
    /// user's `HOMEBREW_*` exports from their login shell (#424), and —
    /// when `autoUpdate` is false — `HOMEBREW_NO_AUTO_UPDATE=1`, so a read
    /// like `brew outdated` reports the local index instead of first fetching
    /// taps from GitHub. Pure given `imported`, so the layering is testable.
    static func environment(
        brew: String,
        autoUpdate: Bool = true,
        base: [String: String] = Foundation.ProcessInfo.processInfo.environment,
        imported: [String: String] = HomebrewEnvironment.imported
    ) -> [String: String] {
        var env = base
        for (key, value) in imported where HomebrewEnvironment.isValidKey(key) {
            env[key] = value
        }
        let dir = (brew as NSString).deletingLastPathComponent
        env["PATH"] = "\(dir):/usr/bin:/bin:/usr/sbin:/sbin:" + (base["PATH"] ?? "")
        if !autoUpdate { env["HOMEBREW_NO_AUTO_UPDATE"] = "1" }
        return env
    }

    /// A missing brew is reported the same way as a failing one (nonzero
    /// code, message in `err`) so every caller has exactly one failure path
    /// to render; `timedOut` is kept separate because "brew never answered"
    /// deserves different copy from "brew said no".
    static func run(_ args: [String], timeout: TimeInterval = 120, autoUpdate: Bool = true) -> Result {
        guard let brew = path() else { return Result(out: "", err: "brew not found", code: -1) }
        do {
            let r = try EngineRunner.shared.capture(
                MoCommand(target: .executable(brew), args: args,
                          environment: environment(brew: brew, autoUpdate: autoUpdate), timeout: timeout))
            return Result(out: r.stdout, err: r.stderr, code: r.exitCode, timedOut: r.timedOut)
        } catch {
            return Result(out: "", err: "\(error)", code: -1)
        }
    }

    static var isInstalled: Bool { path() != nil }
}
