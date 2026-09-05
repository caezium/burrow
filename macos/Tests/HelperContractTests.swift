//
//  HelperContractTests.swift
//  BurrowTests
//
//  The typed-request boundary of the privileged helper. Everything asserted
//  here runs in memory: no daemon, no XPC, no root, no auth prompt.
//
//  The whole security argument for the helper rests on ONE claim — a client
//  cannot describe an arbitrary command, only pick from a closed set of
//  Burrow operations. These tests are what make that claim checkable:
//
//    * the operation set is closed and each member maps to a FIXED argv the
//      client never contributes a single token to;
//    * a request that fails validation produces a named rejection, never a
//      "best effort" run;
//    * an operation ID cannot be replayed.
//
//  If someone later widens the contract to carry a path, an argv element, or
//  a command string, the argv tests below stop compiling or fail. That is the
//  point.
//

import XCTest
@testable import Burrow

final class HelperContractTests: XCTestCase {

    private var validInvokingUserClaim: HelperInvokingUserClaim {
        HelperInvokingUserClaim(uid: 501, canonicalHome: "/Users/test")
    }

    // MARK: - Invoking identity

    func testInvokingUserResolver_bindsTheClaimToThePeerUIDAndDaemonAccount() throws {
        let claim = HelperInvokingUserClaim(uid: 502, canonicalHome: "/Users/Jane Doe")
        let accounts = [
            HelperInvokingUserAccount(uid: 501, username: "other", homeDirectory: "/Users/other"),
            HelperInvokingUserAccount(uid: 502, username: "jane doe", homeDirectory: "/Users/Jane Doe"),
        ]

        let resolved = try HelperInvokingUserResolver.resolve(
            peerUID: 502,
            claim: claim,
            accounts: accounts,
            inspectHome: { path in
                XCTAssertEqual(path, "/Users/Jane Doe")
                return HelperHomeInspection(kind: .directory,
                                            canonicalPath: "/Users/Jane Doe",
                                            ownerUID: 502)
            })

        XCTAssertEqual(resolved.uid, 502)
        XCTAssertEqual(resolved.username, "jane doe")
        XCTAssertEqual(resolved.canonicalHome, "/Users/Jane Doe")
        XCTAssertEqual(resolved.childEnvironment["HOME"], "/Users/Jane Doe")
        XCTAssertEqual(resolved.childEnvironment["USER"], "jane doe")
        XCTAssertEqual(resolved.childEnvironment["LOGNAME"], "jane doe")
        XCTAssertEqual(resolved.childEnvironment["SUDO_USER"], "jane doe")
        XCTAssertEqual(resolved.childEnvironment["SUDO_UID"], "502")
        XCTAssertFalse(resolved.childEnvironment.values.contains("/var/root"))
        // The engine's privileged-run contract, on the helper route too.
        XCTAssertEqual(resolved.childEnvironment["BURROW_HOME"], "/Users/Jane Doe")
        XCTAssertEqual(resolved.childEnvironment["BURROW_PRIVILEGED"], "1")
    }

