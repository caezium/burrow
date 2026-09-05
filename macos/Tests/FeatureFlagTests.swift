//
//  FeatureFlagTests.swift
//  BurrowTests
//
//  Issue #322 acceptance: the flag system must be inert when opted out,
//  discard stale/malformed/oversized caches, ignore unknown keys and
//  non-boolean values, and fall back to conservative defaults on every
//  failure path. These tests pin those rules down without any network.
//

import XCTest
@testable import Burrow

final class FeatureFlagTests: XCTestCase {
    private var directory: URL!
    private var now: Date!

    override func setUp() {
        super.setUp()
        FeatureFlags.resetForTesting()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("feature-flag-tests-\(UUID().uuidString)", isDirectory: true)
        now = Date()
    }

    override func tearDown() {
        FeatureFlags.resetForTesting()
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func cacheURL() -> URL {
        directory.appendingPathComponent(FeatureFlags.cacheFileName)
    }

    private func writeCache(_ data: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: cacheURL(), options: .atomic)
    }

    private func encodeAndWrite(_ flags: [FeatureFlags.Key: Bool], fetchedAt: Date) throws {
        let data = try XCTUnwrap(FeatureFlags.encodeCache(flags, fetchedAt: fetchedAt))
        try writeCache(data)
    }

    // An opted-out launch must not even read the flag cache.
    func testOptedOutLaunchNeverReadsTheCache() throws {
        try encodeAndWrite([.aboutReleaseNotesLink: true], fetchedAt: now)
        XCTAssertNil(
            FeatureFlags.loadCachedIfEnabled(isEnabled: false, directory: directory, now: now),
            "opt-out must ignore a perfectly fresh cache"
        )
        XCTAssertEqual(
            FeatureFlags.loadCachedIfEnabled(isEnabled: true, directory: directory, now: now),
            [.aboutReleaseNotesLink: true],
            "the same cache is readable once telemetry is enabled"
        )
    }

    // Unknown keys and non-boolean values in a decide response are ignored;
    // only allowlisted booleans survive, so a hostile or future payload
    // cannot smuggle new flags or types into the app.
    func testRemotePayloadAcceptsOnlyAllowlistedBooleans() {
        let raw: [String: Any] = [
            "about_release_notes_link": true,
            "delete_everything": true,
            "about_release_notes_link_variant": "bold",
            "rollout_percent": 50,
        ]
        XCTAssertEqual(FeatureFlags.sanitizeRemoteFlags(raw), [.aboutReleaseNotesLink: true])
        XCTAssertEqual(FeatureFlags.sanitizeRemoteFlags(nil), [:])
        XCTAssertEqual(
            FeatureFlags.sanitizeRemoteFlags(["about_release_notes_link": "true"]),
            [:],
            "a string is not a boolean — ignored"
        )
    }

