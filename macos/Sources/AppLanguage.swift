//
//  AppLanguage.swift
//  Burrow
//

import Foundation

/// One shipped UI language.
///
/// This list is the only place a language code appears. The Settings picker,
/// the Explain prompt and the localization tests all read it, so adding a
/// language is one row here plus `<code>.lproj/Localizable.strings` — nothing
/// else has to learn the new code, and nothing can be updated in one place and
/// forgotten in another.
struct AppLanguage: Equatable {
    /// The `.lproj` directory name, which is also the value written to
    /// `AppleLanguages` for the bundle loader to read at the next launch.
    let code: String

    /// The language's own name. A picker that offers "German" to a German
    /// speaker is labelling the one option they can already read, so every
    /// entry stays in its own language and is never localized.
    let endonym: String

    /// How to name this language to the Explain model. `nil` means English,
    /// where the base prompt already answers in English and needs no clause.
    let explainDescription: String?

    /// In picker order: English first, then by when each was added.
    static let all: [AppLanguage] = [
        .init(code: "en",      endonym: "English",             explainDescription: nil),
        .init(code: "zh-Hans", endonym: "简体中文",              explainDescription: "Simplified Chinese (简体中文)"),
        .init(code: "zh-Hant", endonym: "繁體中文",              explainDescription: "Traditional Chinese as used in Taiwan (繁體中文，台灣用語)"),
        .init(code: "ru",      endonym: "Русский",             explainDescription: "Russian (русский)"),
        .init(code: "ja",      endonym: "日本語",                explainDescription: "Japanese (日本語)"),
        .init(code: "de",      endonym: "Deutsch",             explainDescription: "German (Deutsch)"),
        .init(code: "fr",      endonym: "Français",            explainDescription: "French (français)"),
        .init(code: "es",      endonym: "Español",             explainDescription: "Spanish (español)"),
        .init(code: "ko",      endonym: "한국어",                explainDescription: "Korean (한국어)"),
        .init(code: "pt-BR",   endonym: "Português (Brasil)",  explainDescription: "Brazilian Portuguese (português do Brasil)"),
    ]

    /// Every language that carries a `.strings` table — i.e. all of them but
    /// English, whose strings are the keys themselves.
    static var translated: [AppLanguage] { all.filter { $0.code != "en" } }

    static func named(_ code: String) -> AppLanguage? { all.first { $0.code == code } }

    /// The language the UI is actually running in: the explicit override when
    /// the user set one, otherwise whatever the bundle picked for the system.
    ///
    /// `preferred` is a full locale id like `de-DE` or `zh-Hant-TW`, so an
    /// exact hit is the exception and prefix matching is the rule.
    static func resolved(override: String, preferred: String?) -> AppLanguage? {
        if !override.isEmpty { return named(override) }
        guard let preferred, !preferred.isEmpty else { return nil }
        if let exact = named(preferred) { return exact }

        // Chinese is the one script split we ship, and macOS hands back region
        // ids like "zh-TW" that never mention Hant — so the Traditional
        // regions have to be named outright rather than pattern-matched.
        if preferred.hasPrefix("zh") {
            let traditional = ["Hant", "TW", "HK", "MO"].contains { preferred.contains($0) }
            return named(traditional ? "zh-Hant" : "zh-Hans")
        }

        // "pt-PT" lands on pt-BR and "es-419" on es: a near neighbour reads far
        // better than falling all the way back to English.
        return all.first { preferred.hasPrefix($0.code) }
            ?? all.first { $0.code.hasPrefix(String(preferred.prefix(2))) }
    }
}
