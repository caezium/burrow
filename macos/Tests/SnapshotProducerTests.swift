//
//  SnapshotProducerTests.swift
//  BurrowTests
//
//  Boundary tests for the snapshot producer stack. The pure core first:
//  RateTracker (counter differentiation — previously written twice, with
//  drift, in LocalMetrics and IOMonitor) takes counters + timestamps as
//  arguments, so no test ever touches a wall clock.
//

import XCTest
@testable import Burrow

final class RateTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testFirstCallBaselinesThenComputesRate() throws {
        var tr = RateTracker()
        XCTAssertNil(tr.mbps(0, 0, at: t0), "no baseline yet")
        let r = try XCTUnwrap(tr.mbps(10 << 20, 5 << 20, at: t0.addingTimeInterval(10)))
        XCTAssertEqual(r.a, 1.0, accuracy: 1e-9)   // 10 MiB over 10 s
        XCTAssertEqual(r.b, 0.5, accuracy: 1e-9)
    }

    func testCounterRegressionSkipsDeltaAndRebaselines() throws {
        var tr = RateTracker()
        _ = tr.mbps(100, 100, at: t0)
        // Reboot / driver replug: counters went backwards — no negative rate.
        XCTAssertNil(tr.mbps(50, 50, at: t0.addingTimeInterval(1)))
        // Next delta computes from the new baseline.
        let r = try XCTUnwrap(tr.mbps(50 + (1 << 20), 50, at: t0.addingTimeInterval(2)))
        XCTAssertEqual(r.a, 1.0, accuracy: 1e-6)
        XCTAssertEqual(r.b, 0.0, accuracy: 1e-9)
    }

    func testTinyDtIsSkipped() {
        var tr = RateTracker()
        _ = tr.mbps(0, 0, at: t0)
        XCTAssertNil(tr.mbps(1 << 20, 0, at: t0.addingTimeInterval(0.01)),
                     "dt under the floor would explode the rate")
    }
}

// MARK: - SnapshotPatcher — native values fill ONLY the holes mo left

