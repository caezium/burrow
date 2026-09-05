//
//  TelemetryPolicyTests.swift
//  BurrowTests
//

import XCTest
@testable import Burrow

final class TelemetryPolicyTests: XCTestCase {
    func testFlagExposurePassesTheEventGateWithoutAllowingArbitraryReservedNames() {
        XCTAssertTrue(Telemetry.isAllowedEventName("$feature_flag_called"))
        XCTAssertTrue(Telemetry.isAllowedEventName("feature_operation_completed"))
        XCTAssertFalse(Telemetry.isAllowedEventName("$identify"))
        XCTAssertFalse(Telemetry.isAllowedEventName("$feature_flag_called/secret"))
        XCTAssertFalse(Telemetry.isAllowedEventName("$feature_flag_called\n"))
        let properties = DiagnosticPrivacy.sanitize([
            "$feature_flag": "about_release_notes_link", "$feature_flag_response": true,
        ])
        XCTAssertEqual(properties["$feature_flag"] as? String, "about_release_notes_link")
        XCTAssertEqual(properties["$feature_flag_response"] as? Bool, true)
    }

    func testPostHogTransportRequiresHTTPS() {
        XCTAssertEqual(
            Telemetry.postHogEndpoint(host: "https://us.i.posthog.com")?.absoluteString,
            "https://us.i.posthog.com/batch"
        )
        XCTAssertNil(Telemetry.postHogEndpoint(host: "http://us.i.posthog.com")) // greenlight:ignore http-not-https — rejection fixture
        XCTAssertNil(Telemetry.postHogEndpoint(host: "not a url"))
        XCTAssertNil(Telemetry.postHogEndpoint(host: "https://identity@us.i.posthog.com"))
        XCTAssertNil(Telemetry.postHogEndpoint(host: "https://us.i.posthog.com?mode=test"))
    }

    func testTelemetryValuesAreCoarselyBucketed() {
        XCTAssertEqual(Telemetry.bytesBucket(42), "<1MB")
        XCTAssertEqual(Telemetry.countBucket(12), "10-99")
        XCTAssertEqual(Telemetry.secondsBucket(31), "30-120s")
    }

    func testDeliveryPolicyRetriesOnlyTransientFailures() {
        XCTAssertEqual(
            Telemetry.deliveryDisposition(statusCode: 204, hasTransportError: false),
            .delivered
        )
        XCTAssertEqual(
            Telemetry.deliveryDisposition(statusCode: nil, hasTransportError: true),
            .retry
        )
        XCTAssertEqual(
            Telemetry.deliveryDisposition(statusCode: 429, hasTransportError: false),
            .retry
        )
        XCTAssertEqual(
            Telemetry.deliveryDisposition(statusCode: 503, hasTransportError: false),
            .retry
        )
        XCTAssertEqual(
            Telemetry.deliveryDisposition(statusCode: 400, hasTransportError: false),
            .discard
        )
        XCTAssertEqual(
            Telemetry.deliveryDisposition(statusCode: 401, hasTransportError: false),
            .discard
        )
    }

    func testOutboxRetryBackoffIsBounded() {
        XCTAssertEqual(Telemetry.retryDelay(afterFailure: 1), 30)
        XCTAssertEqual(Telemetry.retryDelay(afterFailure: 2), 60)
        XCTAssertEqual(Telemetry.retryDelay(afterFailure: 8), 3_600)
        XCTAssertEqual(Telemetry.retryDelay(afterFailure: 100), 3_600)
    }

    func testLegacyPostHogAnonymousIDMigratesWithoutChangingIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-posthog-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let projectKey = "analytics-project"
        let legacyDirectory = root
            .appendingPathComponent("dev.caezium.Burrow", isDirectory: true)
            .appendingPathComponent(projectKey, isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let anonymousID = UUID().uuidString.lowercased()
        let legacyPayload = try JSONSerialization.data(withJSONObject: [
            "posthog.anonymousId": anonymousID,
        ])
        try legacyPayload.write(
            to: legacyDirectory.appendingPathComponent("posthog.anonymousId"),
            options: .atomic
        )

        let destination = root
            .appendingPathComponent("Burrow", isDirectory: true)
            .appendingPathComponent("telemetry-id")
        XCTAssertEqual(
            Telemetry.migrateLegacyPostHogAnonymousID(
                projectKey: projectKey,
                applicationSupportRoot: root,
                destination: destination
            ),
            anonymousID
        )
        XCTAssertEqual(
            try String(contentsOf: destination, encoding: .utf8),
            anonymousID
        )
    }

    func testLegacyPostHogMigrationRejectsInvalidIDsAndUnsafeProjectPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-posthog-rejection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let projectKey = "analytics-project"
        let legacyDirectory = root
            .appendingPathComponent("dev.caezium.Burrow", isDirectory: true)
            .appendingPathComponent(projectKey, isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let legacyPayload = try JSONSerialization.data(withJSONObject: [
            "posthog.anonymousId": "not-an-anonymous-uuid",
        ])
        try legacyPayload.write(
            to: legacyDirectory.appendingPathComponent("posthog.anonymousId"),
            options: .atomic
        )

        let destination = root.appendingPathComponent("telemetry-id")
        XCTAssertNil(
            Telemetry.migrateLegacyPostHogAnonymousID(
                projectKey: projectKey,
                applicationSupportRoot: root,
                destination: destination
            )
        )
        XCTAssertNil(
            Telemetry.migrateLegacyPostHogAnonymousID(
                projectKey: "../analytics-project",
                applicationSupportRoot: root,
                destination: destination
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testScreenViewsEmitOncePerVisiblePanePresentation() {
        var deduper = ScreenTelemetryDeduper()

        XCTAssertTrue(deduper.appeared(on: .home))
        XCTAssertFalse(deduper.appeared(on: .home))
        XCTAssertTrue(deduper.paneChanged(to: .settings))
        XCTAssertFalse(deduper.paneChanged(to: .settings))

        XCTAssertFalse(deduper.visibilityChanged(to: false, pane: .settings))
        XCTAssertFalse(deduper.paneChanged(to: .home))
        XCTAssertTrue(deduper.visibilityChanged(to: true, pane: .home))
        // SwiftUI may deliver this pane onChange after the visibility event;
        // it must not duplicate the reopened screen impression.
        XCTAssertFalse(deduper.paneChanged(to: .home))

        XCTAssertFalse(deduper.visibilityChanged(to: false, pane: .home))
        XCTAssertTrue(deduper.visibilityChanged(to: true, pane: .home))
    }
}
