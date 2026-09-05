//
//  MCPAuditTests.swift
//  BurrowTests
//
//  Agent-action audit rows (roadmap B.5): a mutating tool leaves a
//  burrow.agent_audit row through the real dispatch path; a read tool doesn't.
//

import XCTest
@testable import Burrow

final class MCPAuditTests: XCTestCase {
    private var tempDir: URL!
    private var db: DB!
    private var catalog: ToolCatalog!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try DB(at: tempDir.appendingPathComponent("burrow.db"))
        catalog = ToolCatalog(db: db)
    }

    override func tearDown() {
        catalog = nil
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
        Store.d.removePersistentDomain(forName: StoreTests.scratchSuite)
        Store.d = .standard
    }

    func testMutatingTool_leavesAuditRow() throws {
        _ = try? catalog.call(name: "burrow_clean", arguments: ["confirm": false])
        let row = try XCTUnwrap(db.findLatest(prefix: AgentAudit.prefix), "a mutating tool must audit")
        let entry = try XCTUnwrap(AgentAudit.decode(row.json))
        XCTAssertEqual(entry.tool, "burrow_clean")
        XCTAssertTrue(entry.dryRun, "confirm:false is a dry run")
        XCTAssertEqual(entry.client, "mcp")
    }

    func testReadTool_doesNotAudit() throws {
        _ = try catalog.call(name: "burrow_snapshot", arguments: [:])
        XCTAssertNil(db.findLatest(prefix: AgentAudit.prefix), "read tools take no action → no audit row")
    }

    func testBlockedActionIsRecordedAsUnsuccessful() throws {
        Store.d = UserDefaults(suiteName: StoreTests.scratchSuite)!
        Store.d.removePersistentDomain(forName: StoreTests.scratchSuite)
        _ = try catalog.call(name: "burrow_clean", arguments: ["confirm": true])
        let row = try XCTUnwrap(db.findLatest(prefix: AgentAudit.prefix))
        let entry = try XCTUnwrap(AgentAudit.decode(row.json))
        XCTAssertFalse(entry.ok, "a refused cleanup must not appear successful in Activity")
    }

    func testFailedEngineIsRecordedAsUnsuccessful() throws {
        try ConductorBundleFixture.withConductor(present: false) {
            _ = try catalog.call(name: "burrow_evict", arguments: ["paths": [tempDir.path]])
        }
        let row = try XCTUnwrap(db.findLatest(prefix: AgentAudit.prefix))
        XCTAssertFalse(try XCTUnwrap(AgentAudit.decode(row.json)).ok)
    }

    func testInteractivePreviewAuditUsesTheActualMode() throws {
        Store.d = UserDefaults(suiteName: StoreTests.scratchSuite)!
        Store.d.removePersistentDomain(forName: StoreTests.scratchSuite)
        Store.mcpActionsEnabled = true
        try ConductorBundleFixture.withConductor(present: true, stub: ConductorBundleFixture.argvEchoStub) {
            _ = try catalog.call(name: "burrow_purge", arguments: ["confirm": true])
        }
        let row = try XCTUnwrap(db.findLatest(prefix: AgentAudit.prefix))
        XCTAssertTrue(try XCTUnwrap(AgentAudit.decode(row.json)).dryRun,
                      "purge is preview-only over MCP even when confirm was requested")
    }
}
