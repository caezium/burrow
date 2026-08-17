//
//  Telemetry.swift
//  Burrow
//
//  Anonymous product analytics sent to PostHog through a deliberately small
//  first-party transport. All disk and network work runs on a private serial
//  queue; there is no SDK run-loop timer, remote config, autocapture, replay,
//  or logging integration in the process.
//

import Foundation
import Combine

enum Telemetry {

    enum DeliveryDisposition: Equatable {
        case delivered
        case retry
        case discard
    }

    private enum Signal {
        case event(String, [String: Any])
        case screen(String)
    }

    private struct DeliveryConfiguration {
        let projectKey: String
        let endpoint: URL
    }

    private static let stateLock = NSLock()
    private static let workQueue = DispatchQueue(
        label: "dev.caezium.Burrow.telemetry.posthog",
        qos: .utility
    )
    private static let deliveries = DispatchGroup()
    private static let timestampFormatter = ISO8601DateFormatter()
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    private static var started = false
    private static var deliveryConfiguration: DeliveryConfiguration?
    /// Accessed only on `workQueue`.
    private static var distinctID: String?
    /// Accessed only on `workQueue`.
    private static var inFlightTasks: [UUID: URLSessionDataTask] = [:]
    /// Accessed only on `workQueue`.
    private static var inFlightOutboxFiles: Set<URL> = []
    /// Accessed only on `workQueue`. Historical outbox delivery is serialized
    /// and driven by later semantic events, never by a run-loop timer.
    private static var outboxRetryInFlight = false
    /// Accessed only on `workQueue`.
    private static var outboxRetryFailures = 0
    /// Accessed only on `workQueue`.
    private static var nextOutboxRetryAt = Date.distantPast
    private static let outboxLimit = 64

    /// In-memory accepted flag values; the source of truth for evaluation.
    /// Written on `workQueue`, read anywhere under `stateLock`.
    private static var flagSnapshot = RemoteFeatureFlags.Snapshot.empty
    /// Accessed only on `workQueue`.
    private static var flagFetchInFlight = false
    private static var flagFetchFailures = 0
    private static var nextFlagFetchAt = Date.distantPast
    /// Flag keys already exposed this launch. Guarded by `stateLock`.
    private static var exposedFlagKeys: Set<String> = []

    /// The single persisted gate shared with Sentry.
    static var isEnabled: Bool {
        get { Store.telemetryEnabled }
        set { Store.telemetryEnabled = newValue }
    }

    // MARK: - Lifecycle

