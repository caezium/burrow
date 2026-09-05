//
//  SnapshotProducer.swift
//  Burrow
//
//  The one snapshot engine: owns the whole sample→patch→persist→publish
//  cycle (replacing Sampler + LocalMetrics) AND the 1 Hz live net/disk feed
//  (replacing IOMonitor), so both paths read hardware through one set of
//  counters and one tested RateTracker instead of two drifting copies.
//
//  Everything impure sits behind four ports — the mo CLI, the hardware
//  counters, the clock, and the persistence sink — so the entire cadence
//  matrix and patch behavior runs deterministically in XCTest with scripted
//  adapters (see SnapshotProducerTests). Production wiring is one call:
//  `SnapshotProducer(deps: .live(db: db))`.
//
//  Cadence model (unchanged from Sampler): snapshots at the configured
//  interval (re-read every tick so a Settings change lands within one
//  cycle), 5 s while a metrics view is foreground; live counters at 1 Hz
//  into an in-memory ring (~1 h), never the database.
//

import Foundation
import IOKit

// MARK: - Ports

/// The mo CLI. Returns `mo status --json` stdout or throws; may block up to
/// its timeout, so the engine always calls it through `Deps.work`.
protocol StatusSource {
    func statusJSON() throws -> String
}

/// Cumulative since-boot byte counters and instantaneous gauges. nil means
/// "unreadable / unavailable" — never a zero-fill.
protocol HardwareCounters {
    func diskBytes() -> (read: UInt64, write: UInt64)?
    func netBytes() -> (rx: UInt64, tx: UInt64)?
    func gpuUtilization() -> Double?
    func fans() -> (count: Int, rpm: [Int])
    func temps() -> (cpu: Double?, gpu: Double?)
}

protocol ClockCancellable {
    func cancel()
}

/// The engine's only source of Date AND scheduling — tests advance a manual
/// clock; no wall-clock time exists anywhere in the producer's logic.
protocol ProducerClock {
    var now: Date { get }
    @discardableResult
    func schedule(after: TimeInterval, _ body: @escaping () -> Void) -> ClockCancellable
}

/// Persistence. The value is the EXACT patched JSON text keyed by mo's
/// `collected_at`; the row prefix is the adapter's secret.
protocol SnapshotSink {
    func persist(ts: Int, json: String) throws
}

// MARK: - View surface

/// What the views observe — the latest decoded snapshot plus the 1 Hz
/// net/disk rates and ring. Main-thread confined: the engine publishes
/// through `publishOnMain`, views read from SwiftUI. The mutators assert
/// main-thread (Thread.isMainThread), so any future off-main writer
/// trips in debug rather than silently re-introducing the off-main publish
/// race the old Sampler had. (A `@MainActor` annotation would force the
/// non-isolated producer's init to construct it off the main actor — a hard
/// error in Swift 5 mode — so the runtime guard is the practical safeguard.)
final class LiveFeed: ObservableObject {
    struct Sample {
        let time: Date
        let rxMBs: Double
        let txMBs: Double
        let readMBs: Double
        let writeMBs: Double
    }

    @Published private(set) var lastSnapshot: MoleStatus?
    @Published private(set) var sampledAt: Date?
    /// Current per-second rates (MB/s).
    @Published private(set) var rxMBs = 0.0
    @Published private(set) var txMBs = 0.0
    @Published private(set) var readMBs = 0.0
    @Published private(set) var writeMBs = 0.0
    /// Timestamped ring, oldest → newest, capped to ~1 h.
    @Published private(set) var samples: [Sample] = []

    /// Convenience series for sparklines (total rx+tx / read+write).
    var diskHistory: [Double] { samples.map { $0.readMBs + $0.writeMBs } }

    /// Net sparkline series windowed to the trailing `lastSeconds` of the
    /// ring, relative to the NEWEST sample (clock-free → unit-testable).
    /// The Status tile reads ~10 min: rendering the whole 1 h ring there
    /// flattened current variation into a near-flat line — long-range
    /// shape belongs to the History tab, which windows the raw samples
    /// itself.
    func netHistory(lastSeconds: TimeInterval) -> [Double] {
        windowed(lastSeconds) { $0.rxMBs + $0.txMBs }
    }

    /// Download (rx) and upload (tx) windowed separately — the net tile
    /// draws them as two lines instead of one summed shape.
    func netRxHistory(lastSeconds: TimeInterval) -> [Double] {
        windowed(lastSeconds) { $0.rxMBs }
    }
    func netTxHistory(lastSeconds: TimeInterval) -> [Double] {
        windowed(lastSeconds) { $0.txMBs }
    }

