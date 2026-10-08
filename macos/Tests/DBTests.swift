//
//  DBTests.swift
//  BurrowTests
//
//  Covers the SQLite-backed history store. Each test gets its own temp
//  DB so cases can't leak state into each other; the @testable import
//  reaches the internal `init(at:)` initializer that takes an explicit
//  path (production code uses `openDefault()` against Application
//  Support, which we don't want test runs touching).
//

import SQLite3
import XCTest
@testable import Burrow

final class DBTests: XCTestCase {
    private var tempDir: URL!
    private var db: DB!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try DB(at: tempDir.appendingPathComponent("burrow.db"))
    }

    override func tearDown() {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Corruption recovery (issue #5)

    /// A corrupt / non-database file at the path must not brick launch.
    /// `DB(at:)` recovers by quarantining the bad file and recreating a
    /// fresh, usable store. Uses its own path so the setUp DB handle
    /// isn't affected.
    func testInit_recoversFromCorruptDatabaseFile() throws {
        let url = tempDir.appendingPathComponent("corrupt.db")
        try Data("this is not a sqlite database".utf8).write(to: url)

        let recovered = try DB(at: url)   // must not throw
        try recovered.insert(prefix: "p", ts: 1, json: "{\"v\":1}")
        let row = try XCTUnwrap(recovered.findLatest(prefix: "p"))
        XCTAssertEqual(row.json, "{\"v\":1}")
    }

    /// The error from the issue: a valid-but-non-writable file. The
    /// non-destructive repair (restore write permission) must recover it
    /// IN PLACE so the user's history survives — no quarantine.
    func testInit_recoversFromReadonlyDatabaseFile() throws {
        let url = tempDir.appendingPathComponent("ro.db")
        var seed: DB? = try DB(at: url)
        try seed!.insert(prefix: "p", ts: 5, json: "{\"seed\":true}")
        seed = nil   // close + checkpoint WAL into the main file

        try? FileManager.default.removeItem(atPath: url.path + "-wal")
        try? FileManager.default.removeItem(atPath: url.path + "-shm")
        try FileManager.default.setAttributes([.posixPermissions: 0o444],
                                              ofItemAtPath: url.path)

        let recovered = try DB(at: url)   // must not throw
        let row = try XCTUnwrap(recovered.findLatest(prefix: "p"))
        XCTAssertEqual(row.json, "{\"seed\":true}", "readonly recovery must preserve history")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".corrupt"),
                       "a writable-again file should be repaired in place, not quarantined")
    }

    /// A genuinely unusable file (not a database, can't be repaired) is
    /// moved aside so the fresh db can take its place — and kept for
    /// forensics rather than silently deleted.
    func testInit_quarantinesUnrecoverableFile() throws {
        let url = tempDir.appendingPathComponent("bad.db")
        try Data("not a database".utf8).write(to: url)
        _ = try DB(at: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".corrupt"),
                      "the unusable file should be preserved alongside the fresh db")
    }

    // MARK: - Reader open (the `--mcp` process) — issue #50

    /// The reader process must NEVER run the destructive recovery ladder:
    /// quarantining the file or deleting the sidecars is only safe in the
    /// writer process — against a live writer it IS the data-loss path.
    /// A reader that can't open fails soft and leaves repair to the writer.
    func testReaderOpen_neverRunsTheDestructiveRecoveryLadder() throws {
        let url = tempDir.appendingPathComponent("damaged.db")
        let garbage = Data("not a sqlite database".utf8)
        try garbage.write(to: url)
        try Data("the writer's live wal".utf8).write(to: URL(fileURLWithPath: url.path + "-wal"))

        XCTAssertThrowsError(try DB(readerAt: url))

        XCTAssertEqual(try Data(contentsOf: url), garbage,
                       "reader open must leave the file byte-identical")
        // (SQLite itself may reset a stale WAL under its own file locks while
        // attempting the open — that's its coordinated recovery, safe against
        // a live writer. What must never happen here is OUR ladder: deleting
        // the sidecars outright or quarantining the database.)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + "-wal"),
                      "reader open must not delete the writer's WAL")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".corrupt"),
                       "reader open must never quarantine")
    }

    /// Second handle on the same file — exactly what `burrow --mcp` does
    /// while the GUI writes. WAL lets the read proceed concurrently.
    func testReaderOpen_seesTheWriterRows() throws {
        try db.insert(prefix: "p", ts: 1, json: "{\"v\":1}")
        let reader = try DB(readerAt: tempDir.appendingPathComponent("burrow.db"))
        XCTAssertEqual(reader.findLatest(prefix: "p")?.json, "{\"v\":1}")
    }

    // MARK: - Roundtrip

    func testInsertAndFindLatest_returnsMostRecent() throws {
        try db.insert(prefix: "p", ts: 100, json: "{\"v\":1}")
        try db.insert(prefix: "p", ts: 200, json: "{\"v\":2}")
        try db.insert(prefix: "p", ts: 150, json: "{\"v\":1.5}")
        let row = try XCTUnwrap(db.findLatest(prefix: "p"))
        XCTAssertEqual(row.ts, 200)
        XCTAssertEqual(row.json, "{\"v\":2}")
    }

    func testFindLatest_returnsNilForUnknownPrefix() {
        XCTAssertNil(db.findLatest(prefix: "nope"))
    }

    /// Two writes at the same (prefix, ts) must last-write-wins, not
    /// duplicate or error. Sampler can fire twice in the same Mole
    /// `collected_at` second if a tick lags slightly.
    func testInsertSameKey_isLastWriteWins() throws {
        try db.insert(prefix: "p", ts: 100, json: "{\"v\":1}")
        try db.insert(prefix: "p", ts: 100, json: "{\"v\":99}")
        let rows = db.findRange(prefix: "p", since: 0, until: 1_000)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].json, "{\"v\":99}")
    }

    // MARK: - Range query

    func testFindRange_isInclusiveAndOrdered() throws {
        for i in 0..<10 {
            try db.insert(prefix: "p", ts: 100 + i, json: "{\"v\":\(i)}")
        }
        let mid = db.findRange(prefix: "p", since: 102, until: 105)
        XCTAssertEqual(mid.map { $0.ts }, [102, 103, 104, 105])
    }

    /// Cross-prefix isolation: a query for "a" must not return "b" rows
    /// even if their timestamps overlap. PK is (prefix, ts) so this is a
    /// correctness floor, not a perf one.
    func testFindRange_isIsolatedByPrefix() throws {
        try db.insert(prefix: "a", ts: 100, json: "{}")
        try db.insert(prefix: "b", ts: 100, json: "{}")
        let aOnly = db.findRange(prefix: "a", since: 0, until: 1_000)
        XCTAssertEqual(aOnly.count, 1)
    }

    // MARK: - Stride-sampled query

    /// Bound the returned count at `maxPoints`, evenly across the window.
    /// We don't assert exact stride — SQL's GROUP BY can produce one
    /// extra bucket at the edge — just that we land in the right
    /// ballpark and the rows are monotonic.
    func testFindRangeSampled_boundedByMaxPoints() throws {
        for i in 0..<1_000 {
            try db.insert(prefix: "p", ts: i, json: "{\"v\":\(i)}")
        }
        let sampled = db.findRangeSampled(prefix: "p", since: 0, until: 999, maxPoints: 100)
        XCTAssertLessThanOrEqual(sampled.count, 110, "should be near 100, not full 1000")
        XCTAssertGreaterThan(sampled.count, 50, "sampler shouldn't collapse data to a single row")
        // Monotone increasing in ts.
        for i in 1..<sampled.count {
            XCTAssertLessThan(sampled[i - 1].ts, sampled[i].ts)
        }
    }

    func testFindRangeSampled_sparseDataReturnsAllRows() throws {
        try db.insert(prefix: "p", ts: 10, json: "{}")
        try db.insert(prefix: "p", ts: 500, json: "{}")
        try db.insert(prefix: "p", ts: 990, json: "{}")
        let sampled = db.findRangeSampled(prefix: "p", since: 0, until: 1_000, maxPoints: 720)
        XCTAssertEqual(sampled.map { $0.ts }, [10, 500, 990])
    }

    // MARK: - listPrefixes

    func testListPrefixes_returnsDistinctSorted() throws {
        try db.insert(prefix: "b", ts: 1, json: "{}")
        try db.insert(prefix: "a", ts: 1, json: "{}")
        try db.insert(prefix: "a", ts: 2, json: "{}")
        try db.insert(prefix: "c", ts: 1, json: "{}")
        XCTAssertEqual(db.listPrefixes(), ["a", "b", "c"])
    }

    // MARK: - Prune

    func testPruneOlderThan_deletesPastCutoff() throws {
        try db.insert(prefix: "p", ts: 100, json: "{}")
        try db.insert(prefix: "p", ts: 200, json: "{}")
        try db.insert(prefix: "p", ts: 300, json: "{}")
        let deleted = try db.pruneOlderThan(250)
        XCTAssertEqual(deleted, 2)
        let surviving = db.findRange(prefix: "p", since: 0, until: 1_000)
        XCTAssertEqual(surviving.map { $0.ts }, [300])
    }

    func testPruneOlderThan_zeroWhenAllRowsFresh() throws {
        try db.insert(prefix: "p", ts: 500, json: "{}")
        let deleted = try db.pruneOlderThan(100)
        XCTAssertEqual(deleted, 0)
    }

    // MARK: - Lock contention is not corruption (audit H3)

    /// `Burrow --mcp` opens the same file while the GUI is writing — by
    /// design. A busy/locked open must NOT walk the recovery ladder:
    /// deleting a live `-wal` corrupts the other connection's database,
    /// and quarantining a healthy file silently discards the history.
    func testInit_lockedDatabaseIsNeitherStrippedNorQuarantined() throws {
        let url = tempDir.appendingPathComponent("busy.db")
        let a = try DB(at: url)
        try a.insert(prefix: "p", ts: 1, json: "{\"keep\":true}")
        try a.exec("BEGIN EXCLUSIVE;")   // hold the lock like a mid-write peer
        defer { try? a.exec("COMMIT;") }

        _ = try? DB(at: url)             // may throw — must not destroy

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + "-wal"),
                      "the live WAL of a concurrently-open DB must survive a busy open")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".corrupt"),
                       "a healthy-but-busy DB must not be quarantined")
    }

    /// Two connections to the same file (GUI + MCP process) must wait out
    /// each other's short write locks instead of failing instantly.
    func testConcurrentConnections_waitOutShortLocks() throws {
        let url = tempDir.appendingPathComponent("shared.db")
        let a = try DB(at: url)
        let b = try DB(at: url)
        try a.exec("BEGIN IMMEDIATE;")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            try? a.exec("COMMIT;")
        }
        // Without a busy handler this throws SQLITE_BUSY the instant the
        // lock collides; with one, the 300 ms lock is simply waited out.
        XCTAssertNoThrow(try b.insert(prefix: "p", ts: 1, json: "{}"))
    }

    // MARK: - Launch open waits out contention instead of quitting

    func testRetryingLockContention_waitsOutBusyThenSucceeds() throws {
        var calls = 0
        var sleeps: [TimeInterval] = []
        let value = try DB.retryingLockContention(attempts: 5, delay: 0.5, sleep: { sleeps.append($0) }) {
            calls += 1
            // Extended codes (SQLITE_BUSY_SNAPSHOT) are contention too.
            if calls == 1 { throw DBError.open(SQLITE_BUSY, "database is locked") }
            if calls == 2 { throw DBError.step(SQLITE_BUSY | (2 << 8), "database is locked") }
            return 7
        }
        XCTAssertEqual(value, 7)
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(sleeps, [0.5, 0.5])
    }

    func testRetryingLockContention_givesUpAfterLastAttempt() {
        var calls = 0
        XCTAssertThrowsError(try DB.retryingLockContention(attempts: 3, delay: 0, sleep: { _ in }) { () -> Int in
            calls += 1
            throw DBError.open(SQLITE_LOCKED, "database table is locked")
        })
        XCTAssertEqual(calls, 3)
    }

    /// Damage is not contention: it goes straight to the caller (the
    /// recovery ladder inside `init(at:)` has already had its turn).
    func testRetryingLockContention_neverRetriesOtherFailures() {
        var calls = 0
        XCTAssertThrowsError(try DB.retryingLockContention(attempts: 5, delay: 0, sleep: { _ in }) { () -> Int in
            calls += 1
            throw DBError.open(SQLITE_READONLY, "attempt to write a readonly database")
        })
        XCTAssertEqual(calls, 1)
    }
}
