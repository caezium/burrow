//
//  EngineCLITests.swift
//  BurrowTests
//
//  The version/capability surface is the pure piece of the engine lifecycle
//  (install/version/update); the rest spawns a subprocess. Two unrelated programs can sit
//  behind `findExecutable()` — the Rust `burrow-engine` (0.x, JSON envelope) and a
//  mo-family binary (1.4x, text banner) — so these tests run against output captured
//  VERBATIM from both, not against a remembered shape.
//

import XCTest
import Darwin
@testable import Burrow

final class EngineCLITests: XCTestCase {

    // MARK: - Version fixtures
    //
    // Captured 2026-08-07 by running each binary and byte-dumping stdout.

    /// `burrow-engine --version` (Rust engine, burrow-engine-new @ 909caa6). Exit 0.
    /// `version`, `--version` and `-V` all produce this identical line.
    static let engineVersionStdout =
        #"{"ok":true,"burrow_cli":"0.1.0","engine":"burrow-engine","command":"version","data":{"version":"0.1.0","engine":"burrow-engine","arch":"arm64"}}"# + "\n"

    /// An `ok:false` envelope from the SAME binary, exit 2. This is the shape `--version`
    /// itself returned before the engine grew a `version` command — the envelope the old
    /// `version()` scraped a number out of. Captured by asking the current binary for an
    /// unknown top-level command (`--verzion`), which is the historical `--version`
    /// response with a different token echoed back into `command`; the pre-`version` build
    /// no longer exists to capture from.
    ///
    /// Note the `"burrow_cli":"0.1.0"` — that field, describing the ENVELOPE FORMAT and not
    /// the engine, is what the old first-semver-anywhere scan returned and what five call
    /// sites believed.
    static let engineErrorEnvelopeStdout =
        #"{"ok":false,"burrow_cli":"0.1.0","engine":"burrow-engine","command":"--verzion","error":{"kind":"error","message":"unknown command: --verzion","platform":"macos"}}"# + "\n"

    /// `mo --version` from the Go digger fork (burrow-engine @ 32cf540, the 1.42.0 MIT fork
    /// of mole). Exit 0. Leading blank line and trailing blank line are real.
    static let moBannerStdout = """

    burrow-engine version 1.42.0 (fork of mole @ 9daf936, last MIT)
    macOS: 26.5.2
    Architecture: arm64
    Kernel: 25.5.0
    SIP: Enabled
    Disk Free: 10.84GB
    Install: Manual
    Shell: /bin/zsh

    """

    // MARK: - Version report

    func testVersionReport_readsTheDeclaredFieldFromTheEngineEnvelope() {
        let report = EngineCLI.parseVersionReport(Captured(stdout: Self.engineVersionStdout, stderr: "", exitCode: 0))
        XCTAssertEqual(report?.version, "0.1.0")
        XCTAssertEqual(report?.name, "burrow-engine")
        XCTAssertEqual(report?.kind, .envelope)
        XCTAssertEqual(report?.display, "burrow-engine 0.1.0")
    }

    func testVersionReport_refusesAFailedRun() {
        // THE original bug: this fixture contains "0.1.0", and the old code returned it
        // from a command that had exited 2. A run that failed has no version to report.
        XCTAssertNil(EngineCLI.parseVersionReport(Captured(stdout: Self.engineErrorEnvelopeStdout, stderr: "", exitCode: 2)))
        // A good payload behind a nonzero exit is still a failed run.
        XCTAssertNil(EngineCLI.parseVersionReport(Captured(stdout: Self.engineVersionStdout, stderr: "", exitCode: 1)))
    }

    func testVersionReport_refusesAnErrorEnvelopeEvenOnAZeroExit() {
        // Belt and braces: `ok:false` is a refusal whatever the exit code says.
        XCTAssertNil(EngineCLI.parseVersionReport(Captured(stdout: Self.engineErrorEnvelopeStdout, stderr: "", exitCode: 0)))
    }

