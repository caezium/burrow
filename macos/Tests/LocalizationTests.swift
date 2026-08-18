//
//  LocalizationTests.swift
//  BurrowTests
//

import XCTest
@testable import Burrow

final class LocalizationTests: XCTestCase {
    /// The table every other table is measured against. It is the oldest and
    /// most complete one, so it is the reference rather than anything special.
    private static let canonicalLanguage = "zh-Hans"

    /// Core keys a language may legitimately leave identical to English.
    /// "Software", "Status" and "Updates" are the native spelling in German,
    /// Spanish and Brazilian Portuguese — forcing a difference here would buy
    /// the assertion nothing and cost the translation its accuracy. Every
    /// other core value matching its key is an untranslated string.
    private static let mayMatchEnglish: Set<String> = ["Software", "Status", "Updates"]

    private static let coreInterfaceKeys = [
        "Clean",
        "Software",
        "Optimize",
        "Analyze",
        "Status",
        "Settings",
        "History",
        "Open Burrow",
        "Clean Now",
        "Preview",
        "Uninstall",
        "Updates",
        "Search apps",
        "Everything's up to date",
        "Update all",
        "Check for Updates",
        "Update external engine",
        "Update Burrow to get the current bundled engine.",
        "Use Settings › Engine › Update external engine, then try again.",
        "Reinstall Burrow to restore the bundled engine.",
        "Run maintenance now",
        "Maintenance complete.",
        "Periodic Maintenance",
        "User directory permissions already optimal",
        // Privacy-critical surfaces added by the 2026-06 audit fixes: the
        // consent dialog and destructive-action gates must not fall back to
        // English in a zh build (covered for both Hans and Hant).
        "Share anonymous usage & crash reports?",
        "Share",
        "Don't Share",
        "Anonymous usage",
        "Also allow uninstalls & permanent deletes",
        "Uninstall aborted",
    ]

    func testTaskReportTextLocalizesOptimizeOutput() throws {
        let bundle = try lprojBundle("zh-Hans")
        XCTAssertEqual(TaskReportText.title("Periodic Maintenance", bundle: bundle), "定期维护")
        XCTAssertEqual(TaskReportText.title("Disk Health", bundle: bundle), "磁盘健康")
        XCTAssertEqual(TaskReportText.item("User directory permissions already optimal", bundle: bundle), "用户目录权限已是最佳状态")
        XCTAssertEqual(TaskReportText.item("Periodic maintenance skipped (not available on this macOS version)", bundle: bundle), "已跳过定期维护（此 macOS 版本不可用）")
        XCTAssertEqual(TaskReportText.item("Disk verify skipped (set MOLE_ENABLE_DISK_VERIFY=1 to enable)", bundle: bundle), "已跳过磁盘验证（设置 MOLE_ENABLE_DISK_VERIFY=1 可启用）")
        XCTAssertEqual(TaskReportText.item("Login items all healthy (3 checked)", bundle: bundle), "登录项均正常（已检查 3 项）")
        XCTAssertEqual(TaskReportText.item("Wallpaper agent cache, 33.0MB dry", bundle: bundle), "壁纸代理缓存，33.0MB 可清理")
    }

    func testTaskReportTextLocalizesOptimizeOutputTraditional() throws {
        let bundle = try lprojBundle("zh-Hant")
        XCTAssertEqual(TaskReportText.title("Periodic Maintenance", bundle: bundle), "定期維護")
        XCTAssertEqual(TaskReportText.title("Disk Health", bundle: bundle), "磁碟健康")
        XCTAssertEqual(TaskReportText.item("User directory permissions already optimal", bundle: bundle), "使用者目錄權限已是最佳狀態")
        XCTAssertEqual(TaskReportText.item("Periodic maintenance skipped (not available on this macOS version)", bundle: bundle), "已略過定期維護（此 macOS 版本不支援）")
        XCTAssertEqual(TaskReportText.item("Disk verify skipped (set MOLE_ENABLE_DISK_VERIFY=1 to enable)", bundle: bundle), "已略過磁碟驗證（設定 MOLE_ENABLE_DISK_VERIFY=1 可啟用）")
        XCTAssertEqual(TaskReportText.item("Login items all healthy (3 checked)", bundle: bundle), "登入項目均正常（已檢查 3 項）")
        XCTAssertEqual(TaskReportText.item("Wallpaper agent cache, 33.0MB dry", bundle: bundle), "桌面背景代理程式快取，33.0MB 可清理")
    }

    /// Every shipped language has to translate the surfaces a user cannot
    /// avoid — including the consent dialog and the destructive-action gates,
    /// which must never fall back to English in a localized build.
    func testEveryLanguageCoversCoreInterface() throws {
        for language in AppLanguage.translated {
            try assertCoversCoreInterface(language: language.code)
        }
    }

