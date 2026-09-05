import XCTest
@testable import Burrow

final class DupeTrashSafetyTests: XCTestCase {
    private var root: URL!
    private var keep: URL!
    private var copy: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("burrow-dupe-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: try XCTUnwrap(InvokingUserIdentity.canonicalPath(root.path)))
        keep = root.appendingPathComponent("kept.txt")
        copy = root.appendingPathComponent("copy.txt")
        try Data("same".utf8).write(to: keep)
        try Data("same".utf8).write(to: copy)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func snapshot() throws -> DupeTrashSnapshot {
        try DupeTrashSnapshot(report: DupesReport(groups: [.init(fileLen: 4, files: [keep.path, copy.path])],
                                                  redundantBytes: 4), root: root)
    }

    func testMissingKeptCopyRefusesTheOriginalSelection() throws {
        let scan = try snapshot()
        try FileManager.default.removeItem(at: keep)
        XCTAssertThrowsError(try scan.plan(selectedPaths: [copy.path]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
    }

    func testReplacementOrContentChangeDuringConfirmationDoesNotMoveAnything() throws {
        for replaceKept in [true, false] {
            let plan = try snapshot().plan(selectedPaths: [copy.path])
            let target = replaceKept ? keep! : copy!
            let handle = try FileHandle(forWritingTo: target)
            try handle.write(contentsOf: Data("else".utf8))
            try handle.close()
            var moves = 0
            let result = plan.moveToTrash { url in moves += 1; return url }
            XCTAssertEqual(result.moved, 0)
            XCTAssertEqual(result.failed, 1)
            XCTAssertEqual(moves, 0)
            try Data("same".utf8).write(to: target)
        }
    }

    func testFilesThatDivergedBeforeTheReportWasDisplayedAreNotDuplicates() throws {
        try Data("else".utf8).write(to: keep)
        let plan = try snapshot().plan(selectedPaths: [copy.path])
        var moves = 0
        let result = plan.moveToTrash { url in moves += 1; return url }
        XCTAssertEqual(result.moved, 0)
        XCTAssertEqual(moves, 0)
    }

    func testUnchangedCopiesMoveThroughTheIdentityCheckedExecutor() throws {
        let plan = try snapshot().plan(selectedPaths: [copy.path])
        let destination = root.appendingPathComponent("fake-trash.txt")
        let result = plan.moveToTrash { source in
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        }
        XCTAssertEqual(result.moved, 1)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(try Data(contentsOf: keep), Data("same".utf8))
        XCTAssertEqual(try Data(contentsOf: destination), Data("same".utf8))
    }

    func testSelectingEveryCopyIsRefusedEvenIfACallerBypassesTheChecklist() throws {
        XCTAssertThrowsError(try snapshot().plan(selectedPaths: [keep.path, copy.path]))
    }

    func testEditDuringContentComparisonInvalidatesTheMove() throws {
        let plan = try snapshot().plan(selectedPaths: [copy.path])
        var moves = 0
        let result = plan.moveToTrash(contentsEqual: { _, _ in
            // Simulate a keeper prefix being changed after the comparison
            // has already read it, so its boolean result alone is stale.
            try! Data("else".utf8).write(to: self.keep)
            return true
        }, move: { source in moves += 1; return source })
        XCTAssertEqual(result.moved, 0)
        XCTAssertEqual(moves, 0)
    }

    func testComplementaryPlansCannotTrashBothCopiesConcurrently() throws {
        let scan = try snapshot()
        let first = try scan.plan(selectedPaths: [copy.path])
        let second = try scan.plan(selectedPaths: [keep.path])
        let firstAtMove = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondAtMove = DispatchSemaphore(value: 0)
        let finished = expectation(description: "both plans finished")
        finished.expectedFulfillmentCount = 2
        let firstDestination = root.appendingPathComponent("fake-trash-first")
        let secondDestination = root.appendingPathComponent("fake-trash-second")

        DispatchQueue.global().async {
            let result = first.moveToTrash { source in
                firstAtMove.signal()
                guard releaseFirst.wait(timeout: .now() + 3) == .success else { throw CocoaError(.userCancelled) }
                try FileManager.default.moveItem(at: source, to: firstDestination)
                return firstDestination
            }
            XCTAssertEqual(result.moved, 1)
            finished.fulfill()
        }
        XCTAssertEqual(firstAtMove.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async {
            let result = second.moveToTrash { source in
                secondAtMove.signal()
                try FileManager.default.moveItem(at: source, to: secondDestination)
                return secondDestination
            }
            XCTAssertEqual(result.moved, 0, "the first move invalidates this plan's surviving copy")
            finished.fulfill()
        }
        XCTAssertEqual(secondAtMove.wait(timeout: .now() + 0.1), .timedOut)
        releaseFirst.signal()
        wait(for: [finished], timeout: 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondDestination.path))
    }
}
