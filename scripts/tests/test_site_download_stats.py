"""Tests for the release-asset counter used by the daily site refresh."""

import importlib.util
import unittest
from pathlib import Path
from unittest.mock import call, patch


SPEC = importlib.util.spec_from_file_location(
    "site_release", Path(__file__).resolve().parents[1] / "site-release.py"
)
RELEASE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RELEASE)


def asset(name, downloads):
    return {"name": name, "download_count": downloads}


class DownloadStatsTests(unittest.TestCase):
    def test_counts_published_app_archives_across_pages(self):
        first_page = [{"assets": [
            asset("Burrow-0.14.0.zip", 11),
            asset("BurrowWin-0.10.0-win-x64.zip", 7),
            asset("appcast.xml", 100_000),
            asset("Burrow-0.14.0-symbols.zip", 50),
            asset("Burrow-0.14.0.zip.sha256", 30),
        ]}, {"draft": True, "assets": [asset("Burrow-0.15.0.zip", 99)]}]
        first_page += [{}] * (100 - len(first_page))
        second_page = [{"prerelease": True, "assets": [
            asset("Burrow-0.8.0-windows-x64-preview.zip", 3),
            asset("source.zip", 21),
        ]}]
        with patch.object(RELEASE, "gh_json", side_effect=[first_page, second_page]) as api:
            self.assertEqual(RELEASE.fetch_download_total(), 21)
        self.assertEqual(api.call_args_list, [
            call("repos/caezium/Burrow/releases?per_page=100&page=1"),
            call("repos/caezium/Burrow/releases?per_page=100&page=2"),
        ])

    def test_api_failure_does_not_publish_a_partial_count(self):
        first_page = [{"assets": [asset("Burrow-0.14.0.zip", 11)]}] + [{}] * 99
        with patch.object(RELEASE, "gh_json", side_effect=[first_page, OSError("offline")]):
            with patch("sys.stderr"):
                self.assertIsNone(RELEASE.fetch_download_total())

    def test_homepage_wording_and_emphasis_stay_the_same(self):
        self.assertIn(
            "Already downloaded by <b>21,411</b> people",
            RELEASE.render_downloads(21_411),
        )
