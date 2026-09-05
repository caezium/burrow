//
//  MCPConformanceTests.swift
//  BurrowTests
//
//  The 2026-07-28 protocol surface: the stateless request path, the legacy
//  handshake alongside it, cache hints, tool metadata, MRTR, tasks, and the
//  resource/prompt surface.
//
//  MCPEnvelopeTests pins the pre-2026 envelope rules and stays as-is —
//  those are the guarantees a legacy client still depends on. This file
//  pins what the new revision added, plus the one safety property that must
//  survive all of it: no round trip and no transport can substitute for the
//  user's Settings opt-in.
//

import XCTest
@testable import Burrow

final class MCPConformanceTests: XCTestCase {
    private var tempDir: URL!
    private var server: MCPServer!

    private static let version = "2026-07-28"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-conformance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        server = MCPServer(db: try DB(at: tempDir.appendingPathComponent("burrow.db")),
                           serverVersion: "9.8.7")
    }

    override func tearDown() {
        server = nil
        try? FileManager.default.removeItem(at: tempDir)
        Store.d.removePersistentDomain(forName: StoreTests.scratchSuite)
        Store.d = .standard
    }

    // MARK: - Helpers

    /// A stateless-era request: protocol version and capabilities travel in
    /// `params._meta`, and there is no handshake before it.
    private func call(_ method: String, _ params: [String: Any] = [:],
                      capabilities: [String: Any] = [:],
                      version: String = MCPConformanceTests.version,
                      id: Int = 1) -> [String: Any]? {
        var p = params
        var meta = (p["_meta"] as? [String: Any]) ?? [:]
        meta[MCPProtocol.Meta.protocolVersion] = version
        meta[MCPProtocol.Meta.clientCapabilities] = capabilities
        meta[MCPProtocol.Meta.clientInfo] = ["name": "xctest", "version": "1"]
        p["_meta"] = meta
        let body: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": p]
        let data = try! JSONSerialization.data(withJSONObject: body)
        return server.response(toLine: data)
    }

    /// A pre-2026 request: no `_meta` at all.
    private func legacyCall(_ method: String, _ params: [String: Any] = [:],
                            id: Int = 1) -> [String: Any]? {
        let body: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let data = try! JSONSerialization.data(withJSONObject: body)
        return server.response(toLine: data)
    }

    private func result(_ response: [String: Any]?) throws -> [String: Any] {
        let r = try XCTUnwrap(response)
        if let err = r["error"] as? [String: Any] {
            XCTFail("expected a result, got error \(err)")
        }
        return try XCTUnwrap(r["result"] as? [String: Any])
    }

    private func errorCode(_ response: [String: Any]?) -> Int? {
        (response?["error"] as? [String: Any])?["code"] as? Int
    }

    private static let tasksCapability: [String: Any] =
        ["extensions": [MCPProtocol.Extensions.tasks: [String: Any]()]]
    private static let elicitCapability: [String: Any] =
        ["elicitation": ["form": [String: Any]()]]

    // MARK: - Stateless core

    func testDiscover_advertisesVersionsCapabilitiesAndIdentity() throws {
        let r = try result(call("server/discover"))
        let versions = try XCTUnwrap(r["supportedVersions"] as? [String])
        XCTAssertEqual(versions.first, MCPProtocol.latest, "newest revision leads the list")
        XCTAssertTrue(versions.contains("2024-11-05"), "legacy revisions stay negotiable")

        let caps = try XCTUnwrap(r["capabilities"] as? [String: Any])
        XCTAssertNotNil(caps["tools"])
        XCTAssertNotNil(caps["resources"])
        XCTAssertNotNil(caps["prompts"])
        let ext = try XCTUnwrap(caps["extensions"] as? [String: Any])
        XCTAssertNotNil(ext[MCPProtocol.Extensions.tasks], "tasks must be advertised to be usable")

        let meta = try XCTUnwrap(r["_meta"] as? [String: Any])
        let info = try XCTUnwrap(meta[MCPProtocol.Meta.serverInfo] as? [String: Any])
        XCTAssertEqual(info["name"] as? String, "burrow")
        XCTAssertEqual(info["version"] as? String, "9.8.7")
    }

    func testStatelessClient_needsNoHandshake() throws {
        // No `initialize` first — this is the whole point of the revision.
        let r = try result(call("tools/list"))
        XCTAssertFalse((r["tools"] as? [[String: Any]] ?? []).isEmpty)
    }

    func testEveryResult_carriesResultTypeComplete() throws {
        for method in ["server/discover", "tools/list", "resources/list",
                       "resources/templates/list", "prompts/list"] {
            let r = try result(call(method))
            XCTAssertEqual(r["resultType"] as? String, MCPProtocol.ResultType.complete,
                           "\(method) must declare its result type")
        }
    }

    func testEveryResult_carriesServerInfo() throws {
        for method in ["server/discover", "tools/list", "prompts/list"] {
            let r = try result(call(method))
            let meta = try XCTUnwrap(r["_meta"] as? [String: Any], "\(method) has no _meta")
            XCTAssertNotNil(meta[MCPProtocol.Meta.serverInfo], "\(method) omitted serverInfo")
        }
    }

    func testUnsupportedVersion_is32022WithTheSupportedList() throws {
        let r = try XCTUnwrap(call("tools/list", version: "1999-01-01"))
        XCTAssertEqual(errorCode(r), MCPProtocol.ErrorCode.unsupportedProtocolVersion)
        let data = try XCTUnwrap((r["error"] as? [String: Any])?["data"] as? [String: Any])
        XCTAssertEqual(data["requested"] as? String, "1999-01-01")
        let supported = try XCTUnwrap(data["supported"] as? [String])
        XCTAssertTrue(supported.contains(MCPProtocol.latest),
                      "the error has to tell the client what to retry with")
    }

    func testLegacyClient_stillWorksWithoutMeta() throws {
        let init_ = try result(legacyCall("initialize", ["protocolVersion": "2024-11-05"]))
        XCTAssertEqual(init_["protocolVersion"] as? String, "2024-11-05",
                       "a legacy client must be answered in its own revision")
        XCTAssertNotNil(init_["serverInfo"])

        let tools = try result(legacyCall("tools/list", id: 2))
        XCTAssertFalse((tools["tools"] as? [[String: Any]] ?? []).isEmpty)
    }

    func testRemovedMethods_stillAnsweredForOldClients() throws {
        // `ping` and `logging/setLevel` are gone in 2026-07-28, but an old
        // client sending them should not see a broken server.
        XCTAssertNil(errorCode(legacyCall("ping")))
        XCTAssertNil(errorCode(legacyCall("logging/setLevel", ["level": "info"], id: 2)))
    }

    // MARK: - Cache hints

    func testCacheableResults_carryTtlAndScope() throws {
        for method in ["server/discover", "tools/list", "resources/list",
                       "resources/templates/list", "prompts/list"] {
            let r = try result(call(method))
            XCTAssertNotNil(r["ttlMs"] as? Int, "\(method) is missing ttlMs")
            let scope = r["cacheScope"] as? String
            XCTAssertTrue(scope == "public" || scope == "private",
                          "\(method) has cacheScope \(scope ?? "nil")")
        }
    }

    func testResourceRead_isPrivateAndShortLived() throws {
        let r = try result(call("resources/read", ["uri": "burrow://info"]))
        XCTAssertEqual(r["cacheScope"] as? String, "private",
                       "anything describing this Mac must not be shared across contexts")
        let ttl = try XCTUnwrap(r["ttlMs"] as? Int)
        // burrow://info declares liveTTL, so digestTTL (12x longer) was a bound
        // loose enough to hold even if the resource regressed to minute-long
        // caching. Pin it to the TTL the resource actually claims.
        XCTAssertLessThanOrEqual(ttl, MCPProtocol.Cache.liveTTL,
                                 "live data must not be cacheable for long")
    }

    // MARK: - Tool metadata

    func testToolsList_isDeterministicallyOrdered() throws {
        let r = try result(call("tools/list"))
        let names = (r["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        XCTAssertEqual(names, names.sorted(), "clients cache on this order")
    }

    func testEveryTool_hasMetadata() throws {
        let r = try result(call("tools/list"))
        let tools = try XCTUnwrap(r["tools"] as? [[String: Any]])
        for tool in tools {
            let name = try XCTUnwrap(tool["name"] as? String)
            XCTAssertNotNil(MCPToolMetadata.table[name], "\(name) has no metadata entry")
            XCTAssertNotNil(tool["annotations"], "\(name) has no annotations")
            XCTAssertNotNil(tool["title"], "\(name) has no title")
        }
    }

    /// The read-only/destructive split is a safety claim, so it gets pinned
    /// rather than left to whoever edits the table next.
    func testAnnotations_matchTheMutatingSet() throws {
        let r = try result(call("tools/list"))
        let tools = try XCTUnwrap(r["tools"] as? [[String: Any]])
        let mutating = Set(ToolCatalog.auditedTools)
        for tool in tools {
            let name = try XCTUnwrap(tool["name"] as? String)
            let ann = try XCTUnwrap(tool["annotations"] as? [String: Any])
            let readOnly = ann["readOnlyHint"] as? Bool ?? false
            XCTAssertEqual(readOnly, !mutating.contains(name),
                           "\(name): readOnlyHint disagrees with the audited-tools set")
            if mutating.contains(name) {
                XCTAssertNotNil(ann["destructiveHint"], "\(name) must state destructiveHint")
            }
        }
    }

    func testStructuredContent_mirrorsJSONPayloads() throws {
        let r = try result(call("tools/call", ["name": "burrow_info", "arguments": [String: Any]()]))
        let structured = try XCTUnwrap(r["structuredContent"] as? [String: Any],
                                       "a tool with an outputSchema must return structuredContent")
        let content = try XCTUnwrap(r["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(structured.keys.sorted(), parsed.keys.sorted(),
                       "structuredContent must be the same payload, not a second answer")
    }

    /// burrow_report is Markdown. Declaring a schema for it would be a
    /// promise the payload can't keep.
    func testMarkdownTool_hasNoSchemaAndNoStructuredContent() throws {
        XCTAssertNil(MCPToolMetadata.table["burrow_report"]?.outputSchema)
        let body = MCPServer.callToolBody(name: "burrow_report", text: "# not json", isError: false)
        XCTAssertNil(body["structuredContent"])
    }

    func testStructuredContent_skippedWhenPayloadIsNotAnObject() {
        let body = MCPServer.callToolBody(name: "burrow_info", text: "not json at all", isError: false)
        XCTAssertNil(body["structuredContent"],
                     "a soft-failed payload must not be presented as structured")
    }

    // MARK: - MRTR

    func testMissingArgument_asksWhenTheClientCanAsk() throws {
        let r = try result(call("tools/call",
                                ["name": "burrow_uninstall", "arguments": [String: Any]()],
                                capabilities: Self.elicitCapability))
        XCTAssertEqual(r["resultType"] as? String, MCPProtocol.ResultType.inputRequired)
        let requests = try XCTUnwrap(r["inputRequests"] as? [String: Any])
        let apps = try XCTUnwrap(requests["apps"] as? [String: Any])
        XCTAssertEqual(apps["method"] as? String, "elicitation/create")
        let params = try XCTUnwrap(apps["params"] as? [String: Any])
        XCTAssertNotNil(params["requestedSchema"])
        XCTAssertNotNil(r["requestState"] as? String)
    }

    func testMissingArgument_staysAnErrorWithoutElicitation() {
        // No elicitation capability: the client gets exactly what it got
        // before this revision existed.
        let r = call("tools/call", ["name": "burrow_uninstall", "arguments": [String: Any]()])
        XCTAssertEqual(errorCode(r), MCPProtocol.ErrorCode.invalidParams)
    }

    func testInputResponses_withoutState_isRejected() {
        let r = call("tools/call", ["name": "burrow_uninstall",
                                    "inputResponses": ["apps": ["action": "accept"]]])
        XCTAssertEqual(errorCode(r), MCPProtocol.ErrorCode.invalidParams)
    }

    func testDecline_isReportedInBandNotAsAnError() throws {
        let state = MCPInputRequests.encodeState(tool: "burrow_uninstall",
                                                 arguments: [:], asking: "apps")
        let r = try result(call("tools/call", [
            "name": "burrow_uninstall", "requestState": state,
            "inputResponses": ["apps": ["action": "decline"]],
        ], capabilities: Self.elicitCapability))
        let content = try XCTUnwrap(r["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("\"declined\":true"),
                      "a decline is an outcome the model should see, not a protocol fault")
    }

    func testStateRoundTrip_expandsACommaSeparatedAnswer() throws {
        let state = MCPInputRequests.encodeState(tool: "burrow_dupes",
                                                 arguments: ["extra": 1], asking: "paths")
        let decoded = try XCTUnwrap(MCPInputRequests.decodeState(state))
        XCTAssertEqual(decoded.tool, "burrow_dupes")
        XCTAssertEqual(decoded.asking, "paths")
        XCTAssertEqual(decoded.arguments["extra"] as? Int, 1, "original arguments must survive")

        let resolution = MCPInputRequests.resolve(
            state: decoded,
            inputResponses: ["paths": ["action": "accept", "content": ["paths": "/a, /b"]]])
        guard case .proceed(let merged) = resolution else {
            return XCTFail("expected to proceed, got \(resolution)")
        }
        XCTAssertEqual(merged["paths"] as? [String], ["/a", "/b"])
        XCTAssertEqual(merged["extra"] as? Int, 1)
    }

    func testEmptyAnswer_isUnusableRatherThanSilentlyAccepted() throws {
        let state = try XCTUnwrap(MCPInputRequests.decodeState(
            MCPInputRequests.encodeState(tool: "burrow_photos", arguments: [:], asking: "path")))
        let resolution = MCPInputRequests.resolve(
            state: state,
            inputResponses: ["path": ["action": "accept", "content": ["path": "   "]]])
        guard case .unusable = resolution else {
            return XCTFail("a blank answer must not become an argument")
        }
    }

    // MARK: - Tasks

    func testTaskHandle_onlyForClientsThatDeclaredTheExtension() throws {
        // Same tool, two clients. Without the capability it must stay
        // synchronous — a task handle would be an unreadable result.
        let withoutExt = try result(call("tools/call",
                                         ["name": "burrow_analyze",
                                          "arguments": ["path": NSTemporaryDirectory()]]))
        XCTAssertEqual(withoutExt["resultType"] as? String, MCPProtocol.ResultType.complete)

        let withExt = try result(call("tools/call",
                                      ["name": "burrow_analyze",
                                       "arguments": ["path": NSTemporaryDirectory()]],
                                      capabilities: Self.tasksCapability, id: 2))
        XCTAssertEqual(withExt["resultType"] as? String, MCPProtocol.ResultType.task)
        XCTAssertNotNil(withExt["taskId"] as? String)
        XCTAssertEqual(withExt["status"] as? String, "working")
        XCTAssertNotNil(withExt["createdAt"] as? String)
        XCTAssertNotNil(withExt["ttlMs"])
    }

    func testShortTool_staysSynchronousEvenForATasksClient() throws {
        let r = try result(call("tools/call", ["name": "burrow_info", "arguments": [String: Any]()],
                                capabilities: Self.tasksCapability))
        XCTAssertEqual(r["resultType"] as? String, MCPProtocol.ResultType.complete,
                       "a fast tool gains nothing from a poll loop")
    }

    func testTaskLifecycle_completesAndCarriesTheResult() throws {
        let store = MCPTaskStore()
        let record = store.start(label: "unit", progressToken: nil) { progress in
            progress("halfway")
            return .success(["content": [["type": "text", "text": "{}"]]])
        }
        XCTAssertEqual(record.status, "working")

        let done = expectation(description: "task reaches a terminal state")
        DispatchQueue.global().async {
            while store.get(record.taskId)?.status == "working" { usleep(20_000) }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        let final = try XCTUnwrap(store.get(record.taskId))
        XCTAssertEqual(final.status, "completed")
        let wire = MCPTaskStore.wire(final)
        XCTAssertNotNil(wire["result"])
        XCTAssertNil(wire["error"])
    }

    func testTaskFailure_carriesAJSONRPCError() throws {
        let store = MCPTaskStore()
        let record = store.start(label: "unit", progressToken: nil) { _ in
            .failure(.invalidParams("nope"))
        }
        let done = expectation(description: "task fails")
        DispatchQueue.global().async {
            while store.get(record.taskId)?.status == "working" { usleep(20_000) }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        let wire = MCPTaskStore.wire(try XCTUnwrap(store.get(record.taskId)))
        XCTAssertEqual(wire["status"] as? String, "failed")
        let error = try XCTUnwrap(wire["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, MCPProtocol.ErrorCode.invalidParams)
    }

    func testCancel_isTerminalAndSurvivesALateResult() throws {
        let store = MCPTaskStore()
        let gate = DispatchSemaphore(value: 0)
        let record = store.start(label: "unit", progressToken: nil) { _ in
            gate.wait()
            return .success(["content": []])
        }
        XCTAssertTrue(store.cancel(record.taskId))
        XCTAssertEqual(store.get(record.taskId)?.status, "cancelled")

        gate.signal()   // let the work finish after the cancel
        // The late success must not resurrect a task the client was told
        // had already stopped.
        let stillCancelled = expectation(description: "stays cancelled")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            XCTAssertEqual(store.get(record.taskId)?.status, "cancelled")
            stillCancelled.fulfill()
        }
        wait(for: [stillCancelled], timeout: 5)
    }

    func testUnknownTask_is32602() {
        XCTAssertEqual(errorCode(call("tasks/get", ["taskId": "nope"])),
                       MCPProtocol.ErrorCode.invalidParams)
        XCTAssertEqual(errorCode(call("tasks/cancel", ["taskId": "nope"])),
                       MCPProtocol.ErrorCode.invalidParams)
    }

    func testCancellingAQueuedTaskPreventsItsWorkFromStarting() {
        let queue = DispatchQueue(label: "burrow.test.queued-mcp")
        queue.suspend()
        let store = MCPTaskStore(queue: queue)
        var executions = 0
        let record = store.start(label: "queued action", progressToken: nil) { _ in
            executions += 1
            return .success(["content": []])
        }
        XCTAssertTrue(store.cancel(record.taskId))
        queue.resume()
        queue.sync {}
        XCTAssertEqual(executions, 0, "a cancelled queued action must never start its engine command")
        XCTAssertEqual(store.get(record.taskId)?.status, MCPTaskStore.Status.cancelled)
    }

    func testProgressNotification_onlyWithAProgressToken() throws {
        let store = MCPTaskStore()
        var notes: [[String: Any]] = []
        let lock = NSLock()
        store.notify = { note in
            lock.lock(); notes.append(note); lock.unlock()
        }

        let silent = store.start(label: "quiet", progressToken: nil) { progress in
            progress("working")
            return .success([:])
        }
        let loud = store.start(label: "loud", progressToken: "tok-1") { progress in
            progress("working")
            return .success([:])
        }
        let done = expectation(description: "both finish")
        DispatchQueue.global().async {
            while store.get(silent.taskId)?.status == "working"
                    || store.get(loud.taskId)?.status == "working" { usleep(20_000) }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        lock.lock()
        let emitted = notes
        lock.unlock()
        XCTAssertEqual(emitted.count, 1, "progress is opt-in via progressToken")
        let params = try XCTUnwrap(emitted.first?["params"] as? [String: Any])
        XCTAssertEqual(params["progressToken"] as? String, "tok-1")
        XCTAssertEqual(emitted.first?["method"] as? String, "notifications/progress")
    }

    // MARK: - Resources and prompts

    func testResourceRead_returnsTheSameAnswerAsItsTool() throws {
        let viaResource = try result(call("resources/read", ["uri": "burrow://info"]))
        let contents = try XCTUnwrap(viaResource["contents"] as? [[String: Any]])
        let text = try XCTUnwrap(contents.first?["text"] as? String)
        XCTAssertTrue(text.contains("\"readers\""), "the resource must be the tool's payload")
        XCTAssertEqual(contents.first?["mimeType"] as? String, "application/json")
    }

    func testUnknownResource_is32602NotTheOldResourceCode() {
        // 2026-07-28 moved resource-not-found from -32002 to -32602.
        XCTAssertEqual(errorCode(call("resources/read", ["uri": "burrow://nope"])),
                       MCPProtocol.ErrorCode.invalidParams)
    }

    func testResourceTemplate_rejectsAJunkParameter() {
        XCTAssertEqual(errorCode(call("resources/read", ["uri": "burrow://history/abc"])),
                       MCPProtocol.ErrorCode.invalidParams)
        XCTAssertEqual(errorCode(call("resources/read", ["uri": "burrow://processes/nonsense"])),
                       MCPProtocol.ErrorCode.invalidParams)
    }

    func testPrompt_interpolatesItsArguments() throws {
        let r = try result(call("prompts/get", ["name": "investigate_process",
                                                "arguments": ["name": "Weird Helper"]]))
        let messages = try XCTUnwrap(r["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? [String: Any])
        let text = try XCTUnwrap(content["text"] as? String)
        XCTAssertTrue(text.contains("Weird Helper"))
        XCTAssertEqual(messages.first?["role"] as? String, "user")
    }

    func testPrompt_missingRequiredArgumentIsRejected() {
        XCTAssertEqual(errorCode(call("prompts/get", ["name": "investigate_process"])),
                       MCPProtocol.ErrorCode.invalidParams)
    }

    func testCompletion_offersTheRealMetricNames() throws {
        let r = try result(call("completion/complete", [
            "ref": ["type": "ref/resource", "uri": "burrow://processes/{metric}"],
            "argument": ["name": "metric", "value": "peak"],
        ]))
        let completion = try XCTUnwrap(r["completion"] as? [String: Any])
        let values = try XCTUnwrap(completion["values"] as? [String])
        XCTAssertEqual(values.sorted(), ["peak_cpu", "peak_mem"])
    }

    // MARK: - The property none of the above may break
    //
    // Everything new in this revision — MRTR round trips, task handles,
    // structured results — is a presentation change. None of it is allowed
    // to become a way to run a destructive action the user hasn't opted in
    // to. This runs against a scratch defaults suite, where both opt-ins are
    // off by construction, so it can assert the refusal without touching the
    // machine's real settings.

    func testConfirmTrue_withoutTheOptIn_isStillBlocked() throws {
        Store.d = UserDefaults(suiteName: StoreTests.scratchSuite)!
        Store.d.removePersistentDomain(forName: StoreTests.scratchSuite)
        XCTAssertFalse(Store.mcpActionsEnabled, "precondition: the opt-in is off")

        let r = try result(call("tools/call",
                                ["name": "burrow_clean", "arguments": ["confirm": true]]))
        let structured = try XCTUnwrap(r["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["blocked"] as? Bool, true)
        XCTAssertEqual(structured["ran"] as? Bool, false)
        XCTAssertNotNil(structured["reason"] as? String, "the refusal has to say why")
        XCTAssertEqual(r["isError"] as? Bool, true, "clients must see a tool failure when the action is blocked")
    }

    func testFailedToolPayloadsAreMarkedAsErrorsForSyncAndTaskResults() {
        for payload in [#"{"error":"engine unavailable"}"#, #"{"exit_code":1,"output":"denied"}"#,
                        #"{"ok":false,"error":{"message":"refused"}}"#, #"{"timed_out":true}"#] {
            let result = MCPServer.callToolBody(name: "burrow_evict", text: payload, isError: false)
            XCTAssertEqual(result["isError"] as? Bool, true, payload)
            XCTAssertNotNil(result["structuredContent"], "failure details must stay available")
        }
        let success = MCPServer.callToolBody(name: "burrow_evict", text: #"{"dry_run":true,"items":[]}"#,
                                            isError: false)
        XCTAssertNil(success["isError"])
    }

    func testMRTRAnswer_cannotUnlockAnUninstall() throws {
        Store.d = UserDefaults(suiteName: StoreTests.scratchSuite)!
        Store.d.removePersistentDomain(forName: StoreTests.scratchSuite)

        // The agent answers its own elicitation and passes confirm:true. The
        // Settings opt-in is the only thing that matters, and it is off.
        let state = MCPInputRequests.encodeState(tool: "burrow_uninstall",
                                                 arguments: ["confirm": true], asking: "apps")
        let r = try result(call("tools/call", [
            "name": "burrow_uninstall", "requestState": state,
            "inputResponses": ["apps": ["action": "accept", "content": ["apps": "Anything"]]],
        ], capabilities: Self.elicitCapability))
        let structured = try XCTUnwrap(r["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["ran"] as? Bool, false,
                       "no round trip may substitute for the user's opt-in")
    }
}