    func testRequestCarriesAnExplicitInvokingUserClaimAndRejectsItsAbsence() throws {
        let claim = HelperInvokingUserClaim(uid: 501, canonicalHome: "/Users/henry")
        let request = HelperRequest(operation: .clean,
                                    operationID: UUID().uuidString,
                                    clientBuild: "24",
                                    invokingUser: claim)

        let roundTripped = try JSONDecoder().decode(
            HelperRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(roundTripped.invokingUser, claim)

        let missingClaim = #"{"operation":"clean","operationID":"00000000-0000-0000-0000-000000000001","clientBuild":"24"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(HelperRequest.self,
                                                       from: Data(missingClaim.utf8)))
    }

    func testInvokingUserResolver_refusesRootAndAClaimForAnotherPeer() {
        let account = HelperInvokingUserAccount(uid: 501, username: "user",
                                                homeDirectory: "/Users/user")
        let inspection = HelperHomeInspection(kind: .directory,
                                              canonicalPath: "/Users/user", ownerUID: 501)

        XCTAssertThrowsError(try HelperInvokingUserResolver.resolve(
            peerUID: 0,
            claim: HelperInvokingUserClaim(uid: 0, canonicalHome: "/var/root"),
            accounts: [], inspectHome: { _ in inspection })) { error in
                XCTAssertEqual(error as? HelperInvokingUserResolutionError, .rootPeer)
            }
        XCTAssertThrowsError(try HelperInvokingUserResolver.resolve(
            peerUID: 501,
            claim: HelperInvokingUserClaim(uid: 502, canonicalHome: "/Users/user"),
            accounts: [account], inspectHome: { _ in inspection })) { error in
                XCTAssertEqual(error as? HelperInvokingUserResolutionError, .claimUIDMismatch)
            }
    }

    func testInvokingUserResolver_refusesMissingOrSymlinkedHomes() {
        let account = HelperInvokingUserAccount(uid: 501, username: "user",
                                                homeDirectory: "/Users/user")
        let claim = HelperInvokingUserClaim(uid: 501, canonicalHome: "/Users/user")

        XCTAssertThrowsError(try HelperInvokingUserResolver.resolve(
            peerUID: 501, claim: claim, accounts: [account],
            inspectHome: { _ in HelperHomeInspection(kind: .missing,
                                                      canonicalPath: nil, ownerUID: nil) })) { error in
                XCTAssertEqual(error as? HelperInvokingUserResolutionError, .missingHome)
            }
        XCTAssertThrowsError(try HelperInvokingUserResolver.resolve(
            peerUID: 501, claim: claim, accounts: [account],
            inspectHome: { _ in HelperHomeInspection(kind: .symbolicLink,
                                                      canonicalPath: nil, ownerUID: 501) })) { error in
                XCTAssertEqual(error as? HelperInvokingUserResolutionError, .symbolicLinkHome)
            }
    }

    func testInvokingUserResolver_refusesWrongOwnerAndCanonicalHomeMismatch() {
        let account = HelperInvokingUserAccount(uid: 501, username: "user",
                                                homeDirectory: "/Users/user")
        let claim = HelperInvokingUserClaim(uid: 501, canonicalHome: "/Users/user")

        XCTAssertThrowsError(try HelperInvokingUserResolver.resolve(
            peerUID: 501, claim: claim, accounts: [account],
            inspectHome: { _ in HelperHomeInspection(kind: .directory,
                                                      canonicalPath: "/Users/user", ownerUID: 502) })) { error in
                XCTAssertEqual(error as? HelperInvokingUserResolutionError, .homeOwnerMismatch)
            }
        XCTAssertThrowsError(try HelperInvokingUserResolver.resolve(
            peerUID: 501, claim: claim, accounts: [account],
            inspectHome: { _ in HelperHomeInspection(kind: .directory,
                                                      canonicalPath: "/Users/renamed", ownerUID: 501) })) { error in
                XCTAssertEqual(error as? HelperInvokingUserResolutionError, .canonicalHomeMismatch)
            }
    }

    func testInvokingUserResolver_refusesMissingAccountAndRootHome() {
        let claim = HelperInvokingUserClaim(uid: 501, canonicalHome: "/Users/user")
        XCTAssertThrowsError(try HelperInvokingUserResolver.resolve(
            peerUID: 501, claim: claim, accounts: [],
            inspectHome: { _ in HelperHomeInspection(kind: .directory,
                                                      canonicalPath: "/Users/user", ownerUID: 501) })) { error in
                XCTAssertEqual(error as? HelperInvokingUserResolutionError, .missingAccount)
            }

        let rootHomeAccount = HelperInvokingUserAccount(uid: 501, username: "user",
                                                        homeDirectory: "/var/root")
        XCTAssertThrowsError(try HelperInvokingUserResolver.resolve(
            peerUID: 501,
            claim: HelperInvokingUserClaim(uid: 501, canonicalHome: "/private/var/root"),
            accounts: [rootHomeAccount],
            inspectHome: { _ in HelperHomeInspection(kind: .directory,
                                                      canonicalPath: "/private/var/root", ownerUID: 501) })) { error in
                XCTAssertEqual(error as? HelperInvokingUserResolutionError, .invalidAccountHome)
            }
    }

    // MARK: - The closed operation set
    //
    // The approved scope is exactly: privileged scan, clean, optimize, the
    // reviewed clean, and three system-state operations. Not "run this binary",
    // not "run this shell string", not "run mo with these args". A new case
    // here is a deliberate security decision, so the set is pinned — adding one
    // without updating this test is a failing build.

    func testOperationSet_isPinned() {
        XCTAssertEqual(Set(HelperOperation.allCases.map(\.rawValue)),
                       ["scan", "clean", "cleanReviewed", "optimize", "optimizeScan",
                        "flushDNS", "renewDHCP", "readLoginItems"],
                       "the helper's operation set is closed; widening it is a security decision")
    }

    /// `cleanReviewed` is the only operation carrying caller data, so the
    /// property that matters is that it stays the only one.
    func testOnlyTheReviewedCleanAcceptsCallerSuppliedPaths() {
        let accepting = HelperOperation.allCases.filter(\.needsReviewedPaths)
        XCTAssertEqual(accepting, [.cleanReviewed],
                       "widening which operations take paths is a security decision")
    }

    // MARK: - The closed executable set
    //
    // Most operations drive the bundled engine. The rest drive system tools, and
    // those are the only non-engine binaries the daemon may ever run.

    func testSystemTools_areAbsolutePathsInSystemDirectories() {
        for tool in HelperSystemTool.all {
            XCTAssertTrue(tool.hasPrefix("/usr/bin/") || tool.hasPrefix("/usr/sbin/"),
                          "\(tool) must be an absolute path in a system directory")
            XCTAssertFalse(tool.contains(".."), "no traversal in a root-executed path")
        }
    }

    func testSystemTools_setIsExactlyWhatTheOperationsNeed() {
        // `find` left with the reviewed clean's `find -delete` loop: the engine's own rails
        // delete now, from a plan file, so root has one fewer general-purpose tool to run.
        XCTAssertEqual(HelperSystemTool.all,
                       ["/usr/bin/dscacheutil", "/usr/bin/killall",
                        "/usr/sbin/ipconfig", "/usr/bin/sfltool"])
    }

    /// No step may ever name a shell. The path this replaces elevated
    /// `/bin/sh -c "dscacheutil -flushcache; killall -HUP mDNSResponder"`,
    /// which put a command string in front of a root shell parser.
    func testSteps_neverInvokeAShell() {
        let shells = ["/bin/sh", "/bin/bash", "/bin/zsh", "/usr/bin/env"]
        // Give the reviewed clean its plan file, as the sibling argv test does.
        // Without one it resolves to no steps, so the step built around the
        // one caller-derived value would never actually be examined here.
        let planFile = "/private/tmp/burrow-helper-plan.abc123/plan.plan"
        for operation in HelperOperation.allCases {
            for step in operation.steps(interface: "en0", reviewedPlanFile: planFile) {
                if case .system(let path) = step.executable {
                    XCTAssertFalse(shells.contains(path), "\(operation) must not run a shell")
                    XCTAssertTrue(HelperSystemTool.all.contains(path),
                                  "\(path) is outside the permitted executable set")
                }
            }
        }
    }

    func testSteps_flushDNSIsTwoSeparateProcesses() {
        let steps = HelperOperation.flushDNS.steps(interface: nil)
        XCTAssertEqual(steps, [
            HelperStep(executable: .system("/usr/bin/dscacheutil"), arguments: ["-flushcache"]),
            HelperStep(executable: .system("/usr/bin/killall"), arguments: ["-HUP", "mDNSResponder"]),
        ])
    }

    func testSteps_renewDHCPCarriesOnlyTheInterface() {
        XCTAssertEqual(HelperOperation.renewDHCP.steps(interface: "en1"),
                       [HelperStep(executable: .system("/usr/sbin/ipconfig"),
                                   arguments: ["set", "en1", "DHCP"])])
    }

    /// Without an interface there is nothing safe to run, so the operation
    /// produces no steps at all rather than guessing a default.
    func testSteps_renewDHCPWithoutAnInterfaceRunsNothing() {
        XCTAssertTrue(HelperOperation.renewDHCP.steps(interface: nil).isEmpty)
    }

    func testSteps_engineOperationsUseTheBundledEngine() {
        for operation in [HelperOperation.scan, .clean, .optimize, .optimizeScan] {
            let steps = operation.steps(interface: nil)
            XCTAssertEqual(steps.count, 1)
            XCTAssertEqual(steps.first?.executable, .bundledEngine)
        }
    }

    // MARK: - Interface names (the only caller value that reaches argv)

    func testInterfaceName_acceptsRealBSDNames() {
        for name in ["en0", "en1", "utun3", "bridge0", "awdl0", "llw0", "anpi11"] {
            XCTAssertTrue(HelperRequest.isPlausibleInterfaceName(name), "\(name) is a real interface shape")
        }
    }

    /// Everything that isn't a bare BSD interface name is refused rather than
    /// escaped — there is no legitimate interface containing a path, a flag,
    /// a space, or a shell metacharacter, so rejecting removes the question.
    func testInterfaceName_rejectsAnythingElse() {
        for hostile in ["", "e", "en", "0", "/usr/sbin/ipconfig", "en0 DHCP", "en0;rm -rf /",
                        "en0\n", "en0\u{0}", "--flag", "en0/../../x", "EN0", "en0.1",
                        "e0n1", String(repeating: "en", count: 20) + "0"] {
            XCTAssertFalse(HelperRequest.isPlausibleInterfaceName(hostile),
                           "must reject \(hostile.debugDescription)")
        }
    }

    func testValidate_renewDHCPRequiresARealInterface() {
        func request(_ name: String?) -> HelperRequest {
            HelperRequest(operation: .renewDHCP, operationID: UUID().uuidString,
                          clientBuild: "23", invokingUser: validInvokingUserClaim,
                          networkInterface: name)
        }
        // Well-formed AND present on the machine.
        XCTAssertNil(request("en0").validate(expectedBuild: "23", liveInterfaces: ["en0", "lo0"]))
        // Well-formed but not a real interface here — still refused.
        XCTAssertEqual(request("en9").validate(expectedBuild: "23", liveInterfaces: ["en0"]),
                       .invalidInterface)
        // Malformed.
        XCTAssertEqual(request("en0;id").validate(expectedBuild: "23", liveInterfaces: ["en0"]),
                       .invalidInterface)
        // Missing entirely.
        XCTAssertEqual(request(nil).validate(expectedBuild: "23", liveInterfaces: ["en0"]),
                       .invalidInterface)
    }

    /// An interface on an operation that takes none means the caller and the
    /// contract disagree. Refused, not ignored.
    func testValidate_rejectsAnInterfaceOnOperationsThatTakeNone() {
        for operation in [HelperOperation.clean, .optimize, .scan, .optimizeScan,
                          .flushDNS, .readLoginItems] {
            let request = HelperRequest(operation: operation, operationID: UUID().uuidString,
                                        clientBuild: "23", invokingUser: validInvokingUserClaim,
                                        networkInterface: "en0")
            XCTAssertEqual(request.validate(expectedBuild: "23", liveInterfaces: ["en0"]),
                           .invalidInterface, "\(operation) takes no interface")
        }
    }

    // MARK: - Fixed argv (the client contributes nothing)
    //
    // The daemon reproduces the engine argv from the enum ALONE, so an attacker
    // who fully controls the XPC payload still cannot add a flag. It is spelled
    // in the ENGINE's convention (preview by default, `--apply` to act) and is
    // always streamed, because the daemon relays stdout live over XPC.

    func testEngineArguments_areFixedPerOperation() {
        XCTAssertEqual(HelperOperation.scan.engineArguments, ["clean", "--dry-run", "--stream"])
        XCTAssertEqual(HelperOperation.clean.engineArguments, ["clean", "--apply", "--stream"])
        XCTAssertEqual(HelperOperation.optimize.engineArguments, ["optimize", "--apply", "--stream"])
        XCTAssertEqual(HelperOperation.optimizeScan.engineArguments, ["optimize", "--dry-run", "--stream"])
        // The network fixes don't drive the engine at all.
        XCTAssertNil(HelperOperation.flushDNS.engineArguments)
        XCTAssertNil(HelperOperation.renewDHCP.engineArguments)
    }

    /// The live operations act and the previews say so on the wire: `--apply` on
    /// exactly the mutating engine operations, `--dry-run` on exactly the
    /// previews, never both, never neither.
    func testEngineArguments_applyExactlyWhenTheOperationMutates() {
        for operation in HelperOperation.allCases {
            guard let argv = operation.engineArguments else { continue }
            XCTAssertEqual(argv.contains("--apply"), operation.mutatesDisk,
                           "\(operation) must carry --apply iff it mutates")
            XCTAssertEqual(argv.contains("--dry-run"), !operation.mutatesDisk,
                           "\(operation) must state --dry-run iff it is a preview")
            XCTAssertTrue(argv.contains("--stream"), "\(operation) relays a live stream")
        }
    }

    /// argv goes to posix_spawn, never a shell — but a stray metacharacter
    /// anywhere in here would signal that someone started templating strings
    /// into a command that runs as root.
    func testArguments_neverEmptyAndNeverShellMetacharacters() {
        // The reviewed clean is driven by the daemon's plan file, so it is given one.
        let planFile = "/private/tmp/burrow-helper-plan.abc123/plan.plan"
        for op in HelperOperation.allCases {
            let steps = op.steps(interface: "en0", reviewedPlanFile: planFile)
            XCTAssertFalse(steps.isEmpty, "\(op) must resolve to at least one command")
            for token in steps.flatMap(\.arguments) {
                XCTAssertFalse(token.contains(where: { ";|&`$<>\n\0".contains($0) }),
                               "\(op) argv token \(token) carries shell/NUL metacharacters")
            }
        }
    }

    /// Decoding is the ONLY way a request enters the daemon, and the operation
    /// is an enum — an unknown verb fails to decode rather than falling through
    /// to some default. This is the test that keeps "run" from ever being a
    /// smuggled operation.
    func testDecoding_rejectsUnknownOperation() throws {
        let payload = #"{"operation":"run","operationID":"\#(UUID().uuidString)","clientBuild":"23"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(HelperRequest.self, from: Data(payload.utf8)))
    }

    func testDecoding_roundTripsEveryOperation() throws {
        for op in HelperOperation.allCases {
            let request = HelperRequest(operation: op, operationID: UUID().uuidString,
                                        clientBuild: "23", invokingUser: validInvokingUserClaim)
            let data = try JSONEncoder().encode(request)
            XCTAssertEqual(try JSONDecoder().decode(HelperRequest.self, from: data), request)
        }
    }

    // MARK: - Validation (named rejections, never a partial run)

    func testValidate_acceptsAWellFormedRequest() {
        let request = HelperRequest(operation: .clean, operationID: UUID().uuidString,
                                    clientBuild: "23", invokingUser: validInvokingUserClaim)
        XCTAssertNil(request.validate(expectedBuild: "23"))
    }

    func testValidate_rejectsMalformedInvokingUserClaims() {
        let claims = [
            HelperInvokingUserClaim(uid: 0, canonicalHome: "/var/root"),
            HelperInvokingUserClaim(uid: 501, canonicalHome: "/private/var/root"),
            HelperInvokingUserClaim(uid: 501, canonicalHome: "Users/test"),
            HelperInvokingUserClaim(uid: 501, canonicalHome: "/Users/test\nother"),
        ]
        for claim in claims {
            let request = HelperRequest(operation: .clean,
                                        operationID: UUID().uuidString,
                                        clientBuild: "23",
                                        invokingUser: claim)
            XCTAssertEqual(request.validate(expectedBuild: "23"), .invalidInvokingUser)
        }
    }

    /// A non-UUID operation ID is rejected outright. The ID is the replay key,
    /// so a client-chosen constant ("1") would let a single authorization be
    /// reused; requiring a UUID makes every request distinguishable.
    func testValidate_rejectsNonUUIDOperationID() {
        for bad in ["", "1", "not-a-uuid", String(repeating: "a", count: 400)] {
            let request = HelperRequest(operation: .clean, operationID: bad,
                                        clientBuild: "23", invokingUser: validInvokingUserClaim)
            XCTAssertEqual(request.validate(expectedBuild: "23"), .malformedOperationID,
                           "operation ID \(bad.prefix(12)) must be rejected")
        }
    }

    /// Version skew is a rejection, not a "try anyway". A stale helper paired
    /// with a new app could hold an older idea of what `clean` does, and it
    /// runs as root — so the mismatch stops the operation and the GUI
    /// re-registers instead.
    func testValidate_rejectsBuildMismatch() {
        let request = HelperRequest(operation: .clean, operationID: UUID().uuidString,
                                    clientBuild: "22", invokingUser: validInvokingUserClaim)
        XCTAssertEqual(request.validate(expectedBuild: "23"), .buildMismatch)
    }

    func testValidate_rejectsEmptyBuild() {
        let request = HelperRequest(operation: .clean, operationID: UUID().uuidString,
                                    clientBuild: "", invokingUser: validInvokingUserClaim)
        XCTAssertEqual(request.validate(expectedBuild: "23"), .buildMismatch)
    }

    // MARK: - Replay resistance
    //
    // One authorization authorizes ONE operation. The daemon remembers the IDs
    // it has already served so a captured payload (auth external form included)
    // cannot be re-sent to get a second root run out of one prompt.

    func testReplayGuard_admitsEachIDOnce() {
        let guardian = HelperReplayGuard()
        let id = UUID().uuidString
        XCTAssertTrue(guardian.admit(id), "first use of an ID is allowed")
        XCTAssertFalse(guardian.admit(id), "the same ID must never be served twice")
        XCTAssertFalse(guardian.admit(id))
    }

    func testReplayGuard_distinctIDsAllPass() {
        let guardian = HelperReplayGuard()
        for _ in 0..<50 {
            XCTAssertTrue(guardian.admit(UUID().uuidString))
        }
    }

    /// A flood of fresh IDs must NOT be able to push an older one back out of
    /// the set. Count-bounded FIFO eviction looks equivalent to age-based
    /// eviction until you notice that the attacker chooses the traffic: send
    /// `capacity` fresh IDs and the ID you wanted to replay is forgotten, which
    /// turns the memory bound into the replay bypass it was meant to prevent.
    func testReplayGuard_floodOfFreshIDsCannotEvictAStillReplayableID() {
        // Capacity 8 still makes the flood 8x the count bound, which is the
        // point; it just stays clear of the hard ceiling exercised below, so
        // this test fails only for the reason it is about.
        let guardian = HelperReplayGuard(capacity: 8)
        let victim = UUID().uuidString
        XCTAssertTrue(guardian.admit(victim))
        for _ in 0..<64 { XCTAssertTrue(guardian.admit(UUID().uuidString)) }

        XCTAssertFalse(guardian.admit(victim),
                       "an ID inside the retention window must never become replayable")
    }

    /// Age-based eviction alone leaves the set unbounded: every ID inside the
    /// retention window is kept, so a caller sending fresh IDs grows a root
    /// process's memory for an hour. The ceiling stops ADMITTING rather than
    /// starting to forget — a refused request is recoverable, a forgotten ID
    /// is replayable.
    func testReplayGuard_failsClosedAtTheMemoryCeilingRatherThanForgetting() {
        let guardian = HelperReplayGuard(capacity: 2)   // ceiling = 32
        let victim = UUID().uuidString
        XCTAssertTrue(guardian.admit(victim))
        while guardian.count < 32 {
            XCTAssertTrue(guardian.admit(UUID().uuidString))
        }

        XCTAssertFalse(guardian.admit(UUID().uuidString),
                       "a full guard must refuse new work, not make room")
        XCTAssertFalse(guardian.admit(victim),
                       "and must still refuse the replay it was holding")
        XCTAssertEqual(guardian.count, 32, "a refused ID is not recorded")
    }

    /// Memory is still bounded, just by time rather than by count: entries are
    /// forgotten once they are far older than any authorization could still be
    /// valid for, so nothing usable is ever discarded.
    func testReplayGuard_forgetsOnlyEntriesPastTheRetentionWindow() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let guardian = HelperReplayGuard(capacity: 8, retention: 60, now: { now })
        let old = UUID().uuidString
        let recent = UUID().uuidString
        XCTAssertTrue(guardian.admit(old))
        now = now.addingTimeInterval(59)
        XCTAssertTrue(guardian.admit(recent))

        // Cross the window for `old` but not for `recent`.
        now = now.addingTimeInterval(2)
        XCTAssertFalse(guardian.admit(recent), "a still-fresh ID stays remembered")
        XCTAssertTrue(guardian.admit(old), "an expired ID is forgotten and its slot reclaimed")
    }

    // MARK: - Response encoding
    //
    // The reply crosses XPC as bytes, so it round-trips like the request. The
    // failure cases are NAMED (matching the existing ElevatedOutcome taxonomy)
    // so the GUI shows the right message instead of re-deriving meaning from a
    // bare nonzero exit — the same rule issue #48 established for osascript.

    func testResponse_roundTripsEveryOutcome() throws {
        let outcomes: [HelperResponse.Outcome] = [
            .exited(0), .exited(2),
            .authorizationCancelled,
            .authorizationDenied,
            .rejected(.buildMismatch),
            .rejected(.replayedOperationID),
            .rejected(.invalidInvokingUser),
            .engineUnavailable,
        ]
        for outcome in outcomes {
            let data = try JSONEncoder().encode(HelperResponse(outcome: outcome))
            XCTAssertEqual(try JSONDecoder().decode(HelperResponse.self, from: data).outcome, outcome)
        }
    }

    /// The GUI still has call sites that branch on an Int32. Every failure
    /// shape must collapse to a NONZERO code, exactly as `ElevatedOutcome`
    /// does today — a cancelled prompt must never read as success.
    func testResponse_everyFailureIsNonzeroToLegacyCallers() {
        XCTAssertEqual(HelperResponse.Outcome.exited(0).exitCode, 0)
        XCTAssertEqual(HelperResponse.Outcome.exited(3).exitCode, 3)
        for failure: HelperResponse.Outcome in [.authorizationCancelled, .authorizationDenied,
                                                .rejected(.malformedPayload), .engineUnavailable] {
            XCTAssertNotEqual(failure.exitCode, 0, "\(failure) must not read as success")
        }
    }

    /// A cancelled authorization maps onto the SAME user-facing meaning as the
    /// osascript path's `.authCancelled`, so both elevation routes tell the
    /// user the same thing and the GUI needs no second taxonomy.
    func testResponse_mapsOntoTheExistingElevatedOutcomeTaxonomy() {
        XCTAssertEqual(HelperResponse.Outcome.exited(0).elevatedOutcome, .exited(0))
        XCTAssertEqual(HelperResponse.Outcome.exited(7).elevatedOutcome, .exited(7))
        XCTAssertEqual(HelperResponse.Outcome.authorizationCancelled.elevatedOutcome, .authCancelled)
        XCTAssertEqual(HelperResponse.Outcome.engineUnavailable.elevatedOutcome, .launchFailed)
        XCTAssertEqual(HelperResponse.Outcome.authorizationDenied.elevatedOutcome, .authCancelled)
    }
}

