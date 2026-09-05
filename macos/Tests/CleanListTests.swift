//
//  CleanListTests.swift
//  BurrowTests
//
//  `mo clean --dry-run` writes ~/.config/mole/clean-list.txt — the
//  parseable preview the Clean review screen (design 1.4) is built on:
//  `=== Category ===` section headers, one path per line with a
//  `# size[, N items]` comment, and a `# Summary` footer. The format is
//  informal CLI output, so parsing is pinned to exactly these shapes
//  (fixture captured from mole 1.41 on 2026-06-11) and the caller fails
//  soft to the aggregate banner if nothing parses.
//

import XCTest
@testable import Burrow

final class CleanListTests: XCTestCase {
    /// Excerpt of a real clean-list.txt (paths shortened, shapes intact).
    static let fixture = """
    # Mole Cleanup Preview - 2026-06-11 10:04:57
    #
    # How to protect files:
    # 1. Copy any path below to ~/.config/mole/whitelist
    # 2. Run: mo clean --whitelist
    #
    # Example:
    #   /Users/*/Library/Caches/com.example.app
    #


    === User essentials ===
    /Users/henry/Library/Caches  # 2.24GB, 20 items
    /Users/henry/Library/Logs  # 8.7MB, 9 items

    === App caches ===
    /Users/henry/Library/Suggestions  # 2.8MB, 16 items
    /Users/henry/Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/com.apple.wallpaper.caches  # 115.1MB

    === Cloud & Office ===

    === Developer tools ===
    /Users/henry/.npm/_cacache  # 1.23GB, 3 items
    /Users/henry/.zcompdump  # 50KB

    # ============================================
    # Summary
    # ============================================
    # Potential cleanup: 6.66GB
    # Items: 474
    # Categories: 52
    """

    func testParse_readsCategoriesAndItems() {
        let list = CleanList.parse(Self.fixture)
        XCTAssertEqual(list.categories.map(\.name),
                       ["User essentials", "App caches", "Developer tools"],
                       "empty sections (Cloud & Office) are dropped")
        let essentials = list.categories[0]
        XCTAssertEqual(essentials.items.count, 2)
        XCTAssertEqual(essentials.items[0].path, "/Users/henry/Library/Caches")
        XCTAssertEqual(essentials.items[0].sizeText, "2.24GB")
        XCTAssertEqual(essentials.items[0].itemCount, 20)
        XCTAssertEqual(essentials.items[1].itemCount, 9)
    }

    func testParse_itemWithoutCountHasNilCount() {
        let list = CleanList.parse(Self.fixture)
        let appCaches = list.categories[1]
        XCTAssertEqual(appCaches.items[1].itemCount, nil)
        XCTAssertEqual(appCaches.items[1].sizeText, "115.1MB")
    }

    func testParse_sizesBecomeBytes() {
        let list = CleanList.parse(Self.fixture)
        let dev = list.categories[2]
        // 1.23GB and 50KB — relative magnitude is what selection totals need.
        XCTAssertEqual(dev.items[0].sizeBytes, Int64(1.23 * 1_073_741_824), accuracy: 1024)
        XCTAssertEqual(dev.items[1].sizeBytes, 50 * 1024)
        XCTAssertEqual(dev.totalBytes, dev.items.map(\.sizeBytes).reduce(0, +))
    }

    func testParse_readsSummaryFooter() {
        let list = CleanList.parse(Self.fixture)
        XCTAssertEqual(list.summaryTotalText, "6.66GB")
        XCTAssertEqual(list.summaryItemCount, 474)
    }

    func testParse_garbageFailsSoftToEmpty() {
        let list = CleanList.parse("complete nonsense\nwithout sections")
        XCTAssertTrue(list.categories.isEmpty)
    }

