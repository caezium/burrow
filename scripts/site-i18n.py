#!/usr/bin/env python3
"""Generate the landing site's translated pages from the English source.

The English pages are rendered by scripts/site-release.py from JSON. This
script reads them, pulls out every user-visible string, and writes the
translated copies to docs/<lang>/. Nothing under docs/<lang>/ is ever edited by
hand — it is build output.

Run order matters: site-release.py first (it owns the English pages, their
language picker and their hreflang links), then this. Running it the other way
round leaves the copies rendered from a stale English source.

That is the whole point: five hand-maintained copies per language would go
stale on the first copy edit and nothing would notice. Here a new English
string simply shows up as untranslated in the catalog, `--check` fails, and
the page falls back to English until someone fills it in.

  python3 scripts/site-i18n.py --extract     # refresh docs/i18n/<lang>.json
  python3 scripts/site-i18n.py               # write docs/<lang>/*.html
  python3 scripts/site-i18n.py --check       # exit 1 if output would change (CI)

Stdlib only. Keep it that way, this runs in the Pages deploy job.
"""

import argparse
import json
import re
import sys
from html.parser import HTMLParser
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
CATALOGS = DOCS / "i18n"

# Everything except blog/: the posts are long-form and are not machine-drafted.
PAGES = ["index.html", "docs.html", "compare.html", "roadmap.html", "releases.html"]

# Mirrors AppLanguage.all minus English. Keep the two in step — see
# docs/localization.md.
LANGUAGES = {
    "zh-Hans": "简体中文",
    "zh-Hant": "繁體中文",
    "ru": "Русский",
    "ja": "日本語",
    "de": "Deutsch",
    "fr": "Français",
    "es": "Español",
    "ko": "한국어",
    "pt-BR": "Português (Brasil)",
}

# Text inside these never reaches a reader as prose.
OPAQUE = {"script", "style", "code", "pre", "kbd", "samp"}

# Attributes worth translating, by tag.
ATTRS = {
    "meta": ("content",),
    "img": ("alt",),
    "a": ("title", "aria-label"),
    "button": ("title", "aria-label"),
    "input": ("placeholder", "aria-label"),
    "html": (),
}
# …but only these <meta> carry prose; the rest are machine values.
META_PROSE = {"description", "og:title", "og:description", "twitter:title",
              "twitter:description", "apple-mobile-web-app-title"}

# A string that is only punctuation, digits, or a bare token isn't prose.
NOT_PROSE = re.compile(r"^[\s\d\W_]*$")


class Slots(HTMLParser):
    """Collect every translatable span in document order, with source offsets.

    Each HTMLParser event reports where it starts, so consecutive starts
    delimit each event's source span. That lets the document be rebuilt
    byte-for-byte and one span swapped without a serializer of our own —
    which matters, because these pages carry hand-written JSON-LD and inline
    CSS that no round-trip should touch.
    """

    def __init__(self, src):
        super().__init__(convert_charrefs=False)
        self.src = src
        self.lines = src.splitlines(keepends=True)
        self.offsets = [0]
        for line in self.lines:
            self.offsets.append(self.offsets[-1] + len(line))
        self.events = []          # (start_offset, kind, payload)
        self.opaque_depth = 0

    def _pos(self):
        line, col = self.getpos()
        return self.offsets[line - 1] + col

    def handle_starttag(self, tag, attrs):
        # The language picker is generated, and its entries are endonyms
        # that stay in their own language — never catalog them.
        if tag in OPAQUE or "langpick" in dict(attrs).get("class", ""):
            self.opaque_depth += 1
        wanted = ATTRS.get(tag, ())
        found = []
        adict = dict(attrs)
        for name in wanted:
            value = adict.get(name)
            if not value or NOT_PROSE.match(value):
                continue
            if tag == "meta":
                key = adict.get("name") or adict.get("property") or ""
                if key not in META_PROSE:
                    continue
            found.append((name, value))
        if found:
            self.events.append((self._pos(), "attrs", found))

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)

    def handle_endtag(self, tag):
        if (tag in OPAQUE or tag == "details") and self.opaque_depth:
            self.opaque_depth -= 1

    def handle_data(self, data):
        if self.opaque_depth or NOT_PROSE.match(data):
            return
        self.events.append((self._pos(), "text", data))


