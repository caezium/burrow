//
//  MCPTasks.swift
//  Burrow
//
//  The `io.modelcontextprotocol/tasks` extension.
//
//  Why Burrow needs it: `mo clean` on a full disk, or `mo analyze` on a
//  home folder, routinely runs past the point where a client is willing to
//  wait. Today those calls block the agent and then come back as
//  `timed_out: true`, which a model reads as "there was nothing to clean"
//  rather than "we gave up". A task handle turns that into a poll: the work
//  keeps running, `tasks/get` reports how long it has been going, and the
//  real result arrives whenever it arrives.
//
//  Opt-in is strictly two-sided. We advertise the extension in
//  `server/discover`, but a task handle is only ever returned to a client
//  that declared the same extension in that request's `_meta` — to anyone
//  else the call stays synchronous and behaves exactly as it did before.
//
//  Cancellation is cooperative and we are honest about the limit: the work
//  is a blocking engine subprocess with its own timeout, so `tasks/cancel`
//  records the intent and stops us reporting the result, but it does not
//  reach into `mo` and stop it mid-delete.
//

import Foundation

/// One asynchronous unit of work, as the client sees it.
final class MCPTaskStore {
    struct Record {
        var taskId: String
        var status: String
        var statusMessage: String?
        var createdAt: Date
        var lastUpdatedAt: Date
        var ttlMs: Int
        var pollIntervalMs: Int
        /// Set on `completed` — the result the synchronous call would have returned.
        var result: [String: Any]?
        /// Set on `failed` — a JSON-RPC error object.
        var error: [String: Any]?
        /// Outstanding MRTR requests when the task is `input_required`.
        var inputRequests: [String: Any]?
        /// Set once the client asked us to stop.
        var cancelRequested: Bool
    }

    enum Status {
        static let working = "working"
        static let inputRequired = "input_required"
        static let completed = "completed"
        static let failed = "failed"
        static let cancelled = "cancelled"

        static let terminal: Set<String> = [completed, failed, cancelled]
    }

    /// How long a finished task stays readable. Long enough that a client
    /// which dropped its connection can come back for the answer.
    static let defaultTTLMs = 600_000
    static let defaultPollIntervalMs = 1_000

    private var records: [String: Record] = [:]
    private let lock = NSLock()
    private let queue: DispatchQueue
    private var counter = 0

    /// Where progress notifications go. The stdio writer installs this; in
    /// tests it collects into an array.
    var notify: (([String: Any]) -> Void)?

    /// Serial on purpose. The work these tasks wrap is disk-bound engine
    /// scans; running two at once would thrash the disk and make both
    /// slower, and a queued task still reports `working` to the client
    /// instead of blocking it. The DB underneath is FULLMUTEX so
    /// concurrency would be *safe* — it just wouldn't be faster.
    init(queue: DispatchQueue = DispatchQueue(label: "dev.caezium.Burrow.mcp.tasks",
                                              qos: .utility)) {
        self.queue = queue
    }

    // MARK: - Creating and running

