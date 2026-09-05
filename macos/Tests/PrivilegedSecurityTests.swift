import XCTest
import Darwin
@testable import Burrow

final class PrivilegedIdentityTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow identity \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        temp = URL(fileURLWithPath: try XCTUnwrap(InvokingUserIdentity.canonicalPath(temp.path)))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    func testInvokingUser_selectsNumericUIDAmongSeveralAccountsAndPreservesSpaces() throws {
        let accounts = [
            InvokingUserIdentity.Account(uid: 502, name: "other", home: "/Users/other"),
            InvokingUserIdentity.Account(uid: 501, name: "henry", home: temp.path),
        ]
        let user = try InvokingUserIdentity.resolve(invokingUID: 501, accounts: accounts)
        XCTAssertEqual(user.uid, 501)
        XCTAssertEqual(user.username, "henry")
        XCTAssertEqual(user.canonicalHome, temp.path)
    }

    func testInvokingUser_canonicalizesSymlinkedHomeBeforeElevation() throws {
        let link = temp.deletingLastPathComponent().appendingPathComponent("home-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: temp)
        defer { try? FileManager.default.removeItem(at: link) }

        let user = try InvokingUserIdentity.resolve(
            invokingUID: 501,
            accounts: [.init(uid: 501, name: "henry", home: link.path)])
        XCTAssertEqual(user.canonicalHome, temp.path)
    }

    func testInvokingUser_refusesMissingRootAndVarRootMismatch() {
        XCTAssertThrowsError(try InvokingUserIdentity.resolve(invokingUID: 501, accounts: []))
        XCTAssertThrowsError(try InvokingUserIdentity.resolve(
            invokingUID: 0, accounts: [.init(uid: 0, name: "root", home: "/var/root")]))
        XCTAssertThrowsError(try InvokingUserIdentity.resolve(
            invokingUID: 501,
            accounts: [.init(uid: 501, name: "root", home: "/var/root")],
            canonicalize: { $0 }))
    }

    func testInvokingUser_refusesHomeOwnedByAnotherAccount() {
        let otherUID = getuid() &+ 1
        XCTAssertThrowsError(try InvokingUserIdentity.resolve(
            invokingUID: otherUID,
            accounts: [.init(uid: otherUID, name: "other", home: temp.path)])) { error in
            guard case InvokingUserIdentity.ResolutionError.mismatchedHomeOwner(
                expected: otherUID, actual: getuid()) = error else {
                return XCTFail("expected mismatched home ownership, got \(error)")
            }
        }
    }

    func testElevatedScriptPinsInvokingIdentityRatherThanRootHome() {
        let executable = PinnedFileIdentity(path: "/usr/bin/true", device: 1, inode: 2,
                                            owner: 0, mode: UInt16(S_IFREG | 0o755))
        let user = InvokingUserIdentity(uid: 501, username: "name with space",
                                        canonicalHome: "/Users/name with space")
        let command = ValidatedElevatedCommand(executable: executable, components: [],
                                               invokingUser: user, signedBundlePath: nil)
        let script = EngineCLI.elevatedScript(command: command, args: [])
        XCTAssertTrue(script.contains("'HOME=/Users/name with space'"))
        XCTAssertTrue(script.contains("'SUDO_UID=501'"))
        XCTAssertFalse(script.contains("HOME=/var/root"))
        XCTAssertTrue(script.contains("'BURROW_HOME=/Users/name with space'"))
        XCTAssertTrue(script.contains("'BURROW_PRIVILEGED=1'"))
    }

    /// The layout every shipped copy of Burrow actually has.
    ///
    /// `/Applications` is `root:admin` mode 0775 on stock macOS and an app
    /// dragged there (or installed by a Homebrew cask) is owned by the account
    /// that installed it. A rule demanding root ownership of the engine and
    /// every ancestor is therefore unsatisfiable in production, and the only
    /// place it shows up is at runtime, as a refusal with no prompt.
    private func makeApplicationsLayout() throws -> (bundle: String, engine: String) {
        let applications = temp.appendingPathComponent("Applications", isDirectory: true)
        let bundle = applications.appendingPathComponent("Burrow.app", isDirectory: true)
        let engineDirectory = bundle.appendingPathComponent("Contents/Resources/engine",
                                                            isDirectory: true)
        try FileManager.default.createDirectory(at: engineDirectory,
                                                withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o775],
                                              ofItemAtPath: applications.path)
        let engine = engineDirectory.appendingPathComponent("mole")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: engine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: engine.path)
        return (bundle.path, engine.path)
    }

    private var currentUser: InvokingUserIdentity {
        InvokingUserIdentity(uid: getuid(), username: NSUserName(),
                             canonicalHome: NSHomeDirectory())
    }

    func testBundledEngineIsAcceptedUnderAGroupWritableApplicationsDirectory() throws {
        let layout = try makeApplicationsLayout()
        let command = try ValidatedElevatedCommand.prepare(
            executable: layout.engine, invokingUser: currentUser,
            requireCurrentBundle: true, bundlePath: layout.bundle)

        XCTAssertEqual(command.signedBundlePath, layout.bundle)
        // Ownership stopped being the guarantee, so the resource seal has to
        // be checked at the boundary — without it nothing is verifying this.
        let script = EngineCLI.elevatedScript(command: command, args: ["optimize"])
        XCTAssertTrue(script.contains("/usr/bin/codesign --verify --strict"),
                      "the signed-bundle policy is only safe with the seal check")
        XCTAssertTrue(script.contains("/usr/bin/stat -f '%d:%i:%u:%p'"),
                      "every ancestor stays pinned regardless of who owns it")
    }

    func testBundledEngineIsRefusedWhenAnAncestorIsWorldWritable() throws {
        let layout = try makeApplicationsLayout()
        // Group-writable is normal; world-writable would let an unrelated
        // account do the swapping, and no install layout needs that.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777],
            ofItemAtPath: temp.appendingPathComponent("Applications").path)

        XCTAssertThrowsError(try ValidatedElevatedCommand.prepare(
            executable: layout.engine, invokingUser: currentUser,
            requireCurrentBundle: true, bundlePath: layout.bundle))
    }

    func testBundledEnginePolicyDoesNotLeakToExecutablesOutsideTheBundle() throws {
        let layout = try makeApplicationsLayout()
        // The same user-owned file, asked for WITHOUT the bundle seal, must
        // still be refused: relaxing ownership is only paid for by the seal.
        XCTAssertThrowsError(try ValidatedElevatedCommand.prepare(
            executable: layout.engine, invokingUser: currentUser,
            requireCurrentBundle: false, bundlePath: layout.bundle))
    }

    func testUserMutableExecutableIsRejectedAndReplacementBreaksPinnedIdentity() throws {
        let executable = temp.appendingPathComponent("mo")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let user = InvokingUserIdentity(uid: getuid(), username: NSUserName(), canonicalHome: NSHomeDirectory())
        XCTAssertThrowsError(try ValidatedElevatedCommand.prepare(
            executable: executable.path, invokingUser: user, requireCurrentBundle: false))

        let pinned = try PinnedFileIdentity.capture(executable.path)
        try FileManager.default.removeItem(at: executable)
        try Data("#!/bin/sh\nexit 9\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        XCTAssertFalse(pinned.matchesCurrent(), "a hostile same-path replacement must fail its inode check")
    }
}

