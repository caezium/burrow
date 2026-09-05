//
//  MCPConductorToolsTests.swift
//  BurrowTests
//
//  The Phase-6.3 conductor-parity tools (dupes, orphans, net, rules
//  dryrun, sentinel, slim-check, photos) route through the bundled
//  `burrow` conductor. These pin the tool CONTRACT — catalog listing,
//  required-argument validation, the no-audit rule, and the degrade-
//  to-JSON-error path when no conductor is bundled (the test bundle
//  never ships one, so that branch is exercised without spawning).
//

import XCTest
@testable import Burrow

final class MCPConductorToolsTests: XCTestCase {
    private var tempDir: URL!
    private var db: DB!
    private var catalog: ToolCatalog!
    private var server: MCPServer!

    /// The seven read-only discovery tools this phase adds.
    private static let conductorTools: Set<String> = [
        "burrow_dupes", "burrow_net", "burrow_orphans", "burrow_photos",
        "burrow_rules_dryrun", "burrow_sentinel", "burrow_slim_check",
    ]

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-conductor-mcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try DB(at: tempDir.appendingPathComponent("burrow.db"))
        catalog = ToolCatalog(db: db)
        server = MCPServer(db: db)
    }

    override func tearDown() {
        server = nil
        catalog = nil
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Catalog listing

    func testDescriptors_listAllSevenConductorTools() {
        let names = Set(catalog.descriptors().compactMap { $0["name"] as? String })
        for tool in Self.conductorTools {
            XCTAssertTrue(names.contains(tool), "tools/list must include \(tool)")
        }
    }

    /// Every conductor tool carries a description that says it is read-only,
    /// and a schema of the same shape the rest of the catalog uses.
    func testDescriptors_conductorToolsHaveSchemaAndReadOnlyDescription() throws {
        for d in catalog.descriptors() where Self.conductorTools.contains((d["name"] as? String) ?? "") {
            let name = try XCTUnwrap(d["name"] as? String)
            let desc = try XCTUnwrap(d["description"] as? String, "\(name) needs a description")
            XCTAssertTrue(desc.localizedCaseInsensitiveContains("read-only"),
                          "\(name) description must say read-only")
            let schema = try XCTUnwrap(d["inputSchema"] as? [String: Any], "\(name) needs an inputSchema")
            XCTAssertEqual(schema["type"] as? String, "object")
            XCTAssertNotNil(schema["properties"], "\(name) schema needs properties")
        }
    }

    /// The required arguments must be declared in the schema so agents
    /// discover them from tools/list instead of by trial and error.
    func testDescriptors_requiredArgumentsAreDeclared() throws {
        let expected: [String: [String]] = [
            "burrow_dupes": ["paths"],
            "burrow_net": [],
            "burrow_orphans": ["path"],
            "burrow_photos": ["path"],
            "burrow_rules_dryrun": ["dir"],
            "burrow_sentinel": [],
            "burrow_slim_check": ["binary"],
        ]
        for d in catalog.descriptors() {
            guard let name = d["name"] as? String, let want = expected[name] else { continue }
            let schema = try XCTUnwrap(d["inputSchema"] as? [String: Any])
            let required = (schema["required"] as? [String]) ?? []
            XCTAssertEqual(Set(required), Set(want), "\(name) required args drifted")
            // Every required arg must also exist as a property.
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            for arg in want {
                XCTAssertNotNil(properties[arg], "\(name) required arg `\(arg)` missing from properties")
            }
        }
    }

    // MARK: - burrow_dupes argv: `group` is pinned, paths are validated, nothing else reaches argv

    /// An agent cannot pick the engine's subcommand or add `--apply`: the strings it hands over are
    /// validated as directories before anything is spawned, so `dedupe`/`--apply` are refused as
    /// bad arguments and the (footprint-recording) stub engine is never run.
    func testDupes_agentSuppliedSubcommandAndApplyFlag_areRefusedWithoutSpawning() throws {
        let marker = tempDir.appendingPathComponent("engine-ran")
        try ConductorBundleFixture.withConductor(
            present: true, stub: ConductorBundleFixture.footprintStub(marker: marker)) {
            XCTAssertThrowsError(try catalog.call(name: "burrow_dupes",
                                                  arguments: ["paths": ["dedupe", "--apply"]])) { err in
                guard case MCPToolError.badArguments(let message) = err else {
                    return XCTFail("expected .badArguments, got \(err)")
                }
                XCTAssertTrue(message.contains("dedupe"), "the refusal names the offending value: \(message)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                           "a refused call must never spawn the engine")
        }
    }

    /// A real absolute directory mixed with one bad entry is still refused whole — the engine
    /// would otherwise read the bad entry as a flag or a subcommand for the good one.
    func testDupes_oneRelativePathInTheList_refusesTheWholeCall() throws {
        let marker = tempDir.appendingPathComponent("engine-ran")
        try ConductorBundleFixture.withConductor(
            present: true, stub: ConductorBundleFixture.footprintStub(marker: marker)) {
            XCTAssertThrowsError(try catalog.call(name: "burrow_dupes",
                                                  arguments: ["paths": [tempDir.path, "Downloads"]]))
            XCTAssertThrowsError(try catalog.call(name: "burrow_dupes",
                                                  arguments: ["paths": [tempDir.appendingPathComponent("missing").path]]))
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    /// The happy path: the engine receives `dupes group <dir> --json` — `group` spelled by the
    /// tool, the directory verbatim, and the conductor's `--json` — nothing else.
    func testDupes_existingAbsoluteDirectory_spawnsTheReadOnlyGroupSubcommand() throws {
        try ConductorBundleFixture.withConductor(present: true, stub: ConductorBundleFixture.argvEchoStub) {
            let json = try catalog.call(name: "burrow_dupes", arguments: ["paths": [tempDir.path]])
            let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            XCTAssertEqual(obj["argv"] as? String, "dupes group \(tempDir.path) --json")
        }
    }

    // MARK: - burrow_evict: the one actuating tool on this seam, gated like the action tools

    func testMutationSwitchesRequireJSONBooleansBeforeDispatch() throws {
        let saved = Store.d
        Store.d = UserDefaults(suiteName: StoreTests.scratchSuite)!
        Store.d.removePersistentDomain(forName: StoreTests.scratchSuite)
        defer { Store.d.removePersistentDomain(forName: StoreTests.scratchSuite); Store.d = saved }
        try ConductorBundleFixture.withConductor(present: true, stub: ConductorBundleFixture.argvEchoStub) {
            for tool in ToolCatalog.auditedTools {
                for literal in ["1", "0", "\"true\"", "null"] {
                    let data = Data("{\"confirm\":\(literal)}".utf8)
                    var args = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
                    args["paths"] = [tempDir.path]
                    args["apps"] = ["com.example.review-fixture"]
                    XCTAssertThrowsError(try catalog.call(name: tool, arguments: args), "\(tool): \(literal)") { error in
                        guard case MCPToolError.badArguments = error else {
                            return XCTFail("expected bad arguments, got \(error)")
                        }
                    }
                }
            }
            let data = Data(#"{"apps":["com.example.review-fixture"],"permanent":1,"confirm":false}"#.utf8)
            let args = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertThrowsError(try catalog.call(name: "burrow_uninstall", arguments: args))
        }
    }

    func testEvict_isAuditedAndDeclaresPathsRequired() throws {
        XCTAssertTrue(ToolCatalog.auditedTools.contains("burrow_evict"), "evict mutates; it must leave an audit row")
        let d = try XCTUnwrap(catalog.descriptors().first { $0["name"] as? String == "burrow_evict" })
        let schema = try XCTUnwrap(d["inputSchema"] as? [String: Any])
        XCTAssertEqual(schema["required"] as? [String], ["paths"])
        XCTAssertNotNil(MCPToolMetadata.table["burrow_evict"])
        XCTAssertEqual(MCPToolMetadata.table["burrow_evict"]?.readOnly, false)
    }

    func testEvict_withoutConfirm_isTheEnginesDryRun_noApply() throws {
        try ConductorBundleFixture.withConductor(present: true, stub: ConductorBundleFixture.argvEchoStub) {
            let json = try catalog.call(name: "burrow_evict", arguments: ["paths": [tempDir.path]])
            let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            XCTAssertEqual(obj["argv"] as? String, "evict \(tempDir.path) --json")
        }
    }

    func testEvict_confirmWithoutOptIn_isBlockedAndNothingSpawns() throws {
        let saved = Store.d
        Store.d = UserDefaults(suiteName: StoreTests.scratchSuite)!
        Store.d.removePersistentDomain(forName: StoreTests.scratchSuite)
        defer { Store.d.removePersistentDomain(forName: StoreTests.scratchSuite); Store.d = saved }
        let marker = tempDir.appendingPathComponent("engine-ran")
        try ConductorBundleFixture.withConductor(
            present: true, stub: ConductorBundleFixture.footprintStub(marker: marker)) {
            let json = try catalog.call(name: "burrow_evict",
                                        arguments: ["paths": [tempDir.path], "confirm": true])
            let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            XCTAssertEqual(obj["blocked"] as? Bool, true)
            XCTAssertEqual(obj["ran"] as? Bool, false)
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    func testEvict_confirmWithOptIn_appendsApply() throws {
        let saved = Store.d
        Store.d = UserDefaults(suiteName: StoreTests.scratchSuite)!
        Store.d.removePersistentDomain(forName: StoreTests.scratchSuite)
        defer { Store.d.removePersistentDomain(forName: StoreTests.scratchSuite); Store.d = saved }
        Store.mcpActionsEnabled = true
        try ConductorBundleFixture.withConductor(present: true, stub: ConductorBundleFixture.argvEchoStub) {
            let json = try catalog.call(name: "burrow_evict",
                                        arguments: ["paths": [tempDir.path], "confirm": true])
            let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            XCTAssertEqual(obj["argv"] as? String, "evict \(tempDir.path) --apply --json")
        }
    }

    func testEvict_relativeOrMissingPath_isRefusedWithoutSpawning() throws {
        let marker = tempDir.appendingPathComponent("engine-ran")
        try ConductorBundleFixture.withConductor(
            present: true, stub: ConductorBundleFixture.footprintStub(marker: marker)) {
            XCTAssertThrowsError(try catalog.call(name: "burrow_evict", arguments: ["paths": ["--apply"]]))
            XCTAssertThrowsError(try catalog.call(name: "burrow_evict",
                                                  arguments: ["paths": [tempDir.appendingPathComponent("nope").path]]))
            XCTAssertThrowsError(try catalog.call(name: "burrow_evict", arguments: [:]))
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    // MARK: - The legacy `.mo` tools run the bundled engine when there is one

    /// analyze / cleanup_history / list_apps used to spawn through `.mo` discovery even on a
    /// build that bundles the engine — a different lookup (and environment) from the conductor
    /// tools beside them. With a bundled engine present they must reach THAT binary.
    func testAnalyze_withBundledEngine_spawnsItRatherThanDiscovery() throws {
        try ConductorBundleFixture.withConductor(present: true, stub: ConductorBundleFixture.argvEchoStub) {
            let json = try catalog.call(name: "burrow_analyze", arguments: ["path": tempDir.path])
            let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            XCTAssertEqual(obj["argv"] as? String, "analyze --json \(tempDir.path)")
        }
    }

    func testCleanupHistoryAndListApps_withBundledEngine_spawnIt() throws {
        try ConductorBundleFixture.withConductor(present: true, stub: ConductorBundleFixture.argvEchoStub) {
            let history = try catalog.call(name: "burrow_cleanup_history", arguments: ["limit": 5])
            let h = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(history.utf8)) as? [String: Any])
            XCTAssertEqual(h["argv"] as? String, "history --json --limit 5")
            let apps = try catalog.call(name: "burrow_list_apps", arguments: [:])
            XCTAssertTrue(apps.contains("uninstall --list"), apps)
        }
    }

    // MARK: - Required-argument validation (before any conductor spawn)

    func testDupes_withoutPaths_throwsBadArguments() {
        XCTAssertThrowsError(try catalog.call(name: "burrow_dupes", arguments: [:])) { err in
            guard case MCPToolError.badArguments = err else {
                return XCTFail("expected .badArguments, got \(err)")
            }
        }
    }

    func testDupes_withEmptyPaths_throwsBadArguments() {
        XCTAssertThrowsError(try catalog.call(name: "burrow_dupes",
                                              arguments: ["paths": ["", "  "]])) { err in
            guard case MCPToolError.badArguments = err else {
                return XCTFail("expected .badArguments, got \(err)")
            }
        }
    }

    func testOrphans_withoutPath_throwsBadArguments() {
        XCTAssertThrowsError(try catalog.call(name: "burrow_orphans", arguments: [:])) { err in
            guard case MCPToolError.badArguments = err else {
                return XCTFail("expected .badArguments, got \(err)")
            }
        }
    }

    func testRulesDryrun_withoutDir_throwsBadArguments() {
        // The bundled conductor ships no rules/ directory and its CLI default
        // (`rules/` relative to CWD) is meaningless from a GUI-spawned
        // process — so `dir` is required. Honest > broken.
        XCTAssertThrowsError(try catalog.call(name: "burrow_rules_dryrun", arguments: [:])) { err in
            guard case MCPToolError.badArguments = err else {
                return XCTFail("expected .badArguments, got \(err)")
            }
        }
    }

    func testSlimCheck_withoutBinary_throwsBadArguments() {
        XCTAssertThrowsError(try catalog.call(name: "burrow_slim_check", arguments: [:])) { err in
            guard case MCPToolError.badArguments = err else {
                return XCTFail("expected .badArguments, got \(err)")
            }
        }
    }

    func testPhotos_withoutPath_throwsBadArguments() {
        XCTAssertThrowsError(try catalog.call(name: "burrow_photos", arguments: [:])) { err in
            guard case MCPToolError.badArguments = err else {
                return XCTFail("expected .badArguments, got \(err)")
            }
        }
    }

    /// Over the JSON-RPC envelope the same validation must surface as the
    /// standard -32602 invalid-arguments error.
    func testSlimCheck_withoutBinary_is32602OverTheEnvelope() {
        let r = server.response(toLine: Data(
            #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"burrow_slim_check","arguments":{}}}"#.utf8))
        XCTAssertEqual((r?["error"] as? [String: Any])?["code"] as? Int, -32602)
    }

    // MARK: - Read-only: never audited, never confirm-gated

    func testConductorTools_areNotAudited() {
        for tool in Self.conductorTools {
            XCTAssertFalse(ToolCatalog.auditedTools.contains(tool),
                           "\(tool) is read-only and must not be in auditedTools")
        }
    }

    // MARK: - Degrade, never throw (build that bundled no conductor)

    /// A build without Resources/burrow must answer with a JSON error object naming the
    /// conductor — never a throw, never a crash, and no process spawned. The fixture chooses
    /// that state explicitly; before it, the test merely inherited whatever the build staged.
    func testNet_withoutBundledConductor_returnsJSONErrorMentioningConductor() throws {
        try ConductorBundleFixture.withConductor(present: false) {
            let json = try catalog.call(name: "burrow_net", arguments: [:])
            let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            let error = try XCTUnwrap(obj["error"] as? String)
            XCTAssertTrue(error.localizedCaseInsensitiveContains("conductor")
                            || error.localizedCaseInsensitiveContains("burrow"),
                          "the error must tell the agent the conductor is missing, got: \(error)")
        }
    }

    func testSentinel_withoutBundledConductor_returnsJSONErrorNotThrow() throws {
        try ConductorBundleFixture.withConductor(present: false) {
            let json = try catalog.call(name: "burrow_sentinel", arguments: [:])
            let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            XCTAssertNotNil(obj["error"])
        }
    }

    /// Valid arguments + missing conductor must still degrade (the
    /// argument check passes, then the availability check reports).
    func testSlimCheck_withBinaryButNoConductor_returnsJSONError() throws {
        try ConductorBundleFixture.withConductor(present: false) {
            let json = try catalog.call(name: "burrow_slim_check", arguments: ["binary": "/usr/bin/true"])
            let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            XCTAssertNotNil(obj["error"])
        }
    }

    // MARK: - The other branch: a build that DID bundle one

    /// The complement nothing covered. Argument validation runs BEFORE the availability check, so
    /// on a build that shipped the conductor a missing argument still surfaces as `badArguments`
    /// — the caller is told what it got wrong instead of being handed a conductor error, and the
    /// tool doesn't spawn anything to discover what the schema already knew.
    func testSlimCheck_withConductorBundled_stillRejectsBadArgumentsWithoutSpawning() throws {
        try ConductorBundleFixture.withConductor(present: true) {
            XCTAssertThrowsError(try catalog.call(name: "burrow_slim_check", arguments: [:])) { err in
                guard case MCPToolError.badArguments(let message) = err else {
                    return XCTFail("expected .badArguments, got \(err)")
                }
                XCTAssertTrue(message.contains("binary"),
                              "the caller must be told which argument is missing, got: \(message)")
                XCTAssertFalse(message.localizedCaseInsensitiveContains("conductor"),
                               "a missing argument must not be reported as a missing conductor")
            }
        }
    }

    /// Resolution is by executable bit, not by name: a non-executable file called `burrow`
    /// (a stray artifact, a partially-staged copy) must not read as a usable conductor.
    func testNonExecutableFileNamedBurrowDoesNotCountAsBundled() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-nonexec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertTrue(
            FileManager.default.createFile(atPath: dir.appendingPathComponent("burrow").path,
                                           contents: Data("not a binary".utf8),
                                           attributes: [.posixPermissions: 0o644]),
            "the fixture must actually stage the file, or the assertions below prove nothing")
        let saved = BurrowEngine.resourceDirectory
        BurrowEngine.resourceDirectory = { dir }
        defer {
            BurrowEngine.resourceDirectory = saved
            try? FileManager.default.removeItem(at: dir)
        }

        XCTAssertNil(BurrowEngine.executableURL())
        XCTAssertFalse(BurrowEngine.isAvailable)
    }
}
