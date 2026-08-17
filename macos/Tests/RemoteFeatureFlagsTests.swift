//
//  RemoteFeatureFlagsTests.swift
//  BurrowTests
//
//  Policy tests for the privacy-safe, cached PostHog feature flags. The pure
//  parsing/evaluation logic lives in RemoteFeatureFlags; Telemetry owns the
//  queue, network, storage, and opt-out gating.
//

import XCTest
@testable import Burrow

final class RemoteFeatureFlagsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Conservative defaults

    func testEveryKeyHasAConservativeDefault() {
        for key in RemoteFeatureFlags.Key.allCases {
            // Every allowlisted key must declare a default; evaluate with no
            // snapshot must return exactly that default.
            XCTAssertEqual(
                RemoteFeatureFlags.evaluate(key, snapshot: nil, now: now),
                key.defaultValue
            )
        }
        XCTAssertEqual(RemoteFeatureFlags.Key.tuneUpBadge.defaultValue, .bool(false))
    }

    // MARK: - Opt-out / no-snapshot inertness

    func testEvaluationWithoutSnapshotReturnsDefault() {
        XCTAssertEqual(
            RemoteFeatureFlags.evaluate(.tuneUpBadge, snapshot: nil, now: now),
            .bool(false)
        )
        XCTAssertEqual(
            RemoteFeatureFlags.evaluate(.tuneUpBadge, snapshot: .empty, now: now),
            .bool(false)
        )
    }

    // MARK: - Stale cache

    func testStaleSnapshotFallsBackToDefault() {
        let fresh = RemoteFeatureFlags.Snapshot(
            fetchedAt: now.addingTimeInterval(-60),
            bools: ["tune_up_badge": true],
            strings: [:],
            ints: [:]
        )
        XCTAssertEqual(RemoteFeatureFlags.evaluate(.tuneUpBadge, snapshot: fresh, now: now), .bool(true))

        let stale = RemoteFeatureFlags.Snapshot(
            fetchedAt: now.addingTimeInterval(-(RemoteFeatureFlags.maxCacheAge + 1)),
            bools: ["tune_up_badge": true],
            strings: [:],
            ints: [:]
        )
        XCTAssertEqual(RemoteFeatureFlags.evaluate(.tuneUpBadge, snapshot: stale, now: now), .bool(false))
    }

    func testFutureDatedSnapshotIsStale() {
        let future = RemoteFeatureFlags.Snapshot(
            fetchedAt: now.addingTimeInterval(60),
            bools: ["tune_up_badge": true],
            strings: [:],
            ints: [:]
        )
        XCTAssertFalse(RemoteFeatureFlags.isFresh(future, now: now))
        XCTAssertEqual(RemoteFeatureFlags.evaluate(.tuneUpBadge, snapshot: future, now: now), .bool(false))
    }

    // MARK: - Malformed cache

    func testMalformedCacheIsRejected() {
        XCTAssertNil(RemoteFeatureFlags.decodeSnapshot(Data("not json".utf8)))
        XCTAssertNil(RemoteFeatureFlags.decodeSnapshot(Data("{".utf8)))

        // Oversized cache is rejected.
        let oversized = Data(repeating: 0x61, count: RemoteFeatureFlags.maxCacheBytes + 1)
        XCTAssertNil(RemoteFeatureFlags.decodeSnapshot(oversized))
    }

    func testEmptyCacheIsRejected() throws {
        let empty = RemoteFeatureFlags.Snapshot.empty
        let data = try XCTUnwrap(RemoteFeatureFlags.encodedSnapshot(empty))
        XCTAssertNil(RemoteFeatureFlags.decodeSnapshot(data))
    }

    func testCacheRoundTripPreservesValues() throws {
        let snapshot = RemoteFeatureFlags.Snapshot(
            fetchedAt: now,
            bools: ["tune_up_badge": true],
            strings: ["some_future_flag": "variant"],
            ints: ["some_int_flag": 7]
        )
        let data = try XCTUnwrap(RemoteFeatureFlags.encodedSnapshot(snapshot))
        XCTAssertEqual(RemoteFeatureFlags.decodeSnapshot(data), snapshot)
    }

    // MARK: - Allowlist / unknown keys

    func testUnknownKeysAreIgnored() {
        let object: [String: Any] = [
            "featureFlags": [
                "tune_up_badge": true,
                "some_unknown_flag": true,
                "another_flag": "variant",
            ],
        ]
        let snapshot = RemoteFeatureFlags.snapshot(from: object, now: now)
        XCTAssertEqual(snapshot.bools, ["tune_up_badge": true])
        XCTAssertTrue(snapshot.strings.isEmpty)
        XCTAssertTrue(snapshot.ints.isEmpty)
    }

    func testLegacyArrayFlagFormatIsAccepted() {
        let object: [String: Any] = [
            "featureFlags": ["tune_up_badge", "some_unknown_flag"],
        ]
        let snapshot = RemoteFeatureFlags.snapshot(from: object, now: now)
        XCTAssertEqual(snapshot.bools, ["tune_up_badge": true])
    }

    // MARK: - Typed values

    func testWrongTypedFlagValueIsDropped() {
        // A variant string is not a valid bool, so it must not be stored.
        let object: [String: Any] = [
            "featureFlags": ["tune_up_badge": "control"],
        ]
        let snapshot = RemoteFeatureFlags.snapshot(from: object, now: now)
        XCTAssertTrue(snapshot.bools.isEmpty)
        XCTAssertEqual(RemoteFeatureFlags.evaluate(.tuneUpBadge, snapshot: snapshot, now: now), .bool(false))
    }

    func testMalformedPayloadIsDropped() {
        let object: [String: Any] = [
            "featureFlags": ["tune_up_badge": true],
            "featureFlagPayloads": ["tune_up_badge": "not-json"],
        ]
        let snapshot = RemoteFeatureFlags.snapshot(from: object, now: now)
        // Payload was malformed, so fall back to the enable flag value.
        XCTAssertEqual(snapshot.bools, ["tune_up_badge": true])
    }

    func testBoolPayloadIsAcceptedAndOverridesEnableState() {
        let object: [String: Any] = [
            "featureFlags": ["tune_up_badge": false],
            "featureFlagPayloads": ["tune_up_badge": "true"],
        ]
        let snapshot = RemoteFeatureFlags.snapshot(from: object, now: now)
        // Payload is the source of truth over the enable flag value.
        XCTAssertEqual(snapshot.bools, ["tune_up_badge": true])
    }

    func testFragmentPayloadsParse() {
        // Payloads are JSON fragments (bare values), not just objects.
        let object: [String: Any] = [
            "featureFlagPayloads": [
                "tune_up_badge": "false",
            ],
        ]
        let snapshot = RemoteFeatureFlags.snapshot(from: object, now: now)
        XCTAssertEqual(snapshot.bools, ["tune_up_badge": false])
    }

    // MARK: - Network-failure behaviour (no snapshot)

    func testNetworkFailureMeansDefaults() {
        // A failed fetch leaves the snapshot empty; evaluation must not block
        // and must return the conservative default.
        XCTAssertEqual(
            RemoteFeatureFlags.evaluate(.tuneUpBadge, snapshot: .empty, now: now),
            .bool(false)
        )
    }

    // MARK: - Decide endpoint

    func testDecideEndpointMapsBesideBatchEndpoint() {
        XCTAssertEqual(
            Telemetry.decideEndpoint(from: URL(string: "https://us.i.posthog.com/batch")!)?.absoluteString,
            "https://us.i.posthog.com/decide?v=3"
        )
        XCTAssertEqual(
            Telemetry.decideEndpoint(from: URL(string: "https://example.com/path/batch")!)?.absoluteString,
            "https://example.com/path/decide?v=3"
        )
    }
}