// MARK: - Reviewed cleanup targets
//
// The one operation that accepts data from the caller beyond a verb. Every
// rule below is enforced against facts the DAEMON gathers, so these tests
// inject the inspection rather than the policy trusting a supplied fact.

final class HelperReviewedPathPolicyTests: XCTestCase {
    private let uid: UInt32 = 501
    private let homeDevice: UInt64 = 1
    private let cacheDevice: UInt64 = 1

    private var roots: [HelperReviewedRoot] {
        [
            HelperReviewedRoot(path: "/Users/henry", device: homeDevice, allowsForeignOwner: false),
            HelperReviewedRoot(path: "/Library/Caches", device: cacheDevice, allowsForeignOwner: true),
        ]
    }

    private func target(device: UInt64? = nil,
                        owner: UInt32? = nil,
                        exists: Bool = true,
                        isSymbolicLink: Bool = false,
                        canonical: String?) -> HelperReviewedTarget {
        HelperReviewedTarget(exists: exists, isSymbolicLink: isSymbolicLink,
                             canonicalPath: canonical,
                             device: device ?? homeDevice, ownerUID: owner ?? uid)
    }

    private func validate(_ paths: [String],
                          inspect: @escaping (String) -> HelperReviewedTarget)
        -> Result<[String], HelperReviewedPathRejection> {
        HelperReviewedPathPolicy.validate(paths: paths, roots: roots,
                                          invokingUID: uid, inspect: inspect)
    }

