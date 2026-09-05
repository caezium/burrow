//
//  CleanList.swift
//  Burrow
//
//  Parser for ~/.config/mole/clean-list.txt — the per-path preview
//  `mo clean --dry-run` writes. This is what makes selective cleaning
//  possible: the review screen (CleanReviewView) shows these items, and
//  unticked paths become a whitelist session for the real run.
//
//  The file is informal CLI output, so parsing is pinned to the exact
//  shapes mole 1.41 emits (fixture in Tests/CleanListTests):
//
//      === Category ===
//      /path/to/cache  # 2.24GB, 20 items
//      /path/to/file  # 50KB
//      ...
//      # Potential cleanup: 6.66GB
//      # Items: 474
//
//  Anything unrecognized is skipped; a file with no sections parses to
//  zero categories and the caller falls back to the aggregate banner.
//

import Foundation

struct CleanList: Equatable {
    struct Item: Identifiable, Equatable {
        let path: String
        let sizeBytes: Int64
        let sizeText: String      // as the engine printed it ("2.24GB")
        let itemCount: Int?       // ", 20 items" — nil when absent
        var id: String { path }
    }

    struct Category: Identifiable, Equatable {
        let name: String
        var items: [Item]
        var id: String { name }
        var totalBytes: Int64 { items.reduce(0) { $0 + $1.sizeBytes } }
    }

    /// Non-empty categories, in file order.
    let categories: [Category]
    /// "# Potential cleanup: 6.66GB" — the engine's own total.
    let summaryTotalText: String?
    /// "# Items: 474"
    let summaryItemCount: Int?

    /// Where the engine writes the preview.
    static let liveURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/mole/clean-list.txt")

    static func loadLive() -> CleanList? {
        guard let text = try? String(contentsOf: liveURL, encoding: .utf8) else { return nil }
        let parsed = parse(text)
        return parsed.categories.isEmpty ? nil : parsed
    }

    /// The bundled engine publishes the preview on stdout and never writes the legacy list.
    /// Require its completed dry run so an interrupted scan cannot authorize a cleanup.
    static func fromEngineOutput(_ lines: [String]) -> CleanList? {
        var categories: [Category] = []
        var seen = Set<String>()
        var summaryTotal: String?
        var summaryCount: Int?
        var completed = false

        func add(path: String, bytes: Int64, sizeText: String?, category: String) -> Bool {
            guard path.hasPrefix("/"), bytes >= 0 else { return false }
            guard seen.insert(path).inserted else { return true }
            let item = Item(path: path, sizeBytes: bytes,
                            sizeText: sizeText ?? Fmt.bytes(bytes), itemCount: nil)
            if let index = categories.firstIndex(where: { $0.name == category }) {
                categories[index].items.append(item)
            } else {
                categories.append(Category(name: category, items: [item]))
            }
            return true
        }

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let event = object["event"] as? String {
                switch event {
                case "would_remove":
                    guard !completed, let path = object["path"] as? String,
                          let bytes = object["bytes"] as? Int64,
                          add(path: path, bytes: bytes, sizeText: nil,
                              category: NSLocalizedString("Cleanup", comment: "")) else { return nil }
                case "done":
                    guard object["dry_run"] as? Bool == true else { return nil }
                    completed = true
                    summaryTotal = object["would_free_human"] as? String
                    summaryCount = object["count"] as? Int
                case "protected": break
                default: return nil
                }
            } else if object["ok"] != nil {
                guard object["ok"] as? Bool == true,
                      object["command"] as? String == "clean",
                      let payload = object["data"] as? [String: Any],
                      payload["dry_run"] as? Bool == true,
                      let items = payload["items"] as? [[String: Any]] else { return nil }
                for item in items {
                    guard let path = item["path"] as? String, let bytes = item["size"] as? Int64,
                          add(path: path, bytes: bytes, sizeText: item["size_human"] as? String,
                              category: item["label"] as? String ?? NSLocalizedString("Cleanup", comment: ""))
                    else { return nil }
                }
                completed = true
                summaryTotal = payload["total_human"] as? String
                summaryCount = seen.count
            }
        }
        guard completed else { return nil }
        return CleanList(categories: categories, summaryTotalText: summaryTotal,
                         summaryItemCount: summaryCount)
    }

    static func parse(_ text: String) -> CleanList {
        var categories: [Category] = []
        var current: Category?
        var summaryTotal: String?
        var summaryItems: Int?

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("==="), line.hasSuffix("===") {
                if let c = current, !c.items.isEmpty { categories.append(c) }
                let name = line.trimmingCharacters(in: CharacterSet(charactersIn: "= "))
                current = Category(name: name, items: [])
                continue
            }

            if line.hasPrefix("#") {
                let comment = line.drop(while: { $0 == "#" || $0 == " " })
                if comment.hasPrefix("Potential cleanup:") {
                    summaryTotal = comment.dropFirst("Potential cleanup:".count)
                        .trimmingCharacters(in: .whitespaces)
                } else if comment.hasPrefix("Items:") {
                    summaryItems = Int(comment.dropFirst("Items:".count)
                        .trimmingCharacters(in: .whitespaces))
                }
                continue
            }

            // "/path  # 2.24GB, 20 items" — only inside a section.
            guard current != nil, line.hasPrefix("/") || line.hasPrefix("~"),
                  let hash = line.range(of: "  #") ?? line.range(of: " #") else { continue }
            let path = String(line[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
            let meta = line[hash.upperBound...].trimmingCharacters(in: .whitespaces)
            let parts = meta.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let sizeText = parts.first, !sizeText.isEmpty else { continue }
            var count: Int? = nil
            if parts.count > 1, parts[1].hasSuffix("items") {
                count = Int(parts[1].dropLast("items".count).trimmingCharacters(in: .whitespaces))
            }
            current?.items.append(Item(path: path,
                                       sizeBytes: parseSize(sizeText),
                                       sizeText: sizeText,
                                       itemCount: count))
        }
        if let c = current, !c.items.isEmpty { categories.append(c) }
        return CleanList(categories: categories,
                         summaryTotalText: summaryTotal,
                         summaryItemCount: summaryItems)
    }

    /// "2.24GB" → bytes (1024-based, matching the engine's humanized sizes
    /// closely enough for selection totals). Forwards to the shared
    /// `Fmt.parseSize` — the single source of truth, also used by
    /// `MoleClient.parseSize`; kept as a named entry the streamed-line and
    /// selection-total call sites (and `CleanListTests`) read by intent.
    static func parseSize(_ text: String) -> Int64 { Fmt.parseSize(text) }

    /// Live count-up support (design 2.1): the bytes one streamed dry-run
    /// line contributes. Only per-item "…, <size> dry" lines count;
    /// review-only callouts and the summary line contribute nothing (the
    /// engine's own total replaces the running figure at the end).
    static func streamedItemBytes(_ line: String) -> Int64 {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasSuffix(" dry"),
              let comma = t.range(of: ", ", options: .backwards) else { return 0 }
        let sizeText = String(t[comma.upperBound...].dropLast(" dry".count))
        return parseSize(sizeText)
    }
}