    func testRemoteJSONNumbersAreNotBooleans() throws {
        for token in ["0", "1", "0.0", "1.0", "\"true\"", "null"] {
            let data = Data("{\"about_release_notes_link\":\(token)}".utf8)
            let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(FeatureFlags.sanitizeRemoteFlags(raw), [:], "Rejected token: \(token)")
        }
        let data = Data(#"{"about_release_notes_link":true}"#.utf8)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(FeatureFlags.sanitizeRemoteFlags(raw), [.aboutReleaseNotesLink: true])
    }

    func testCacheRejectsKnownFlagsWithInvalidTypesAndBooleanVersion() throws {
        let valid = try XCTUnwrap(FeatureFlags.encodeCache([.aboutReleaseNotesLink: true], fetchedAt: now))
        let text = String(decoding: valid, as: UTF8.self)
        for token in ["1", "0", "\"true\"", "null"] {
            let invalid = text.replacingOccurrences(of: "\"about_release_notes_link\":true",
                                                   with: "\"about_release_notes_link\":\(token)")
            XCTAssertNotEqual(invalid, text)
            XCTAssertNil(FeatureFlags.decodeCache(Data(invalid.utf8), now: now))
        }
        let booleanVersion = text.replacingOccurrences(of: "\"version\":1", with: "\"version\":true")
        XCTAssertNil(FeatureFlags.decodeCache(Data(booleanVersion.utf8), now: now))
    }

    func testOptingOutImmediatelyRestoresBakedInDefaults() {
        let oldDefaults = Store.d
        let suiteName = "burrow-feature-flags-opt-out-\(UUID().uuidString)"
        let scratch = UserDefaults(suiteName: suiteName)!
        Store.d = scratch
        defer {
            Store.d = oldDefaults
            scratch.removePersistentDomain(forName: suiteName)
        }
        Store.telemetryEnabled = true
        FeatureFlags.apply([.aboutReleaseNotesLink: true], persistTo: nil)
        XCTAssertTrue(FeatureFlags.isEnabled(.aboutReleaseNotesLink))
        Telemetry.setEnabled(false)
        XCTAssertFalse(FeatureFlags.isEnabled(.aboutReleaseNotesLink))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL().path))
    }

    // A malformed cache (bad JSON, wrong version, wrong types, missing or
    // stale timestamp) discards the whole file; only a strict, fresh shape
    // decodes. This keeps a corrupt or malicious file from ever overriding
    // the conservative defaults.
    func testMalformedOrStaleCachesAreDiscarded() throws {
        let stale = now.addingTimeInterval(-FeatureFlags.maxCacheAge - 60)
        let fresh = now.addingTimeInterval(-FeatureFlags.maxCacheAge + 60)
        let future = now.addingTimeInterval(60)

        XCTAssertNil(FeatureFlags.decodeCache(Data("not json".utf8), now: now))
        XCTAssertNil(FeatureFlags.decodeCache(Data("[]".utf8), now: now))

        // A cache with the wrong schema or types is unsafe to use; it
        // must be discarded rather than partially decoded.
        XCTAssertNil(
            FeatureFlags.decodeCache(Data(#"{"version":1,"fetched_at":"oops","flags":{}}"#.utf8), now: now)
        )
        XCTAssertNil(
            FeatureFlags.decodeCache(Data(#"{"version":2,"fetched_at":"2026-01-01T00:00:00Z","flags":{}}"#.utf8), now: now)
        )

        // Future or stale timestamps are both untrustworthy.
        try encodeAndWrite([.aboutReleaseNotesLink: true], fetchedAt: stale)
        XCTAssertNil(FeatureFlags.loadCached(from: directory, now: now), "stale cache must be discarded")

        let futureData = try XCTUnwrap(FeatureFlags.encodeCache([.aboutReleaseNotesLink: true], fetchedAt: future))
        XCTAssertNil(FeatureFlags.decodeCache(futureData, now: now), "future cache timestamp must be rejected")

        // Persisting and reloading must reproduce the accepted snapshot
        // exactly while discarding unknown keys.
        let roundtrip = try XCTUnwrap(FeatureFlags.encodeCache([.aboutReleaseNotesLink: true], fetchedAt: fresh))
        XCTAssertEqual(FeatureFlags.decodeCache(roundtrip, now: now), [.aboutReleaseNotesLink: true])
    }

    // The cache file is allowlist-sized by construction; anything bigger is
    // corrupt or foreign and must be discarded before it is even read.
    func testOversizedCacheFileIsDiscardedUnread() throws {
        try writeCache(Data(repeating: 0x20, count: FeatureFlags.maxCacheBytes + 1))
        XCTAssertNil(FeatureFlags.loadCached(from: directory, now: now))
    }

    // Conservative defaults: before anything is applied — and after any
    // empty/failed application — every flag reads OFF.
    func testLookupsServeConservativeDefaultsOnEveryFailure() {
        XCTAssertFalse(FeatureFlags.isEnabled(.aboutReleaseNotesLink), "default is OFF")

        // The network-failure path: no (or an empty) accepted set is applied.
        FeatureFlags.apply(FeatureFlags.sanitizeRemoteFlags(nil), persistTo: nil)
        XCTAssertFalse(FeatureFlags.isEnabled(.aboutReleaseNotesLink))

        FeatureFlags.apply([.aboutReleaseNotesLink: true], persistTo: nil)
        XCTAssertTrue(FeatureFlags.isEnabled(.aboutReleaseNotesLink))
    }

    // apply(persistTo:) writes the merged snapshot; a later launch reads it
    // back through the same codec and non-allowlisted content never lands
    // in the file.
    func testApplyPersistsMergedSnapshotForLaterLaunches() throws {
        FeatureFlags.apply([.aboutReleaseNotesLink: true], persistTo: directory)
        XCTAssertEqual(FeatureFlags.loadCached(from: directory, now: now), [.aboutReleaseNotesLink: true])

        let written = try String(contentsOf: cacheURL(), encoding: .utf8)
        XCTAssertFalse(written.contains("delete_everything"))
        XCTAssertTrue(written.contains("about_release_notes_link"))
    }

    // Flag keys become event properties and on-disk names, so the allowlist
    // must stay safe identifiers and duplicate-free.
    func testAllowlistedKeysAreSafeUniqueIdentifiers() {
        XCTAssertEqual(Set(FeatureFlags.Key.allCases.map(\.rawValue)).count,
                       FeatureFlags.Key.allCases.count,
                       "keys key the snapshot map, so they must be unique")
        for key in FeatureFlags.Key.allCases {
            XCTAssertTrue(DiagnosticPrivacy.isSafeIdentifier(key.rawValue),
                          "\(key.rawValue) must remain a safe identifier")
        }
    }

    // The decide URL is fixed by the validated HTTPS host root; only the
    // API version appears as a query. Trailing slashes must not create
    // double path separators.
    func testDecideEndpointIsHTTPSWithFixedVersion() throws {
        let host = try XCTUnwrap(Telemetry.postHogHostRoot(host: "https://us.i.posthog.com"))
        XCTAssertEqual(
            Telemetry.decideEndpoint(on: host)?.absoluteString,
            "https://us.i.posthog.com/decide/?v=3"
        )

        let hostWithSlash = try XCTUnwrap(Telemetry.postHogHostRoot(host: "https://us.i.posthog.com/"))
        XCTAssertEqual(
            Telemetry.decideEndpoint(on: hostWithSlash)?.absoluteString,
            "https://us.i.posthog.com/decide/?v=3"
        )

        XCTAssertNil(Telemetry.postHogHostRoot(host: "http://insecure.example.com"))
    }
}