    func testAcceptsOwnedEntriesBelowAnApprovedRoot() throws {
        let path = "/Users/henry/Library/Caches/app"
        let result = validate([path]) { [unowned self] in self.target(canonical: $0) }
        XCTAssertEqual(try result.get(), [path])
    }

    func testRefusesAPathOutsideEveryApprovedRoot() {
        let result = validate(["/System/Library/Caches/x"]) { [unowned self] in self.target(canonical: $0) }
        XCTAssertEqual(result.failureRejection, .outsideApprovedRoots)
    }

    /// A root itself is not a cache entry. Deleting `/Library/Caches` wholesale
    /// is never what a reviewed selection meant.
    func testRefusesAnApprovedRootItself() {
        let result = validate(["/Library/Caches"]) { [unowned self] in self.target(canonical: $0) }
        XCTAssertEqual(result.failureRejection, .outsideApprovedRoots)
    }

    func testRefusesTraversalOutOfAnApprovedRoot() {
        let result = validate(["/Users/henry/../root/.ssh"]) { [unowned self] in self.target(canonical: $0) }
        XCTAssertEqual(result.failureRejection, .malformedPath)
    }

    /// A symlink would put the delete wherever it points, which is the whole
    /// reason the daemon lstats instead of trusting the string.
    func testRefusesASymbolicLink() {
        let result = validate(["/Users/henry/Library/Caches/link"]) { [unowned self] in
            self.target(isSymbolicLink: true, canonical: $0)
        }
        XCTAssertEqual(result.failureRejection, .symbolicLink)
    }

