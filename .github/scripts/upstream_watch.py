#!/usr/bin/env python3
"""
Upstream release watcher for Burrow.

Watches the engines Burrow depends on (currently `mo` / tw93/Mole) for new
GitHub releases and files a triage issue for each, plus a weekly digest of the
commits between releases. Burrow drives `mo` at runtime, so a new engine release
can change behaviour, flags, output format, or the minimum supported version --
this keeps those changes from slipping past.

Driven by .github/upstream-watch.json. Invoked by .github/workflows/upstream-watch.yml.

Dedup: a hidden marker in each issue body. We list the engine's labelled issues
and check their bodies before filing, so the issue itself is the state -- it
never double-files or misses.

Quoting: upstream text is run through neutralize() before it lands in an issue,
so quoting a release note never notifies an upstream contributor or
cross-references an upstream PR. See the comment above that function.

Env:
  GH_TOKEN           token for `gh` (needs issues: write)
  GITHUB_REPOSITORY  owner/repo to file issues into
"""
import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / ".github" / "upstream-watch.json"
REPO = os.environ.get("GITHUB_REPOSITORY", "")
DRY_RUN = False

# --- quoting upstream text without notifying upstream people -----------------
# Upstream release notes and commit subjects are full of `@handles`, `#123` refs
# and issue/PR URLs. Pasted verbatim into an issue here, GitHub notifies those
# people and cross-references those PRs, so upstream contributors get pinged by
# tooling they never opted into. We keep the text, but wrap the parts GitHub
# would linkify in code spans (GitHub does not link or notify inside code), and
# fold issue/PR/discussion URLs down to a plain `owner/repo#N` ref.

# Regions we pass through untouched. Erring wide here is not safe: anything we
# treat as code but GitHub does not is a live mention we skipped, so each shape
# is matched the way GitHub parses it. A fenced block closes only on a run of
# its own character, at least as long -- a ``` line does not close a ~~~ block.
# An inline span closes on a run of equal length, and may wrap across a line but
# not across a blank line. An e-mail address is passed through whole, which is
# what stops us mangling a local part that ends in punctuation (ops+@x.com,
# o'brien'@x.com) without having to guess at every character one may end with.
FENCE = r"^ {0,3}(?P<fence>(?P<fchar>[`~])(?P=fchar){2,})(?P<info>[^\n]*)$"
# An escaped backtick is text, and a span can contain runs of a different length.
# Conservatively treating a backslash-adjacent opener as text is safe because
# _neutralize_span also removes its delimiter role before quoting references.
BLOCK_BREAK = (r"\n[ \t]*(?:\n|>|#{1,6}(?:[ \t]|\n)|[-=]+[ \t]*(?:\n|\Z)"
               r"|`{3,}|~{3,}|<|(?:[-+*]|\d+[.)])[ \t])")
CODE_SPAN = (r"(?<![\\`\t])(?<!    )(?P<tick>`+)(?!`)"
             r"(?:(?!(?P=tick)(?!`)|" + BLOCK_BREAK + r")[\s\S])*?(?P=tick)(?!`)")
EMAIL = r"(?<![@\w])[\w.!#$%&'*+/=?^{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9-]+)+"
PROTECTED_RE = re.compile(
    r"(?ms)" + FENCE + r".*?(?:^ {0,3}(?P=fence)(?P=fchar)*[ \t]*$|\Z)"
    r"|" + CODE_SPAN + r"|" + EMAIL
)
MENTION_RE = re.compile(r"(?<![\w`/@])@([A-Za-z0-9][A-Za-z0-9-]{0,38}(?:/[A-Za-z0-9._-]+)?)")
ISSUE_REF_RE = re.compile(r"(?<![\w`/#&-])((?:[A-Za-z0-9][\w.-]*/[A-Za-z0-9][\w.-]*)?#\d+)\b")
ISSUE_URL = (r"https?://(?:www\.)?github\.com/([A-Za-z0-9][\w.-]*/[A-Za-z0-9][\w.-]*)"
             r"/(?:issues|pull|discussions)/(\d+)(?:/[A-Za-z0-9._-]+)*(?:[#?][^\s)\]]*)?")
