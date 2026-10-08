//
//  DB.swift
//  Burrow
//
//  SQLite-backed history store. Single table `samples(prefix, ts, json)`
//  with composite primary key. Two indices: the PK covers
//  prefix-then-ts range queries (the common case for chart rendering),
//  and a separate `idx_ts` covers cross-prefix TTL prunes.
//
//  Schema mirrors what the Stats fork did with leveldb (`<prefix>@<ts>`
//  keys) but in a row-shaped table the planner can reason about.
//  Stride-sampled chart queries become a single SQL with a window
//  function — see `findTimeSeriesSampled` — instead of the seek-stride
//  iterator Stats had to hand-roll over leveldb's bytes.
//
//  Concurrency model: serial dispatch queue serialises all writes;
//  SQLite's WAL mode lets readers run in parallel without blocking on
//  the writer. The QueryServer reads through a per-thread connection
//  (cheap) so HTTP requests don't queue behind the sampler.
//

import Foundation
import SQLite3

/// SQLite's "transient destructor" sentinel. We pass it to `sqlite3_bind_*`
/// so SQLite makes its own copy of bound strings/blobs — required because
/// the Swift String we pass goes out of scope before the statement runs.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum DBError: Error, LocalizedError {
    // open/step carry the SQLite result code so recovery can tell lock
    // contention (transient, propagate) from corruption (quarantine).
    case open(Int32, String)
    case prepare(String)
    case step(Int32, String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .open(let c, let m): return "DB open failed (\(c)): \(m)"
        case .prepare(let m): return "DB prepare failed: \(m)"
        case .step(let c, let m): return "DB step failed (\(c)): \(m)"
        case .unsupported(let m): return "DB unsupported: \(m)"
        }
    }
}

final class DB {
    private var handle: OpaquePointer?
    private let writeQueue = DispatchQueue(label: "dev.caezium.burrow.db.write")

    /// Opens (or creates) the default DB at
    /// `~/Library/Application Support/Burrow/burrow.db`. Application
    /// Support is created on demand because the directory may not exist
    /// on a fresh install.
    static func openDefault() throws -> DB {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
            .appendingPathComponent("Burrow", isDirectory: true)
        try FileManager.default.createDirectory(at: support,
                                                withIntermediateDirectories: true)
        return try DB(at: support.appendingPathComponent("burrow.db"))
    }

    /// The launch-time open. Lock contention is not damage (see `init(at:)`),
    /// and surfacing the first SQLITE_BUSY quits the app over a lock another
    /// Burrow process releases moments later, so wait it out a few times
    /// first. Can block for seconds: call it off the main thread.
    static func openDefaultWaitingOutContention() throws -> DB {
        try retryingLockContention(attempts: 5, delay: 0.5) { try openDefault() }
    }