    /// realpath disagreeing with the literal path means some ANCESTOR is a
    /// link, so the entry is not where the client says it is.
    func testRefusesWhenAnAncestorIsASymbolicLink() {
        let result = validate(["/Users/henry/Library/Caches/app"]) { [unowned self] _ in
            self.target(canonical: "/Volumes/elsewhere/app")
        }
        XCTAssertEqual(result.failureRejection, .notCanonical)
    }

    func testRefusesAnEntryOnAnotherVolume() {
        let result = validate(["/Users/henry/Library/Caches/app"]) { [unowned self] in
            self.target(device: 99, canonical: $0)
        }
        XCTAssertEqual(result.failureRejection, .foreignVolume)
    }

    /// The escalation that matters. Per-user trees hold other accounts' files,
    /// and root deleting those is something the invoking user could not do
    /// themselves — unlike anything in their own home.
    func testRefusesAnotherAccountsEntryInAPerUserTree() {
        let result = validate(["/Users/henry/Library/Caches/app"]) { [unowned self] in
            self.target(owner: 502, canonical: $0)
        }
        XCTAssertEqual(result.failureRejection, .foreignOwner)
    }

    /// System cache trees are root-owned and shared, so foreign ownership
    /// there is normal rather than suspicious.
    func testAllowsForeignOwnershipUnderSharedSystemCaches() throws {
        let path = "/Library/Caches/com.apple.something"
        let result = validate([path]) { [unowned self] in self.target(owner: 0, canonical: $0) }
        XCTAssertEqual(try result.get(), [path])
    }