    func testVersionReport_readsTheProductLineOfAMoBanner() {
        let report = EngineCLI.parseVersionReport(Captured(stdout: Self.moBannerStdout, stderr: "", exitCode: 0))
        XCTAssertEqual(report?.version, "1.42.0")
        XCTAssertEqual(report?.name, "burrow-engine")
        XCTAssertEqual(report?.kind, .moBanner,
                       "a text banner is a mo-family binary, whatever it calls itself")
        XCTAssertEqual(report?.display, "burrow-engine 1.42.0")
    }

    func testVersionReport_ignoresTheDecoyNumbersInAMoBanner() {
        // Every trailing line of the real banner is dotted-numeric — macOS 26.5.2, Kernel
        // 25.5.0, Disk Free 10.84GB — and each of them clears every minimum in EngineCLI.
        // A first-semver-anywhere scan gets 1.42.0 only because the product line prints
        // first, so re-run the REAL fixture with its lines reversed: anchoring on the line
        // that says "version" must still land on the product.
        let reordered = Self.moBannerStdout
            .split(whereSeparator: \.isNewline)
            .reversed()
            .joined(separator: "\n")
        XCTAssertEqual(EngineCLI.parseVersion(reordered), "10.84",
                       "the unanchored scan takes the first number it sees — that is why it is not the gate")
        let report = EngineCLI.parseVersionReport(Captured(stdout: reordered, stderr: "", exitCode: 0))
        XCTAssertEqual(report?.version, "1.42.0")
        XCTAssertEqual(report?.name, "burrow-engine")
    }

    func testVersionReport_nilWhenTheOutputCarriesNoVersion() {
        XCTAssertNil(EngineCLI.parseVersionReport(Captured(stdout: "", stderr: "", exitCode: 0)))
        XCTAssertNil(EngineCLI.parseVersionReport(Captured(stdout: "no version here\n", stderr: "", exitCode: 0)))
    }

    func testVersionReport_fallsBackToStderrForABannerOnTheErrorStream() {
        let report = EngineCLI.parseVersionReport(Captured(stdout: "", stderr: "mole version 1.41.0\n", exitCode: 0))
        XCTAssertEqual(report?.version, "1.41.0")
        XCTAssertEqual(report?.name, "mole")
    }

    // MARK: - Streaming capability
    //
    // The gate that decides whether SnapshotProducer asks for an NDJSON status stream.
    // It must key off WHICH program answered, because the two number themselves on scales
    // that have nothing to do with each other.

    func testSupportsWatch_theBundledEngineStreamsWhateverItNumbersItself() throws {
        let today = try XCTUnwrap(EngineCLI.parseVersionReport(Captured(stdout: Self.engineVersionStdout, stderr: "", exitCode: 0)))
        XCTAssertTrue(EngineCLI.supportsWatch(today),
                      "the bundled engine serves `status --watch` (BUR-132); the app streams it")

        // The answer is a capability of WHAT answered, never a compare against mo's scale: the
        // engine's 0.x numbering sits below every `minimum*Version` in EngineCLI, and a compare
        // there once returned "no" for the wrong reason. Whatever it numbers itself, it streams.
        for shipped in ["0.1.0", "1.0.0", "1.44.0", "2.7.3"] {
            let future = EngineCLI.EngineVersion(version: shipped, name: "burrow-engine", kind: .envelope)
            XCTAssertTrue(EngineCLI.supportsWatch(future),
                          "the envelope engine at \(shipped) still streams")
        }
    }

    func testSupportsWatch_admitsTheDiggerForkTheOldGateExcluded() throws {
        // The fork back-ported `--watch` onto its 1.42.0 base (cmd/status/main.go:31 declares
        // it: "stream metrics as newline-delimited JSON (NDJSON) until interrupted"), so the
        // upstream 1.44.0 gate was excluding a binary that streams.
        let fork = try XCTUnwrap(EngineCLI.parseVersionReport(Captured(stdout: Self.moBannerStdout, stderr: "", exitCode: 0)))
        XCTAssertTrue(EngineCLI.supportsWatch(fork))
    }

