//
//  PrivilegeRouteTests.swift
//  BurrowTests
//
//  Which elevation route an operation takes, and — more importantly — which
//  ones it must NOT take.
//
//  The helper and the osascript path both end in an administrator prompt and
//  both run the same trusted engine, so falling back is safe. What would not
//  be safe is the reverse: quietly widening what the helper accepts, or
//  routing to a root daemon whose build no longer matches the app driving it.
//  Every guard below is one of those.
//
//  Pure decisions, no daemon, no registration, no XPC.
//

import XCTest
@testable import Burrow

final class PrivilegeRouteTests: XCTestCase {

    // MARK: - argv → typed operation
    //
    // The migration seam. `OperationFlow` still describes elevated work as
    // argv, and this is the ONLY place that argv is allowed to become a typed
    // operation. Anything it doesn't recognise keeps the old route rather than
    // being forwarded as an approximate match.

    func testRecognition_mapsTheEngineConventionArgvTheFlowActuallySends() {
        // Exactly what OperationFlow sends after `BurrowEngine.streamArgv` / `engineArgv`:
        // the engine's convention (preview by default, `--apply` to act), streamed.
        XCTAssertEqual(HelperOperation(engineArguments: ["clean", "--apply", "--stream"]), .clean)
        XCTAssertEqual(HelperOperation(engineArguments: ["optimize", "--apply", "--stream"]), .optimize)
        XCTAssertEqual(HelperOperation(engineArguments: ["clean", "--stream"]), .scan)
        XCTAssertEqual(HelperOperation(engineArguments: ["optimize", "--stream"]), .optimizeScan)
        // The streaming kill-switch off: same operations, buffered.
        XCTAssertEqual(HelperOperation(engineArguments: ["clean", "--apply"]), .clean)
        XCTAssertEqual(HelperOperation(engineArguments: ["clean", "--dry-run"]), .scan)
        XCTAssertEqual(HelperOperation(engineArguments: ["optimize", "--dry-run", "--stream"]), .optimizeScan)
    }

    /// The engine's convention decides, never mo's. A bare `["clean"]` is what the engine
    /// treats as a PREVIEW, so it must map to the scan — the first version of this seam read
    /// it as the live clean, and the daemon would have run a dry run and called it a cleanup.
    func testRecognition_aBareVerbIsThePreviewNotTheLiveRun() {
        XCTAssertEqual(HelperOperation(engineArguments: ["clean"]), .scan)
        XCTAssertEqual(HelperOperation(engineArguments: ["optimize"]), .optimizeScan)
    }

    func testRecognition_isExactAboutVerbAndFlags() {
        // A near-miss is not a match. An unknown flag, a verb that isn't first, a different
        // verb, or the apply/dry-run contradiction the engine itself refuses — all fall
        // through to osascript rather than being coerced into the closest typed operation.
        XCTAssertNil(HelperOperation(engineArguments: ["--dry-run", "clean"]))
        XCTAssertNil(HelperOperation(engineArguments: ["clean", "--yes"]))
        XCTAssertNil(HelperOperation(engineArguments: ["clean", "--dry-run", "--verbose"]))
        XCTAssertNil(HelperOperation(engineArguments: ["clean", "--apply", "--dry-run"]))
        XCTAssertNil(HelperOperation(engineArguments: ["clean", "--apply", "--apply"]))
        XCTAssertNil(HelperOperation(engineArguments: ["clean", "--permanent", "--apply"]),
                     "the removal mode is not something the client may choose for the daemon")
        XCTAssertNil(HelperOperation(engineArguments: ["clean", "--apply", "--plan", "/tmp/x"]),
                     "a plan file is the daemon's own, never a client argument")
        XCTAssertNil(HelperOperation(engineArguments: ["uninstall", "Safari"]))
        XCTAssertNil(HelperOperation(engineArguments: ["purge", "--apply", "--stream"]))
        XCTAssertNil(HelperOperation(engineArguments: []))
    }