    private func windowed(_ lastSeconds: TimeInterval, _ pick: (Sample) -> Double) -> [Double] {
        guard let newest = samples.last?.time else { return [] }
        let cutoff = newest.addingTimeInterval(-lastSeconds)
        // `samples` is ascending by time and the in-window slice is a contiguous
        // suffix, so walk back from the end to the first in-window index — O(window)
        // (~120) instead of filtering the whole ~3600-element ring every render. #237
        var start = samples.count
        while start > 0, samples[start - 1].time >= cutoff { start -= 1 }
        return samples[start...].map(pick)
    }

    fileprivate func applySnapshot(_ s: MoleStatus, at: Date) {
        assert(Thread.isMainThread, "LiveFeed must publish on the main thread")
        lastSnapshot = s
        sampledAt = at
        // Threshold alerts ride the same snapshot stream (D.12) — off by
        // default, inert under XCTest, so this is a no-op unless opted in.
        ThresholdMonitor.shared.evaluate(s, at: at)
    }

    /// nil rate = no usable delta this tick (first tick, counter reset) —
    /// keep the previous published value, same as IOMonitor always did.
    fileprivate func applyTick(time: Date, rx: Double?, tx: Double?,
                               read: Double?, write: Double?, window: Int) {
        assert(Thread.isMainThread, "LiveFeed must publish on the main thread")
        if let rx { rxMBs = rx }
        if let tx { txMBs = tx }
        if let read { readMBs = read }
        if let write { writeMBs = write }
        samples.append(Sample(time: time, rxMBs: rxMBs, txMBs: txMBs,
                              readMBs: readMBs, writeMBs: writeMBs))
        if samples.count > window { samples.removeFirst(samples.count - window) }
    }
}

// MARK: - Engine

final class SnapshotProducer {
    struct Deps {
        var status: StatusSource
        var hardware: HardwareCounters
        var clock: ProducerClock
        var sink: SnapshotSink
        /// Re-read at every re-arm so a Settings change takes effect within
        /// one cycle without a restart.
        var snapshotInterval: () -> TimeInterval
        /// Background executor for the blocking mo fetch. Production hops to
        /// a serial utility queue; tests pass `{ $0() }` for synchrony.
        var work: (@escaping () -> Void) -> Void
        /// NDJSON status stream (`status --watch`) — ONE long-lived engine process whose
        /// lines are the snapshots, instead of a `status --json` spawn per tick. Used when the
        /// resolved engine can actually serve one: the bundled engine always can (BUR-132); an
        /// old mo predates the flag. Returns nil when it can't or when nothing resolves, and
        /// the producer polls instead. Tests script it with a canned stream (see
        /// `SnapshotProducerEngineTests.testWatchStream_…`) or omit it for the poll path.
        var statusWatch: (() -> AsyncStream<ProcessEvent>?)? = nil

        static func live(db: DB) -> Deps {
            let queue = DispatchQueue(label: "dev.caezium.burrow.producer", qos: .utility)
            return Deps(status: MoCLIStatusSource(),
                        hardware: IOKitHardware(),
                        clock: DispatchClock(),
                        sink: DBSnapshotSink(db: db),
                        snapshotInterval: { TimeInterval(Store.sampleIntervalSeconds) },
                        work: { queue.async(execute: $0) },
                        statusWatch: {
                            // Stream when the engine we're about to spawn can stream.
                            // `supportsWatch()` decides on WHAT answered `--version`: the
                            // bundled engine streams (BUR-132); a system mo older than
                            // 1.44 doesn't and is polled instead. Both `supportsWatch()`
                            // and `statusWatch()` resolve through the same
                            // `EngineCLI.findExecutable()`, so the binary asked is the
                            // binary spawned. Spawns a subprocess, so this runs off-main
                            // (the producer calls the factory inside `work`).
                            EngineCLI.supportsWatch() ? EngineRunner.shared.statusWatch() : nil
                        })
        }
    }

    let live = LiveFeed()

    private let deps: Deps
    private let dec = JSONDecoder()