final class SnapshotPatcherTests: XCTestCase {
    private func dict(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    func testDiskFilledOnlyWhenMoReportsZero() {
        let hole = #"{"disk_io":{"read_rate":0,"write_rate":0}}"#
        let fill = SnapshotPatcher.NativeFill(disk: (3.5, 1.25), gpu: nil, fans: nil, cpuTemp: nil, gpuTemp: nil)

        let patched = dict(SnapshotPatcher.patch(json: hole, fill: fill))
        let io = patched["disk_io"] as? [String: Any]
        XCTAssertEqual((io?["read_rate"] as? NSNumber)?.doubleValue, 3.5)
        XCTAssertEqual((io?["write_rate"] as? NSNumber)?.doubleValue, 1.25)

        // mo reported real numbers → keep them, never overwrite.
        let real = #"{"disk_io":{"read_rate":9,"write_rate":2}}"#
        let kept = dict(SnapshotPatcher.patch(json: real, fill: fill))
        XCTAssertEqual(((kept["disk_io"] as? [String: Any])?["read_rate"] as? NSNumber)?.doubleValue, 9)
    }

    func testGPUFilledOnlyWhenUnavailable() {
        let fill = SnapshotPatcher.NativeFill(disk: nil, gpu: 43, fans: nil, cpuTemp: nil, gpuTemp: nil)

        let hole = #"{"gpu":[{"name":"G","usage":-1}]}"#
        let patched = dict(SnapshotPatcher.patch(json: hole, fill: fill))
        XCTAssertEqual(((patched["gpu"] as? [[String: Any]])?.first?["usage"] as? NSNumber)?.doubleValue, 43)

        // Apple Silicon: Mole can't read GPU% and reports 0 (not -1). The
        // native reading must still fill, or every stored sample sits at 0.
        let zero = #"{"gpu":[{"name":"G","usage":0}]}"#
        let filled = dict(SnapshotPatcher.patch(json: zero, fill: fill))
        XCTAssertEqual(((filled["gpu"] as? [[String: Any]])?.first?["usage"] as? NSNumber)?.doubleValue, 43)

        let real = #"{"gpu":[{"name":"G","usage":12}]}"#
        let kept = dict(SnapshotPatcher.patch(json: real, fill: fill))
        XCTAssertEqual(((kept["gpu"] as? [[String: Any]])?.first?["usage"] as? NSNumber)?.doubleValue, 12)
    }

    func testThermalFillsZerosButNeverSynthesizes() {
        let fill = SnapshotPatcher.NativeFill(disk: nil, gpu: nil,
                                              fans: (count: 1, rpm: [1200]), cpuTemp: 55, gpuTemp: nil)

        let hole = #"{"thermal":{"fan_count":0,"fan_speed":0,"cpu_temp":0,"gpu_temp":0,"battery_temp":31.5}}"#
        let t = dict(SnapshotPatcher.patch(json: hole, fill: fill))["thermal"] as? [String: Any]
        XCTAssertEqual((t?["fan_count"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((t?["fan_speed"] as? NSNumber)?.intValue, 1200)
        XCTAssertEqual((t?["cpu_temp"] as? NSNumber)?.doubleValue, 55)
        XCTAssertEqual((t?["gpu_temp"] as? NSNumber)?.doubleValue, 0, "no native gpu temp → hole stays")
        XCTAssertEqual((t?["battery_temp"] as? NSNumber)?.doubleValue, 31.5, "mo's value untouched")

        // No thermal object in mo's output → never invent one.
        let none = SnapshotPatcher.patch(json: #"{"cpu":{"usage":1}}"#, fill: fill)
        XCTAssertNil(dict(none)["thermal"])
    }

    func testInvalidOrUnchangedJSONReturnedVerbatim() {
        let fill = SnapshotPatcher.NativeFill(disk: (1, 1), gpu: 50, fans: nil, cpuTemp: nil, gpuTemp: nil)
        XCTAssertEqual(SnapshotPatcher.patch(json: "not json", fill: fill), "not json")
        // Nothing to patch → the exact original text comes back (no re-encode).
        let real = #"{"disk_io":{"read_rate":9,"write_rate":2},"gpu":[{"usage":12}]}"#
        XCTAssertEqual(SnapshotPatcher.patch(json: real, fill: fill), real)
    }
}

// MARK: - Engine — scripted ports, logical time, temp DB

final class SnapshotProducerEngineTests: XCTestCase {
    private var tempDir: URL!
    private var db: DB!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-producer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try DB(at: tempDir.appendingPathComponent("burrow.db"))
    }

    override func tearDown() {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: Test adapters

    /// Fires due callbacks synchronously, in deadline order, on the caller's
    /// thread — the whole cadence matrix runs without a wall clock.
    final class ManualClock: ProducerClock {
        private(set) var current: Date
        init(start: Date) { current = start }
        var now: Date { current }

        final class Token: ClockCancellable {
            var cancelled = false
            func cancel() { cancelled = true }
        }
        private var scheduled: [(deadline: Date, token: Token, body: () -> Void)] = []

        @discardableResult
        func schedule(after: TimeInterval, _ body: @escaping () -> Void) -> ClockCancellable {
            let t = Token()
            scheduled.append((current.addingTimeInterval(after), t, body))
            return t
        }

        /// Timers armed and not yet fired or cancelled — how a test observes that the
        /// producer re-armed its poll after the watch stream ended, without a wall clock.
        var pending: Int { scheduled.filter { !$0.token.cancelled }.count }

        func advance(by interval: TimeInterval) {
            let target = current.addingTimeInterval(interval)
            while true {
                let due = scheduled
                    .filter { !$0.token.cancelled && $0.deadline <= target }
                    .sorted { $0.deadline < $1.deadline }
                guard let next = due.first else { break }
                scheduled.removeAll { $0.token === next.token }
                current = max(current, next.deadline)
                next.body()    // may re-arm; loop re-collects
            }
            current = target
        }
    }

    final class FakeCounters: HardwareCounters {
        var disk: (read: UInt64, write: UInt64)? = (0, 0)
        var net: (rx: UInt64, tx: UInt64)? = (0, 0)
        var gpu: Double? = 43
        var fanRPM: [Int] = []
        func diskBytes() -> (read: UInt64, write: UInt64)? { disk }
        func netBytes() -> (rx: UInt64, tx: UInt64)? { net }
        func gpuUtilization() -> Double? { gpu }
        func fans() -> (count: Int, rpm: [Int]) { (fanRPM.isEmpty ? 0 : fanRPM.count, fanRPM) }
        func temps() -> (cpu: Double?, gpu: Double?) { (nil, nil) }
    }

    struct CannedStatus: StatusSource {
        let json: () -> String
        func statusJSON() throws -> String { json() }
    }

    final class HeldWork {
        private let lock = NSLock()
        private var pending: [() -> Void] = []
        var count: Int { lock.lock(); defer { lock.unlock() }; return pending.count }
        func submit(_ body: @escaping () -> Void) {
            lock.lock(); pending.append(body); lock.unlock()
        }
        func runNext() {
            lock.lock()
            let body = pending.isEmpty ? nil : pending.removeFirst()
            lock.unlock()
            body?()
        }
    }

    /// Canned `mo status --json` with the Apple-Silicon holes: disk 0/0 and
    /// gpu -1. `seq` varies collected_at so each sample lands on its own ts.
    private func holeyJSON(seq: Int) -> String {
        """
        {"collected_at":"2026-06-08T03:16:\(String(format: "%02d", seq)).000000-07:00","host":"h","platform":"darwin",
         "uptime_seconds":100,"procs":1,
         "hardware":{"model":"Mac","cpu_model":"M","total_ram":"24 GB","disk_size":"460 GB","os_version":"26"},
         "health_score":90,"health_score_msg":"Good",
         "cpu":{"usage":12,"load1":1,"load5":1,"load15":1,"core_count":10,"logical_cpu":10},
         "memory":{"used":1,"total":2,"used_percent":50,"swap_used":0,"swap_total":0,"pressure":""},
         "disk_io":{"read_rate":0,"write_rate":0},
         "gpu":[{"name":"G","usage":-1,"memory_used":0,"memory_total":0,"core_count":10,"note":null}]}
        """
    }

    private func makeProducer(clock: ManualClock, hw: FakeCounters,
                              interval: @escaping () -> TimeInterval = { 60 }) -> SnapshotProducer {
        var seq = 0
        let status = CannedStatus(json: { seq += 1; return self.holeyJSON(seq: seq) })
        return SnapshotProducer(deps: .init(status: status, hardware: hw, clock: clock,
                                            sink: DBSnapshotSink(db: db),
                                            snapshotInterval: interval,
                                            work: { $0() }))
    }

    // MARK: Tests

    func testStart_samplesImmediatelyPatchesGPUAndPublishes() throws {
        let clock = ManualClock(start: Date(timeIntervalSince1970: 0))
        let p = makeProducer(clock: clock, hw: FakeCounters())
        p.start()

        let stored = try XCTUnwrap(MetricsStore(db: db).latest(), "first sample persisted on start")
        XCTAssertEqual(stored.status.gpu?.first?.usage, 43, "gpu hole filled from native counters")
        XCTAssertEqual(p.live.lastSnapshot?.healthScore, 90, "published for the views")
        XCTAssertEqual(stored.status.diskIO.readRate, 0, "no disk baseline yet → hole stays")
    }

    func testSecondSample_patchesDiskRateFromCounterDelta() throws {
        let clock = ManualClock(start: Date(timeIntervalSince1970: 0))
        let hw = FakeCounters()
        let p = makeProducer(clock: clock, hw: hw)
        p.start()

        hw.disk = (read: 60 << 20, write: 30 << 20)   // +60/+30 MiB over 60 s
        clock.advance(by: 60)

        let stored = try XCTUnwrap(MetricsStore(db: db).latest())
        XCTAssertEqual(stored.status.diskIO.readRate, 1.0, accuracy: 0.001)
        XCTAssertEqual(stored.status.diskIO.writeRate, 0.5, accuracy: 0.001)
    }

    func testLiveTicks_publishRatesAndGrowRing() {
        let clock = ManualClock(start: Date(timeIntervalSince1970: 0))
        let hw = FakeCounters()
        let p = makeProducer(clock: clock, hw: hw)
        p.start()

        hw.net = (rx: 2 << 20, tx: 1 << 20)           // +2/+1 MiB over 1 s
        clock.advance(by: 1)
        XCTAssertEqual(p.live.rxMBs, 2.0, accuracy: 0.001)
        XCTAssertEqual(p.live.txMBs, 1.0, accuracy: 0.001)
        XCTAssertEqual(p.live.samples.count, 1)

        hw.net = (rx: 3 << 20, tx: 1 << 20)
        clock.advance(by: 1)
        XCTAssertEqual(p.live.rxMBs, 1.0, accuracy: 0.001)
        XCTAssertEqual(p.live.samples.count, 2)
        XCTAssertEqual(p.live.netHistory(lastSeconds: 600).last ?? -1, 1.0, accuracy: 0.001)
    }

    func testNetHistoryWindowsToTrailingSeconds() {
        let clock = ManualClock(start: Date(timeIntervalSince1970: 0))
        let hw = FakeCounters()
        let p = makeProducer(clock: clock, hw: hw)
        p.start()

        // 30 one-second ticks at a steady +1 MiB/s on rx.
        for i in 1...30 {
            hw.net = (rx: UInt64(i + 1) << 20, tx: 0)
            clock.advance(by: 1)
        }
        XCTAssertEqual(p.live.samples.count, 30)

        // The window is measured from the NEWEST sample, not the wall clock.
        XCTAssertEqual(p.live.netHistory(lastSeconds: 10).count, 11,
                       "trailing 10 s inclusive of both endpoints")
        XCTAssertEqual(p.live.netHistory(lastSeconds: 3600).count, 30,
                       "a window wider than the ring returns the whole ring")
        XCTAssertEqual(p.live.netHistory(lastSeconds: 0).count, 1,
                       "zero window still yields the newest sample")
    }

    func testNetHistoryEmptyRing() {
        let clock = ManualClock(start: Date(timeIntervalSince1970: 0))
        let p = makeProducer(clock: clock, hw: FakeCounters())
        // No ticks yet — no samples, no crash.
        XCTAssertTrue(p.live.netHistory(lastSeconds: 600).isEmpty)
    }

    /// Exact persisted-row count (findRangeSampled time-buckets wide
    /// windows, which would collapse same-minute samples into one).
    private func persistedCount() -> Int {
        MetricsStore(db: db).rawRows(prefix: MetricsStore.snapshotPrefix,
                                     .init(since: 0, until: 2_000_000_000), maxPoints: nil).count
    }

    func testForeground_samplesImmediatelyAndSpeedsCadence() throws {
        let clock = ManualClock(start: Date(timeIntervalSince1970: 0))
        let p = makeProducer(clock: clock, hw: FakeCounters())
        p.start()
        let countAfterStart = persistedCount()

        p.setForeground(true)     // immediate fresh sample
        XCTAssertEqual(persistedCount(), countAfterStart + 1)

        clock.advance(by: 5)      // foreground cadence: min(5, configured 60)
        XCTAssertEqual(persistedCount(), countAfterStart + 2)
    }

    func testMalformedStatusIsQuarantined() {
        let clock = ManualClock(start: Date(timeIntervalSince1970: 0))
        let status = CannedStatus(json: { "garbage not json" })
        let p = SnapshotProducer(deps: .init(status: status, hardware: FakeCounters(), clock: clock,
                                             sink: DBSnapshotSink(db: db),
                                             snapshotInterval: { 60 }, work: { $0() }))
        p.start()
        XCTAssertNil(MetricsStore(db: db).latest(), "malformed snapshot never reaches the DB")
        XCTAssertNil(p.live.lastSnapshot)
    }

    // MARK: `status --watch`

    /// Spin the main run loop until `condition` holds. The watch consumer is a Task that
    /// publishes through `DispatchQueue.main.async`, so a synchronous assertion right after
    /// `start()` would race it; everything else in this file is clock-driven and needs no wait.
    private func waitUntil(_ what: String, timeout: TimeInterval = 3,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "timed out waiting for \(what)", file: file, line: line)
    }

    /// One long-lived `status --watch` process feeds the dashboard: every NDJSON line is
    /// published, only lines due at the configured interval are persisted, and NO poll is
    /// spawned while the stream is alive. When the stream ends the producer falls back to
    /// polling — armed only then, so a dropped stream never freezes the dashboard and a live
    /// one is never doubled by a per-tick spawn.
    func testWatchStream_publishesEveryLine_persistsThrottled_thenFallsBackToPolling() throws {
        let clock = ManualClock(start: Date(timeIntervalSince1970: 0))
        var polls = 0
        let status = CannedStatus(json: { polls += 1; return self.holeyJSON(seq: polls) })
        // The fixture stream: three ticks the engine would write (`status --watch` emits the
        // buffered `status` data object per line), then the process exiting.
        func tick(_ seq: Int, health: Int) -> String {
            holeyJSON(seq: seq).replacingOccurrences(of: "\"health_score\":90", with: "\"health_score\":\(health)")
        }
        let watch = AsyncStream<ProcessEvent> { cont in
            cont.yield(.line(tick(10, health: 71)))
            cont.yield(.line(tick(11, health: 72)))
            cont.yield(.line(tick(12, health: 73)))
            cont.yield(.exited(0))
            cont.finish()
        }
        var vended = 0
        let p = SnapshotProducer(deps: .init(status: status, hardware: FakeCounters(), clock: clock,
                                             sink: DBSnapshotSink(db: db),
                                             snapshotInterval: { 60 }, work: { $0() },
                                             statusWatch: { vended += 1; return watch }))
        p.setForeground(true)   // someone is watching, so non-persisted lines still publish
        p.start()

        XCTAssertEqual(vended, 1, "the stream is opened once, not per tick")
        XCTAssertEqual(polls, 1, "one seed poll before the stream takes over")
        waitUntil("the last streamed line to publish") { p.live.lastSnapshot?.healthScore == 73 }
        XCTAssertEqual(persistedCount(), 2,
                       "the seed sample plus the first streamed line; the next two are within the "
                       + "60 s interval and are published only")
        XCTAssertEqual(polls, 1, "no `status --json` spawn while the stream is live")

        // The stream ended → the poll cadence is armed as the fallback (live timer + poll).
        waitUntil("the poll timer to be re-armed after the stream ended") { clock.pending == 2 }
        clock.advance(by: 5)    // foreground poll cadence: min(5, configured 60)
        XCTAssertEqual(polls, 2, "polling resumed once the stream was gone")
        XCTAssertEqual(persistedCount(), 3)
        XCTAssertEqual(p.live.lastSnapshot?.healthScore, 90, "the poll's snapshot is published too")
    }

    func testStop_cancelsBothCadences() {
        let clock = ManualClock(start: Date(timeIntervalSince1970: 0))
        let p = makeProducer(clock: clock, hw: FakeCounters())
        p.start()
        p.stop()
        clock.advance(by: 120)
        XCTAssertEqual(persistedCount(), 1,
                       "only the start() sample — no timers survive stop()")
        XCTAssertTrue(p.live.samples.isEmpty)
    }

    func testWatchUsesTheSampleQueueAndDropsFramesQueuedBeforeStop() {
        let clock = ManualClock(start: Date(timeIntervalSince1970: 0))
        let work = HeldWork()
        var continuation: AsyncStream<ProcessEvent>.Continuation!
        let stream = AsyncStream<ProcessEvent> { continuation = $0 }
        defer { continuation.finish() }
        let p = SnapshotProducer(deps: .init(
            status: CannedStatus(json: { self.holeyJSON(seq: 1) }),
            hardware: FakeCounters(), clock: clock, sink: DBSnapshotSink(db: db),
            snapshotInterval: { 60 }, work: work.submit, statusWatch: { stream }))
        p.setForeground(true)
        p.start()
        work.runNext() // seed and open the watch
        let frame = holeyJSON(seq: 10).replacingOccurrences(of: "\"health_score\":90", with: "\"health_score\":71")
        continuation.yield(.line(frame))
        waitUntil("a frame is received") { work.count > 0 || p.live.lastSnapshot?.healthScore == 71 }
        XCTAssertEqual(p.live.lastSnapshot?.healthScore, 90,
                       "stream frames must wait behind in-flight poll work before touching rate trackers or persistence")
        XCTAssertEqual(persistedCount(), 1)
        XCTAssertEqual(work.count, 1)
        work.runNext()
        XCTAssertEqual(p.live.lastSnapshot?.healthScore, 71)
        XCTAssertEqual(persistedCount(), 2)

        continuation.yield(.line(frame.replacingOccurrences(of: ":71", with: ":72")))
        waitUntil("a second frame is received") { work.count > 0 || p.live.lastSnapshot?.healthScore == 72 }
        p.stop()
        work.runNext()
        XCTAssertEqual(p.live.lastSnapshot?.healthScore, 71, "stopping invalidates pending stream work")
        XCTAssertEqual(persistedCount(), 2)
    }

    func testStoppingBeforeTheInitialWorkRunsDoesNotStartTheEngine() {
        let work = HeldWork()
        var polls = 0
        var watches = 0
        let p = SnapshotProducer(deps: .init(
            status: CannedStatus(json: { polls += 1; return self.holeyJSON(seq: 1) }),
            hardware: FakeCounters(), clock: ManualClock(start: Date()), sink: DBSnapshotSink(db: db),
            snapshotInterval: { 60 }, work: work.submit,
            statusWatch: { watches += 1; return nil }))
        p.start()
        p.stop()
        work.runNext()
        XCTAssertEqual(polls, 0)
        XCTAssertEqual(watches, 0)
        XCTAssertEqual(persistedCount(), 0)
    }
}