ISSUE_URL_RE = re.compile(ISSUE_URL)
MD_ISSUE_LINK_RE = re.compile(r"\[[^\]]*\]\(\s*" + ISSUE_URL + r"""\s*(?:"[^"]*"|'[^']*')?\s*\)""")


def _neutralize_span(s):
    # Unmatched/escaped source delimiters must not pair with the backticks we
    # insert below. For example, `stray @user otherwise turns into `stray `@user`,
    # which leaves the handle OUTSIDE the only code span GitHub recognizes.
    # A named entity also stays harmless when an upstream backslash escapes its
    # ampersand; a numeric &#96; would then become a live reference to issue #96.
    s = s.replace("`", "&grave;")
    s = MD_ISSUE_LINK_RE.sub(lambda m: f"`{m.group(1)}#{m.group(2)}`", s)
    s = ISSUE_URL_RE.sub(lambda m: f"`{m.group(1)}#{m.group(2)}`", s)
    s = MENTION_RE.sub(lambda m: f"`@{m.group(1)}`", s)
    return ISSUE_REF_RE.sub(lambda m: f"`{m.group(1)}`", s)


def neutralize(text):
    """Quote upstream-authored text so GitHub links nothing and notifies nobody.

    Scans the whole text rather than line by line: a fenced block or an inline
    span can cover several lines, and quoting only part of one would insert a
    backtick that re-pairs the span and leaves the mention after it live.
    """
    text = text or ""
    out, pos = [], 0
    for m in PROTECTED_RE.finditer(text):
        # Already code -- GitHub neither links nor notifies in there.
        out.append(_neutralize_span(text[pos:m.start()]))
        # CommonMark forbids backticks in a backtick fence's info string. Such
        # a line is ordinary text even when a later line looks like its close.
        if m.group("fchar") == "`" and "`" in m.group("info"):
            out.append(_neutralize_span(m.group(0)))
        else:
            out.append(m.group(0))
        pos = m.end()
    out.append(_neutralize_span(text[pos:]))
    return "".join(out)


def log(msg):
    print(msg, flush=True)