    /// Installs Sentry synchronously, then schedules PostHog delivery only when
    /// the release key is present and the user has not opted out. With analytics
    /// disabled, no PostHog object, identifier, file, or request is created.
    static func start() {
        stateLock.lock()
        guard !started else {
            stateLock.unlock()
            return
        }
        started = true

        let info = Bundle.main.infoDictionary
        let projectKey = (info?["PHPostHogApiKey"] as? String) ?? ""
        let host = (info?["PHPostHogHost"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? "https://us.i.posthog.com"
        if !projectKey.isEmpty, let endpoint = postHogEndpoint(host: host) {
            deliveryConfiguration = DeliveryConfiguration(projectKey: projectKey, endpoint: endpoint)
        }
        let delivery = deliveryConfiguration
        stateLock.unlock()

        // The crash handler must be installed at launch, before background
        // service setup. It is a no-op without a release DSN.
        CrashReporter.start(enabled: isEnabled)

        guard let delivery, isEnabled else { return }
        CrashReporter.breadcrumb("app_opened", category: "lifecycle")
        enqueue(.event("app_opened", ["cold_start": true]), using: delivery)
        reloadFeatureFlagCache()
        refreshFeatureFlags(using: delivery)
    }

    /// Best-effort termination flush. Every event has already started its own
    /// background request; this only gives those requests a short grace period.
    static func flush() {
        stateLock.lock()
        let canFlush = started && deliveryConfiguration != nil
        stateLock.unlock()
        guard canFlush else { return }

        CrashReporter.withoutAppHangTracking {
            // Ensure all caller-side enqueue blocks have started their request
            // before waiting on the in-flight group.
            workQueue.sync {}
            _ = deliveries.wait(timeout: .now() + 1)
        }
    }

    // MARK: - Capture

    /// Records a fixed-name product event. Properties are sanitized before any
    /// background work; callers must bucket sizes/counts/durations first.
    static func capture(_ event: String, _ props: [String: Any] = [:]) {
        guard DiagnosticPrivacy.isSafeIdentifier(event), isEnabled else { return }
        let sanitized = DiagnosticPrivacy.sanitize(props)
        guard let delivery = activeDeliveryConfiguration() else { return }

        CrashReporter.breadcrumb(event, category: "product", data: sanitized)
        enqueue(.event(event, sanitized), using: delivery)
    }

    /// Semantic navigation only. `$screen` contains a fixed pane name, never a
    /// screenshot, element tree, typed text, window title, or pixel recording.
    static func screen(_ pane: Pane) {
        let name: String
        switch pane {
        case .home: name = "home"
        case .settings: name = "settings"
        case .tool(let tool): name = "tool.\(tool.rawValue)"
        }
        guard DiagnosticPrivacy.isSafeIdentifier(name), isEnabled,
              let delivery = activeDeliveryConfiguration() else { return }

        CrashReporter.breadcrumb("screen_viewed", category: "navigation", data: ["screen": name])
        enqueue(.screen(name), using: delivery)
    }

    // MARK: - Opt-out toggle

    /// Applies the shared switch immediately. A launch that begins opted out
    /// performs no PostHog request. When an enabled user turns it off, one final
    /// fixed opt-out event is queued before all subsequent events are rejected.
    static func setEnabled(_ enabled: Bool) {
        let previous = isEnabled
        guard previous != enabled else { return }

        isEnabled = enabled
        CrashReporter.setEnabled(enabled)
        guard let delivery = configuredDelivery() else { return }

        if enabled {
            capture("telemetry_opt_in_changed", ["enabled": true])
            reloadFeatureFlagCache()
            refreshFeatureFlags(using: delivery)
        } else {
            workQueue.async {
                cancelInFlightDeliveries()
                clearFeatureFlagState()
                sendNow(.event("telemetry_opt_in_changed", ["enabled": false]), using: delivery)
            }
        }
    }

    // MARK: - Feature flags (cached, conservative, UI-only)

    /// Current effective value for an allowlisted flag: the fresh cached value
    /// or the baked-in conservative default. Synchronous and pure — it never
    /// touches the network or disk. With telemetry off the snapshot is empty,
    /// so callers always get the default and no exposure is recorded.
    static func featureFlagValue(for key: RemoteFeatureFlags.Key) -> RemoteFeatureFlags.Value {
        let snapshot = currentFlagSnapshot()
        let value = RemoteFeatureFlags.evaluate(key, snapshot: snapshot, now: Date())
        reportFeatureFlagExposure(key, value: value)
        return value
    }

    static func featureFlagBool(_ key: RemoteFeatureFlags.Key) -> Bool {
        switch featureFlagValue(for: key) {
        case .bool(let value): return value
        default: return false
        }
    }

    /// Reads the on-disk flag cache into memory once per launch, only while
    /// telemetry is enabled. An opted-out launch never reaches here.
    private static func reloadFeatureFlagCache() {
        workQueue.async {
            guard isEnabled, currentFlagSnapshot().isEmpty else { return }
            guard let url = featureFlagCacheURL(),
                  let data = try? Data(contentsOf: url),
                  let snapshot = RemoteFeatureFlags.decodeSnapshot(data) else { return }
            setFlagSnapshot(snapshot)
        }
    }

    /// Work-queue entry point: fetch flags once with serialized/backed-off
    /// retries driven by later product events — never a run-loop timer.
    private static func refreshFeatureFlags(using delivery: DeliveryConfiguration) {
        workQueue.async { refreshFeatureFlagsIfDue(using: delivery) }
    }

    private static func refreshFeatureFlagsIfDue(using delivery: DeliveryConfiguration) {
        guard isEnabled, !flagFetchInFlight, Date() >= nextFlagFetchAt else { return }
        guard let request = featureFlagRequest(using: delivery) else { return }
        flagFetchInFlight = true

        let requestID = UUID()
        deliveries.enter()
        let task = session.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            let disposition = deliveryDisposition(statusCode: status, hasTransportError: error != nil)
            workQueue.async {
                inFlightTasks.removeValue(forKey: requestID)
                flagFetchInFlight = false
                defer { deliveries.leave() }

                // A mid-session opt-out must not be overwritten by a request
                // that was already in flight when the user flipped the switch.
                guard isEnabled else { return }

                switch disposition {
                case .delivered:
                    flagFetchFailures = 0
                    nextFlagFetchAt = .distantPast
                    guard let data,
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    else { return }
                    let snapshot = RemoteFeatureFlags.snapshot(from: object, now: Date())
                    persistFeatureFlagSnapshot(snapshot)
                    setFlagSnapshot(snapshot)
                case .retry:
                    flagFetchFailures += 1
                    nextFlagFetchAt = Date().addingTimeInterval(
                        retryDelay(afterFailure: flagFetchFailures)
                    )
                case .discard:
                    // A permanent rejection cannot be usefully retried; re-check
                    // no sooner than the cache's own trust window.
                    flagFetchFailures = 0
                    nextFlagFetchAt = Date().addingTimeInterval(RemoteFeatureFlags.maxCacheAge)
                }
            }
        }
        inFlightTasks[requestID] = task
        task.resume()
    }

    private static func featureFlagRequest(using delivery: DeliveryConfiguration) -> URLRequest? {
        guard let endpoint = decideEndpoint(from: delivery.endpoint) else { return nil }
        // The only fields ever sent: the release-injected project key and the
        // random anonymous distinct id. No user content, no arbitrary properties.
        let payload: [String: Any] = [
            "token": delivery.projectKey,
            "distinct_id": resolveDistinctID(projectKey: delivery.projectKey),
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Burrow/\(RuntimeEnvironment.current.appVersion)", forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        return request
    }

    /// `/decide/` lives beside `/batch/` under the same host root.
    static func decideEndpoint(from batchEndpoint: URL) -> URL? {
        let base = batchEndpoint.deletingLastPathComponent()
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        let basePath = components.path.hasSuffix("/") ? components.path : components.path + "/"
        components.path = basePath + "decide"
        components.queryItems = [URLQueryItem(name: "v", value: "3")]
        return components.url
    }

    private static func persistFeatureFlagSnapshot(_ snapshot: RemoteFeatureFlags.Snapshot) {
        guard let url = featureFlagCacheURL(),
              let data = RemoteFeatureFlags.encodedSnapshot(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    private static func featureFlagCacheURL() -> URL? {
        applicationSupportDirectory()?.appendingPathComponent("feature-flags.json")
    }

    /// Records a PostHog `$feature_flag_called` exposure once per flag per
    /// launch, only while telemetry is enabled. The response is the typed,
    /// allowlisted value — never user content.
    private static func reportFeatureFlagExposure(
        _ key: RemoteFeatureFlags.Key,
        value: RemoteFeatureFlags.Value
    ) {
        stateLock.lock()
        let isNew = !exposedFlagKeys.contains(key.rawValue)
        if isNew { exposedFlagKeys.insert(key.rawValue) }
        let delivery = deliveryConfiguration
        let enabled = started && isEnabled
        stateLock.unlock()

        guard isNew, enabled, let delivery else { return }

        let response: Any
        switch value {
        case .bool(let v): response = v
        case .int(let v): response = v
        case .string(let v): response = DiagnosticPrivacy.redact(v)
        }
        enqueue(.event("$feature_flag_called", [
            "$feature_flag": key.rawValue,
            "$feature_flag_response": response,
        ]), using: delivery)
    }

    private static func currentFlagSnapshot() -> RemoteFeatureFlags.Snapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        return flagSnapshot
    }

    private static func setFlagSnapshot(_ snapshot: RemoteFeatureFlags.Snapshot) {
        stateLock.lock()
        flagSnapshot = snapshot
        stateLock.unlock()
        publishFlagSnapshot(snapshot)
    }

    private static func clearFeatureFlagState() {
        stateLock.lock()
        flagSnapshot = .empty
        exposedFlagKeys.removeAll()
        stateLock.unlock()
        flagFetchInFlight = false
        flagFetchFailures = 0
        nextFlagFetchAt = .distantPast
        publishFlagSnapshot(.empty)
    }

    /// Mirrors the evaluation snapshot to the SwiftUI-observable holder on the
    /// main thread so views re-render when a background refresh lands.
    private static func publishFlagSnapshot(_ snapshot: RemoteFeatureFlags.Snapshot) {
        DispatchQueue.main.async { FeatureFlags.shared.update(snapshot) }
    }

    // MARK: - Bucketing (never send raw sizes/counts/durations)

    static func bytesBucket(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_000_000
        switch mb {
        case ..<1:      return "<1MB"
        case ..<10:     return "1-10MB"
        case ..<100:    return "10-100MB"
        case ..<1_000:  return "100MB-1GB"
        case ..<10_000: return "1-10GB"
        default:        return ">10GB"
        }
    }

    static func countBucket(_ n: Int) -> String {
        switch n {
        case ..<1:    return "0"
        case ..<10:   return "1-9"
        case ..<100:  return "10-99"
        case ..<1000: return "100-999"
        default:      return "1000+"
        }
    }

    static func secondsBucket(_ s: Double) -> String {
        switch s {
        case ..<1:   return "<1s"
        case ..<5:   return "1-5s"
        case ..<30:  return "5-30s"
        case ..<120: return "30-120s"
        default:     return ">2m"
        }
    }

    // MARK: - Background transport

    private static func activeDeliveryConfiguration() -> DeliveryConfiguration? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard started, isEnabled else { return nil }
        return deliveryConfiguration
    }

    private static func configuredDelivery() -> DeliveryConfiguration? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard started else { return nil }
        return deliveryConfiguration
    }

    private static func enqueue(_ signal: Signal, using delivery: DeliveryConfiguration) {
        workQueue.async {
            // Re-check at execution time so a queued event cannot escape after
            // the user flips the switch off.
            guard isEnabled else { return }
            drainOutbox(using: delivery)
            refreshFeatureFlagsIfDue(using: delivery)
            sendNow(signal, using: delivery)
        }
    }

    /// Runs exclusively on `workQueue`; JSON encoding, identifier disk I/O,
    /// and URLSession request construction never block AppKit's main thread.
    private static func sendNow(_ signal: Signal, using delivery: DeliveryConfiguration) {
        let event: String
        var properties: [String: Any]
        switch signal {
        case .event(let name, let supplied):
            event = name
            properties = supplied
        case .screen(let name):
            event = "$screen"
            properties = ["$screen_name": name]
        }

        properties.merge(superProperties()) { current, _ in current }
        let now = timestampFormatter.string(from: Date())
        let eventPayload: [String: Any] = [
            "event": event,
            "distinct_id": resolveDistinctID(projectKey: delivery.projectKey),
            "properties": properties,
            "timestamp": now,
            "uuid": UUID().uuidString.lowercased(),
        ]
        let payload: [String: Any] = [
            "api_key": delivery.projectKey,
            "batch": [eventPayload],
            "sent_at": now,
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        let outboxFile = persistToOutbox(body)
        deliver(body, outboxFile: outboxFile, isOutboxRetry: false, using: delivery)
    }

    private static func deliver(
        _ body: Data,
        outboxFile: URL?,
        isOutboxRetry: Bool,
        using delivery: DeliveryConfiguration
    ) {
        if let outboxFile {
            guard !inFlightOutboxFiles.contains(outboxFile) else { return }
            inFlightOutboxFiles.insert(outboxFile)
        }

        var request = URLRequest(url: delivery.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Burrow/\(RuntimeEnvironment.current.appVersion)", forHTTPHeaderField: "User-Agent")
        request.httpBody = body

        let requestID = UUID()
        deliveries.enter()
        let task = session.dataTask(with: request) { _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            let disposition = deliveryDisposition(statusCode: status, hasTransportError: error != nil)
            workQueue.async {
                inFlightTasks.removeValue(forKey: requestID)
                if let outboxFile {
                    inFlightOutboxFiles.remove(outboxFile)
                    if disposition != .retry {
                        try? FileManager.default.removeItem(at: outboxFile)
                    }
                }
                if isOutboxRetry {
                    outboxRetryInFlight = false
                    switch disposition {
                    case .delivered, .discard:
                        outboxRetryFailures = 0
                        nextOutboxRetryAt = .distantPast
                    case .retry:
                        outboxRetryFailures += 1
                        nextOutboxRetryAt = Date().addingTimeInterval(
                            retryDelay(afterFailure: outboxRetryFailures)
                        )
                    }
                }
                deliveries.leave()
            }
        }
        inFlightTasks[requestID] = task
        task.resume()
    }

    /// A bounded disk outbox makes startup/update breadcrumbs survive a lost
    /// network or forced reboot. It is touched only while telemetry is enabled,
    /// and contains the same already-sanitized JSON that is sent to PostHog.
    private static func persistToOutbox(_ body: Data) -> URL? {
        guard let directory = applicationSupportDirectory()?.appendingPathComponent(
            "telemetry-outbox",
            isDirectory: true
        ) else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let existing = outboxFiles(in: directory)
        var remainingCount = existing.count
        if remainingCount >= outboxLimit {
            for file in existing where remainingCount >= outboxLimit {
                guard !inFlightOutboxFiles.contains(file) else { continue }
                try? FileManager.default.removeItem(at: file)
                remainingCount -= 1
            }
        }
        guard remainingCount < outboxLimit else { return nil }

        let fileURL = directory.appendingPathComponent("\(UUID().uuidString.lowercased()).json")
        do {
            try body.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            return nil
        }
    }

    private static func drainOutbox(using delivery: DeliveryConfiguration) {
        guard !outboxRetryInFlight, Date() >= nextOutboxRetryAt else { return }
        guard let directory = applicationSupportDirectory()?.appendingPathComponent(
            "telemetry-outbox",
            isDirectory: true
        ) else { return }

        // Retry at most one historical event at a time. This prevents a full
        // 64-item outbox from turning one product event into 65 requests during
        // an outage; later semantic events advance the drain after backoff.
        for file in outboxFiles(in: directory) where !inFlightOutboxFiles.contains(file) {
            guard let body = try? Data(contentsOf: file) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            outboxRetryInFlight = true
            deliver(body, outboxFile: file, isOutboxRetry: true, using: delivery)
            return
        }
    }

    private static func outboxFiles(in directory: URL) -> [URL] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .sorted {
                let lhs = try? $0.resourceValues(forKeys: keys).contentModificationDate
                let rhs = try? $1.resourceValues(forKeys: keys).contentModificationDate
                return (lhs ?? .distantPast) < (rhs ?? .distantPast)
            }
    }

    private static func cancelInFlightDeliveries() {
        for task in inFlightTasks.values { task.cancel() }
    }

    static func deliveryDisposition(
        statusCode: Int?,
        hasTransportError: Bool
    ) -> DeliveryDisposition {
        if hasTransportError || statusCode == nil { return .retry }
        guard let statusCode else { return .retry }
        if (200 ... 299).contains(statusCode) { return .delivered }
        if statusCode == 408 || statusCode == 425 || statusCode == 429 || statusCode >= 500 {
            return .retry
        }
        // Redirects have already been followed by URLSession. Any remaining
        // 3xx/4xx is a permanent payload/auth/configuration rejection; keeping
        // it would retry forever and eventually crowd out useful new events.
        return .discard
    }

    static func retryDelay(afterFailure failure: Int) -> TimeInterval {
        let exponent = min(max(failure - 1, 0), 7)
        return min(30 * pow(2, Double(exponent)), 3_600)
    }

    private static func superProperties() -> [String: Any] {
        let environment = RuntimeEnvironment.current
        return [
            // PostHog uses this instead of the connection IP, which disables
            // IP persistence and GeoIP enrichment for the event.
            "$ip": "0",
            "$lib": "burrow-macos",
            "$lib_version": environment.appVersion,
            "$process_person_profile": false,
            "platform": "macos",
            "app_version": environment.appVersion,
            "build_number": environment.appBuild,
            "os_version": environment.osVersion,
            "os_build": environment.osBuild,
            "os_prerelease": environment.isPrereleaseOS,
            "arch": environment.architecture,
            "locale": Locale.current.identifier,
        ]
    }

    static func postHogEndpoint(host: String) -> URL? {
        guard let base = URL(string: host),
              base.scheme == "https",
              base.host != nil,
              base.user == nil,
              base.password == nil,
              base.query == nil,
              base.fragment == nil else { return nil }
        return base.appendingPathComponent("batch")
    }

    /// Stable random install id, resolved only after telemetry is enabled. For
    /// existing 0.11.0 installs, migrate the UUID created by posthog-ios so an
    /// updater release does not split retention and update funnels.
    private static func resolveDistinctID(projectKey: String) -> String {
        if let distinctID { return distinctID }

        guard let directory = applicationSupportDirectory() else {
            let generated = UUID().uuidString.lowercased()
            distinctID = generated
            return generated
        }
        let fileURL = directory.appendingPathComponent("telemetry-id")
        if let existing = try? String(contentsOf: fileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let normalized = normalizedAnonymousID(existing) {
            distinctID = normalized
            return normalized
        }

        if let root = applicationSupportRoot(),
           let migrated = migrateLegacyPostHogAnonymousID(
               projectKey: projectKey,
               applicationSupportRoot: root,
               destination: fileURL
           ) {
            distinctID = migrated
            return migrated
        }

        let generated = UUID().uuidString.lowercased()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(generated.utf8).write(to: fileURL, options: .atomic)
        distinctID = generated
        return generated
    }

    /// posthog-ios 3.x stored its anonymous UUID as a tiny JSON object under
    /// Application Support/<bundle id>/<project key>/posthog.anonymousId.
    /// Read only that exact, bounded file and accept only a UUID before copying
    /// it into Burrow's first-party transport location.
    @discardableResult
    static func migrateLegacyPostHogAnonymousID(
        projectKey: String,
        applicationSupportRoot: URL,
        destination: URL
    ) -> String? {
        guard isSafePostHogProjectKey(projectKey) else { return nil }
        let source = applicationSupportRoot
            .appendingPathComponent("dev.caezium.Burrow", isDirectory: true)
            .appendingPathComponent(projectKey, isDirectory: true)
            .appendingPathComponent("posthog.anonymousId")
        guard let values = try? source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let size = values.fileSize,
              (1 ... 1_024).contains(size),
              let data = try? Data(contentsOf: source),
              let decoded = try? JSONSerialization.jsonObject(with: data),
              let object = decoded as? [String: Any],
              let rawID = object["posthog.anonymousId"] as? String,
              let anonymousID = normalizedAnonymousID(rawID) else { return nil }

        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(anonymousID.utf8).write(to: destination, options: .atomic)
            return anonymousID
        } catch {
            return nil
        }
    }

    private static func normalizedAnonymousID(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let uuid = UUID(uuidString: trimmed) else { return nil }
        return uuid.uuidString.lowercased()
    }

    private static func isSafePostHogProjectKey(_ value: String) -> Bool {
        let bytes = value.utf8
        guard (1 ... 256).contains(bytes.count) else { return false }
        return bytes.allSatisfy { byte in
            (48 ... 57).contains(byte)
                || (65 ... 90).contains(byte)
                || (97 ... 122).contains(byte)
                || byte == 45
                || byte == 95
        }
    }

    private static func applicationSupportDirectory() -> URL? {
        applicationSupportRoot()?.appendingPathComponent("Burrow", isDirectory: true)
    }

    private static func applicationSupportRoot() -> URL? {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
    }
}

/// SwiftUI-observable holder for the accepted flag snapshot. Telemetry mirrors
/// every snapshot change here on the main thread (see `publishFlagSnapshot`);
/// views observe the shared instance so a background refresh re-renders them
/// instead of leaving a static flag read stale.
final class FeatureFlags: ObservableObject {
    static let shared = FeatureFlags()

    @Published private(set) var snapshot: RemoteFeatureFlags.Snapshot = .empty

    func update(_ snapshot: RemoteFeatureFlags.Snapshot) {
        self.snapshot = snapshot
    }

    /// Evaluates `key` and records its exposure via `Telemetry`, while reading
    /// `snapshot` so the calling view also re-renders when the cache refreshes.
    func boolValue(_ key: RemoteFeatureFlags.Key) -> Bool {
        _ = snapshot
        return Telemetry.featureFlagBool(key)
    }
}
