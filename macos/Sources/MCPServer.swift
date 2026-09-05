//
//  MCPServer.swift
//  Burrow
//
//  JSON-RPC routing for the MCP server: one method per spec method, and
//  the two-era handling that keeps a 2024-11-05 client working next to a
//  2026-07-28 one.
//
//  The whole surface is reachable through `response(toLine:)`, which takes
//  bytes and returns a dictionary (or nil for a notification). No
//  FileHandles are involved, which is what makes the conformance tests
//  cheap to write — `serve(input:output:)` is only framing on top of it.
//
//  Two rules run through everything here:
//
//    * Never hand a client a shape it didn't ask for. Task handles need the
//      tasks extension in the request's `_meta`; MRTR elicitations need the
//      elicitation capability. Without those, the same call behaves exactly
//      as it did before this revision existed.
//
//    * MRTR is not a consent mechanism. It fills in arguments the server
//      cannot invent. The destructive tools stay gated by `MoActions.decide`
//      and the user's Settings opt-ins, which no round trip can satisfy.
//

import Foundation

final class MCPServer {
    private let db: DB
    private let catalog: ToolCatalog
    private let resources: MCPResources
    private let tasks: MCPTaskStore
    private let serverVersion: String

    /// What a pre-2026 client settled on at `initialize`. The stateless era
    /// repeats its version on every request and never reads this; it exists
    /// for the era that physically can't.
    private var legacyVersion = MCPProtocol.legacyFallback

    /// Guards the output stream. Task progress notifications are emitted
    /// from the task queue, so writes are no longer single-threaded.
    private let writeLock = NSLock()
    private var out: FileHandle?

    init(db: DB, serverVersion: String = RuntimeEnvironment.current.appVersion) {
        let catalog = ToolCatalog(db: db)
        self.db = db
        self.catalog = catalog
        self.resources = MCPResources(catalog: catalog, db: db)
        self.tasks = MCPTaskStore()
        self.serverVersion = serverVersion
        self.tasks.notify = { [weak self] note in self?.write(note) }
    }

    // MARK: - Framing