    func testSupportsWatch_stillHoldsUpstreamMoToItsOwnMinimum() {
        // The fork's back-port does not make upstream 1.42/1.43 capable — only the fork's
        // own name lowers the bar.
        func upstream(_ v: String) -> EngineCLI.EngineVersion {
            EngineCLI.EngineVersion(version: v, name: "Mole", kind: .moBanner)
        }
        XCTAssertFalse(EngineCLI.supportsWatch(upstream("1.42.0")))
        XCTAssertFalse(EngineCLI.supportsWatch(upstream("1.43.9")))
        XCTAssertTrue(EngineCLI.supportsWatch(upstream("1.44.0")))
        XCTAssertTrue(EngineCLI.supportsWatch(upstream("1.45.2")))
    }

    // MARK: - parseVersion (single-line scrape)

    func testParseVersion_extractsSemverFromDecoratedOutput() {
        XCTAssertEqual(EngineCLI.parseVersion("mole 1.41.0"), "1.41.0")
        XCTAssertEqual(EngineCLI.parseVersion("v1.41.0\n"), "1.41.0")
        XCTAssertEqual(EngineCLI.parseVersion("mole version 2.0.10 (build 7)"), "2.0.10")
    }

    func testParseVersion_nilWhenNoVersion() {
        XCTAssertNil(EngineCLI.parseVersion("no version here"))
        XCTAssertNil(EngineCLI.parseVersion(""))
    }

    func testParseVersion_ignoresLoneNumbers() {
        // A bare integer isn't a version; needs at least major.minor.
        XCTAssertNil(EngineCLI.parseVersion("built for macOS 14"))
    }

    /// The undecorated banners `parseVersion` was written for still resolve, product and
    /// all, now that the report goes through the line-anchored path.
    func testParseMoBanner_namesTheProductForUndecoratedBanners() {
        XCTAssertEqual(EngineCLI.parseMoBanner("mole 1.41.0")?.name, "mole")
        XCTAssertEqual(EngineCLI.parseMoBanner("mole v1.41.0")?.name, "mole")
        XCTAssertEqual(EngineCLI.parseMoBanner("v1.41.0\n")?.name, "mo")
        XCTAssertEqual(EngineCLI.parseMoBanner("mole version 2.0.10 (build 7)")?.version, "2.0.10")
        XCTAssertEqual(EngineCLI.parseMoBanner("mole version 2.0.10 (build 7)")?.name, "mole")
    }

    func testEngineUpdatePolicy_keepsSignedBundleImmutable() {
        let bundled = "/Applications/Burrow.app/Contents/Resources/burrow"
        XCTAssertEqual(
            EngineCLI.engineUpdatePolicy(executable: bundled, bundledExecutable: bundled),
            .bundledWithApp
        )
        XCTAssertEqual(
            EngineCLI.engineUpdatePolicy(executable: "/opt/homebrew/bin/mo", bundledExecutable: nil),
            .external
        )
        XCTAssertEqual(
            EngineCLI.engineUpdatePolicy(executable: nil, bundledExecutable: nil),
            .unavailable
        )
        XCTAssertEqual(
            EngineCLI.engineUpdateInstruction(for: .bundledWithApp),
            "Update Burrow to get the current bundled engine."
        )
        XCTAssertEqual(
            EngineCLI.engineUpdateInstruction(for: .external),
            "Use Settings › Engine › Update external engine, then try again."
        )
        XCTAssertEqual(
            EngineCLI.engineUpdateInstruction(for: .unavailable),
            "Reinstall Burrow to restore the bundled engine."
        )
    }

    // MARK: - Capture runner (EngineCLI.run)
    //
    // The subprocess boundary is exercised with real tiny system binaries
    // (echo / cat / false / sleep) rather than a mock — the local-substitutable
    // way to test a process runner: actual plumbing, deterministic, fast.