    /// Start `work` in the background and hand back the initial task record.
    /// `work` runs off the stdio reader thread, so it must not touch the
    /// output stream directly — progress goes through `notify`.
    @discardableResult
    func start(label: String, progressToken: Any?,
               work: @escaping (_ progress: @escaping (String) -> Void) -> Result<[String: Any], MCPTaskFailure>) -> Record {
        let now = Date()
        self.lock.lock()
        self.counter += 1
        let taskId = "burrow-task-\(self.counter)-\(UUID().uuidString.prefix(8))"
        let record = Record(taskId: taskId, status: Status.working,
                            statusMessage: "\(label) started",
                            createdAt: now, lastUpdatedAt: now,
                            ttlMs: Self.defaultTTLMs,
                            pollIntervalMs: Self.defaultPollIntervalMs,
                            result: nil, error: nil, inputRequests: nil,
                            cancelRequested: false)
        self.records[taskId] = record
        self.lock.unlock()

        self.queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let shouldRun = self.records[taskId].map { !$0.cancelRequested && !Status.terminal.contains($0.status) } ?? false
            self.lock.unlock()
            guard shouldRun else { return }
            let started = Date()
            let progress: (String) -> Void = { [weak self] message in
                guard let self else { return }
                let elapsed = Int(Date().timeIntervalSince(started))
                self.setStatusMessage(taskId, "\(message) (\(elapsed)s elapsed)")
                self.emitProgress(token: progressToken, taskId: taskId,
                                  elapsed: elapsed, message: message)
            }
            let outcome = work(progress)
            self.finish(taskId, outcome: outcome)
        }
        return record
    }

    private func finish(_ taskId: String, outcome: Result<[String: Any], MCPTaskFailure>) {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard var rec = self.records[taskId] else { return }
        // A cancelled task keeps its cancelled status: the client already
        // stopped caring, and reporting a fresh result would contradict the
        // terminal state it was told about.
        if rec.status == Status.cancelled { return }
        rec.lastUpdatedAt = Date()
        switch outcome {
        case .success(let value):
            rec.status = Status.completed
            rec.result = value
            rec.statusMessage = "finished"
        case .failure(let failure):
            rec.status = Status.failed
            rec.error = ["code": failure.code, "message": failure.message]
            rec.statusMessage = failure.message
        }
        self.records[taskId] = rec
    }

    private func setStatusMessage(_ taskId: String, _ message: String) {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard var rec = self.records[taskId], !Status.terminal.contains(rec.status) else { return }
        rec.statusMessage = message
        rec.lastUpdatedAt = Date()
        self.records[taskId] = rec
    }

    /// `notifications/progress`, but only when the client actually asked for
    /// it. The spec makes progress opt-in via `progressToken`; without one
    /// we stay quiet and let the client poll.
    private func emitProgress(token: Any?, taskId: String, elapsed: Int, message: String) {
        guard let token, let notify = self.notify else { return }
        notify([
            "jsonrpc": "2.0",
            "method": "notifications/progress",
            "params": [
                "progressToken": token,
                "progress": elapsed,
                "message": message,
                "_meta": [MCPProtocol.Meta.relatedTask: ["taskId": taskId]],
            ] as [String: Any],
        ])
    }

    // MARK: - Reading

    func get(_ taskId: String) -> Record? {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.sweepExpiredLocked()
        return self.records[taskId]
    }

    /// Cooperative cancel. Returns false when the id is unknown.
    @discardableResult
    func cancel(_ taskId: String) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard var rec = self.records[taskId] else { return false }
        guard !Status.terminal.contains(rec.status) else { return true }
        rec.cancelRequested = true
        rec.status = Status.cancelled
        rec.statusMessage = "cancellation requested — the engine subprocess may still be finishing"
        rec.lastUpdatedAt = Date()
        self.records[taskId] = rec
        return true
    }

    /// `tasks/update`. Responses for unknown or already-satisfied keys are
    /// ignored per the extension, so this only ever acknowledges.
    @discardableResult
    func update(_ taskId: String, inputResponses: [String: Any]) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard var rec = self.records[taskId] else { return false }
        guard rec.status == Status.inputRequired else { return true }
        var outstanding = rec.inputRequests ?? [:]
        for key in inputResponses.keys { outstanding.removeValue(forKey: key) }
        rec.inputRequests = outstanding.isEmpty ? nil : outstanding
        if outstanding.isEmpty { rec.status = Status.working }
        rec.lastUpdatedAt = Date()
        self.records[taskId] = rec
        return true
    }

    /// Drop terminal tasks whose TTL has run out. Called on read, which is
    /// enough for a process that only lives as long as a conversation.
    private func sweepExpiredLocked() {
        let now = Date()
        self.records = self.records.filter { _, rec in
            guard Status.terminal.contains(rec.status) else { return true }
            return now.timeIntervalSince(rec.lastUpdatedAt) * 1000 < Double(rec.ttlMs)
        }
    }

    var count: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.records.count
    }

    // MARK: - Wire shapes

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// The `Task` object the extension defines. `result`/`error` only appear
    /// on the terminal states that carry them.
    static func wire(_ rec: Record) -> [String: Any] {
        var out: [String: Any] = [
            "taskId": rec.taskId,
            "status": rec.status,
            "createdAt": Self.isoFormatter.string(from: rec.createdAt),
            "lastUpdatedAt": Self.isoFormatter.string(from: rec.lastUpdatedAt),
            "ttlMs": rec.ttlMs,
            "pollIntervalMs": rec.pollIntervalMs,
        ]
        if let m = rec.statusMessage { out["statusMessage"] = m }
        if rec.status == Status.completed, let r = rec.result { out["result"] = r }
        if rec.status == Status.failed, let e = rec.error { out["error"] = e }
        if rec.status == Status.inputRequired, let r = rec.inputRequests { out["inputRequests"] = r }
        return out
    }
}

/// A task that ended badly, in the shape `FailedTask.error` wants.
struct MCPTaskFailure: Error {
    let code: Int
    let message: String

    static func invalidParams(_ message: String) -> MCPTaskFailure {
        MCPTaskFailure(code: MCPProtocol.ErrorCode.invalidParams, message: message)
    }

    static func internalError(_ message: String) -> MCPTaskFailure {
        MCPTaskFailure(code: MCPProtocol.ErrorCode.internalError, message: message)
    }
}