    /// Drive the loop. Reads line by line from `input`; one JSON-RPC
    /// message per line is the de-facto standard for stdio MCP. Exits
    /// cleanly on EOF.
    func serve(input: FileHandle, output: FileHandle) {
        self.writeLock.lock()
        self.out = output
        self.writeLock.unlock()

        var buffer = Data()
        while true {
            let chunk = input.availableData
            if chunk.isEmpty { break }   // EOF — peer closed
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                if line.isEmpty { continue }
                if let response = self.response(toLine: line) {
                    self.write(response)
                }
            }
        }
    }

    private func write(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.withoutEscapingSlashes]) else {
            return
        }
        data.append(0x0A)
        self.writeLock.lock()
        defer { self.writeLock.unlock() }
        try? self.out?.write(contentsOf: data)
    }

    // MARK: - Routing

    /// The whole JSON-RPC envelope decision for one input line — nil means
    /// "send nothing" (notifications).
    func response(toLine data: Data) -> [String: Any]? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return MCPServer.errorResponse(id: nil, code: MCPProtocol.ErrorCode.parse,
                                           message: "parse error")
        }
        let method = (raw["method"] as? String) ?? ""
        let id = raw["id"]
        let params = (raw["params"] as? [String: Any]) ?? [:]

        // Notifications have no id. Answering one — even with an error —
        // would be malformed JSON-RPC.
        guard id != nil else {
            self.handleNotification(method: method, params: params)
            return nil
        }

        let ctx = MCPRequestContext.parse(params: params, fallbackVersion: self.legacyVersion)
        // The version gate only bites once a client has actually declared a
        // version. `initialize` negotiates in its own params, below.
        if ctx.declaredVersion, !MCPProtocol.supported.contains(ctx.protocolVersion) {
            return self.unsupportedVersion(id: id, requested: ctx.protocolVersion)
        }

        switch method {
        case "server/discover":
            return self.discover(id: id)
        case "initialize":
            return self.initializeResponse(id: id, params: params)
        // `ping` and `logging/setLevel` were removed in this revision, but a
        // pre-2026 client still sends them and an error would look like a
        // broken server. Answer empty and move on.
        case "ping", "logging/setLevel":
            return self.ok(id: id, [:])
        case "tools/list":
            return self.toolsList(id: id)
        case "tools/call":
            return self.toolsCall(id: id, params: params, ctx: ctx)
        case "resources/list":
            return self.resourcesList(id: id)
        case "resources/templates/list":
            return self.resourceTemplatesList(id: id)
        case "resources/read":
            return self.resourcesRead(id: id, params: params)
        case "prompts/list":
            return self.promptsList(id: id)
        case "prompts/get":
            return self.promptsGet(id: id, params: params)
        case "completion/complete":
            return self.completionComplete(id: id, params: params)
        case "tasks/get":
            return self.tasksGet(id: id, params: params)
        case "tasks/update":
            return self.tasksUpdate(id: id, params: params)
        case "tasks/cancel":
            return self.tasksCancel(id: id, params: params)
        default:
            return MCPServer.errorResponse(id: id, code: MCPProtocol.ErrorCode.methodNotFound,
                                           message: "method not found: \(method)")
        }
    }

    /// Notifications are fire-and-forget. `notifications/cancelled` targets a
    /// JSON-RPC request id; our long work is addressed by task id instead, so
    /// there is nothing to cancel here — a client that wants to stop a task
    /// sends `tasks/cancel`.
    private func handleNotification(method: String, params: [String: Any]) {
        // Deliberately empty. Listed here so the silence is a decision.
        _ = method
        _ = params
    }

    // MARK: - Result helpers

    private func ok(id: Any?, _ body: [String: Any]) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id as Any,
            "result": MCPResult.complete(body, serverVersion: self.serverVersion),
        ]
    }

    private func okCacheable(id: Any?, _ body: [String: Any], ttlMs: Int, scope: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id as Any,
            "result": MCPResult.cacheable(body, ttlMs: ttlMs, scope: scope,
                                          serverVersion: self.serverVersion),
        ]
    }

    private func unsupportedVersion(id: Any?, requested: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id as Any,
            "error": [
                "code": MCPProtocol.ErrorCode.unsupportedProtocolVersion,
                "message": "unsupported protocol version: \(requested)",
                "data": ["requested": requested, "supported": MCPProtocol.supported],
            ] as [String: Any],
        ]
    }

    static func errorResponse(id: Any?, code: Int, message: String) -> [String: Any] {
        return [
            "jsonrpc": "2.0",
            "id": id as Any,
            "error": ["code": code, "message": message],
        ]
    }

    // MARK: - Discovery and handshake

    /// What we can do, in the shape both eras read it.
    private func capabilities() -> [String: Any] {
        return [
            "tools": ["listChanged": false],
            "resources": ["listChanged": false, "subscribe": false],
            "prompts": ["listChanged": false],
            "completions": [String: Any](),
            "extensions": [MCPProtocol.Extensions.tasks: [String: Any]()],
        ]
    }

    /// `server/discover` — mandatory in 2026-07-28, and the probe a stdio
    /// client uses to work out which era it's talking to.
    private func discover(id: Any?) -> [String: Any] {
        let body: [String: Any] = [
            "supportedVersions": MCPProtocol.supported,
            "capabilities": self.capabilities(),
            "instructions": MCPProtocol.instructions,
        ]
        return self.okCacheable(id: id, body,
                                ttlMs: MCPProtocol.Cache.catalogTTL,
                                scope: MCPProtocol.Cache.publicScope)
    }

    /// The legacy handshake. Still answered because the deprecation window
    /// runs for a year and clients probe downward.
    private func initializeResponse(id: Any?, params: [String: Any]) -> [String: Any] {
        let requested = params["protocolVersion"] as? String
        let negotiated = requested.flatMap { MCPProtocol.supported.contains($0) ? $0 : nil }
            ?? MCPProtocol.latest
        self.legacyVersion = negotiated
        let body: [String: Any] = [
            "protocolVersion": negotiated,
            "capabilities": self.capabilities(),
            "serverInfo": MCPProtocol.serverInfo(version: self.serverVersion),
            "instructions": MCPProtocol.instructions,
        ]
        return self.ok(id: id, body)
    }

    // MARK: - Tools

    private func toolsList(id: Any?) -> [String: Any] {
        let tools = MCPToolMetadata.decorate(self.catalog.descriptors())
        // The catalogue is fixed for the lifetime of the binary and carries
        // nothing machine-specific, so it is both long-lived and shareable.
        return self.okCacheable(id: id, ["tools": tools],
                                ttlMs: MCPProtocol.Cache.catalogTTL,
                                scope: MCPProtocol.Cache.publicScope)
    }

    private func toolsCall(id: Any?, params: [String: Any], ctx: MCPRequestContext) -> [String: Any] {
        var name = params["name"] as? String ?? ""
        var arguments = (params["arguments"] as? [String: Any]) ?? [:]

        if let responses = params["inputResponses"] as? [String: Any] {
            // MRTR retry: the client is answering what we asked for.
            guard let state = MCPInputRequests.decodeState(params["requestState"] as? String) else {
                return MCPServer.errorResponse(
                    id: id, code: MCPProtocol.ErrorCode.invalidParams,
                    message: "inputResponses arrived without a requestState this server issued")
            }
            name = state.tool
            switch MCPInputRequests.resolve(state: state, inputResponses: responses) {
            case .proceed(let merged):
                arguments = merged
            case .declined(let why):
                // A decline is an outcome, not a fault — report it in-band so
                // the model can see it and pick something else.
                return self.toolResult(id: id, name: name, isError: false,
                                       text: MCPServer.jsonObject(["declined": true, "reason": why]))
            case .unusable(let why):
                return MCPServer.errorResponse(id: id, code: MCPProtocol.ErrorCode.invalidParams,
                                               message: why)
            }
        } else if let missing = MCPInputRequests.missingArgument(tool: name, arguments: arguments),
                  ctx.supportsElicitation {
            // Ask instead of erroring — but only when the client can ask a
            // human. Without the capability this falls through and the tool
            // returns its usual argument error.
            return [
                "jsonrpc": "2.0",
                "id": id as Any,
                "result": MCPResult.inputRequired(
                    inputRequests: MCPInputRequests.elicitation(for: missing),
                    requestState: MCPInputRequests.encodeState(tool: name, arguments: arguments,
                                                               asking: missing.key),
                    serverVersion: self.serverVersion),
            ]
        }

        if MCPToolMetadata.longRunning.contains(name), ctx.supportsTasks {
            return self.startTask(id: id, name: name, arguments: arguments, ctx: ctx)
        }

        return self.runToolSynchronously(id: id, name: name, arguments: arguments)
    }

    private func runToolSynchronously(id: Any?, name: String, arguments: [String: Any]) -> [String: Any] {
        do {
            let text = try self.catalog.call(name: name, arguments: arguments)
            return self.toolResult(id: id, name: name, isError: false, text: text)
        } catch let MCPToolError.unknown(toolName) {
            return MCPServer.errorResponse(id: id, code: MCPProtocol.ErrorCode.invalidParams,
                                           message: "unknown tool: \(toolName)")
        } catch let MCPToolError.badArguments(reason) {
            return MCPServer.errorResponse(id: id, code: MCPProtocol.ErrorCode.invalidParams,
                                           message: "bad arguments: \(reason)")
        } catch {
            return MCPServer.errorResponse(id: id, code: MCPProtocol.ErrorCode.internalError,
                                           message: "internal error: \(error.localizedDescription)")
        }
    }

    private func toolResult(id: Any?, name: String, isError: Bool, text: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id as Any,
            "result": MCPResult.complete(MCPServer.callToolBody(name: name, text: text, isError: isError),
                                         serverVersion: self.serverVersion),
        ]
    }

    /// The `CallToolResult` body. `structuredContent` is attached only where
    /// we declared an `outputSchema` and the payload really is a JSON object
    /// — `burrow_report` returns Markdown, and promising structure for it
    /// would be a lie the schema can't back up.
    static func callToolBody(name: String, text: String, isError: Bool) -> [String: Any] {
        var body: [String: Any] = ["content": [["type": "text", "text": text]]]
        if isError || MCPResult.reportsToolFailure(text) { body["isError"] = true }
        guard MCPToolMetadata.table[name]?.outputSchema != nil,
              let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return body
        }
        body["structuredContent"] = obj
        return body
    }

    // MARK: - Tasks

    /// Hand back a task handle and run the work behind it. Only reached when
    /// the client declared `io.modelcontextprotocol/tasks` on this request.
    private func startTask(id: Any?, name: String, arguments: [String: Any],
                           ctx: MCPRequestContext) -> [String: Any] {
        let catalog = self.catalog
        let record = self.tasks.start(label: name, progressToken: ctx.progressToken) { progress in
            progress("running \(name)")
            do {
                let text = try catalog.call(name: name, arguments: arguments)
                return .success(MCPServer.callToolBody(name: name, text: text, isError: false))
            } catch let MCPToolError.badArguments(reason) {
                return .failure(.invalidParams("bad arguments: \(reason)"))
            } catch let MCPToolError.unknown(toolName) {
                return .failure(.invalidParams("unknown tool: \(toolName)"))
            } catch {
                return .failure(.internalError(error.localizedDescription))
            }
        }
        var body = MCPTaskStore.wire(record)
        // A task handle is its own result type — not `complete`, because
        // nothing has completed yet.
        body["resultType"] = MCPProtocol.ResultType.task
        return [
            "jsonrpc": "2.0",
            "id": id as Any,
            "result": MCPResult.stamped(body, serverVersion: self.serverVersion),
        ]
    }

    private func tasksGet(id: Any?, params: [String: Any]) -> [String: Any] {
        guard let taskId = params["taskId"] as? String, !taskId.isEmpty else {
            return MCPServer.errorResponse(id: id, code: MCPProtocol.ErrorCode.invalidParams,
                                           message: "tasks/get needs a taskId")
        }
        guard let record = self.tasks.get(taskId) else {
            return MCPServer.errorResponse(id: id, code: MCPProtocol.ErrorCode.invalidParams,
                                           message: "unknown or expired task: \(taskId)")
        }
        var body = MCPTaskStore.wire(record)
        body["resultType"] = MCPProtocol.ResultType.task
        return [
            "jsonrpc": "2.0",
            "id": id as Any,
            "result": MCPResult.stamped(body, serverVersion: self.serverVersion),
        ]
    }

    private func tasksUpdate(id: Any?, params: [String: Any]) -> [String: Any] {
        guard let taskId = params["taskId"] as? String, !taskId.isEmpty else {
            return MCPServer.errorResponse(id: id, code: MCPProtocol.ErrorCode.invalidParams,
                                           message: "tasks/update needs a taskId")
        }
        let responses = (params["inputResponses"] as? [String: Any]) ?? [:]
        guard self.tasks.update(taskId, inputResponses: responses) else {
            return MCPServer.errorResponse(id: id, code: MCPProtocol.ErrorCode.invalidParams,
                                           message: "unknown or expired task: \(taskId)")
        }
        return self.ok(id: id, [:])
    }

    private func tasksCancel(id: Any?, params: [String: Any]) -> [String: Any] {
        guard let taskId = params["taskId"] as? String, !taskId.isEmpty else {
            return MCPServer.errorResponse(id: id, code: MCPProtocol.ErrorCode.invalidParams,
                                           message: "tasks/cancel needs a taskId")
        }
        guard self.tasks.cancel(taskId) else {
            return MCPServer.errorResponse(id: id, code: MCPProtocol.ErrorCode.invalidParams,
                                           message: "unknown or expired task: \(taskId)")
        }
        return self.ok(id: id, [:])
    }

    // MARK: - Resources

    private func resourcesList(id: Any?) -> [String: Any] {
        // The list of resources is static; their contents are not, which is
        // why the TTL here is nothing like the TTL on a read.
        self.okCacheable(id: id, ["resources": MCPResources.listing()],
                         ttlMs: MCPProtocol.Cache.resourceListTTL,
                         scope: MCPProtocol.Cache.publicScope)
    }

    private func resourceTemplatesList(id: Any?) -> [String: Any] {
        self.okCacheable(id: id, ["resourceTemplates": MCPResources.templates],
                         ttlMs: MCPProtocol.Cache.catalogTTL,
                         scope: MCPProtocol.Cache.publicScope)
    }

    private func resourcesRead(id: Any?, params: [String: Any]) -> [String: Any] {
        guard let uri = params["uri"] as? String, !uri.isEmpty else {
            return MCPServer.errorResponse(id: id, code: MCPProtocol.ErrorCode.invalidParams,
                                           message: "resources/read needs a uri")
        }
        do {
            let contents = try self.resources.read(uri: uri)
            let body: [String: Any] = [
                "contents": [[
                    "uri": uri,
                    "mimeType": contents.mimeType,
                    "text": contents.text,
                ]],
            ]
            // Everything readable here describes this Mac, so it is private
            // to this authorization context no matter how short-lived it is.
            return self.okCacheable(id: id, body, ttlMs: contents.ttlMs,
                                    scope: MCPProtocol.Cache.privateScope)
        } catch let MCPResources.ReadError.notFound(message) {
            // -32602, not -32002: this revision realigned resource-not-found
            // with JSON-RPC's Invalid Params.
            return MCPServer.errorResponse(id: id, code: MCPProtocol.ErrorCode.invalidParams,
                                           message: message)
        } catch {
            return MCPServer.errorResponse(id: id, code: MCPProtocol.ErrorCode.internalError,
                                           message: error.localizedDescription)
        }
    }

    // MARK: - Prompts

    private func promptsList(id: Any?) -> [String: Any] {
        self.okCacheable(id: id, ["prompts": MCPResources.prompts],
                         ttlMs: MCPProtocol.Cache.catalogTTL,
                         scope: MCPProtocol.Cache.publicScope)
    }

    private func promptsGet(id: Any?, params: [String: Any]) -> [String: Any] {
        guard let name = params["name"] as? String, !name.isEmpty else {
            return MCPServer.errorResponse(id: id, code: MCPProtocol.ErrorCode.invalidParams,
                                           message: "prompts/get needs a name")
        }
        let arguments = (params["arguments"] as? [String: Any]) ?? [:]
        guard let rendered = MCPResources.prompt(name: name, arguments: arguments) else {
            return MCPServer.errorResponse(id: id, code: MCPProtocol.ErrorCode.invalidParams,
                                           message: "unknown prompt, or a required argument is missing: \(name)")
        }
        return self.ok(id: id, rendered)
    }

    private func completionComplete(id: Any?, params: [String: Any]) -> [String: Any] {
        guard let ref = params["ref"] as? [String: Any],
              let argument = params["argument"] as? [String: Any],
              let argName = argument["name"] as? String else {
            return MCPServer.errorResponse(id: id, code: MCPProtocol.ErrorCode.invalidParams,
                                           message: "completion/complete needs `ref` and `argument`")
        }
        let value = argument["value"] as? String ?? ""
        return self.ok(id: id, self.resources.complete(ref: ref, argumentName: argName, value: value))
    }

    // MARK: - Small helpers

    static func jsonObject(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj,
                                                     options: [.withoutEscapingSlashes]),
              let s = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"encode failed\"}"
        }
        return s
    }
}