    private let lock = NSLock()
    private var running = false
    private var foreground = false
    private var streaming = false            // `status --watch` active (guarded by lock)
    private var snapTimer: ClockCancellable?
    private var liveTimer: ClockCancellable?
    private var streamTask: Task<Void, Never>?
    /// Last time a streamed snapshot was persisted — throttles DB writes to the
    /// configured interval so a fast `--watch` stream doesn't write
    /// 1 s-resolution rows into the long-range history (guarded by lock).
    private var lastStreamPersist = Date.distantPast

    private let foregroundInterval: TimeInterval = 5
    private let liveInterval: TimeInterval = 1
    private let ringWindow = 3600

    /// Separate baselines on purpose: the live trackers differentiate over
    /// 1 s, the snapshot tracker over the inter-sample window (a windowed
    /// average reads more honestly on a 60 s chart than an instant spike).
    private var liveNet = RateTracker()
    private var liveDisk = RateTracker()
    private var snapDisk = RateTracker()

    /// The popover is a live consumer even when the main window is closed; the
    /// status-bar controller reports its visibility. (guarded by lock)
    private var popoverOpen = false

    // Sensor reads (SMC temps/fans, IOAccelerator GPU) change slowly; a 1 Hz
    // `--watch` stream would otherwise hammer IOKit every line. Cache them and
    // refresh at most every `sensorTTL`. Byte counters (disk/net) are NOT cached
    // — they feed rate trackers that need real per-tick deltas. #235
    private let sensorLock = NSLock()
    private var sensorCacheAt = Date.distantPast
    private var cachedFans: (count: Int, rpm: [Int]) = (0, [])
    private var cachedTemps: (cpu: Double?, gpu: Double?) = (nil, nil)
    private var cachedGPU: Double?
    private let sensorTTL: TimeInterval = 2.5

    /// True when something is actually watching live metrics: the main window's
    /// metrics pane (`foreground`), the popover, or a live menu-bar mode. When
    /// false, the stream's non-persisted lines and the 1 Hz counter tick skip
    /// their work — no point reading sensors nobody sees. #235
    private var liveWanted: Bool {
        lock.lock(); let fg = foreground, pop = popoverOpen; lock.unlock()
        return fg || pop || Store.menuBarDisplayMode != .icon
    }

    /// Cached slow-sensor read, refreshed at most every `sensorTTL`.
    private func sensors(at now: Date) -> (fans: (count: Int, rpm: [Int]), temps: (cpu: Double?, gpu: Double?), gpu: Double?) {
        sensorLock.lock(); defer { sensorLock.unlock() }
        if now.timeIntervalSince(sensorCacheAt) >= sensorTTL {
            cachedFans = deps.hardware.fans()
            cachedTemps = deps.hardware.temps()
            cachedGPU = deps.hardware.gpuUtilization()
            sensorCacheAt = now
        }
        return (cachedFans, cachedTemps, cachedGPU)
    }

    init(deps: Deps) {
        self.deps = deps
    }

    func start() {
        lock.lock()
        running = true
        lock.unlock()
        // Prime the live baselines so the first 1 Hz tick has a delta.
        let now = deps.clock.now
        if let n = deps.hardware.netBytes() { _ = liveNet.mbps(n.rx, n.tx, at: now) }
        if let d = deps.hardware.diskBytes() { _ = liveDisk.mbps(d.read, d.write, at: now) }
        armLiveTimer()
        // Off-main: seed one snapshot immediately, then either start the
        // `status --watch` stream or arm the poll timer. The gate spawns
        // `--version`, so the decision must run off the main thread.
        deps.work { self.beginSnapshots() }
    }

    /// Seed one snapshot, then choose snapshot delivery: stream when
    /// `deps.statusWatch` vends one (the bundled engine, or mo 1.44+), else
    /// poll. Runs on `deps.work` (off-main).
    private func beginSnapshots() {
        lock.lock()
        let shouldStart = running
        lock.unlock()
        guard shouldStart else { return }
        sampleNow()
        if let factory = deps.statusWatch, let stream = factory() {
            startStreaming(stream)
        } else {
            armSnapshotTimer()
        }
    }

