//
//  RemoteFeatureFlags.swift
//  Burrow
//
//  Privacy-safe, cached PostHog feature flags for gradual rollout and
//  product/UI experiments. Only an explicit allowlist of fixed, non-safety-
//  critical keys is ever accepted; every value is typed, locally cached, and
//  backed by a conservative baked-in default so startup and evaluation never
//  depend on PostHog availability.
//
//  This file is pure policy: parsing, typing, allowlisting, cache encode/decode,
//  and evaluation. `Telemetry.swift` owns the queue, network request, storage,
//  opt-out gating, and exposure events, and only ever hands this type decoded,
//  bounded JSON.
//

import Foundation

enum RemoteFeatureFlags {

    // MARK: - Allowlist

    /// The only remote flag keys Burrow will ever accept. Keys are fixed,
    /// documented in TELEMETRY.md, and restricted to harmless UI/rollout
    /// choices. PostHog may return anything; anything not listed here is
    /// ignored.
    enum Key: String, CaseIterable, Codable {
        /// A cosmetic badge on the Tune-Up section. Harmless, UI-only, off by
        /// default — the first rollout validation target.
        case tuneUpBadge = "tune_up_badge"

        /// The remote value shape this key accepts. A value that decodes to a
        /// different shape is treated as malformed and dropped.
        var expectedType: ValueType {
            switch self {
            case .tuneUpBadge: return .bool
            }
        }

        /// Conservative baked-in default, returned whenever the remote value is
        /// absent, stale, malformed, or the network is unreachable.
        var defaultValue: Value {
            switch self {
            case .tuneUpBadge: return .bool(false)
            }
        }
    }

    enum ValueType: String, Codable, Equatable {
        case bool
        case string
        case int
    }

    /// A decoded, typed flag value. Only these three shapes are accepted.
    enum Value: Equatable {
        case bool(Bool)
        case string(String)
        case int(Int)
    }

    // MARK: - Cache format

    /// The on-disk cache. Bounded in size and age; only values that passed the
    /// allowlist and type checks are ever written, so `evaluate` looks up only
    /// allowlisted keys regardless of what a hand-edited file contains.
    struct Snapshot: Codable, Equatable {
        static let empty = Snapshot(fetchedAt: .distantPast, bools: [:], strings: [:], ints: [:])

        var fetchedAt: Date
        var bools: [String: Bool]
        var strings: [String: String]
        var ints: [String: Int]

        var isEmpty: Bool { bools.isEmpty && strings.isEmpty && ints.isEmpty }
    }

    /// A cached snapshot stays trusted this long. Older snapshots fall back to
    /// defaults until a fresh fetch succeeds.
    static let maxCacheAge: TimeInterval = 24 * 60 * 60

    /// Hard ceiling on the encoded cache size. The allowlist is tiny and values
    /// are primitive, so a well-formed cache never approaches this; the bound
    /// stops a corrupted file from growing unbounded.
    static let maxCacheBytes = 8 * 1_024

    // MARK: - Decide-response parsing

    /// Extract the allowlisted, typed values from a PostHog `/decide/` response
    /// body (already decoded to JSON). Unknown keys, wrong-typed values, and
    /// malformed payloads are ignored; the returned snapshot contains only
    /// values that passed every check.
    ///
    /// PostHog returns `featureFlags` as an array of enabled keys (legacy) or
    /// as an object mapping key → `Bool`/variant `String`, plus an optional
    /// `featureFlagPayloads` object mapping key → JSON-encoded payload string.
    static func snapshot(from decideObject: [String: Any], now: Date) -> Snapshot {
        var bools: [String: Bool] = [:]
        var strings: [String: String] = [:]
        var ints: [String: Int] = [:]

        let flagField = decideObject["featureFlags"]
        let payloads = decideObject["featureFlagPayloads"] as? [String: String] ?? [:]

        for key in Key.allCases {
            // 1. A payload, when present, is the source of truth for the value.
            if let rawPayload = payloads[key.rawValue],
               let value = decodedValue(fromPayload: rawPayload, expected: key.expectedType) {
                store(value, for: key, bools: &bools, strings: &strings, ints: &ints)
                continue
            }
            // 2. Otherwise fall back to the flag's enable/variant state.
            guard let remote = flagValue(named: key.rawValue, in: flagField) else { continue }
            if let value = typedValue(fromFlagValue: remote, expected: key.expectedType) {
                store(value, for: key, bools: &bools, strings: &strings, ints: &ints)
            }
        }

        return Snapshot(fetchedAt: now, bools: bools, strings: strings, ints: ints)
    }

