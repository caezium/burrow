import Foundation
import Darwin

/// Holds the files shown by a duplicate scan, including the copies the
/// user will keep. A checklist alone cannot preserve a copy that changed
/// or disappeared while the review was open.
struct DupeTrashSnapshot {
    struct Stamp: Equatable {
        let identity: PinnedFileIdentity
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        static func capture(_ path: String) throws -> Self {
            let identity = try PinnedFileIdentity.capture(path)
            var info = stat()
            guard identity.isRegular, lstat(path, &info) == 0,
                  UInt64(info.st_dev) == identity.device, UInt64(info.st_ino) == identity.inode else {
                throw CleanupSnapshot.SnapshotError.staleOrChanged
            }
            return Self(identity: identity, size: Int64(info.st_size),
                        modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec,
                        changedSeconds: info.st_ctimespec.tv_sec, changedNanoseconds: info.st_ctimespec.tv_nsec)
        }

        func matchesCurrent() -> Bool { (try? Self.capture(identity.path)) == self }
    }

    struct Plan {
        private static let moveLock = NSLock()
        let cleanup: CleanupExecutionPlan
        let selected: [String: Stamp]
        let kept: [Stamp]
        let keepers: [String: [Stamp]]

        func moveToTrash(contentsEqual: (String, String) -> Bool = FileManager.default.contentsEqual(atPath:andPath:),
                         move: (URL) throws -> URL = systemTrashMove) -> CleanupExecutor.Result {
            // Different windows can hold inverse selections of the same
            // group. Complete one plan before validating another's keeper.
            Self.moveLock.lock()
            defer { Self.moveLock.unlock() }
            guard kept.allSatisfy({ $0.matchesCurrent() }), selected.values.allSatisfy({ $0.matchesCurrent() }) else {
                return .init(moved: 0, failed: cleanup.items.count)
            }
            return CleanupExecutor.moveToTrash(cleanup) { source in
                guard kept.allSatisfy({ $0.matchesCurrent() }), selected[source.path]?.matchesCurrent() == true else {
                    throw CleanupSnapshot.SnapshotError.staleOrChanged
                }
                // A long scan may have observed this group before its
                // files changed. Check the surviving contents as well as
                // the identities captured when the result was displayed.
                guard keepers[source.path]?.contains(where: {
                    contentsEqual(source.path, $0.identity.path)
                }) == true else { throw CleanupSnapshot.SnapshotError.staleOrChanged }
                guard kept.allSatisfy({ $0.matchesCurrent() }), selected[source.path]?.matchesCurrent() == true else {
                    throw CleanupSnapshot.SnapshotError.staleOrChanged
                }
                return try move(source)
            }
        }

        private static func systemTrashMove(_ source: URL) throws -> URL {
            var destination: NSURL?
            try FileManager.default.trashItem(at: source, resultingItemURL: &destination)
            guard let destination else { throw CocoaError(.fileWriteUnknown) }
            return destination as URL
        }
    }

    private let report: DupesReport
    private let snapshot: CleanupSnapshot
    private let stamps: [String: Stamp]

    init(report: DupesReport, root: URL) throws {
        var stamps: [String: Stamp] = [:]
        var items: [CleanList.Item] = []
        for group in report.groups {
            guard group.files.count >= 2 else { throw CleanupSnapshot.SnapshotError.selectionMismatch }
            for path in group.files {
                guard stamps[path] == nil else { throw CleanupSnapshot.SnapshotError.selectionMismatch }
                let stamp = try Stamp.capture(path)
                guard stamp.size == group.fileLen else { throw CleanupSnapshot.SnapshotError.staleOrChanged }
                stamps[path] = stamp
                items.append(.init(path: path, sizeBytes: group.fileLen, sizeText: Fmt.bytes(group.fileLen), itemCount: nil))
            }
        }
        let list = CleanList(categories: [.init(name: "Duplicates", items: items)],
                             summaryTotalText: nil, summaryItemCount: nil)
        let snapshot = try CleanupSnapshot.capture(list: list, approvedRootURLs: [root])
        guard snapshot.skipped.isEmpty else { throw CleanupSnapshot.SnapshotError.staleOrChanged }
        self.report = report
        self.snapshot = snapshot
        self.stamps = stamps
    }

    func plan(selectedPaths: [String]) throws -> Plan {
        let selected = Set(selectedPaths)
        var kept: [Stamp] = []
        var keepers: [String: [Stamp]] = [:]
        for group in report.groups where group.files.contains(where: selected.contains) {
            let remaining = group.files.filter { !selected.contains($0) }
            guard !remaining.isEmpty else { throw CleanupSnapshot.SnapshotError.selectionMismatch }
            let surviving = remaining.compactMap { stamps[$0] }
            kept.append(contentsOf: surviving)
            for path in group.files where selected.contains(path) { keepers[path] = surviving }
        }
        let selectedStamps = stamps.filter { selected.contains($0.key) }
        guard kept.allSatisfy({ $0.matchesCurrent() }), selectedStamps.values.allSatisfy({ $0.matchesCurrent() }) else {
            throw CleanupSnapshot.SnapshotError.staleOrChanged
        }
        return Plan(cleanup: try snapshot.plan(selectedPaths: selectedPaths), selected: selectedStamps,
                    kept: kept, keepers: keepers)
    }
}