    /// Consume `status --watch` NDJSON: publish every line, persist throttled
    /// to the configured interval. On stream end (the engine exited / errored)
    /// fall back to polling, so a dropped stream never leaves the dashboard
    /// frozen — the poll timer is armed only once the stream has finished, so
    /// there is never a per-tick spawn alongside a live stream.
    private func startStreaming(_ stream: AsyncStream<ProcessEvent>) {
        lock.lock()
        guard running else { lock.unlock(); return }
        streaming = true
        streamTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                guard case .line(let json) = event else { continue }
                // Polls and stream frames share the decoder, disk-rate
                // baseline and persistence order, so all ingestion must
                // run on the producer's serial work queue.
                self.deps.work {
                    self.lock.lock()
                    guard self.running else { self.lock.unlock(); return }
                    let now = self.deps.clock.now
                    let due = now.timeIntervalSince(self.lastStreamPersist) >= self.deps.snapshotInterval() - 0.5
                    if due { self.lastStreamPersist = now }
                    self.lock.unlock()
                    self.ingest(raw: json, persist: due)
                }
            }
            guard let self else { return }
            self.deps.work {
                self.lock.lock()
                self.streaming = false
                let resume = self.running
                self.lock.unlock()
                if resume { self.armSnapshotTimer() }
            }
        }
        lock.unlock()
    }

    func stop() {
        lock.lock()
        running = false
        streaming = false
        snapTimer?.cancel(); snapTimer = nil
        liveTimer?.cancel(); liveTimer = nil
        let task = streamTask
        streamTask = nil
        lock.unlock()
        task?.cancel()   // cancellation terminates the mo child
    }

    /// Switch between background and live (foreground) cadence. Turning it
    /// on takes a fresh sample immediately so the opening view isn't waiting
    /// a whole interval for data.
    func setForeground(_ on: Bool) {
        lock.lock()
        guard foreground != on else { lock.unlock(); return }
        foreground = on
        let isRunning = running
        let isStreaming = streaming
        lock.unlock()
        guard isRunning else { return }
        // While streaming, the watch supplies snapshots — no poll to re-pace.
        if on && !isStreaming { deps.work { self.sampleNow() } }
        armSnapshotTimer()   // no-op while streaming (guarded)
    }

    /// Report popover visibility. While the popover is up the engine keeps live
    /// data flowing even with the main window closed; opening takes an immediate
    /// sample so the popover isn't blank for a whole interval. #235
    func setPopoverOpen(_ open: Bool) {
        lock.lock()
        guard popoverOpen != open else { lock.unlock(); return }
        popoverOpen = open
        let isRunning = running
        lock.unlock()
        if isRunning && open { deps.work { self.sampleNow() } }
    }

    // MARK: Cadence

    private func armSnapshotTimer() {
        lock.lock()
        defer { lock.unlock() }
        guard running, !streaming else { return }   // the watch stream owns snapshots
        snapTimer?.cancel()
        let slow = deps.snapshotInterval()
        let interval = foreground ? min(foregroundInterval, slow) : slow
        snapTimer = deps.clock.schedule(after: interval) { [weak self] in
            guard let self else { return }
            self.deps.work { self.sampleNow() }
            self.armSnapshotTimer()
        }
    }

    private func armLiveTimer() {
        lock.lock()
        defer { lock.unlock() }
        guard running else { return }
        liveTimer?.cancel()
        liveTimer = deps.clock.schedule(after: liveInterval) { [weak self] in
            guard let self else { return }
            self.tickLive()
            self.armLiveTimer()
        }
    }

    // MARK: Ticks

    /// One 1 Hz pulse: read counters, differentiate, publish into the ring.
    /// Cheap (sub-ms registry reads) — runs on the clock's context.
    private func tickLive() {
        let now = deps.clock.now
        var rx: Double?, tx: Double?, rd: Double?, wr: Double?
        if let n = deps.hardware.netBytes(), let r = liveNet.mbps(n.rx, n.tx, at: now) {
            rx = r.a; tx = r.b
        }
        if let d = deps.hardware.diskBytes(), let r = liveDisk.mbps(d.read, d.write, at: now) {
            rd = r.a; wr = r.b
        }
        let window = ringWindow
        publishOnMain { self.live.applyTick(time: now, rx: rx, tx: tx, read: rd, write: wr, window: window) }
    }

    /// One snapshot cycle: fetch → patch holes from native counters →
    /// parse-validate (a malformed snapshot never pollutes the DB) →
    /// persist → publish.
    private func sampleNow() {
        let raw: String
        do {
            raw = try deps.status.statusJSON()
        } catch {
            NSLog("Burrow.SnapshotProducer: mo status failed: \(error.localizedDescription)")
            return
        }
        ingest(raw: raw, persist: true)
    }

    /// Patch holes from native counters → parse-validate (a malformed snapshot
    /// never pollutes the DB) → optionally persist → publish. Shared by the poll
    /// (`persist: true` every tick) and the `--watch` stream (persist throttled).
    private func ingest(raw: String, persist: Bool) {
        // Nothing watching and not due for persistence → skip the whole line:
        // no sensor reads, no decode, no publish. That's the `--watch` saving.
        // Persisted lines always run so the long-range history stays complete. #235
        if !persist && !liveWanted { return }
        let now = deps.clock.now
        let sensed = sensors(at: now)               // cached SMC/GPU read
        let fans = sensed.fans
        let temps = sensed.temps
        let disk = deps.hardware.diskBytes().flatMap { snapDisk.mbps($0.read, $0.write, at: now) }
        let fill = SnapshotPatcher.NativeFill(
            disk: disk.map { (read: $0.a, write: $0.b) },
            gpu: sensed.gpu,
            fans: fans.count > 0 ? fans : nil,
            cpuTemp: temps.cpu,
            gpuTemp: temps.gpu)
        let json = SnapshotPatcher.patch(json: raw, fill: fill)
        guard let data = json.data(using: .utf8) else { return }

        let snapshot: MoleStatus
        do {
            snapshot = try dec.decode(MoleStatus.self, from: data)
        } catch let DecodingError.keyNotFound(key, ctx) {
            // Surface the full coding path so a schema drift in `mo` shows
            // up as "missing key 'X' at path [a, b]" rather than the
            // useless "data couldn't be read" localized string.
            let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
            NSLog("Burrow.SnapshotProducer: missing key '\(key.stringValue)' at path '\(path)'")
            return
        } catch let DecodingError.typeMismatch(type, ctx) {
            let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
            NSLog("Burrow.SnapshotProducer: type mismatch (expected \(type)) at path '\(path)' — \(ctx.debugDescription)")
            return
        } catch let DecodingError.valueNotFound(type, ctx) {
            let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
            NSLog("Burrow.SnapshotProducer: nil value where \(type) expected at path '\(path)'")
            return
        } catch let DecodingError.dataCorrupted(ctx) {
            let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
            NSLog("Burrow.SnapshotProducer: data corrupted at path '\(path)' — \(ctx.debugDescription)")
            return
        } catch {
            NSLog("Burrow.SnapshotProducer: JSON decode failed: \(error). First 200b: \(raw.prefix(200))")
            return
        }

        if persist {
            // Mole's `collected_at` (not Date()): if the tick lags, the chart
            // x-axis stays accurate to the sample window.
            let ts = Int(snapshot.collectedAt.timeIntervalSince1970)
            do {
                try deps.sink.persist(ts: ts, json: json)
            } catch {
                NSLog("Burrow.SnapshotProducer: persist failed: \(error.localizedDescription)")
                return
            }
        }

        let at = deps.clock.now
        publishOnMain { self.live.applySnapshot(snapshot, at: at) }
    }

    /// LiveFeed is main-confined; synchronous when already on main so tests
    /// (which drive the clock from the main thread) assert without waiting.
    private func publishOnMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
    }
}