def load_json(path, default):
    try:
        return json.loads(Path(path).read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return default


def gh(*args, check=True):
    r = subprocess.run(["gh", *args], capture_output=True, text=True)
    if check and r.returncode != 0:
        raise RuntimeError(f"`gh {' '.join(args)}` failed: {r.stderr.strip()}")
    return r.stdout


def gh_api(path):
    return gh("api", path, "-H", "Accept: application/vnd.github+json")


def ensure_label(label):
    if DRY_RUN:
        return
    gh("label", "create", label, "--repo", REPO, "--color", "FBCA04",
       "--description", "New release/commits from a watched upstream engine",
       "--force", check=False)


def existing_bodies(label):
    """All issue bodies (any state) carrying `label`, joined -- the dedup index."""
    out = gh("issue", "list", "--repo", REPO, "--label", label, "--state", "all",
             "--limit", "400", "--json", "body", check=False)
    try:
        return "\n".join(i.get("body") or "" for i in json.loads(out or "[]"))
    except json.JSONDecodeError:
        return ""


def create_issue(title, body, label):
    if DRY_RUN:
        log(f"  [dry-run] would file: {title}")
        return
    out = gh("issue", "create", "--repo", REPO, "--title", title,
             "--body", body, "--label", label, check=False)
    log(f"  filed: {title} -> {out.strip()}")


def do_releases(cfg):
    s = cfg.get("settings", {})
    lookback = int(s.get("release_lookback_days", 14))
    scan = int(s.get("release_scan_count", 8))
    cutoff = datetime.now(timezone.utc) - timedelta(days=lookback)
    for eng in cfg.get("engines", []):
        repo, name, label = eng["repo"], eng["name"], eng["label"]
        log(f"[releases] {repo}")
        try:
            rels = json.loads(gh_api(f"repos/{repo}/releases?per_page={scan}"))
        except Exception as e:
            log(f"  ! fetch failed: {e}")
            continue
        ensure_label(label)
        seen = existing_bodies(label)
        for rel in rels:
            if rel.get("draft"):
                continue
            tag = rel.get("tag_name") or ""
            pub = rel.get("published_at") or ""
            try:
                if datetime.fromisoformat(pub.replace("Z", "+00:00")) < cutoff:
                    continue
            except ValueError:
                pass
            marker = f"upstream-watch:RELEASE:{repo}:{tag}"
            if marker in seen:
                log(f"  = {tag} already tracked")
                continue
            rel_name = rel.get("name") or ""
            pre = " (prerelease)" if rel.get("prerelease") else ""
            notes = neutralize((rel.get("body") or "").strip()) or "_(no release notes)_"
            html_url = rel.get("html_url") or f"https://github.com/{repo}/releases/tag/{tag}"
            title = f"[{name}] {tag}"
            if rel_name and rel_name not in (tag, ""):
                title += f" — {rel_name}"
            body = f"""<!-- {marker} -->
**Upstream [`{name}`]({html_url}) released `{tag}`{pre}** on {pub[:10]}.

Burrow drives `{name}` at runtime, so a new engine release can change behaviour, flags, output format, or the minimum supported version.

### Triage
- [ ] New / renamed / removed subcommand or flag Burrow wraps?
- [ ] Bump Burrow's pinned / minimum `{name}` version?
- [ ] Breaking change to any output the parser relies on?
- [ ] New capability worth surfacing in the GUI or MCP tools?
- [ ] Compat smoke-test against `{tag}`.

<details><summary>Upstream release notes</summary>

{notes}

</details>

<sub>Handles and issue refs above are quoted as code on purpose, so mirroring upstream notes here never notifies upstream contributors. Read them at the [source]({html_url}).</sub>

<sub>Filed automatically by <code>.github/workflows/upstream-watch.yml</code>.</sub>
"""
            create_issue(title, body, label)


def do_digest(cfg):
    s = cfg.get("settings", {})
    days = int(s.get("digest_lookback_days", 7))
    since = datetime.now(timezone.utc) - timedelta(days=days)
    since_iso = since.strftime("%Y-%m-%dT%H:%M:%SZ")
    yr, wk, _ = datetime.now(timezone.utc).isocalendar()
    week = f"{yr}-W{wk:02d}"
    for eng in cfg.get("engines", []):
        repo, name, label = eng["repo"], eng["name"], eng["label"]
        log(f"[digest] {repo} since {since_iso}")
        ensure_label(label)
        marker = f"upstream-watch:DIGEST:{repo}:{week}"
        if marker in existing_bodies(label):
            log(f"  = digest {week} already filed")
            continue
        try:
            commits = json.loads(gh_api(f"repos/{repo}/commits?since={since_iso}&per_page=100"))
        except Exception as e:
            log(f"  ! fetch failed: {e}")
            continue
        rows = []
        for c in commits:
            sha = c["sha"]
            msg = neutralize((c["commit"]["message"].splitlines() or [""])[0])
            rows.append(f"- [`{sha[:7]}`](https://github.com/{repo}/commit/{sha}) {msg}")
        if not rows:
            log("  = no commits in window")
            continue
        title = f"[{name}] weekly commit digest — {week}"
        body = f"""<!-- {marker} -->
**{len(rows)} commit(s)** to [`{repo}`](https://github.com/{repo}) in the last {days} days (since {since_iso[:10]}).

Engine churn between tagged releases. Most won't need action — scan for anything that touches a command Burrow wraps or an output format it parses.

{chr(10).join(rows)}

<sub>Filed automatically by <code>.github/workflows/upstream-watch.yml</code>.</sub>
"""
        create_issue(title, body, label)


def main():
    global DRY_RUN
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", default="all", help="comma list of: releases,digest (or all)")
    ap.add_argument("--dry-run", action="store_true", help="log actions without filing issues")
    args = ap.parse_args()
    DRY_RUN = args.dry_run or os.environ.get("WATCH_DRY_RUN") == "1"

    modes = {m.strip() for m in args.mode.replace("all", "releases,digest").split(",") if m.strip()}
    if not REPO:
        log("GITHUB_REPOSITORY not set")
        sys.exit(1)

    cfg = load_json(CONFIG, {})
    log(f"upstream-watch: modes={sorted(modes)} repo={REPO} dry_run={DRY_RUN}")

    if "releases" in modes:
        do_releases(cfg)
    if "digest" in modes:
        do_digest(cfg)
    log("done")


if __name__ == "__main__":
    main()
