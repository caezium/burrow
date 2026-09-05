//
//  MCPProtocol.swift
//  Burrow
//
//  The wire vocabulary of MCP's 2026-07-28 revision — the one that
//  retired the `initialize` handshake and made every request carry its
//  own context.
//
//  Two eras have to coexist here. A pre-2026 client negotiates once at
//  `initialize` and then sends bare requests; a 2026-07-28 client sends
//  no handshake at all and repeats its protocol version, capabilities,
//  and identity in `params._meta` on every single request. Burrow serves
//  both: `MCPRequestContext.parse` reads the per-request `_meta` when it
//  is there and falls back to whatever the legacy handshake negotiated
//  when it isn't.
//
//  Nothing in here talks to the DB or the engine — it is the envelope
//  layer only, which is what makes the conformance tests cheap.
//

import Foundation

enum MCPProtocol {
    /// The newest revision we speak, and what `server/discover` leads with.
    static let latest = "2026-07-28"

    /// Every revision we can serve, newest first. Old entries are kept
    /// deliberately: the spec's deprecation policy gives removed features a
    /// twelve-month window, and clients still probe downward.
    static let supported = [latest, "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    /// The revision that made the protocol stateless. Dates are ISO-8601, so
    /// lexicographic order is chronological order.
    static let statelessEra = "2026-07-28"

    static func isStatelessEra(_ version: String) -> Bool { version >= statelessEra }

    /// The version we assume for a client that never told us — a pre-2026
    /// client that skipped `initialize` entirely.
    static let legacyFallback = "2024-11-05"

    /// Reserved `_meta` keys. The `io.modelcontextprotocol/` prefix is
    /// reserved by the spec for protocol-level metadata.
    enum Meta {
        static let protocolVersion = "io.modelcontextprotocol/protocolVersion"
        static let clientCapabilities = "io.modelcontextprotocol/clientCapabilities"
        static let clientInfo = "io.modelcontextprotocol/clientInfo"
        static let logLevel = "io.modelcontextprotocol/logLevel"
        static let serverInfo = "io.modelcontextprotocol/serverInfo"
        static let relatedTask = "io.modelcontextprotocol/related-task"
        static let progressToken = "progressToken"
    }

    /// Extension identifiers we care about, in both directions.
    enum Extensions {
        static let tasks = "io.modelcontextprotocol/tasks"
    }

    /// JSON-RPC error codes. -32020…-32099 is the range the 2026-07-28
    /// revision reserved for the spec itself; the three below are the ones
    /// it defines. -32000…-32019 stays implementation-defined.
    enum ErrorCode {
        static let parse = -32700
        static let invalidRequest = -32600
        static let methodNotFound = -32601
        static let invalidParams = -32602
        static let internalError = -32603
        static let headerMismatch = -32020
        static let missingRequiredClientCapability = -32021
        static let unsupportedProtocolVersion = -32022
    }

    /// `resultType` discriminates an ordinary result from an interim one.
    enum ResultType {
        static let complete = "complete"
        static let inputRequired = "input_required"
        static let task = "task"
    }

    /// Cache hints. `ttlMs`/`cacheScope` are required on every list result
    /// in this revision, so the numbers are policy, not decoration.
    ///
    /// "public" is only correct for responses with no machine-specific data
    /// in them — the tool and prompt catalogues are identical for every
    /// install of a given build. Anything derived from this Mac is
    /// "private", and short-lived on top of that.
    enum Cache {
        /// Static catalogues: fixed for the lifetime of the binary.
        static let catalogTTL = 3_600_000
        /// The resource *list* is static; the resource *contents* are not.
        static let resourceListTTL = 300_000
        /// Live metric reads. Roughly one sampler tick — re-reading sooner
        /// than that just returns the same row.
        static let liveTTL = 5_000
        /// Reads that summarise a long window and move slowly.
        static let digestTTL = 60_000

        static let publicScope = "public"
        static let privateScope = "private"
    }

    /// Our own identity, echoed into every result's `_meta`.
    static func serverInfo(version: String) -> [String: Any] {
        return [
            "name": "burrow",
            "title": "Burrow",
            "version": version,
            "description": "Local Mac system telemetry, disk analysis, and gated cleanup.",
            "websiteUrl": "https://burrow.henryzh.dev",
        ]
    }

    /// Natural-language guidance handed to the model alongside the tool
    /// list. Kept to the things tool descriptions can't say — cross-tool
    /// ordering and the safety model.
    static let instructions = """
        Burrow reports on the Mac it is running on: system metrics sampled over time, \
        disk usage, listening ports, duplicate files, and the cleanup history of the \
        bundled engine.

        Ordering that matters: call burrow_doctor first when something is wrong — it \
        tells you whether the data is even flowing before you trust the rest. Use \
        burrow_process_usage (cumulative CPU-seconds) rather than burrow_top_processes \
        (a single peak sample) when the question is "what used my computer", and call \
        burrow_list_apps for the exact name burrow_uninstall accepts.

        Safety: every tool that can delete something is preview-by-default. Passing \
        confirm:true is necessary but never sufficient — the user must also have \
        switched the matching opt-in on in Burrow's Settings, and uninstall needs a \
        second one. A refusal comes back as a normal result explaining the missing \
        opt-in; that is the user's decision to change, not something to work around.
        """
}

// MARK: - Per-request context

/// What a 2026-07-28 request carries in `params._meta`, plus the shims that
/// let a legacy client work without it.
struct MCPRequestContext {
    let protocolVersion: String
    let clientCapabilities: [String: Any]
    let clientInfo: [String: Any]?
    let logLevel: String?
    let progressToken: Any?
    /// True when the request actually declared a version — as opposed to us
    /// falling back to the handshake. Lets the server tell the eras apart.
    let declaredVersion: Bool