    /// Every table translates exactly the same key set as the canonical one,
    /// so a key added to any single table can't go silently missing from the
    /// other nine. This is also what stops English copy from being edited
    /// without the translations following: the key *is* the English string, so
    /// changing it orphans every table at once and fails right here.
    func testEveryLanguageSharesTheCanonicalKeySet() throws {
        let canonical = Set(try localizedStrings(Self.canonicalLanguage).keys)
        for language in AppLanguage.translated where language.code != Self.canonicalLanguage {
            let keys = Set(try localizedStrings(language.code).keys)
            XCTAssertEqual(keys.subtracting(canonical).sorted(), [],
                           "keys in \(language.code) missing from \(Self.canonicalLanguage)")
            XCTAssertEqual(canonical.subtracting(keys).sorted(), [],
                           "keys missing from \(language.code)")
        }
    }

    /// `AppLanguage.translated` and the `.lproj` folders in the bundle have to
    /// agree in both directions. A row without a table ships a picker entry
    /// that silently renders English; a table without a row ships a
    /// translation no one can select. Neither fails anywhere else.
    ///
    /// English is compared out: its strings *are* the keys, so it ships no
    /// table and never will.
    func testShippedLanguagesMatchTheBundle() throws {
        let declared = Set(AppLanguage.translated.map(\.code))
        let bundled = Set(
            (Bundle.main.urls(forResourcesWithExtension: "lproj", subdirectory: nil) ?? [])
                .map { $0.deletingPathExtension().lastPathComponent }
                .filter { $0 != "Base" }
        )
        XCTAssertEqual(declared.subtracting(bundled).sorted(), [],
                       "declared in AppLanguage.all but no .lproj ships")
        XCTAssertEqual(bundled.subtracting(declared).sorted(), [],
                       ".lproj ships but is missing from AppLanguage.all")
    }

    /// A translation that retypes or *plainly* reorders `%` placeholders is a
    /// runtime `String(format:)` crash (or garbage) no compiler catches. The
    /// conversion bound to each ARGUMENT must survive translation — but an
    /// explicit positional reorder (`%2$lld … %1$lld`, the correct way to fix
    /// word order across languages) is allowed. So we reconstruct the
    /// per-argument conversion sequence (honoring `%n$`) and compare that, not
    /// the raw left-to-right order. Runs for every localized table.
    func testFormatSpecifiersSurviveTranslation() throws {
        let pattern = try NSRegularExpression(pattern: "%(?:(\\d+)\\$)?(?:ll|l|h)?([@dioufgexXscp])")
        func argTypes(_ s: String) -> [String] {
            let ns = s as NSString
            var byPosition: [Int: String] = [:]
            var nextImplicit = 1
            for m in pattern.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                let conv = ns.substring(with: m.range(at: 2))
                let pos: Int
                if m.range(at: 1).location != NSNotFound {
                    pos = Int(ns.substring(with: m.range(at: 1))) ?? nextImplicit
                } else {
                    pos = nextImplicit; nextImplicit += 1
                }
                byPosition[pos] = conv
            }
            return byPosition.keys.sorted().map { byPosition[$0]! }
        }
        for language in AppLanguage.translated.map(\.code) {
            for (key, value) in try localizedStrings(language) {
                XCTAssertEqual(argTypes(key), argTypes(value),
                               "format argument types drifted in \(language) translation of \"\(key)\"")
            }
        }
    }

    private func assertCoversCoreInterface(language: String) throws {
        let strings = try localizedStrings(language)
        for key in Self.coreInterfaceKeys {
            let value = try XCTUnwrap(strings[key], "missing \(language) translation for \(key)")
            XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if !Self.mayMatchEnglish.contains(key) {
                XCTAssertNotEqual(value, key, "\(language) leaves \"\(key)\" untranslated")
            }
        }
    }

    // Read the lproj from the BUILT app bundle (the test host), not the
    // repo checkout: it validates the artifact that actually ships, and
    // it keeps the suite off TCC-protected user folders — a repo on
    // ~/Desktop made every Data(contentsOf:) here block on a tccd that
    // had wedged, hanging the whole suite.
    private func localizedStrings(_ language: String) throws -> [String: String] {
        let url = try lprojURL(language).appendingPathComponent("Localizable.strings")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: String])
    }

    private func lprojBundle(_ language: String) throws -> Bundle {
        try XCTUnwrap(Bundle(url: lprojURL(language)))
    }

    private func lprojURL(_ language: String) throws -> URL {
        try XCTUnwrap(Bundle.main.url(forResource: language, withExtension: "lproj"),
                      "\(language).lproj missing from the app bundle")
    }
}