def slots(src):
    """[(start, end, kind, payload)] for every translatable span."""
    p = Slots(src)
    p.feed(src)
    p.close()
    out = []
    for start, kind, payload in p.events:
        if kind == "text":
            end = start + len(payload)
            out.append((start, end, kind, payload))
        else:
            out.append((start, None, kind, payload))
    return out


def strings_in(src):
    """Every translatable string in a page, deduplicated, in document order."""
    seen, order = set(), []
    for _, _, kind, payload in slots(src):
        values = [payload.strip()] if kind == "text" else [v for _, v in payload]
        for v in values:
            if v and v not in seen:
                seen.add(v)
                order.append(v)
    return order


def render(src, table, lang, page_name="index.html"):
    """The English page with every known string swapped for its translation.

    The English pages are rendered by site-release.py, picker and alternates
    included; this only ever writes docs/<lang>/.
    """
    out, cursor = [], 0
    for start, end, kind, payload in slots(src):
        if kind == "text":
            translated = table.get(payload.strip())
            if not translated:
                continue
            # Keep the original surrounding whitespace: it is load-bearing for
            # inline elements, where collapsing it would glue words together.
            lead = payload[: len(payload) - len(payload.lstrip())]
            tail = payload[len(payload.rstrip()):]
            out.append(src[cursor:start])
            out.append(lead + translated + tail)
            cursor = end
        else:
            tag_end = src.index(">", start)
            chunk = src[start:tag_end]
            for name, value in payload:
                translated = table.get(value)
                if not translated:
                    continue
                for quote in ('"', "'"):
                    needle = f'{name}={quote}{value}{quote}'
                    if needle in chunk:
                        chunk = chunk.replace(
                            needle, f'{name}={quote}{translated}{quote}', 1)
                        break
            out.append(src[cursor:start])
            out.append(chunk)
            cursor = tag_end
    out.append(src[cursor:])
    page = "".join(out)

    if lang != "en":
        # The copy lives one directory deeper, so relative links need care in
        # two directions. Routes that exist per-language must stay relative, or
        # a reader clicking "Docs" on the Japanese page lands back in English.
        # Everything else — assets, and the pages that only exist in English —
        # has to climb back out.
        translated_routes = {"./", "./#tools", ""} | {
            p.removesuffix(".html") for p in PAGES}

        def rebase(m):
            target = m.group(2)
            base = target.split("#", 1)[0].split("?", 1)[0]
            if base in translated_routes or base.rstrip("/") in translated_routes:
                return f'{m.group(1)}{target}'
            return f'{m.group(1)}../{target}'

        page = re.sub(r'((?:href|src)=")(?!https?:|/|#|mailto:)([^"]*)"',
                      lambda m: rebase(m) + '"', page)
        page = page.replace('<html lang="en">', f'<html lang="{lang}">')

    # Point canonical at this copy, then list every sibling. Without both, the
    # nine translations read as duplicates of the English page.
    path = "" if page_name == "index.html" else page_name.removesuffix(".html")
    prefix = "" if lang == "en" else f"{lang}/"
    page = re.sub(r'<link rel="canonical" href="[^"]*">',
                  f'<link rel="canonical" href="https://burrow.computer/{prefix}{path}">'
                  + "\n" + hreflang_block(page_name),
                  page, count=1)
    # Replaced between markers, not at a one-shot placeholder: the English
    # page is regenerated in place, so the substitution has to be idempotent.
    page = re.sub(r"<!-- LANGPICK:BEGIN -->.*?<!-- LANGPICK:END -->",
                  lambda _: "<!-- LANGPICK:BEGIN -->" + switcher(lang, page_name)
                            + "<!-- LANGPICK:END -->",
                  page, count=1, flags=re.S)
    return page


