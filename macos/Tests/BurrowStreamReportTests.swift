//
//  BurrowStreamReportTests.swift
//  BurrowTests
//
//  Locks the NDJSON → TaskRunReport contract that OperationFlow uses for streamed
//  clean/optimize. The engine emits one JSON object per line; the reducer must build the
//  same (groups, summary) shape the views render.
//

import XCTest
@testable import Burrow

final class BurrowStreamReportTests: XCTestCase {
    func testCleanPreview_yieldsCleanedSummary() {
        let lines = [
            #"{"event":"would_remove","path":"/Users/x/Library/Caches/npm","bytes":201129000}"#,
            #"{"event":"done","dry_run":true,"would_free_bytes":402438000,"would_free_human":"383.8MB","count":372}"#,
        ]
        let report = BurrowStreamReport.reduce(lines)
        XCTAssertEqual(report.groups.count, 1)
        XCTAssertEqual(report.groups.first?.items.count, 1)
        XCTAssertEqual(report.summary?.space, "383.8MB")
        XCTAssertEqual(report.summary?.items, "372")
        // No freeChange on a preview → "Cleaned", not "Freed".
        XCTAssertEqual(report.summary?.completionLine, "Cleaned 383.8MB · 372 items")
    }

    func testCleanLive_yieldsFreedSummary() {
        let lines = [
            #"{"event":"removed","path":"/a/x","bytes":10}"#,
            #"{"event":"failed","path":"/a/y","error":"denied"}"#,
            #"{"event":"protected","path":"/a/keep"}"#,
            #"{"event":"done","freed_bytes":2048,"freed_human":"2.0KB","removed":1,"failed":1,"protected":1}"#,
        ]
        let report = BurrowStreamReport.reduce(lines)
        XCTAssertEqual(report.groups.first?.items.count, 3, "removed + failed + protected are shown")
        // A live done carries freed_human → freeChange → "Freed".
        XCTAssertEqual(report.summary?.completionLine, "Freed 2.0KB · 1 items")
    }

    func testOptimize_taskEvents() {
        let lines = [
            #"{"event":"task","name":"flush_dns","ok":true,"error":null}"#,
            #"{"event":"task","name":"restart_dock","ok":false,"error":"no proc"}"#,
            #"{"event":"done","ok":false,"tasks":2,"failed":1}"#,
        ]
        let report = BurrowStreamReport.reduce(lines)
        XCTAssertEqual(report.groups.first?.items.count, 2)
        XCTAssertEqual(report.summary?.items, "2", "task count")
    }

    func testGarbageLinesAreIgnored() {
        // A stray non-JSON line (e.g. a warning) must not break the reduce.
        let lines = [
            "warning: something on stderr",
            #"{"event":"removed","path":"/a","bytes":1}"#,
            "",
            #"{"event":"done","freed_bytes":1,"freed_human":"1B","removed":1,"failed":0,"protected":0}"#,
        ]
        let report = BurrowStreamReport.reduce(lines)
        XCTAssertEqual(report.groups.first?.items.count, 1)
        XCTAssertNotNil(report.summary)
    }

    func testHudLine_extractsReadableLabel() {
        XCTAssertEqual(
            BurrowStreamReport.hudLine(#"{"event":"removed","path":"/a/b/npm cache","bytes":1}"#),
            "npm cache")
        XCTAssertEqual(
            BurrowStreamReport.hudLine(#"{"event":"task","name":"flush_dns","ok":true}"#),
            "flush_dns")
        XCTAssertEqual(BurrowStreamReport.hudLine("not json"), "")
    }
}
