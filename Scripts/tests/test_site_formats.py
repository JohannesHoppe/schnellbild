"""Tests that the list of formats (site/formats.json) is what the app shows, and
that the README's tables and every language's formats page name each of its
extensions (Scripts/site_formats.py; FormatListTests holds the list to the
app's own sets at run time).

    python3 -I -m unittest discover -s Scripts/tests
"""
import importlib.util
import json
import os
import re
import shutil
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent.parent
ROOT = SCRIPTS.parent

spec = importlib.util.spec_from_file_location("site_formats", SCRIPTS / "site_formats.py")
site_formats = importlib.util.module_from_spec(spec)
spec.loader.exec_module(site_formats)


class FormatListTests(unittest.TestCase):
    def setUp(self):
        self.formats, _ = site_formats.load()

    def test_the_list_is_what_the_app_shows(self):
        self.assertEqual(site_formats.differences(self.formats), [])

    def test_the_readme_names_every_extension(self):
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        self.assertEqual(site_formats.readme_missing(self.formats, readme), [])

    def test_every_formats_page_names_every_extension(self):
        languages = sorted(p.stem for p in (ROOT / "site" / "i18n").glob("*.json"))
        self.assertEqual(len(languages), 20)
        for code in languages:
            slug = json.loads((ROOT / "site" / "i18n" / f"{code}.json").read_text(encoding="utf-8"))["formatsSlug"]
            page = ROOT / "docs" / ("" if code == "en" else code.lower()) / slug / "index.html"
            html = page.read_text(encoding="utf-8")
            for f in self.formats:
                for ext in f["ext"]:
                    self.assertIn(f"<code>.{ext}</code>", html, f"{page.relative_to(ROOT)}: .{ext}")

    def test_an_extension_added_to_the_app_is_missed(self):
        """A copy of the sources with one more video extension: the list lacks it."""
        with tempfile.TemporaryDirectory() as folder:
            copy = Path(folder)
            shutil.copytree(ROOT / "Schnellbild", copy / "Schnellbild",
                            ignore=lambda _, names: [n for n in names if not n.endswith(".swift")])
            model = copy / "Schnellbild" / "BrowserModel.swift"
            source = model.read_text(encoding="utf-8")
            source = re.sub(r'(static let videoExtensions: Set<String> = \[\n\s*)', r'\1"nsv", ', source, count=1)
            model.write_text(source, encoding="utf-8")
            problems = site_formats.differences(self.formats, copy)
            self.assertEqual(problems, ["formats.json lacks .nsv, which the app shows"])

    def test_an_archive_extension_added_to_the_app_is_missed(self):
        with tempfile.TemporaryDirectory() as folder:
            copy = Path(folder)
            shutil.copytree(ROOT / "Schnellbild", copy / "Schnellbild",
                            ignore=lambda _, names: [n for n in names if not n.endswith(".swift")])
            archives = copy / "Schnellbild" / "Archives.swift"
            source = archives.read_text(encoding="utf-8").replace('"cbr": .rar,', '"cbr": .rar, "cbt": .zip,', 1)
            archives.write_text(source, encoding="utf-8")
            self.assertEqual(site_formats.differences(self.formats, copy), ["formats.json lacks .cbt, which the app shows"])


if __name__ == "__main__":
    unittest.main()