def hreflang_block(page_name):
    """Alternate-language links, so search engines pair the copies up."""
    base = "https://burrow.computer"
    path = "" if page_name == "index.html" else page_name.removesuffix(".html")
    lines = [f'<link rel="alternate" hreflang="x-default" href="{base}/{path}">',
             f'<link rel="alternate" hreflang="en" href="{base}/{path}">']
    for code in LANGUAGES:
        lines.append(
            f'<link rel="alternate" hreflang="{code}" href="{base}/{code}/{path}">')
    return "\n".join(lines)


def switcher(current, page_name):
    """A plain <details> menu — no script, so it works before JS and without.

    Every link is absolute from the site root: the copies sit at two different
    depths, and relative hops between them are the kind of thing that breaks
    silently on one page and nowhere else.
    """
    path = "" if page_name == "index.html" else page_name.removesuffix(".html")
    here = LANGUAGES.get(current, "English")
    items = []
    for code, name in [("en", "English"), *LANGUAGES.items()]:
        target = f'/{path}' if code == "en" else f'/{code}/{path}'
        mark = ' aria-current="page"' if code == current else ""
        items.append(f'<a href="{target}" hreflang="{code}"{mark}>{name}</a>')
    return ('<details class="langpick"><summary aria-label="Language">'
            f'<span>{here}</span></summary><nav>{"".join(items)}</nav></details>')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--extract", action="store_true",
                    help="refresh the catalogs from the English pages")
    ap.add_argument("--check", action="store_true",
                    help="exit 1 if any generated page or catalog is stale")
    args = ap.parse_args()

    def source(name):
        """The English page with any previously generated picker emptied out.

        The English copy is regenerated in place, so without this the last
        run's switcher becomes this run's input and the nine translations get
        rendered from a different source than the English page was.
        """
        text = (DOCS / name).read_text(encoding="utf-8")
        text = re.sub(r"<!-- LANGPICK:BEGIN -->.*?<!-- LANGPICK:END -->",
                      "<!-- LANGPICK:BEGIN --><!-- LANGPICK:END -->",
                      text, count=1, flags=re.S)
        # Drop a previous run's alternates too, or each run stacks another set.
        return re.sub(r'\n?<link rel="alternate" hreflang="[^"]*" href="[^"]*">',
                      "", text)

    sources = {name: source(name) for name in PAGES}
    wanted = {}
    for name, src in sources.items():
        for s in strings_in(src):
            wanted.setdefault(s, []).append(name)

    if args.extract:
        CATALOGS.mkdir(parents=True, exist_ok=True)
        for code in LANGUAGES:
            path = CATALOGS / f"{code}.json"
            table = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
            merged = {s: table.get(s, "") for s in wanted}
            path.write_text(
                json.dumps(merged, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
            missing = sum(1 for v in merged.values() if not v)
            print(f"{code}: {len(merged)} strings, {missing} untranslated")
        return 0

    stale, missing_total = [], {}
    for code in LANGUAGES:
        path = CATALOGS / f"{code}.json"
        if not path.exists():
            print(f"no catalog for {code} — run --extract", file=sys.stderr)
            return 1
        table = {k: v for k, v in
                 json.loads(path.read_text(encoding="utf-8")).items() if v}
        missing_total[code] = len(wanted) - len(table)
        for name, src in sources.items():
            page = render(src, table, code, name)
            out = DOCS / code / name
            if args.check:
                if not out.exists() or out.read_text(encoding="utf-8") != page:
                    stale.append(f"{code}/{name}")
            else:
                out.parent.mkdir(parents=True, exist_ok=True)
                out.write_text(page, encoding="utf-8")

    for code, n in missing_total.items():
        if n:
            print(f"{code}: {n} strings still untranslated (they render in English)")
    if args.check and stale:
        print("stale generated pages: " + ", ".join(stale), file=sys.stderr)
        print("run: python3 scripts/site-i18n.py", file=sys.stderr)
        return 1
    if not args.check:
        print(f"wrote {len(LANGUAGES) * len(PAGES)} pages under docs/<lang>/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