    /// The one that matters: an attacker-shaped argv must never resolve to an
    /// operation. It can't, because recognition admits a verb from a closed set
    /// followed only by flags from a closed set — but this is the assertion
    /// that says so out loud.
    func testRecognition_neverAcceptsInjectedArgv() {
        for hostile in [["clean", "; rm -rf /"],
                        ["clean", "--dry-run", "&&", "curl", "evil"],
                        ["/bin/sh"],
                        ["clean\0"],
                        ["clean\n--force"]] {
            XCTAssertNil(HelperOperation(engineArguments: hostile),
                         "\(hostile) must not resolve to a privileged operation")
        }
    }

    // MARK: - The routing rule

    func testRoute_usesTheHelperWhenEverythingLinesUp() {
        XCTAssertEqual(PrivilegeRoute.decide(arguments: ["clean", "--apply", "--stream"],
                                             registration: .enabled,
                                             skew: .matched),
                       .helper(.clean))
    }

    func testRoute_unrecognisedArgvKeepsTheLegacyPath() {
        XCTAssertEqual(PrivilegeRoute.decide(arguments: ["uninstall", "Safari"],
                                             registration: .enabled,
                                             skew: .matched),
                       .osascript)
    }

    /// A daemon that isn't registered, or that the user hasn't approved, is
    /// not a daemon we may use. Registration is the user's decision, and
    /// declining it must leave Burrow working exactly as before.
    func testRoute_unregisteredOrUnapprovedKeepsTheLegacyPath() {
        for registration: HelperRegistrationStatus in [.notRegistered, .requiresApproval] {
            XCTAssertEqual(PrivilegeRoute.decide(arguments: ["clean"],
                                                 registration: registration,
                                                 skew: .matched),
                           .osascript,
                           "registration \(registration) must not reach the helper")
        }
    }

    /// The sharp one. A registered daemon OUTLIVES the app that installed it —
    /// Sparkle can replace Burrow.app underneath it — so a helper from an
    /// older build could be running as root with an older idea of what `clean`
    /// does. Skew routes away from the helper entirely.
    func testRoute_versionSkewKeepsTheLegacyPath() {
        XCTAssertEqual(PrivilegeRoute.decide(arguments: ["clean"],
                                             registration: .enabled,
                                             skew: .mismatched),
                       .osascript)
    }

    /// Every combination, so no future edit can produce a `.helper` route from
    /// a state that isn't fully green.
    func testRoute_helperRequiresEveryConditionSimultaneously() {
        let registrations: [HelperRegistrationStatus] = [.enabled, .notRegistered, .requiresApproval]
        let skews: [HelperVersionSkew.Skew] = [.matched, .mismatched]
        let argvs = [["clean"], ["optimize"], ["clean", "--dry-run"], ["uninstall"], []]

        for registration in registrations {
            for skew in skews {
                for argv in argvs {
                    let route = PrivilegeRoute.decide(arguments: argv, registration: registration, skew: skew)
                    let allGreen = registration == .enabled
                        && skew == .matched
                        && HelperOperation(engineArguments: argv) != nil
                    if allGreen {
                        XCTAssertNotEqual(route, .osascript)
                    } else {
                        XCTAssertEqual(route, .osascript,
                                       "argv \(argv), registration \(registration), skew \(skew)")
                    }
                }
            }
        }
    }

    // MARK: - Registration status mapping

    func testRegistrationStatus_needsUserActionOnlyWhenApprovalIsPending() {
        XCTAssertTrue(HelperRegistrationStatus.requiresApproval.needsUserAction)
        XCTAssertFalse(HelperRegistrationStatus.enabled.needsUserAction)
        XCTAssertFalse(HelperRegistrationStatus.notRegistered.needsUserAction,
                       "never registered is the default state, not a pending decision")
    }

    // MARK: - The reviewed clean
    //
    // This is the regression that quietly removed Touch ID from the single
    // most consequential operation Burrow has. The permanent clean stopped
    // being described by engine argv and became a reviewed PLAN, and because
    // routing only ever recognised argv, it fell through to osascript — which
    // is password-only by construction — while every other elevated operation
    // kept authenticating through the helper.

    func testReviewedCleanupRoutesToTheHelperDespiteHavingNoEngineArguments() {
        XCTAssertEqual(PrivilegeRoute.decide(arguments: [],
                                             registration: .enabled,
                                             skew: .matched,
                                             hasReviewedCleanup: true),
                       .helper(.cleanReviewed))
    }

