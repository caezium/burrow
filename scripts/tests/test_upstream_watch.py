"""Quoting upstream release notes never notifies an upstream contributor.

The watcher mirrors upstream release notes and commit subjects into our triage
issues. Those carry `@handles`, `#123` refs and PR URLs, and GitHub links and
notifies on all three, so upstream contributors got pinged by tooling they
never opted into. neutralize() quotes those so GitHub links nothing.

Both failure directions matter and both have bitten us:

  quoting too little   a mention stays live and someone gets notified
  quoting too much     text GitHub would not treat as code is skipped, so a
                       mention hiding in it stays live too

which is why the code-span and fence rules below are pinned to how GitHub
itself parses them rather than to something looser that merely looks right.
"""

import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WATCHER = ROOT / ".github" / "scripts" / "upstream_watch.py"


def _load():
    """Import the watcher by path -- it lives under .github, not on sys.path."""
    spec = importlib.util.spec_from_file_location("upstream_watch", WATCHER)
    assert spec and spec.loader, f"cannot import {WATCHER}"
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


watch = _load()
neutralize = watch.neutralize


class NeutralizeTests(unittest.TestCase):
    def assertQuoted(self, text: str, live: str) -> None:
        """`live` must not survive in `text` as something GitHub would link."""
        self.assertNotIn(live, neutralize(text).replace(f"`{live}`", ""))

    def assertUnchanged(self, text: str) -> None:
        self.assertEqual(neutralize(text), text)

    # --- the thing the whole module exists for -------------------------------

    def test_handles_are_quoted(self):
        self.assertEqual(neutralize("thanks @foo"), "thanks `@foo`")

    def test_issue_refs_are_quoted(self):
        self.assertEqual(neutralize("see #34 and o/r#56"), "see `#34` and `o/r#56`")

    def test_pull_urls_fold_to_a_plain_ref(self):
        # A URL cross-references the PR exactly as a bare number does.
        self.assertEqual(neutralize("in https://github.com/tw93/Mole/pull/636"),
                         "in `tw93/Mole#636`")

    def test_real_release_note_line(self):
        self.assertEqual(
            neutralize("* fix: bump by @pranahonk in https://github.com/tw93/Mole/pull/636"),
            "* fix: bump by `@pranahonk` in `tw93/Mole#636`")

    def test_url_keeps_trailing_path_segments_out_of_the_output(self):
        self.assertEqual(neutralize("see https://github.com/o/r/pull/12/files done"),
                         "see `o/r#12` done")

    def test_markdown_link_with_a_title(self):
        self.assertEqual(neutralize('[#9](https://github.com/o/r/pull/9 "t") x'),
                         "`o/r#9` x")

    # --- quoting too little --------------------------------------------------

    def test_mention_after_emphasis_is_quoted(self):
        # Markdown emphasis runs first, so GitHub links these.
        for text in ("**@user**", "*@user*", "-@user", ".@user", "+@user"):
            with self.subTest(text=text):
                self.assertQuoted(text, "@user")

    def test_mention_after_an_unclosed_tilde_fence_marker_is_quoted(self):
        # A ``` line must not close a ~~~ block, or everything past the real
        # close goes unquoted.
        out = neutralize("~~~\n@inside\n```\n@still_inside\n~~~\n@after")
        self.assertQuoted(out, "@after")

    def test_mention_after_a_longer_closing_fence_is_quoted(self):
        # ```` closes a ``` block, per CommonMark.
        self.assertQuoted("```\n@in\n````\n@out", "@out")

    def test_mention_in_an_unequal_delimiter_run_is_quoted(self):
        # Opener of two, closer of one: not a code span to GitHub, so the
        # mention inside it is live and must be quoted.
        self.assertQuoted("``not code @user` more", "@user")

    def test_mention_after_a_stray_backtick_is_quoted(self):
        # A span cannot cross a blank line, so this one never opened.
        self.assertQuoted("start `stray tick\n\nnew para @user here", "@user")

    def test_unmatched_backtick_cannot_pair_with_an_inserted_quote(self):
        self.assertEqual(neutralize("fix `formatter @user"),
                         "fix &grave;formatter `@user`")

    def test_escaped_backtick_does_not_hide_a_live_mention(self):
        self.assertEqual(neutralize(r"escaped \`literal @user` end"),
                         r"escaped \&grave;literal `@user`&grave; end")

    def test_invalid_backtick_fence_info_does_not_hide_a_mention(self):
        self.assertEqual(neutralize("```lang`invalid\n@user\n```"),
                         "&grave;&grave;&grave;lang&grave;invalid\n`@user`\n&grave;&grave;&grave;")

    def test_indented_fence_does_not_capture_an_unindented_mention(self):
        self.assertQuoted("    ```\n@user\n    ```", "@user")

    def test_code_span_does_not_cross_a_markdown_block_boundary(self):
        for boundary in ("# heading", "> quote", "- item", "1. item", "<div>"):
            with self.subTest(boundary=boundary):
                self.assertQuoted(f"`before\n{boundary} @user\n`after", "@user")
        self.assertQuoted("`before\n---\n@user\n`after", "@user")

    # --- quoting too much ----------------------------------------------------

    def test_fenced_blocks_are_left_alone(self):
        self.assertUnchanged("```\n@in_fence #12\n```")

    def test_unterminated_fence_runs_to_the_end(self):
        self.assertUnchanged("```\n@in_fence_forever @x")

    def test_existing_code_spans_are_left_alone(self):
        self.assertUnchanged("already `@bar` quoted")

    def test_code_span_wrapping_a_line_is_left_whole(self):
        # Quoting only the part on one line inserts a backtick that re-pairs
        # the delimiters and pushes the mention out of the span, live.
        self.assertUnchanged("Here is `code with @user\nmore code` end")

    def test_equal_delimiter_run_is_a_span(self):
        self.assertUnchanged("``code @user`` more")

    def test_code_span_with_a_shorter_internal_run_is_left_whole(self):
        self.assertUnchanged("``code `literal @user`` more")

    def test_compare_urls_and_doc_anchors_stay_clickable(self):
        self.assertUnchanged("https://github.com/tw93/Mole/compare/v1...v2 and https://x.dev/d#s")

    # --- e-mail addresses ----------------------------------------------------

    def test_addresses_are_passed_through_whole(self):
        # A local part may end in punctuation; none of these is a mention.
        for addr in ("a.b+tag@example.com", "ops+@example.com", "o'brien'@example.com",
                     "a&b&@example.com", "x=y=@example.com", "n!@example.co.uk"):
            with self.subTest(addr=addr):
                self.assertUnchanged(f"mail {addr} now")

    def test_a_mention_before_an_address_is_still_quoted(self):
        # The address must not swallow the handle in front of it.
        self.assertEqual(neutralize("ping @user@example.com"), "ping `@user`@example.com")

    # --- shape ---------------------------------------------------------------

    def test_empty_and_none(self):
        self.assertEqual(neutralize(""), "")
        self.assertEqual(neutralize(None), "")

    def test_plain_text_is_untouched(self):
        self.assertUnchanged("Nothing here to quote at all.\n\nSecond paragraph.")


if __name__ == "__main__":
    unittest.main()
