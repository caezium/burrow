# Localization

Burrow's macOS app ships ten languages. This is how they stay correct.

## The rules, in one place

1. **`AppLanguage.all` is the only list.** `macos/Sources/AppLanguage.swift` holds one row per language — code, endonym, and how to name the language to the Explain model. The Settings picker, the Explain prompt and the tests all read it. Adding a language is one row plus one `.strings` file; if you find yourself editing a third place, something has drifted.
2. **`zh-Hans` is the canonical table.** Every other table must translate exactly its key set — no more, no fewer. It holds that role because it is the oldest and most complete, not because Simplified Chinese is special.
3. **The key is the English string.** There is no separate English table; `NSLocalizedString("Clean")` falls back to `Clean`. This is why editing English copy is never a one-file change (see below).
4. **Never translate a format specifier.** `%@`, `%d`, `%lld`, `%.1f` and `%%` survive verbatim. If the target language needs a different word order, reorder with positional specifiers (`%2$d … %1$@`) rather than moving the bare ones — moving them rebinds each conversion to the wrong argument, which is a runtime crash or garbage, not a compile error.
5. **The `ACTION:` line in the Explain prompt stays English in every language.** It is a control token matched against `ExplainSuggestion`'s raw values and then dropped, so nobody reads it; translating it silently costs the user the action button.

## Adding a language

1. Add a row to `AppLanguage.all`. Put the endonym in its own language — a picker offering "German" to a German speaker labels the one option they can already read.
2. Create `macos/Resources/<code>.lproj/Localizable.strings` with every key from `zh-Hans`, in the same order, keeping the section comments. XcodeGen picks the folder up automatically; no project change is needed.
3. Run the test suite. Four tests gate the result, described below.
4. Add the language to the README's Settings table.

## What CI checks — and what it cannot

`macos/Tests/LocalizationTests.swift` enforces four things across every language automatically, so none of them need a per-language test:

- **Key parity** with the canonical table, both directions.
- **Core interface coverage** — the tabs, the consent dialog and the destructive-action gates must never fall back to English.
- **Format-argument survival**, honouring positional reordering.
- **`AppLanguage.all` matches the shipped `.lproj` folders**, both directions. A row without a table ships a picker entry that silently renders English; a table without a row ships a translation nobody can select.

What no test can tell you is whether a translation is *correct*. Key parity proves a string is present, not that it says the right thing — the Russian table shipped with `Clean` and `Purge` both rendered as "Очистка", two different tools under one name, and every test passed. **A new language needs a native speaker to read it before it ships.**

### Translation status

| Language | Code | Reviewed by a native speaker |
| --- | --- | --- |
| 简体中文 | `zh-Hans` | yes |
| 繁體中文 | `zh-Hant` | yes |
| Русский | `ru` | contributed by a speaker, machine-corrected since |
| 日本語 | `ja` | **not yet** |
| Deutsch | `de` | **not yet** |
| Français | `fr` | **not yet** |
| Español | `es` | **not yet** |
| 한국어 | `ko` | **not yet** |
| Português (Brasil) | `pt-BR` | **not yet** |

Rows marked "not yet" are machine-drafted. They are structurally sound — parity, format specifiers and coverage are all enforced — but the wording has not been read by a speaker. Fixing one is a welcome first contribution: correct the `.strings` file and flip the row.

## Editing English copy

Changing an English string changes the key, which orphans that key in all nine tables at once and fails the parity test. That is deliberate: it is what stops a copy edit from silently leaving nine stale translations behind. The fix is to update every table in the same commit.

The corollary is that **each language is a permanent tax on every copy change**, which is the real argument for restraint. Add a language because someone asked for it and will help maintain it, not to fill in a matrix.

There is one gap this does not cover: a new `NSLocalizedString` in Swift that never reaches any table passes CI and just renders English. Nothing enforces that today.

## Plurals

Russian, Ukrainian, Polish, Czech, Arabic and Hebrew agree the counted noun with the number across three to six forms. Burrow's tables cannot express that: the scheme is two keys (`"%d update"` / `"%d updates"`), which covers exactly the languages with two forms.