// MARK: - Production adapters

/// `mo status --json` through the shared CLI runner; throws on spawn failure
/// or nonzero exit so the engine's failure model stays "skip this tick".
struct MoCLIStatusSource: StatusSource {
    func statusJSON() throws -> String {
        // Prefer the bundled conductor (burrow status --json): its envelope `data` is the same
        // status JSON the snapshot pipeline decodes + patches, and it runs the bundled engine
        // (no system mo needed). Fall back to the direct engine on any miss.
        if BurrowEngine.isAvailable,
           let envelope = try? BurrowEngine.capture("status", timeout: 8),
           let data = envelope.data,
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        let result = try EngineRunner.shared.capture(
            MoCommand(target: .mo, args: ["status", "--json"], timeout: 8))
        // `stderr=` was empty on every engine failure (the reason is in the `ok:false` envelope
        // on stdout), so this NSError carried an exit code and nothing else into the log the one
        // time anyone would want to read it.
        guard result.exitCode == 0,
              let json = result.payload
                  .map({ String(decoding: $0, as: UTF8.self) }) else {
            let reason = BurrowEnvelope.failureReason(stdout: result.stdout, stderr: result.stderr)
                .map { String($0.prefix(200)) } ?? "no error output"
            throw NSError(domain: "Burrow.MoStatus", code: Int(result.exitCode), userInfo: [
                NSLocalizedDescriptionKey: "mo status exit=\(result.exitCode): \(reason)",
            ])
        }
        // Unwrapped for the same reason the conductor branch above unwraps: `MoleStatus` is a
        // STRICT decoder, and handing it the envelope instead of `data` throws on every required
        // key. That failed loudly enough to skip the tick, so it was never a wrong dashboard —
        // but it was also never a working one, and this branch is the fallback that runs when the
        // conductor path is the one that broke. A legacy `mo` has no envelope and passes through.
        return json
    }
}