    private func enginePreview(_ ext: String) throws -> [String] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/clean-preview.\(ext)")
        return try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
    }

    func testEnginePreview_capturedStreamAndEnvelopeKeepExactPathsAndBytes() throws {
        for ext in ["ndjson", "json"] {
            let lines = try enginePreview(ext)
            let report = CleanDryReport.reduce(lines, bundledEngine: true) {
                XCTFail("The bundled engine must never load an old clean-list.txt")
                return CleanList.parse(Self.fixture)
            }
            let list = try XCTUnwrap(report.list)
            let items = list.categories.flatMap(\.items)
            XCTAssertEqual(items.map { URL(fileURLWithPath: $0.path).lastPathComponent },
                           ["review one", "review #two"])
            XCTAssertEqual(items.map(\.sizeBytes), [1234, 5678],
                           "Review uses exact bytes, not rounded size_human strings")
            XCTAssertEqual(list.summaryItemCount, 2)
            XCTAssertEqual(CleanSelection(list: list, locked: [:]).selectedBytes, 6912)
        }
    }

    func testEnginePreview_incompleteStreamCannotFallBackToAnOldList() throws {
        let lines = try enginePreview("ndjson").filter { !$0.contains("\"done\"") }
        let report = CleanDryReport.reduce(lines, bundledEngine: true) {
            XCTFail("An incomplete engine scan cannot authorize a stale legacy preview")
            return CleanList.parse(Self.fixture)
        }
        XCTAssertNil(report.list)
    }

    func testEnginePreview_emptyAndFailedScansNeverLoadAnOldList() {
        let responses = [
            #"{"event":"done","dry_run":true,"would_free_bytes":0,"would_free_human":"0B","count":0}"#,
            #"{"ok":false,"command":"clean","error":{"kind":"error","message":"scan failed"}}"#,
        ]
        for response in responses {
            let report = CleanDryReport.reduce([response], bundledEngine: true) {
                XCTFail("Engine results are never substituted with an old preview")
                return CleanList.parse(Self.fixture)
            }
            XCTAssertTrue(report.list?.categories.isEmpty ?? true)
        }
    }

    func testLegacyPreview_stillReadsTheLegacyList() {
        let expected = CleanList.parse(Self.fixture)
        let report = CleanDryReport.reduce([], bundledEngine: false, legacyList: { expected })
        XCTAssertEqual(report.list, expected)
    }

    func testParseSize_units() {
        XCTAssertEqual(CleanList.parseSize("4KB"), 4 * 1024)
        XCTAssertEqual(CleanList.parseSize("978KB"), 978 * 1024)
        XCTAssertEqual(CleanList.parseSize("33.0MB"), Int64(33.0 * 1_048_576))
        XCTAssertEqual(CleanList.parseSize("2.24GB"), Int64(2.24 * 1_073_741_824), accuracy: 1024)
        XCTAssertEqual(CleanList.parseSize("1.2TB"), Int64(1.2 * 1_099_511_627_776), accuracy: 1024)
        XCTAssertEqual(CleanList.parseSize("512B"), 512)
        XCTAssertEqual(CleanList.parseSize("junk"), 0)
    }

    /// The live count-up (design 2.1): accumulate a running total from the
    /// dry-run's streamed lines. Only per-item "… , <size> dry" lines count
    /// — review-only callouts and summaries must not inflate the number.
    func testStreamTotal_accumulatesOnlyDryItemLines() {
        let lines = [
            "➤ App caches",
            "  → Wallpaper agent cache, 33.0MB dry",
            "  → User app cache 20 items, 2.24GB dry",
            "  ✓ Nothing to clean",
            "  ◎ LM Studio models (review only): 310.11GB, Path: /Users/henry/.lmstudio/models",
            "Potential space: 6.66GB | Items: 474 | Categories: 52",
        ]
        let total = lines.reduce(Int64(0)) { $0 + CleanList.streamedItemBytes($1) }
        XCTAssertEqual(total, CleanList.parseSize("33.0MB") + CleanList.parseSize("2.24GB"))
    }
}

private func XCTAssertEqual(_ a: Int64, _ b: Int64, accuracy: Int64,
                            file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(abs(a - b) <= accuracy, "\(a) != \(b) ± \(accuracy)", file: file, line: line)
}