    func testRefusesAMissingEntryRatherThanSkippingIt() {
        let result = validate(["/Users/henry/Library/Caches/gone"]) { [unowned self] in
            self.target(exists: false, canonical: $0)
        }
        XCTAssertEqual(result.failureRejection, .missingPath)
    }

    func testRefusesAnEmptyOrOversizedSelection() {
        XCTAssertEqual(validate([]) { [unowned self] in self.target(canonical: $0) }.failureRejection,
                       .emptySelection)
        let many = (0...HelperReviewedPathPolicy.maximumTargets)
            .map { "/Users/henry/Library/Caches/app-\($0)" }
        XCTAssertEqual(validate(many) { [unowned self] in self.target(canonical: $0) }.failureRejection,
                       .tooManyTargets)
    }

    func testDeduplicatesRepeatedEntries() throws {
        let path = "/Users/henry/Library/Caches/app"
        let result = validate([path, path]) { [unowned self] in self.target(canonical: $0) }
        XCTAssertEqual(try result.get(), [path])
    }
}

final class HelperReviewedRequestTests: XCTestCase {
    private func claim() -> HelperInvokingUserClaim {
        HelperInvokingUserClaim(uid: 501, canonicalHome: "/Users/henry")
    }

    private func request(_ operation: HelperOperation, paths: [String]) -> HelperRequest {
        HelperRequest(operation: operation, operationID: UUID().uuidString,
                      clientBuild: "1", invokingUser: claim(), reviewedPaths: paths,
                      reviewedSelection: operation.needsReviewedPaths
                          ? HelperReviewedSelection(expiresAt: Date().addingTimeInterval(300), roots: [], items: [])
                          : nil)
    }