final class CleanupAuthorizationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-clean-auth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: try XCTUnwrap(InvokingUserIdentity.canonicalPath(root.path)))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func list(_ paths: [String]) -> CleanList {
        CleanList(categories: [.init(name: "Test", items: paths.map {
            .init(path: $0, sizeBytes: 1, sizeText: "1B", itemCount: nil)
        })], summaryTotalText: "1B", summaryItemCount: paths.count)
    }

    func testSnapshotAcceptsCanonicalPathsWithSpacesAndPinsReviewedIdentity() throws {
        let item = root.appendingPathComponent("cache with spaces")
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false)
        let snapshot = try CleanupSnapshot.capture(list: list([item.path]),
                                                   approvedRootURLs: [root])
        let plan = try snapshot.plan(selectedPaths: [item.path])
        XCTAssertTrue(plan.validateForLaunch())
        XCTAssertEqual(plan.items.map(\.identity.path), [item.path])
    }

    func testSnapshotRejectsControlsNULJSONRelativeSymlinkAndOutsideRoots() throws {
        for malformed in ["relative/cache", "{\"path\":\"/tmp/x\"}",
                          "/tmp/bad\npath", "/tmp/bad\0suffix"] {
            XCTAssertThrowsError(try CleanupSnapshot.capture(
                list: list([malformed]), approvedRootURLs: [root]), malformed)
        }

        // A well-formed entry that simply can't be represented is SKIPPED, not
        // fatal — see testOneUnrepresentableEntryDoesNotKillTheWholePreview.
        // Alone in a list it leaves nothing to clean, which is still an error.
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: outside) }
        XCTAssertThrowsError(try CleanupSnapshot.capture(list: list([outside.path]),
                                                         approvedRootURLs: [root]))

        let real = root.appendingPathComponent("real")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertThrowsError(try CleanupSnapshot.capture(list: list([link.path]),
                                                         approvedRootURLs: [root]))
    }

    /// The bug that broke Clean for essentially everyone.
    ///
    /// The engine's export writer collapses siblings to their common PARENT,
    /// so a category removing two or more loose files directly inside an
    /// approved root records the ROOT. `find "$HOME" -name .DS_Store` over a
    /// home folder with more than one match writes `/Users/<you>`, and almost
    /// every Mac has that. Accepting it would have meant deleting the home
    /// directory, so refusing is right — but refusing the whole preview took
    /// the Clean button with it and blocked gigabytes of valid cleanup.
    func testOneUnrepresentableEntryDoesNotKillTheWholePreview() throws {
        let good = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: good, withIntermediateDirectories: false)

        // `root.path` is the approved root itself — exactly what the collapse
        // produces for a home-directory sweep.
        let snapshot = try CleanupSnapshot.capture(list: list([root.path, good.path]),
                                                   approvedRootURLs: [root])

        XCTAssertEqual(snapshot.items.map(\.identity.path), [good.path],
                       "the usable entry survives")
        XCTAssertEqual(snapshot.skipped.map(\.path), [root.path],
                       "the root-collapsed entry is refused and reported")

        // And it must never reach a plan: this is the difference between
        // deleting a cache directory and deleting someone's home folder.
        let plan = try snapshot.plan(selectedPaths: [good.path])
        XCTAssertEqual(plan.items.map(\.identity.path), [good.path])
        XCTAssertThrowsError(try snapshot.plan(selectedPaths: [root.path, good.path]),
                             "a refused entry cannot be selected back in")
    }

    /// Skipping must not become a way to launder a corrupt list. A path the
    /// engine's writer cannot produce means the list isn't the engine's, and
    /// partially executing it would be the wrong call.
    func testStructurallyCorruptPreviewsAreStillFatalRatherThanSkipped() {
        for corrupt in ["relative/cache", "{\"path\":\"/tmp/x\"}", "/tmp/bad\npath"] {
            XCTAssertThrowsError(try CleanupSnapshot.capture(
                list: list([corrupt, root.appendingPathComponent("cache").path]),
                approvedRootURLs: [root]), corrupt)
        }
    }

    /// Why a fully successful clean reported "exit 1".
    ///
    /// The engine's export list routinely names a parent AND its own children
    /// as separate entries. Delete the parent first and every nested entry is
    /// already gone when its turn comes, so `find` exits nonzero with "No such
    /// file or directory" for work that succeeded. Deepest-first means each
    /// entry still exists when it is reached — and both elevation routes have
    /// to use this order, since the helper path skipping it is what produced
    /// the failure.
    func testNestedEntriesAreOrderedDeepestFirstSoNoneVanishesBeforeItsTurn() throws {
        let caches = root.appendingPathComponent("Caches")
        let nested = caches.appendingPathComponent("GeoServices")
        let deeper = nested.appendingPathComponent("tiles")
        try FileManager.default.createDirectory(at: deeper, withIntermediateDirectories: true)

        // Parent first in the list, exactly as the engine emits it.
        let snapshot = try CleanupSnapshot.capture(
            list: list([caches.path, nested.path, deeper.path]), approvedRootURLs: [root])
        let plan = try snapshot.plan(
            selectedPaths: [caches.path, nested.path, deeper.path])

        XCTAssertEqual(plan.orderedReviewedPaths(), [deeper.path, nested.path, caches.path],
                       "a parent must never be deleted before its own listed children")
        // The plan file both elevation routes hand the engine is written in that order.
        let dir = root.appendingPathComponent("plans", isDirectory: true)
        let file = try plan.writePlanFile(in: dir)
        let listed = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") }
        XCTAssertEqual(listed, [deeper.path, nested.path, caches.path])
    }

    func testApprovedRootRejectsUnexpectedVolumeIdentity() throws {
        let rootIdentity = try PinnedFileIdentity.capture(root.path)
        XCTAssertThrowsError(try CleanupSnapshot.approvedRoot(
            for: root.path + "/cache", device: rootIdentity.device + 1, roots: [rootIdentity])) {
            XCTAssertEqual($0 as? CleanupSnapshot.SnapshotError,
                           .unexpectedVolume(root.path + "/cache"))
        }
    }

    func testPlanFailsClosedWhenStaleOrSymlinkSwapped() throws {
        let item = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false)
        let old = Date(timeIntervalSince1970: 1_000)
        let snapshot = try CleanupSnapshot.capture(list: list([item.path]),
                                                   approvedRootURLs: [root], now: old)
        XCTAssertThrowsError(try snapshot.plan(selectedPaths: [item.path],
                                               now: old.addingTimeInterval(301)))

        let moved = root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: item, to: moved)
        try FileManager.default.createSymbolicLink(at: item, withDestinationURL: moved)
        XCTAssertThrowsError(try snapshot.plan(selectedPaths: [item.path], now: old))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path),
                      "malformed/swapped directories are refused, never auto-deleted")
    }

    func testTrashMoveRestoresAnUnreviewedObjectCapturedByAPathRace() throws {
        let reviewed = root.appendingPathComponent("reviewed")
        let original = root.appendingPathComponent("original-reviewed")
        let fakeTrash = root.appendingPathComponent("fake-trash")
        try FileManager.default.createDirectory(at: reviewed, withIntermediateDirectories: false)
        try Data("reviewed".utf8).write(to: reviewed.appendingPathComponent("marker"))
        let snapshot = try CleanupSnapshot.capture(list: list([reviewed.path]),
                                                   approvedRootURLs: [root])
        let plan = try snapshot.plan(selectedPaths: [reviewed.path])

        let result = CleanupExecutor.moveToTrash(plan) { source in
            // Simulate a same-user process replacing the reviewed name in the
            // instant after launch validation but before the Trash rename.
            try FileManager.default.moveItem(at: source, to: original)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            try Data("unreviewed".utf8).write(to: source.appendingPathComponent("marker"))
            try FileManager.default.moveItem(at: source, to: fakeTrash)
            return fakeTrash
        }

        XCTAssertEqual(result, .init(moved: 0, failed: 1))
        XCTAssertEqual(try String(contentsOf: reviewed.appendingPathComponent("marker")),
                       "unreviewed", "the raced object must be restored, not deleted")
        XCTAssertEqual(try String(contentsOf: original.appendingPathComponent("marker")),
                       "reviewed", "the reviewed inode remains untouched when its name changes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fakeTrash.path))
    }

    /// The plan file names exactly the reviewed entries — paths that came out of the dry run's
    /// enumeration and were pinned at review — and nothing else. Its contents are the engine's
    /// delete list, so this is the assertion that Confirm cannot widen the review.
    func testPlanFileListsExactlyTheReviewedPathsAndNothingElse() throws {
        let a = root.appendingPathComponent("cache-a")
        let b = root.appendingPathComponent("cache-b")
        let unticked = root.appendingPathComponent("cache-unticked")
        for dir in [a, b, unticked] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        }
        let snapshot = try CleanupSnapshot.capture(list: list([a.path, b.path, unticked.path]),
                                                   approvedRootURLs: [root])
        let plan = try snapshot.plan(selectedPaths: [a.path, b.path])

        let dir = root.appendingPathComponent("plans", isDirectory: true)
        let file = try plan.writePlanFile(in: dir)
        defer { try? FileManager.default.removeItem(at: file) }
        let listed = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") }
        XCTAssertEqual(Set(listed), [a.path, b.path])
        XCTAssertFalse(listed.contains(unticked.path), "an unticked entry never reaches the plan")
        XCTAssertTrue(listed.allSatisfy { $0.hasPrefix("/") && !$0.contains("/../") })
    }

    /// The osascript route's shell: the boundary checks run, and only then the engine. With the
    /// review intact the command runs; nothing in the shell deletes anything itself.
    func testGuardedShellRunsTheEngineCommandWhenTheReviewIsIntact() throws {
        let item = root.appendingPathComponent("permanent cache")
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false)
        let snapshot = try CleanupSnapshot.capture(list: list([item.path]),
                                                   approvedRootURLs: [root])
        let plan = try snapshot.plan(selectedPaths: [item.path])
        let marker = root.appendingPathComponent("engine-ran")

        let shell = plan.guardedShell(running: "/usr/bin/touch \(EngineCLI.shellQuote(marker.path))")
        XCTAssertTrue(shell.contains("/usr/bin/stat -f '%d:%i:%u:%p'"),
                      "the reviewed identity must still be re-checked at the boundary")
        XCTAssertFalse(shell.contains("-delete"), "the shell no longer deletes; the engine does")
        XCTAssertTrue(shell.hasSuffix("/usr/bin/touch \(EngineCLI.shellQuote(marker.path))"),
                      "the engine command is the LAST statement, after every check")

        XCTAssertEqual(try runCleanupShell(shell), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "the command ran")
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.path),
                      "the shell itself touched nothing that was reviewed")
    }

    func testElevatedEngineUsesTheImmutableReviewAndCleansUpItsPrivatePlan() throws {
        let item = root.appendingPathComponent("reviewed ' cache")
        let unreviewed = root.appendingPathComponent("unreviewed")
        for directory in [item, unreviewed] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        let snapshot = try CleanupSnapshot.capture(list: list([item.path]), approvedRootURLs: [root])
        let plan = try snapshot.plan(selectedPaths: [item.path])
        let guiPlan = try plan.writePlanFile(in: root.appendingPathComponent("gui-plans"))
        try Data((unreviewed.path + "\n").utf8).write(to: guiPlan)

        let captured = root.appendingPathComponent("captured-plan")
        let location = root.appendingPathComponent("private-plan-path")
        let permissions = root.appendingPathComponent("private-plan-mode")
        let reader = root.appendingPathComponent("fake-engine.sh")
        let script = """
        /bin/cat "$5" > \(EngineCLI.shellQuote(captured.path))
        /usr/bin/printf '%s' "$5" > \(EngineCLI.shellQuote(location.path))
        /usr/bin/stat -f '%Lp' "$5" > \(EngineCLI.shellQuote(permissions.path))
        """
        try Data(script.utf8).write(to: reader)
        let shell = plan.guardedEngineShell(commandPrefix: ["/bin/sh", reader.path])
        XCTAssertEqual(try runCleanupShell(shell), 0)
        XCTAssertEqual(try String(contentsOf: captured), try CleanPlanFile.render(paths: [item.path]))
        XCTAssertEqual(try String(contentsOf: permissions).trimmingCharacters(in: .whitespacesAndNewlines), "600")
        let privatePath = try String(contentsOf: location)
        XCTAssertNotEqual(privatePath, guiPlan.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: privatePath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: (privatePath as NSString).deletingLastPathComponent))
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unreviewed.path))
    }

    func testHelperSelectionRetainsIdentityAndExpiryAcrossAuthentication() throws {
        let item = root.appendingPathComponent("reviewed")
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false)
        let snapshot = try CleanupSnapshot.capture(list: list([item.path]), approvedRootURLs: [root])
        let plan = try snapshot.plan(selectedPaths: [item.path])
        let selection = try JSONDecoder().decode(HelperReviewedSelection.self,
                                                from: JSONEncoder().encode(plan.helperSelection))
        XCTAssertTrue(selection.matches(paths: [item.path]))
        XCTAssertFalse(selection.matches(paths: [item.path], now: plan.expiresAt.addingTimeInterval(1)))
        XCTAssertFalse(selection.matches(paths: [root.appendingPathComponent("unticked").path]))

        let moved = root.appendingPathComponent("original")
        try FileManager.default.moveItem(at: item, to: moved)
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false)
        XCTAssertFalse(selection.matches(paths: [item.path]),
                       "The helper must refuse an inode substituted while authentication was open")
    }

    func testGuardedShellRefusesBeforeTheEngineWhenTheReviewedInodeWasSwapped() throws {
        let item = root.appendingPathComponent("swapped")
        let moved = root.appendingPathComponent("moved-away")
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false)
        try Data("reviewed".utf8).write(to: item.appendingPathComponent("marker"))
        let snapshot = try CleanupSnapshot.capture(list: list([item.path]),
                                                   approvedRootURLs: [root])
        let plan = try snapshot.plan(selectedPaths: [item.path])
        let marker = root.appendingPathComponent("engine-ran")

        // Substitute a different directory at the reviewed NAME after review.
        try FileManager.default.moveItem(at: item, to: moved)
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false)
        try Data("unreviewed".utf8).write(to: item.appendingPathComponent("marker"))

        let shell = plan.guardedShell(running: "/usr/bin/touch \(EngineCLI.shellQuote(marker.path))")
        XCTAssertEqual(try runCleanupShell(shell), ElevatedExitCode.boundaryCheckFailed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "the engine must not be spawned once a boundary check refuses")
        XCTAssertEqual(try String(contentsOf: item.appendingPathComponent("marker")),
                       "unreviewed", "the substituted inode is untouched")
    }

    func testGuardedShellRefusesOnceTheReviewHasExpired() throws {
        let item = root.appendingPathComponent("stale")
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false)
        let old = Date(timeIntervalSince1970: 1_000)
        let snapshot = try CleanupSnapshot.capture(list: list([item.path]),
                                                   approvedRootURLs: [root], now: old)
        let plan = try snapshot.plan(selectedPaths: [item.path], now: old)
        let marker = root.appendingPathComponent("engine-ran")

        // The plan expired long ago on the wall clock the shell's `date +%s` reads.
        let shell = plan.guardedShell(running: "/usr/bin/touch \(EngineCLI.shellQuote(marker.path))")
        XCTAssertEqual(try runCleanupShell(shell), ElevatedExitCode.boundaryCheckFailed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testStalePlanFilesAreSweptAndFreshOnesKept() throws {
        let dir = root.appendingPathComponent("plans", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stale = dir.appendingPathComponent("old.plan")
        let fresh = dir.appendingPathComponent("new.plan")
        let other = dir.appendingPathComponent("notes.txt")
        for file in [stale, fresh, other] { try Data("x".utf8).write(to: file) }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)],
                                              ofItemAtPath: stale.path)

        CleanupExecutionPlan.sweepStalePlanFiles(in: dir, olderThan: 3600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path), "only .plan files are swept")
    }

    private func runCleanupShell(_ shell: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", shell]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

final class PrivilegedLogSinkTests: XCTestCase {
    func testNamesAreUnguessableAndDistinct() throws {
        let a = try PrivilegedLogSink.make(), b = try PrivilegedLogSink.make()
        XCTAssertNotEqual(a.directoryPath, b.directoryPath)
        XCTAssertTrue(a.directoryPath.hasPrefix("/private/var/tmp/dev.caezium.burrow.operation-"))
    }

    func testHostileSymlinkCollisionFailsWithoutFollowingOrDeletingIt() throws {
        let token = "TESTCOLLISION" + String(repeating: "A", count: 32)
        let sink = try PrivilegedLogSink.make(token: token)
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-log-target-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: sink.directoryPath,
                                                   withDestinationPath: target.path)
        defer {
            try? FileManager.default.removeItem(atPath: sink.directoryPath)
            try? FileManager.default.removeItem(at: target)
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", sink.exclusiveCreationShell]
        try task.run(); task.waitUntilExit()
        XCTAssertNotEqual(task.terminationStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sink.directoryPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("output.log").path))
    }
}