/// All three native stacks behind the one counters port: block-storage and
/// interface byte counters, the IOAccelerator utilisation gauge, and the
/// SMC fan/temperature sensors.
final class IOKitHardware: HardwareCounters {
    private let sensors = SensorReader()

    func diskBytes() -> (read: UInt64, write: UInt64)? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOBlockStorageDriver"),
                                           &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        var r: UInt64 = 0, w: UInt64 = 0, found = false
        var svc = IOIteratorNext(iter)
        while svc != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let stats = dict["Statistics"] as? [String: Any] {
                if let rr = (stats["Bytes (Read)"] as? NSNumber)?.uint64Value { r += rr; found = true }
                if let ww = (stats["Bytes (Write)"] as? NSNumber)?.uint64Value { w += ww; found = true }
            }
            IOObjectRelease(svc)
            svc = IOIteratorNext(iter)
        }
        return found ? (r, w) : nil
    }

    func netBytes() -> (rx: UInt64, tx: UInt64)? {
        // NET_RT_IFLIST2 carries the 64-bit counters (if_data64). The
        // getifaddrs route only exposes 32-bit if_data, which wraps every
        // 4 GiB per interface — a guaranteed rate glitch on busy links.
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &len, nil, 0) == 0, len > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, UInt32(mib.count), &buf, &len, nil, 0) == 0 else { return nil }

        var rx: UInt64 = 0, tx: UInt64 = 0, found = false
        buf.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= len {
                // if_msghdr prefix: ifm_msglen (u_short), ifm_version, ifm_type.
                let msglen = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard msglen > 0 else { break }
                let type = raw.loadUnaligned(fromByteOffset: offset + 3, as: UInt8.self)
                if Int32(type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= len {
                    let msg = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var nameBuf = [CChar](repeating: 0, count: Int(IFNAMSIZ) + 1)
                    let name = if_indextoname(UInt32(msg.ifm_index), &nameBuf)
                        .map { String(cString: $0) } ?? ""
                    if !(name.hasPrefix("lo") || name.hasPrefix("gif") || name.hasPrefix("stf")) {
                        rx &+= msg.ifm_data.ifi_ibytes
                        tx &+= msg.ifm_data.ifi_obytes
                        found = true
                    }
                }
                offset += msglen
            }
        }
        return found ? (rx, tx) : nil
    }

    func gpuUtilization() -> Double? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        var best: Double? = nil
        var svc = IOIteratorNext(iter)
        while svc != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let perf = dict["PerformanceStatistics"] as? [String: Any],
               let util = (perf["Device Utilization %"] as? NSNumber)?.doubleValue {
                best = max(best ?? 0, util)
            }
            IOObjectRelease(svc)
            svc = IOIteratorNext(iter)
        }
        return best
    }

    func fans() -> (count: Int, rpm: [Int]) { sensors.fans() }
    func temps() -> (cpu: Double?, gpu: Double?) { sensors.temps() }
}

/// One-shot timers on a private utility queue; `now` is the wall clock.
final class DispatchClock: ProducerClock {
    private let queue = DispatchQueue(label: "dev.caezium.burrow.clock", qos: .utility)
    var now: Date { Date() }

    private final class Token: ClockCancellable {
        let timer: DispatchSourceTimer
        init(_ timer: DispatchSourceTimer) { self.timer = timer }
        func cancel() { timer.cancel() }
    }

    @discardableResult
    func schedule(after: TimeInterval, _ body: @escaping () -> Void) -> ClockCancellable {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + after, repeating: .never, leeway: .milliseconds(250))
        t.setEventHandler(handler: body)
        t.resume()
        return Token(t)
    }
}

/// Owns the row prefix; persists the exact patched JSON keyed by mo's
/// `collected_at` timestamp.
final class DBSnapshotSink: SnapshotSink {
    private let db: DB
    init(db: DB) { self.db = db }
    func persist(ts: Int, json: String) throws {
        try db.insert(prefix: MetricsStore.snapshotPrefix, ts: ts, json: json)
    }
}