    func testReviewedPathsRoundTripAcrossTheWire() throws {
        let original = request(.cleanReviewed, paths: ["/Users/henry/Library/Caches/a"])
        let decoded = try JSONDecoder().decode(
            HelperRequest.self, from: try JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testCleanReviewedRequiresAtLeastOnePath() {
        XCTAssertEqual(request(.cleanReviewed, paths: []).validate(expectedBuild: "1"),
                       .invalidReviewedPaths)
    }

    func testCleanReviewedRefusesPathsWithoutOriginalIdentities() {
        let unpinned = HelperRequest(operation: .cleanReviewed, operationID: UUID().uuidString,
                                    clientBuild: "1", invokingUser: claim(),
                                    reviewedPaths: ["/Users/henry/Library/Caches/a"])
        XCTAssertEqual(unpinned.validate(expectedBuild: "1"), .invalidReviewedPaths)
    }

    /// Paths on an operation that takes none means the caller and the contract
    /// disagree; refuse rather than silently ignoring them.
    func testOtherOperationsRefusePathsRatherThanIgnoringThem() {
        XCTAssertEqual(request(.clean, paths: ["/Users/henry/x"]).validate(expectedBuild: "1"),
                       .invalidReviewedPaths)
    }

    /// The recogniser maps engine argv onto operations. A reviewed cleanup has
    /// no engine argv, so it must never be reachable that way.
    func testReviewedCleanupIsNotReachableFromEngineArguments() {
        for operation in HelperOperation.allCases {
            if let argv = operation.engineArguments {
                XCTAssertNotEqual(HelperOperation(engineArguments: argv), .cleanReviewed)
            }
        }
        XCTAssertNil(HelperOperation.cleanReviewed.engineArguments)
    }

    /// The reviewed clean is ONE engine run over the daemon's plan file, with fixed flags:
    /// `--apply --permanent` (this is the permanent path), `--plan <file>` (no re-scan; the
    /// engine removes only the listed paths, each through its rails), `--stream` (live relay).
    func testStepsAreOneEngineRunOverTheDaemonsPlanFile() {
        let planFile = "/private/tmp/burrow-helper-plan.abc123/plan.plan"
        let steps = HelperOperation.cleanReviewed.steps(interface: nil, reviewedPlanFile: planFile)
        XCTAssertEqual(steps, [HelperStep(
            executable: .bundledEngine,
            arguments: ["clean", "--apply", "--permanent", "--plan", planFile, "--stream"])])
        XCTAssertTrue(HelperOperation.cleanReviewed.usesBundledEngine)
    }

    func testNoPlanFileMeansNoStepsRatherThanACleanOfSomethingElse() {
        XCTAssertTrue(HelperOperation.cleanReviewed.steps(interface: nil,
                                                          reviewedPlanFile: nil).isEmpty)
    }
}

private extension Result where Success == [String], Failure == HelperReviewedPathRejection {
    var failureRejection: HelperReviewedPathRejection? {
        if case .failure(let rejection) = self { return rejection }
        return nil
    }
}