    func testRun_capturesStdoutAndExitZero() throws {
        let r = try EngineCLI.run(args: ["hello world"], executable: "/bin/echo")
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertEqual(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello world")
    }

    func testRun_feedsStdinToChild() throws {
        // `cat` echoes whatever it reads on stdin — proves the stdin feed lands.
        let r = try EngineCLI.run(args: [], executable: "/bin/cat", stdin: "piped input\n")
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertTrue(r.stdout.contains("piped input"))
    }

    func testRun_reportsNonZeroExit() throws {
        let r = try EngineCLI.run(args: [], executable: "/usr/bin/false")
        XCTAssertNotEqual(r.exitCode, 0)
    }

    // Audit H1: `mo analyze --json` and `uninstall --list` emit far more
    // than the ~64 KB kernel pipe buffer. The runner must keep draining
    // while the child writes — otherwise the child blocks in write(2), the
    // parent blocks in waitUntilExit, and the only way out is the timeout
    // killer plus a truncated capture.
    func testRun_capturesOutputLargerThanPipeBuffer() throws {
        let size = 512 * 1024
        let big = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-bigout-\(UUID().uuidString).txt")
        try String(repeating: "x", count: size).write(to: big, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: big) }

        let start = Date()
        let r = try EngineCLI.run(args: [big.path], executable: "/bin/cat", timeout: 5)
        XCTAssertLessThan(Date().timeIntervalSince(start), 4.0,
                          "large output must stream out, not stall until the timeout killer")
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertEqual(r.stdout.count, size, "the whole output must be captured, not one pipe-buffer's worth")
    }

    // MARK: - Elevated script builder (audit M3)
    //
    // The string handed to `do shell script … with administrator privileges`
    // runs as ROOT. Two escaping layers must both hold: single-quoting for
    // the shell, then backslash/quote escaping for the AppleScript literal.

    func testElevatedScript_shellQuotesEveryArgument() {
        let s = EngineCLI.elevatedScript(command: fakeCommand("/tmp/m o/mo"),
                                       args: ["clean", "--dry-run"])
        XCTAssertTrue(s.hasPrefix("do shell script \""))
        XCTAssertTrue(s.hasSuffix("\" with administrator privileges"))
        XCTAssertTrue(s.contains("'/tmp/m o/mo' 'clean' '--dry-run'"))
    }

    func testElevatedScript_replacesTheAmbientRootEnvironment() {
        let s = EngineCLI.elevatedScript(command: fakeCommand("/tmp/mo"), args: ["clean"])

        XCTAssertTrue(s.contains("'/usr/bin/env' '-i'"))
        XCTAssertTrue(s.contains("'PATH=/usr/bin:/bin:/usr/sbin:/sbin'"))
        XCTAssertTrue(s.contains("'HOME=/Users/test'"))
        XCTAssertTrue(s.contains("'LC_ALL=C'"))
    }

    /// The engine's privileged-run contract rides on every elevated invocation: BURROW_HOME
    /// names the invoking user's real home (the engine refuses a /var/root home without it, and
    /// would otherwise enumerate root's ~/Library for leftovers), and BURROW_PRIVILEGED=1 makes
    /// it ignore sidecar overrides outside its own bundle. Both spelled exactly — the engine
    /// reads these names, not a paraphrase.
    func testElevatedScript_carriesTheEnginesPrivilegedRunContract() {
        let s = EngineCLI.elevatedScript(command: fakeCommand("/tmp/mo"), args: ["uninstall", "--apply", "com.x.Y"])
        XCTAssertTrue(s.contains("'BURROW_HOME=/Users/test'"), s)
        XCTAssertTrue(s.contains("'BURROW_PRIVILEGED=1'"), s)
        XCTAssertFalse(s.contains("BURROW_HOME=/var/root"))
        // The same builder feeds the privileged helper, so the two routes cannot disagree.
        let vars = Dictionary(uniqueKeysWithValues:
            PrivilegedEngineEnvironment.variables(home: "/Users/test", username: "test", uid: 501)
                .map { ($0.key, $0.value) })
        XCTAssertEqual(vars["BURROW_HOME"], "/Users/test")
        XCTAssertEqual(vars["BURROW_PRIVILEGED"], "1")
        XCTAssertEqual(vars["HOME"], "/Users/test")
    }