    /// Extensions the client opted into, by identifier.
    var clientExtensions: [String: Any] {
        (self.clientCapabilities["extensions"] as? [String: Any]) ?? [:]
    }

    /// Never hand a task handle to a client that didn't ask for one — it
    /// would read as a malformed tool result.
    var supportsTasks: Bool {
        self.clientExtensions[MCPProtocol.Extensions.tasks] != nil
    }

    /// MRTR elicitation is only reachable when the client can render a form.
    var supportsElicitation: Bool {
        guard let e = self.clientCapabilities["elicitation"] as? [String: Any] else { return false }
        // An empty object still means "supported"; `form` is the mode we use.
        return e.isEmpty || e["form"] != nil
    }

    var isStatelessEra: Bool { MCPProtocol.isStatelessEra(self.protocolVersion) }

    /// Read the context out of a request's params. `fallbackVersion` is what
    /// the legacy `initialize` handshake settled on for this connection.
    static func parse(params: [String: Any], fallbackVersion: String) -> MCPRequestContext {
        let meta = (params["_meta"] as? [String: Any]) ?? [:]
        let declared = meta[MCPProtocol.Meta.protocolVersion] as? String
        return MCPRequestContext(
            protocolVersion: declared ?? fallbackVersion,
            clientCapabilities: (meta[MCPProtocol.Meta.clientCapabilities] as? [String: Any]) ?? [:],
            clientInfo: meta[MCPProtocol.Meta.clientInfo] as? [String: Any],
            logLevel: meta[MCPProtocol.Meta.logLevel] as? String,
            progressToken: meta[MCPProtocol.Meta.progressToken],
            declaredVersion: declared != nil)
    }

    /// A context for code paths with no request behind them (tests, the
    /// legacy handshake itself).
    static func legacy(version: String = MCPProtocol.legacyFallback) -> MCPRequestContext {
        MCPRequestContext(protocolVersion: version, clientCapabilities: [:], clientInfo: nil,
                          logLevel: nil, progressToken: nil, declaredVersion: false)
    }
}

// MARK: - Result envelopes

/// Builders for the fields the revision made mandatory. Every result the
/// server emits goes through one of these, so `resultType` and the server
/// identity can't be forgotten on a new method.
enum MCPResult {
    /// Tools return their execution failures as structured JSON. Preserve
    /// those details while exposing the same outcome to clients and audit.
    static func reportsToolFailure(_ text: String) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            return false // Markdown and other successful text results.
        }
        if let error = object["error"], !(error is NSNull) { return true }
        if JSONScalar.boolean(object["ok"]) == false
            || JSONScalar.boolean(object["blocked"]) == true
            || JSONScalar.boolean(object["timed_out"]) == true { return true }
        return (object["exit_code"] as? Int).map { $0 != 0 } ?? false
    }

    /// An ordinary, finished result.
    static func complete(_ body: [String: Any], serverVersion: String) -> [String: Any] {
        var out = body
        out["resultType"] = MCPProtocol.ResultType.complete
        return Self.stamped(out, serverVersion: serverVersion)
    }

    /// A finished result that clients are allowed to cache.
    static func cacheable(_ body: [String: Any], ttlMs: Int, scope: String,
                          serverVersion: String) -> [String: Any] {
        var out = body
        out["ttlMs"] = ttlMs
        out["cacheScope"] = scope
        return Self.complete(out, serverVersion: serverVersion)
    }

    /// An interim result: the server needs something before it can finish.
    static func inputRequired(inputRequests: [String: Any], requestState: String,
                              serverVersion: String) -> [String: Any] {
        var out: [String: Any] = [
            "resultType": MCPProtocol.ResultType.inputRequired,
            "inputRequests": inputRequests,
            "requestState": requestState,
        ]
        out = Self.stamped(out, serverVersion: serverVersion)
        return out
    }

    /// Attach `io.modelcontextprotocol/serverInfo` without clobbering any
    /// `_meta` the caller already built.
    static func stamped(_ body: [String: Any], serverVersion: String) -> [String: Any] {
        var out = body
        var meta = (out["_meta"] as? [String: Any]) ?? [:]
        meta[MCPProtocol.Meta.serverInfo] = MCPProtocol.serverInfo(version: serverVersion)
        out["_meta"] = meta
        return out
    }
}