**A `.stringsdict` does not currently fix this.** Foundation resolves plural rules from the locale passed to the format call, and all 252 `String(format:)` call sites in the app pass none — so it applies English rules and renders "5 приложения". Adding a stringsdict would move the breakage rather than remove it.

So languages in this family use count-neutral phrasing, which is grammatical at every number:

```
"%d apps" = "приложений: %d";        /* not "%d приложений" — wrong for 2-4 */
"Remove %d apps?" = "Удалить приложения (%d)?";
```

To fix this properly, thread `locale: .current` through those call sites first; then a stringsdict becomes the right answer and the workaround can be unwound.

## Languages by cost

Popularity is not what makes a language expensive — its plural rules are.

- **Free** (no number-noun agreement): Japanese, Korean, Chinese, Vietnamese, Thai. The two-key scheme is already more than these need.
- **Cheap** (two forms, aligned with English): German, French, Spanish, Italian, Dutch, Portuguese.
- **Blocked on the plural work above**: Russian (shipped with the workaround), Ukrainian, Polish, Czech, Arabic, Hebrew.

## The landing site

The site is localized by a different mechanism than the app, for the same
reason: nine hand-maintained copies of five pages would go stale on the first
copy edit and nothing would catch it.

Two scripts share the work, and the split matters: `site-release.py` renders the
**English** pages from JSON, including their language picker and `hreflang`
links; `site-i18n.py` reads those pages and writes the **translated** copies
under `docs/<lang>/`. Neither writes the other's files — two generators editing
one page is how they end up disagreeing.

Run order is `site-release.py` first, then `site-i18n.py`. Everything under
`docs/` and `docs/<lang>/` is build output; editing either by hand is wasted
work that the next run overwrites.

```bash
python3 scripts/site-i18n.py --extract   # pull new English strings into the catalogs
python3 scripts/site-i18n.py             # rebuild docs/<lang>/*.html
python3 scripts/site-i18n.py --check     # CI: fail if any copy has drifted
```

Three things follow from generating rather than copying:

- **An untranslated string falls back to English on its own.** The catalogs hold
  every string with `""` for the ones nobody has done yet; the renderer skips
  those, so a page is never blocked on being finished. This is why a partly
  translated site is safe to ship.
- **Editing English copy is a one-file change again.** Re-run the script and all
  nine copies follow. The new string arrives in the catalogs as untranslated.
- **The picker, the `hreflang` alternates, the canonical URLs and the sitemap
  rows are generated too**, so the ten copies cannot disagree about which
  languages exist.

`--check` runs in the compliance job, so a copy edit that skips the regenerate
step fails CI rather than shipping ten pages that disagree.

### Site translation status

`index.html` is the page a non-English visitor uses to decide whether to
download, so it is translated first. Everything else renders English until its
catalog is filled — which is a working site, not a broken one.

| | index | docs | compare | roadmap | releases |
| --- | --- | --- | --- | --- | --- |
| all nine languages | done | — | — | — | — |

155 strings per language, covering the hero, the sixteen tool cards, the
screenshot captions, the trust section, install and the FAQ. Proper nouns,
version strings and shell commands are deliberately left untranslated.

### releases.html is translated too, and that has a cost to manage

`releases.html` is 513 of the site's 824 strings, and it is regenerated from
`releases.json` by `site-release.py` on every release. So **every release adds
new untranslated strings to all nine catalogs** — the changelog is a treadmill
the other four pages are not.

That is a known, accepted cost, not an oversight. What it means in practice:

1. After `site-release.py` runs, run `site-i18n.py --extract`. The new release's
   notes appear in every catalog as empty strings.
2. Until someone fills them, that release's entry renders in English while every
   older entry stays translated. The page still ships; the fallback is per
   string, not per page.
3. `--check` will not fail for this — untranslated is a legal state. It fails
   only when a generated page has drifted from its source.

If the treadmill ever stops being worth it, dropping `releases.html` from
`PAGES` is a one-line change and the existing translations stay valid for the
rest of the site.