    /// Runs `body`, retrying only SQLITE_BUSY / SQLITE_LOCKED failures, up to
    /// `attempts` tries in all. Any other error, and the last contention
    /// error, propagate.
    static func retryingLockContention<T>(
        attempts: Int,
        delay: TimeInterval,
        sleep: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:),
        _ body: () throws -> T
    ) throws -> T {
        var attempt = 1
        while true {
            do {
                return try body()
            } catch where attempt < attempts && isLockContention(error) {
                attempt += 1
                sleep(delay)
            }
        }
    }

    /// Reader-process open of the default DB — what `burrow --mcp` uses.
    /// Same file, same WAL connection, but NO recovery ladder (see
    /// `init(readerAt:)`).
    static func openDefaultReader() throws -> DB {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
            .appendingPathComponent("Burrow", isDirectory: true)
        try FileManager.default.createDirectory(at: support,
                                                withIntermediateDirectories: true)
        return try DB(readerAt: support.appendingPathComponent("burrow.db"))
    }

    /// Test-friendly initialiser. Pass a temp path from `XCTestCase.setUp`.
    ///
    /// A damaged or non-writable history file must never brick launch
    /// (issue #5: "attempt to write a readonly database"). So opening is
    /// staged from least to most destructive:
    ///
    ///   1. Open + prepare as-is. The happy path.
    ///   2. On failure, try non-destructive repairs that PRESERVE history:
    ///      drop the regenerable WAL/SHM sidecars (a stale or root-owned
    ///      `-wal` is a classic readonly cause) and restore user write
    ///      permission on our own file, then retry.
    ///   3. Still unusable (corrupt, not-a-database, or unwritable file):
    ///      quarantine it aside and recreate fresh.
    ///
    /// If even step 3 throws — e.g. the directory itself is read-only —
    /// the error propagates to the caller, which surfaces it.
    init(at url: URL) throws {
        do {
            try self.open(at: url)
        } catch {
            // Lock contention is NOT damage. A concurrent Burrow process
            // (the GUI vs `Burrow --mcp`) holds this file mid-write by
            // design; deleting its live -wal or quarantining the healthy
            // file IS the data-loss path. Propagate and let the caller
            // fail soft — the busy timeout already absorbed any short lock.
            if DB.isLockContention(error) { throw error }
            DB.removeSidecars(url)
            DB.restoreWritePermission(url)
            do {
                try self.open(at: url)
            } catch {
                if DB.isLockContention(error) { throw error }
                try DB.quarantine(url)
                try self.open(at: url)
            }
        }
    }

    /// Reader-process initialiser: opens WITHOUT the recovery ladder.
    ///
    /// The GUI and `burrow --mcp` share one file; recovery (dropping
    /// sidecars, quarantining) is only safe in the writer process — a
    /// reader doing it against the writer's live WAL is the data-loss
    /// path. So a reader that can't open simply throws; repair belongs
    /// to the writer, on its next launch.
    ///
    /// (The connection itself is still read-write — SQLite needs RW to
    /// participate in WAL — but this process never inserts.)
    init(readerAt url: URL) throws {
        try self.open(at: url)
    }

    /// SQLITE_BUSY / SQLITE_LOCKED (or their extended forms) — another
    /// connection holds the file; nothing about it is broken.
    private static func isLockContention(_ error: Error) -> Bool {
        guard let dbError = error as? DBError else { return false }
        switch dbError {
        case .open(let code, _), .step(let code, _):
            let base = code & 0xff   // strip extended-result bits
            return base == SQLITE_BUSY || base == SQLITE_LOCKED
        case .prepare, .unsupported:
            return false
        }
    }

    /// Open the SQLite file at `url`, configure pragmas, and ensure the
    /// schema. Sets `self.handle` on success; on any failure closes the
    /// handle, leaves it nil, and rethrows so a caller can recover.
    private func open(at url: URL) throws {
        var h: OpaquePointer?
        // SQLITE_OPEN_FULLMUTEX lets us call into the same connection from
        // multiple threads without serializing ourselves. SQLite handles
        // the locking, and the cost is a per-call mutex grab — negligible
        // at our query rate.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &h, flags, nil)
        if rc != SQLITE_OK {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if h != nil { sqlite3_close(h) }   // close only a real handle
            self.handle = nil
            throw DBError.open(rc, msg)
        }
        self.handle = h
        // Wait (up to 2 s) on another connection's short write locks instead
        // of failing instantly with SQLITE_BUSY — the GUI and `Burrow --mcp`
        // share this file by design.
        sqlite3_busy_timeout(h, 2000)

        do {
            // WAL mode lets readers run concurrently with the writer.
            // Without it the sampler's 1-row insert blocks every chart
            // query — very visible at 60s cadence with the popup open.
            try exec("PRAGMA journal_mode=WAL;")
            try exec("PRAGMA synchronous=NORMAL;")  // WAL + NORMAL is the canonical durability/perf tradeoff
            try exec("PRAGMA foreign_keys=ON;")

            try exec("""
                CREATE TABLE IF NOT EXISTS samples (
                    prefix TEXT NOT NULL,
                    ts     INTEGER NOT NULL,
                    json   TEXT NOT NULL,
                    PRIMARY KEY (prefix, ts)
                );
                """)
            // Cross-prefix TTL prune needs a ts-only index; the PK above is
            // (prefix, ts) so it can't satisfy `WHERE ts < ?` without scanning.
            try exec("CREATE INDEX IF NOT EXISTS idx_samples_ts ON samples(ts);")
        } catch {
            // A pragma/schema write failed — the file is corrupt or
            // readonly. Close so the next attempt opens cleanly.
            sqlite3_close(self.handle)
            self.handle = nil
            throw error
        }
    }

    // MARK: - Recovery (issue #5)

    /// Delete the WAL/SHM sidecars. They're regenerated on next open, and
    /// a stale or root-owned `-wal` is a common "readonly database" cause.
    private static func removeSidecars(_ url: URL) {
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    /// Ensure the owner can read+write our own db file, preserving the rest
    /// of its mode (don't broaden group/other access). Best-effort: if we
    /// don't own it (or it's immutable) this no-ops and recovery falls
    /// through to quarantine.
    private static func restoreWritePermission(_ url: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let current = ((try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
        try? fm.setAttributes([.posixPermissions: current | 0o600], ofItemAtPath: url.path)
    }

    /// Move the unusable db **and its sidecars** aside so a fresh one can
    /// be created in its place. The sidecars travel with the db (forensics)
    /// and none are left at the original path to poison the new one. Picks
    /// the first free `<name>.corrupt[-n]` so an earlier quarantine isn't
    /// clobbered. Throws if the move fails (e.g. a read-only directory).
    private static func quarantine(_ url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { removeSidecars(url); return }
        var dest = url.path + ".corrupt"
        var n = 1
        while fm.fileExists(atPath: dest) { dest = url.path + ".corrupt-\(n)"; n += 1 }
        try fm.moveItem(atPath: url.path, toPath: dest)
        for suffix in ["-wal", "-shm"] {
            let side = url.path + suffix
            if fm.fileExists(atPath: side) { try? fm.moveItem(atPath: side, toPath: dest + suffix) }
        }
    }

    deinit {
        if let h = handle {
            sqlite3_close(h)
        }
    }

    // MARK: - Writes

    /// Insert a (prefix, ts) row. Last-write-wins on PK collision because
    /// the sampler can fire twice in the same second on a long stall.
    func insert(prefix: String, ts: Int, json: String) throws {
        try writeQueue.sync {
            var stmt: OpaquePointer?
            let sql = "INSERT OR REPLACE INTO samples(prefix, ts, json) VALUES (?, ?, ?);"
            guard sqlite3_prepare_v2(self.handle, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DBError.prepare(self.lastErrorMessage())
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, prefix, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, Int64(ts))
            sqlite3_bind_text(stmt, 3, json, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw DBError.step(sqlite3_errcode(self.handle), self.lastErrorMessage())
            }
        }
    }

    // MARK: - Reads

    struct Row {
        let ts: Int
        let json: String
    }

    /// Most recent row for a prefix, or nil. O(log N) via the (prefix, ts)
    /// PK — SQLite walks the index backwards from the prefix's upper bound.
    func findLatest(prefix: String) -> Row? {
        findLatestRows(prefix: prefix, limit: 1).first
    }

    /// The newest `limit` rows for a prefix, newest first. Same index walk
    /// as `findLatest`; the reader uses it to fall back past drifted rows.
    func findLatestRows(prefix: String, limit: Int) -> [Row] {
        guard limit > 0 else { return [] }
        var rows: [Row] = []
        var stmt: OpaquePointer?
        let sql = "SELECT ts, json FROM samples WHERE prefix=? ORDER BY ts DESC LIMIT ?;"
        guard sqlite3_prepare_v2(self.handle, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, prefix, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, Int64(limit))
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ts = Int(sqlite3_column_int64(stmt, 0))
            let json = String(cString: sqlite3_column_text(stmt, 1))
            rows.append(Row(ts: ts, json: json))
        }
        return rows
    }

    /// All rows for `prefix` in `[since, until]` (inclusive). Returned in
    /// ascending ts order. Bounded by the PK range so a 24h window over
    /// a million-row prefix walks just the slice.
    func findRange(prefix: String, since: Int, until: Int) -> [Row] {
        var rows: [Row] = []
        var stmt: OpaquePointer?
        let sql = """
            SELECT ts, json FROM samples
            WHERE prefix=? AND ts BETWEEN ? AND ?
            ORDER BY ts ASC;
            """
        guard sqlite3_prepare_v2(self.handle, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, prefix, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, Int64(since))
        sqlite3_bind_int64(stmt, 3, Int64(until))
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ts = Int(sqlite3_column_int64(stmt, 0))
            let json = String(cString: sqlite3_column_text(stmt, 1))
            rows.append(Row(ts: ts, json: json))
        }
        return rows
    }

    /// Stride-sampled range read. Returns at most `maxPoints` rows evenly
    /// spaced across the window. Implemented by computing a target stride
    /// (`ceil(window / maxPoints)`) and grouping rows by the bucket they
    /// land in, picking the first row of each bucket.
    ///
    /// This is the same shape Stats's seek-stride sampler had, but in SQL
    /// it's one round trip instead of an iterator loop. The point at the
    /// row level: a wide range query (24h, 7d) materializes O(maxPoints)
    /// rows in Swift, not the full window.
    func findRangeSampled(prefix: String,
                                 since: Int,
                                 until: Int,
                                 maxPoints: Int = 720) -> [Row] {
        let window = until - since
        guard window > 0, maxPoints > 0 else { return [] }
        let stride = max(1, (window + maxPoints - 1) / maxPoints)  // ceil
        var rows: [Row] = []
        var stmt: OpaquePointer?
        // For each bucket `(ts - since) / stride` we take the row with the
        // smallest ts. SQLite picks the row with MIN(ts) per group cheaply
        // because the index is already ts-sorted within the prefix.
        let sql = """
            SELECT MIN(ts) AS ts, json FROM samples
            WHERE prefix=? AND ts BETWEEN ? AND ?
            GROUP BY (ts - ?) / ?
            ORDER BY ts ASC;
            """
        guard sqlite3_prepare_v2(self.handle, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, prefix, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, Int64(since))
        sqlite3_bind_int64(stmt, 3, Int64(until))
        sqlite3_bind_int64(stmt, 4, Int64(since))
        sqlite3_bind_int64(stmt, 5, Int64(stride))
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ts = Int(sqlite3_column_int64(stmt, 0))
            let json = String(cString: sqlite3_column_text(stmt, 1))
            rows.append(Row(ts: ts, json: json))
        }
        return rows
    }

    /// Distinct prefixes currently in the DB. Cheap because the PK starts
    /// with `prefix` — SQLite can satisfy this from the index alone.
    func listPrefixes() -> [String] {
        var out: [String] = []
        var stmt: OpaquePointer?
        let sql = "SELECT DISTINCT prefix FROM samples ORDER BY prefix;"
        guard sqlite3_prepare_v2(self.handle, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(String(cString: sqlite3_column_text(stmt, 0)))
        }
        return out
    }

    // MARK: - Maintenance

    /// Delete rows older than `cutoff` (a unix timestamp). Returns number
    /// of rows deleted. Uses the `idx_ts` index — wouldn't be possible
    /// without it because the PK leads with `prefix`.
    @discardableResult
    func pruneOlderThan(_ cutoff: Int) throws -> Int {
        return try writeQueue.sync {
            var stmt: OpaquePointer?
            let sql = "DELETE FROM samples WHERE ts < ?;"
            guard sqlite3_prepare_v2(self.handle, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DBError.prepare(self.lastErrorMessage())
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(cutoff))
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw DBError.step(sqlite3_errcode(self.handle), self.lastErrorMessage())
            }
            return Int(sqlite3_changes(self.handle))
        }
    }

    /// `VACUUM` reclaims disk space after a heavy prune. Not run
    /// automatically — the sampler doesn't generate enough churn day to
    /// day to need it. Tests + a future "compact now" settings button.
    func vacuum() throws {
        try writeQueue.sync { try self.exec("VACUUM;") }
    }

    // MARK: - Internals

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(self.handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw DBError.step(rc, msg)
        }
    }

    private func lastErrorMessage() -> String {
        if let h = self.handle {
            return String(cString: sqlite3_errmsg(h))
        }
        return "no handle"
    }
}
