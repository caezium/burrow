//
//  HomebrewEnvironment.swift
//  Burrow
//
//  The user's own Homebrew configuration (issue #424). A Finder-launched app
//  inherits launchd's environment, not the login shell's, so every
//  `HOMEBREW_*` export in ~/.zshrc — most importantly the mirror variables
//  (`HOMEBREW_API_DOMAIN`, `HOMEBREW_BOTTLE_DOMAIN`, the `*_GIT_REMOTE`
//  pair) that users behind a slow or blocked path to GitHub rely on — was
//  invisible to the `brew` Burrow spawns. Inside the app, brew then went
//  straight to github.com and ghcr.io, stalled, and the Updates pane showed
//  an empty list.
//
//  This asks the login shell once for its environment and keeps ONLY the
//  `HOMEBREW_`-prefixed entries. Nothing else crosses over: PATH stays the
//  app's own fixed one (brew is still resolved from its known prefixes, never
//  a PATH lookup), and no other variable from the shell can reach a child
//  process. The probe is the user's shell running the user's rc files as the
//  user — the same code `brew` itself would run from a terminal.
//

import Foundation

enum HomebrewEnvironment {
    /// The `HOMEBREW_*` entries of the user's interactive login shell,
    /// probed once per process on first use. Empty when the probe fails or
    /// the shell exports nothing relevant.
    static let imported: [String: String] = probe()

    /// Keep only well-formed `HOMEBREW_*` assignments from `env` output. Pure
    /// so the filter is unit-tested against captured shell output: a banner
    /// line, an `alias` echo, or an unrelated export must never leak through.
    static func parse(_ envOutput: String) -> [String: String] {
        var out: [String: String] = [:]
        for rawLine in envOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard line.hasPrefix("HOMEBREW_"), let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq])
            let value = String(line[line.index(after: eq)...])
            guard isValidKey(key), !value.isEmpty, !value.contains("\0") else { continue }
            out[key] = value
        }
        return out
    }

    /// `HOMEBREW_` followed by shell-identifier characters only.
    static func isValidKey(_ key: String) -> Bool {
        guard key.hasPrefix("HOMEBREW_"), key.count > "HOMEBREW_".count else { return false }
        return key.unicodeScalars.allSatisfy { scalar in
            (scalar >= "A" && scalar <= "Z") || (scalar >= "0" && scalar <= "9") || scalar == "_"
        }
    }

    /// Absolute path of the user's login shell, or nil when it isn't one we
    /// can run. `SHELL` is set by launchd from the user record for every
    /// app it launches; `/bin/zsh` is the macOS default when it isn't.
    static func loginShell(environment: [String: String] = Foundation.ProcessInfo.processInfo.environment) -> String? {
        let candidate = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        guard candidate.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: candidate) else { return nil }
        return candidate
    }

    /// Run `<shell> -i -l -c env` with a short deadline and parse it. Failing
    /// closed (empty) is fine: brew then runs exactly as it did before this
    /// existed.
    private static func probe() -> [String: String] {
        guard let shell = loginShell() else { return [:] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-i", "-l", "-c", "env"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        let handle = pipe.fileHandleForReading
        var buffer = Data()
        let drained = DispatchSemaphore(value: 0)
        handle.readabilityHandler = { fh in
            let chunk = fh.availableData
            if chunk.isEmpty {
                fh.readabilityHandler = nil
                drained.signal()
            } else {
                buffer.append(chunk)
            }
        }
        do { try process.run() } catch {
            handle.readabilityHandler = nil
            return [:]
        }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: killer)
        process.waitUntilExit()
        killer.cancel()
        // Wait for EOF so a fast exit can't race the last chunk; the child is
        // gone, so this returns promptly.
        _ = drained.wait(timeout: .now() + 1)
        handle.readabilityHandler = nil
        guard process.terminationStatus == 0 else { return [:] }
        return parse(String(decoding: buffer, as: UTF8.self))
    }
}