    /// A reviewed clean's script: the plan's boundary checks (expiry, then the pinned identity
    /// of every root and entry) come FIRST, and the engine over the plan file comes LAST — the
    /// shell only removes its temporary plan. A refused check exits `boundaryCheckFailed` before the
    /// engine is spawned.
    func testElevatedScript_reviewedCleanRunsTheBoundaryChecksThenTheEngineOverThePlan() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-elevated-plan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let canonical = URL(fileURLWithPath: try XCTUnwrap(InvokingUserIdentity.canonicalPath(root.path)),
                            isDirectory: true)
        let item = canonical.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false)
        let snapshot = try CleanupSnapshot.capture(
            list: CleanList(categories: [.init(name: "T", items: [
                .init(path: item.path, sizeBytes: 1, sizeText: "1B", itemCount: nil)])],
                            summaryTotalText: "1B", summaryItemCount: 1),
            approvedRootURLs: [canonical])
        let plan = try snapshot.plan(selectedPaths: [item.path])

        let s = EngineCLI.elevatedScript(
            command: fakeCommand("/tmp/mo"),
            args: ["clean", "--permanent", "--plan", "/Users/test/Library/Application Support/Burrow/clean-plans/x.plan", "--apply", "--stream"],
            cleanupPlan: plan)
        let engine = "'/tmp/mo' 'clean' '--apply' '--permanent' '--plan'"
        XCTAssertTrue(s.contains(engine), s)
        XCTAssertTrue(s.contains("burrow_review_file"), "the engine consumes the elevated process's private plan")
        XCTAssertFalse(s.contains("clean-plans/x.plan"), "the mutable GUI file is never read after authentication")
        XCTAssertFalse(s.contains("-delete"), "the script no longer deletes; the engine does, from the plan")
        let checkIndex = try XCTUnwrap(s.range(of: "/bin/date +%s")).lowerBound
        let identityIndex = try XCTUnwrap(s.range(of: "/usr/bin/stat -f '%d:%i:%u:%p' -- '\(item.path)'")).lowerBound
        let engineIndex = try XCTUnwrap(s.range(of: engine)).lowerBound
        XCTAssertLessThan(checkIndex, engineIndex, "expiry is checked before the engine runs")
        XCTAssertLessThan(identityIndex, engineIndex, "the reviewed identity is checked before the engine runs")
        XCTAssertTrue(s.contains("|| exit \(ElevatedExitCode.boundaryCheckFailed)"))
    }

    func testElevatedScript_neutralizesShellMetacharacters() {
        let s = EngineCLI.elevatedScript(command: fakeCommand("/tmp/$(reboot)/mo"),
                                       args: ["a;b", "`x`"])
        XCTAssertTrue(s.contains("'/tmp/$(reboot)/mo' 'a;b' '`x`'"),
                      "metacharacters must ride inert inside single quotes")
    }

    func testElevatedScript_escapesAppleScriptLiteralBreakers() {
        // A double quote in a path must not terminate the AppleScript string.
        let s = EngineCLI.elevatedScript(command: fakeCommand(#"/tmp/he said "hi"/mo"#), args: [])
        XCTAssertFalse(s.contains(#"said "hi""#), "raw quote would break out of the literal")
        XCTAssertTrue(s.contains(#"said \"hi\""#))
        // A single quote goes through the shell's '\'' dance, whose
        // backslash must itself be AppleScript-escaped.
        let s2 = EngineCLI.elevatedScript(command: fakeCommand("/tmp/a'b/mo"), args: [])
        XCTAssertTrue(s2.contains(#"'/tmp/a'\\''b/mo'"#))
    }

    func testElevatedScript_redirectsThroughQuotedLogPath() {
        let sink = try! PrivilegedLogSink.make(token: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
        let s = EngineCLI.elevatedScript(command: fakeCommand("/usr/local/bin/mo"), args: ["clean"],
                                       logSink: sink)
        XCTAssertTrue(s.contains("> '\(sink.filePath)' 2>&1"))
    }

    /// Elevation may execute only the engine sealed inside Burrow.app.
    /// Homebrew prefixes and PATH entries are mutable by the invoking user.
    func testTrustedExecutable_onlyEverReturnsKnownLocations() {
        if let p = EngineCLI.trustedExecutable() {
            XCTAssertEqual(p, EngineCLI.bundledExecutable(),
                           "elevation must never use a Homebrew/user-mutable engine")
        }
    }

    private func fakeCommand(_ path: String) -> ValidatedElevatedCommand {
        let identity = PinnedFileIdentity(path: path, device: 1, inode: 2,
                                          owner: 0, mode: UInt16(S_IFREG | 0o755))
        let user = InvokingUserIdentity(uid: 501, username: "test",
                                        canonicalHome: "/Users/test")
        return ValidatedElevatedCommand(executable: identity, components: [],
                                        invokingUser: user, signedBundlePath: nil)
    }

    func testRun_timesOutInsteadOfHanging() throws {
        let start = Date()
        let r = try EngineCLI.run(args: ["5"], executable: "/bin/sleep", timeout: 0.4)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 3.0, "the 5s sleep must be killed by the 0.4s timeout")
        XCTAssertNotEqual(r.exitCode, 0, "a terminated process is non-zero")
    }

    // MARK: - Discovery caching + revalidation (issue #48)
    //
    // GUI call sites hit findExecutable() on every sampler tick and tool
    // run; without a cache each call re-stats 3 paths and may shell out to
    // `which`. The cache must REVALIDATE (a deleted binary can't keep
    // being returned) and must not cache negatives (the user installs mo
    // mid-session and the installer view rechecks).

    private var fakeMo: URL!

    private func makeFakeMo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-disco-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let exe = dir.appendingPathComponent("mo")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: exe)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        return exe
    }

    override func tearDown() {
        EngineCLI.discoveryCandidates = nil
        EngineCLI.resetDiscoveryCache()
        if let fakeMo { try? FileManager.default.removeItem(at: fakeMo.deletingLastPathComponent()) }
        super.tearDown()
    }

    func testFindExecutable_cachesAPositiveHit() throws {
        fakeMo = try makeFakeMo()
        EngineCLI.discoveryCandidates = [fakeMo.path]
        EngineCLI.resetDiscoveryCache()

        XCTAssertEqual(EngineCLI.findExecutable(), fakeMo.path)
        // Point discovery somewhere else: a cached (still-valid) hit must
        // win without re-walking the candidate list.
        EngineCLI.discoveryCandidates = ["/nonexistent/mo"]
        XCTAssertEqual(EngineCLI.findExecutable(), fakeMo.path, "valid cache hit skips re-discovery")
    }

    func testFindExecutable_revalidatesAndDropsAStaleHit() throws {
        fakeMo = try makeFakeMo()
        EngineCLI.discoveryCandidates = [fakeMo.path]
        EngineCLI.resetDiscoveryCache()
        XCTAssertEqual(EngineCLI.findExecutable(), fakeMo.path)

        try FileManager.default.removeItem(at: fakeMo)
        XCTAssertNil(EngineCLI.findExecutable(),
                     "a vanished binary must not keep being served from the cache")
    }

    func testFindExecutable_neverCachesAMiss() throws {
        EngineCLI.discoveryCandidates = ["/nonexistent/mo"]
        EngineCLI.resetDiscoveryCache()
        XCTAssertNil(EngineCLI.findExecutable())

        // mo gets installed mid-session → the next lookup must see it.
        fakeMo = try makeFakeMo()
        EngineCLI.discoveryCandidates = [fakeMo.path]
        XCTAssertEqual(EngineCLI.findExecutable(), fakeMo.path)
    }
}