    // MARK: - Cache encode/decode

    /// Encode a snapshot for the on-disk cache, or `nil` if it would exceed the
    /// size bound (callers then simply keep the previous cache).
    static func encodedSnapshot(_ snapshot: Snapshot) -> Data? {
        guard let data = try? JSONEncoder().encode(snapshot) else { return nil }
        guard data.count <= maxCacheBytes else { return nil }
        return data
    }

    /// Decode a cache file, or `nil` if it is oversized, unreadable, or empty.
    static func decodeSnapshot(_ data: Data) -> Snapshot? {
        guard data.count <= maxCacheBytes,
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              !snapshot.isEmpty else { return nil }
        return snapshot
    }

    /// Whether a snapshot is still within its trust window. Future-dated or
    /// empty snapshots are stale so a clock-skewed file falls back to defaults.
    static func isFresh(_ snapshot: Snapshot, now: Date, maxAge: TimeInterval = maxCacheAge) -> Bool {
        guard !snapshot.isEmpty else { return false }
        let age = now.timeIntervalSince(snapshot.fetchedAt)
        return age >= 0 && age <= maxAge
    }

    // MARK: - Evaluation

    /// The effective value for a key: the fresh cached value when one exists,
    /// otherwise the baked-in conservative default. Synchronous and pure — never
    /// touches the network. An opted-out process passes no snapshot (or an
    /// empty one) and therefore always receives the default.
    static func evaluate(_ key: Key, snapshot: Snapshot?, now: Date = Date()) -> Value {
        guard let snapshot, isFresh(snapshot, now: now) else { return key.defaultValue }
        switch key.expectedType {
        case .bool:
            if let value = snapshot.bools[key.rawValue] { return .bool(value) }
        case .string:
            if let value = snapshot.strings[key.rawValue] { return .string(value) }
        case .int:
            if let value = snapshot.ints[key.rawValue] { return .int(value) }
        }
        return key.defaultValue
    }

    // MARK: - Private parsing helpers

    private static func store(
        _ value: Value,
        for key: Key,
        bools: inout [String: Bool],
        strings: inout [String: String],
        ints: inout [String: Int]
    ) {
        switch value {
        case .bool(let v): bools[key.rawValue] = v
        case .string(let v): strings[key.rawValue] = v
        case .int(let v): ints[key.rawValue] = v
        }
    }

    private static func flagValue(named key: String, in flagField: Any?) -> Any? {
        if let array = flagField as? [String] {
            return array.contains(key) ? true : nil
        }
        if let object = flagField as? [String: Any] {
            return object[key]
        }
        return nil
    }

    private static func decodedValue(fromPayload raw: String, expected: ValueType) -> Value? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(
                  with: data,
                  options: [.fragmentsAllowed]
              ) else { return nil }
        return typedValue(object, expected: expected)
    }

    private static func typedValue(fromFlagValue remote: Any, expected: ValueType) -> Value? {
        switch expected {
        case .int:
            // A bare enable/variant state carries no number; ints come only from
            // JSON payloads.
            return nil
        case .bool, .string:
            return typedValue(remote, expected: expected)
        }
    }

    private static func typedValue(_ object: Any, expected: ValueType) -> Value? {
        switch expected {
        case .bool:
            guard let value = object as? Bool else { return nil }
            return .bool(value)
        case .string:
            guard let value = object as? String else { return nil }
            return .string(value)
        case .int:
            guard let value = integerValue(object) else { return nil }
            return .int(value)
        }
    }

    /// Accept only an integral JSON number — never a Boolean (`true`/`false`
    /// box as `NSNumber`) or a fractional/out-of-range double. `Int(exactly:)`
    /// returns `nil` for fractional and out-of-range values, so `2^63`
    /// (`Double(Int.max)` rounds up to it) cannot trap.
    static func integerValue(_ object: Any) -> Int? {
        if object is Bool { return nil }
        if let value = object as? Int { return value }
        if let value = object as? Int64 { return Int(exactly: value) }
        if let value = object as? Double { return Int(exactly: value) }
        return nil
    }
}
