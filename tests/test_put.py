"""Unit tests for the pure halves of bin/pixeldrain-put.

The network paths need a Pro account, but the two functions that decide what the
orchestrator actually sees — the listing formatter and the path encoder — are
pure, so they get tested against fixture responses.

    python3 -m unittest discover -s tests
"""
import importlib.machinery
import importlib.util
import json
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
FIXTURES = pathlib.Path(__file__).resolve().parent / "fixtures"


def _load_helper():
    """Import bin/pixeldrain-put, which has no .py extension."""
    path = ROOT / "bin" / "pixeldrain-put"
    loader = importlib.machinery.SourceFileLoader("pixeldrain_put", str(path))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


pd = _load_helper()


def fixture(name):
    with open(FIXTURES / name) as f:
        return json.load(f)


class TestFormatListing(unittest.TestCase):
    def test_dirs_first_then_files(self):
        lines = pd.format_listing(fixture("mixed.json"))
        kinds = [line.split(" ", 1)[0] for line in lines]
        self.assertEqual(kinds, ["DIR"] * 3 + ["FILE"] * 4)

    def test_sorted_case_insensitively(self):
        lines = pd.format_listing(fixture("mixed.json"))
        dirs = [l[len("DIR "):] for l in lines if l.startswith("DIR ")]
        self.assertEqual(dirs, ["apple", "Photos", "zebra"])

    def test_file_lines_carry_size_before_name(self):
        lines = pd.format_listing(fixture("mixed.json"))
        self.assertIn("FILE 1073741824 Archive.zip", lines)
        self.assertIn("FILE 0 notes.txt", lines)

    def test_names_with_spaces_survive_intact(self):
        # The orchestrator splits FILE lines on the *first* space only, so a
        # name containing spaces has to come through unquoted and unescaped.
        lines = pd.format_listing(fixture("mixed.json"))
        self.assertIn("FILE 204800 report final.pdf", lines)

    def test_null_file_size_becomes_zero(self):
        lines = pd.format_listing(fixture("mixed.json"))
        self.assertIn("FILE 0 no-size.bin", lines)

    def test_empty_directory_yields_no_lines(self):
        self.assertEqual(pd.format_listing(fixture("empty.json")), [])

    def test_missing_children_key_is_not_an_error(self):
        self.assertEqual(pd.format_listing({}), [])

    def test_null_children_is_not_an_error(self):
        self.assertEqual(pd.format_listing({"children": None}), [])

    def test_unnamed_entries_are_dropped(self):
        data = {"children": [{"type": "dir"}, {"type": "file", "file_size": 1}]}
        self.assertEqual(pd.format_listing(data), [])

    def test_untyped_entries_count_as_files(self):
        # PixelDrain omits "type" for plain files in some responses.
        data = {"children": [{"name": "x.bin", "file_size": 5}]}
        self.assertEqual(pd.format_listing(data), ["FILE 5 x.bin"])


class TestEncodePath(unittest.TestCase):
    def test_separators_are_preserved(self):
        self.assertEqual(pd.encode_path("me/a/b"), "me/a/b")

    def test_spaces_are_encoded(self):
        self.assertEqual(pd.encode_path("me/my folder"), "me/my%20folder")

    def test_hash_is_encoded(self):
        # An unencoded '#' truncates the URL at the fragment when pasted.
        self.assertEqual(pd.encode_path("me/a#b"), "me/a%23b")

    def test_question_mark_is_encoded(self):
        self.assertEqual(pd.encode_path("me/a?b"), "me/a%3Fb")

    def test_unicode_is_encoded(self):
        self.assertEqual(pd.encode_path("me/café"), "me/caf%C3%A9")

    def test_plain_path_is_unchanged(self):
        self.assertEqual(pd.encode_path("me"), "me")


class TestResultCodes(unittest.TestCase):
    def test_permanent_and_transient_are_distinct(self):
        # The orchestrator retries TRANSIENT and gives up on PERMANENT, so they
        # must never collapse to the same value.
        self.assertNotEqual(pd.PERMANENT, pd.TRANSIENT)

    def test_permanent_is_not_mistaken_for_an_http_status(self):
        self.assertTrue(str(pd.PERMANENT).startswith("-"))


if __name__ == "__main__":
    unittest.main()
