//
//  BurrowStreamReport.swift
//  Burrow
//
//  Reduces the NDJSON progress feed from `burrow-engine clean --stream` / `optimize --stream`
//  into the (groups, summary) shape TaskReportView renders — the same TaskRunReport the old
//  human-text `parseTaskReport` produced, so the Clean/Optimize views + completion notification
//  are unchanged. The engine emits one JSON object per line:
//
//    clean live:    {"event":"removed","path":P,"bytes":N} | {"event":"failed",...} |
//                   {"event":"protected",...}  then  {"event":"done","freed_bytes":N,
//                   "freed_human":H,"removed":N,"failed":N,"protected":N}
//    clean preview: {"event":"would_remove","path":P,"bytes":N}  then  {"event":"done",
//                   "dry_run":true,"would_free_bytes":N,"would_free_human":H,"count":N}
//    optimize live: {"event":"task","name":T,"ok":B,"error":E|null}  then  {"event":"done",
//                   "ok":B,"tasks":N,"failed":N}
//    optimize prev: {"event":"would_run","name":T,"description":D}  then  {"event":"done",
//                   "dry_run":true,"tasks":N}
//
//  Parsed line-by-line with JSONSerialization (like BurrowEnvelope) — the reduce is called on the
//  accumulated `[String]` after every streamed line (throttled) and once at exit.
//

import Foundation

enum BurrowStreamReport {
    /// Reduce the accumulated NDJSON lines into a TaskRunReport. Unparseable / non-event lines are
    /// skipped, so a stray warning on stderr never breaks the result screen.
    static func reduce(_ lines: [String]) -> TaskRunReport {
        var items: [TaskItem] = []
        var summary: TaskSummary?

        for line in lines {
            guard let obj = object(from: line), let event = obj["event"] as? String else { continue }
            switch event {
            case "removed":
                if let p = obj["path"] as? String { items.append(TaskItem(marker: .ok, text: p)) }
            case "would_remove":
                if let p = obj["path"] as? String { items.append(TaskItem(marker: .action, text: p)) }
            case "failed":
                if let p = obj["path"] as? String { items.append(TaskItem(marker: .error, text: p)) }
            case "protected":
                if let p = obj["path"] as? String { items.append(TaskItem(marker: .review, text: p)) }
            case "task":
                if let name = obj["name"] as? String {
                    let ok = obj["ok"] as? Bool ?? true
                    items.append(TaskItem(marker: ok ? .ok : .error, text: name))
                }
            case "would_run":
                if let name = obj["name"] as? String { items.append(TaskItem(marker: .action, text: name)) }
            case "done":
                summary = makeSummary(from: obj, itemCount: items.count)
            default:
                break
            }
        }

        let groups = items.isEmpty
            ? []
            : [TaskGroup(title: NSLocalizedString("Cleanup", comment: "streamed op group title"),
                         items: items)]
        return (groups: groups, summary: summary)
    }

    /// A short human label for the HUD detail line, extracted from one NDJSON event. Empty for the
    /// terminal `done` (the HUD keeps the last item line) or an unparseable line.
    static func hudLine(_ line: String) -> String {
        guard let obj = object(from: line), let event = obj["event"] as? String else { return "" }
        switch event {
        case "removed", "would_remove", "failed", "protected":
            if let p = obj["path"] as? String { return (p as NSString).lastPathComponent }
        case "task", "would_run":
            if let name = obj["name"] as? String { return name }
        default:
            break
        }
        return ""
    }

    // MARK: - internals

    private static func object(from line: String) -> [String: Any]? {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.first == "{", let data = t.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    /// Build the summary from a `done` event, covering both the live and preview shapes of clean
    /// and optimize. `itemCount` is the number of accumulated item lines (fallback when a specific
    /// count field is absent).
    private static func makeSummary(from done: [String: Any], itemCount: Int) -> TaskSummary {
        // Freed disk (live clean) vs would-free (preview) vs no size (optimize).
        let freedHuman = done["freed_human"] as? String
        let wouldFreeHuman = done["would_free_human"] as? String
        let space = freedHuman ?? wouldFreeHuman ?? ""

        // Item count: removed (clean live) → count (clean preview) → tasks (optimize) → accumulated.
        let count = intField(done, "removed")
            ?? intField(done, "count")
            ?? intField(done, "tasks")
            ?? itemCount
        let items = count > 0 ? String(count) : ""

        // Live clean prints the actual freed size → surface it as the freed-space number.
        let freeChange = freedHuman ?? ""

        return TaskSummary(space: space, items: items, categories: "", freeChange: freeChange, freeNow: "")
    }

    /// Read an integer field regardless of whether JSONSerialization bridged it to Int or Double.
    private static func intField(_ obj: [String: Any], _ key: String) -> Int? {
        if let n = obj[key] as? Int { return n }
        if let d = obj[key] as? Double { return Int(d) }
        return nil
    }
}