    func testReviewedCleanupStillFallsBackWhenTheHelperIsUnusable() {
        for (registration, skew) in [(HelperRegistrationStatus.notRegistered, HelperVersionSkew.Skew.matched),
                                     (.requiresApproval, .matched),
                                     (.enabled, .mismatched)] {
            XCTAssertEqual(PrivilegeRoute.decide(arguments: [],
                                                 registration: registration,
                                                 skew: skew,
                                                 hasReviewedCleanup: true),
                           .osascript)
        }
    }

    /// Without a plan there is nothing to delete, so an empty argv must stay
    /// unroutable rather than reaching the daemon as a cleanup of nothing.
    func testEmptyArgumentsWithoutAPlanDoNotReachTheHelper() {
        XCTAssertEqual(PrivilegeRoute.decide(arguments: [],
                                             registration: .enabled,
                                             skew: .matched),
                       .osascript)
    }

    // MARK: - Running-helper handshake

    func testHandshake_currentDaemonAllowsReviewedCleanup() throws {
        let status = HelperStatus.current(build: "26")
        let data = try JSONEncoder().encode(status)
        XCTAssertEqual(try JSONDecoder().decode(HelperStatus.self, from: data), status)
        XCTAssertEqual(reviewedRoute(statusData: data), .helper(.cleanReviewed))
    }

    func testHandshake_sameBuildWithoutReviewedSelectionCapabilityFallsBack() throws {
        let status = HelperStatus(build: "26",
                                  protocolVersion: HelperStatus.currentProtocolVersion,
                                  capabilities: [])
        XCTAssertEqual(reviewedRoute(statusData: try JSONEncoder().encode(status)), .osascript)
    }

    func testHandshake_oldOrUnavailableDaemonNeverPassesOnItsBuildAlone() {
        // Missing selector/error/timeout gives nil; the old build-only reply
        // is also insufficient even when its number is exactly the app's.
        for reply in [nil, Data("26".utf8), Data("\"26\"".utf8), Data(#"{"build":"26"}"#.utf8)] {
            XCTAssertEqual(reviewedRoute(statusData: reply), .osascript)
        }
    }

    func testHandshake_missingMalformedOrUnknownProtocolFallsBack() throws {
        for version in [0, HelperStatus.currentProtocolVersion + 1] {
            let status = HelperStatus(build: "26", protocolVersion: version,
                                      capabilities: [HelperStatus.reviewedSelectionCapability])
            XCTAssertEqual(reviewedRoute(statusData: try JSONEncoder().encode(status)), .osascript)
        }
        for reply in ["", "{", #"{"build":"26","capabilities":["reviewed-selection-v1"]}"#,
                      #"{"build":"26","protocolVersion":1}"#,
                      #"{"build":"26","protocolVersion":"1","capabilities":["reviewed-selection-v1"]}"#] {
            XCTAssertEqual(reviewedRoute(statusData: Data(reply.utf8)), .osascript)
        }
    }

    func testHandshake_requiredCapabilityDoesNotRelaxTheBuildCheck() throws {
        for helperBuild in ["", "25", "27"] {
            let data = try JSONEncoder().encode(HelperStatus.current(build: helperBuild))
            XCTAssertEqual(reviewedRoute(statusData: data), .osascript)
        }
        let matching = try JSONEncoder().encode(HelperStatus.current(build: "26"))
        XCTAssertEqual(HelperVersionSkew.evaluate(appBuild: "", statusData: matching), .mismatched)
    }

    func testHandshake_additiveCapabilitiesKeepTheCurrentContractCompatible() throws {
        let status = HelperStatus(build: "26",
                                  protocolVersion: HelperStatus.currentProtocolVersion,
                                  capabilities: [HelperStatus.reviewedSelectionCapability, "future-optional-check"])
        XCTAssertEqual(reviewedRoute(statusData: try JSONEncoder().encode(status)), .helper(.cleanReviewed))
    }

    private func reviewedRoute(statusData: Data?) -> PrivilegeRoute {
        PrivilegeRoute.decide(arguments: [], registration: .enabled,
                              skew: HelperVersionSkew.evaluate(appBuild: "26", statusData: statusData),
                              hasReviewedCleanup: true)
    }
}
