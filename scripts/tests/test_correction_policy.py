# SPDX-License-Identifier: GPL-3.0-or-later
"""Keeper of the two open choices of the typo correction (spec/01-engine.md section 15, Q10 and Q11), each built in
ONE named place: `CorrectionPolicy.sentenceStart` and `CorrectionPolicy.commitKeys` in
Packages/VietnameseEngine/Sources/VietnameseEngine/Commit/CorrectionPolicy.swift. The texts that follow a choice
must agree with the constant, so flipping a choice is a short, checked edit (plan of 19/11/2026, section "Q10 and
Q11: one named place each"):

- Q10 (sentence case at a sentence start): the D30 copy of PRD-R80 and the D30 row of spec/03-product.md say
  `từ viết hoa toàn bộ` / `words in all capitals` when such a word is corrected, `từ viết hoa` / `capitalised words`
  otherwise; rows S23 and S24 of 13.12 show the corrected word exactly when it is corrected.
- Q11 (Return and Tab): row S26 of 13.12 shows `android` and the Return exactly when every committing key corrects.

The String Catalog half (plan Task 29): the vi and en values of the D30 explanation in
App/Resources/Localization/Settings.xcstrings and of its two restore-key variants say the same Q10 words as the spec;
it skips while the catalog has no D30 entry. Run: python3 -I scripts/tests/test_correction_policy.py
"""
from __future__ import annotations

import json
import re
import sys
import unittest
from pathlib import Path

sys.dont_write_bytecode = True  # keep scripts/tests free of __pycache__
sys.path.insert(0, str(Path(__file__).resolve().parent))

from support import REPO  # noqa: E402

POLICY = REPO / "Packages" / "VietnameseEngine" / "Sources" / "VietnameseEngine" / "Commit" / "CorrectionPolicy.swift"
ENGINE_SPEC = REPO / "spec" / "01-engine.md"
PRODUCT_SPEC = REPO / "spec" / "03-product.md"
SETTINGS_CATALOG = REPO / "App" / "Resources" / "Localization" / "Settings.xcstrings"
# The D30 explanation for Escape and its variants for another restore key and for the key off (PRD-R80, PRD-R78).
D30_EXPLANATION_KEYS = (
    "settings.typing.typoCorrection.explanation",
    "settings.typing.typoCorrection.explanationOtherKey",
    "settings.typing.typoCorrection.explanationNoKey",
)


def policy_value(name: str, source: str) -> str:
    """The case name a `package static let <name>` of CorrectionPolicy.swift is set to."""
    match = re.search(rf"package static let {name}: \w+ = \.(\w+)", source)
    if match is None:
        raise AssertionError(f"CorrectionPolicy.swift has no `package static let {name}: ... = .<case>`")
    return match.group(1)


def table_row(spec: str, row_id: str) -> list[str]:
    """The cells of the 13.12 row `row_id` (first cell `S..`), backticks kept."""
    for line in spec.splitlines():
        if line.startswith(f"| {row_id} |"):
            return [cell.strip() for cell in line.strip().strip("|").split("|")]
    raise AssertionError(f"row {row_id} not found in spec/01-engine.md")


def backticked(paragraph: str, prefix: str) -> str:
    """The first backticked span of `paragraph` that starts with `prefix`."""
    for span in re.findall(r"`([^`]+)`", paragraph):
        if span.startswith(prefix):
            return span
    raise AssertionError(f"no backticked text starting with {prefix!r}")


def catalog_value(catalog: dict, key: str, language: str) -> str:
    """The `language` value of `key` in a String Catalog."""
    return catalog["strings"][key]["localizations"][language]["stringUnit"]["value"]


def line_starting(text: str, prefix: str) -> str:
    for line in text.splitlines():
        if line.startswith(prefix):
            return line
    raise AssertionError(f"no line starting with {prefix!r}")


class CorrectionPolicyKeeperTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        source = POLICY.read_text(encoding="utf-8")
        cls.sentence_start = policy_value("sentenceStart", source)
        cls.commit_keys = policy_value("commitKeys", source)
        cls.engine = ENGINE_SPEC.read_text(encoding="utf-8")
        cls.product = PRODUCT_SPEC.read_text(encoding="utf-8")

    def test_the_constants_name_known_cases(self) -> None:
        self.assertIn(self.sentence_start, {"corrected", "neverCorrected"})
        self.assertIn(self.commit_keys, {"everyCommitKey", "spaceAndPunctuationOnly"})

    def test_q10_the_d30_copy_follows_sentence_start(self) -> None:
        corrected = self.sentence_start == "corrected"
        paragraph = line_starting(self.product, "PRD-R80 ")
        vi = backticked(paragraph, "Gõ nhầm một từ tiếng Anh")
        en = backticked(paragraph, "When you mistype an English word")
        d30 = line_starting(self.product, "| D30 |")
        if corrected:
            self.assertIn("từ viết hoa toàn bộ", vi)
            self.assertIn("words in all capitals", en)
            self.assertIn("words in all capitals", d30)
        else:
            self.assertIn("từ viết hoa hay", vi)
            self.assertNotIn("toàn bộ", vi)
            self.assertIn("capitalised words", en)
            self.assertNotIn("words in all capitals", en)
            self.assertIn("capitalised words", d30)

    def test_q10_the_catalog_copy_follows_sentence_start(self) -> None:
        catalog = json.loads(SETTINGS_CATALOG.read_text(encoding="utf-8"))
        present = [key for key in D30_EXPLANATION_KEYS if key in catalog["strings"]]
        if not present:
            self.skipTest("Settings.xcstrings has no D30 explanation yet")
        self.assertEqual(present, list(D30_EXPLANATION_KEYS), "the D30 explanation comes with both variants")
        corrected = self.sentence_start == "corrected"
        for key in present:
            vi = catalog_value(catalog, key, "vi")
            en = catalog_value(catalog, key, "en")
            with self.subTest(key=key):
                if corrected:
                    self.assertIn("từ viết hoa toàn bộ", vi)
                    self.assertIn("words in all capitals", en)
                else:
                    self.assertIn("từ viết hoa hay", vi)
                    self.assertNotIn("toàn bộ", vi)
                    self.assertIn("capitalised words", en)
                    self.assertNotIn("words in all capitals", en)

    def test_q10_the_catalog_says_what_the_spec_says(self) -> None:
        """The catalog's D30 explanation for Escape is the PRD-R80 draft, the app name as its argument."""
        catalog = json.loads(SETTINGS_CATALOG.read_text(encoding="utf-8"))
        key = D30_EXPLANATION_KEYS[0]
        if key not in catalog["strings"]:
            self.skipTest("Settings.xcstrings has no D30 explanation yet")
        paragraph = line_starting(self.product, "PRD-R80 ")
        for language, prefix in (("vi", "Gõ nhầm một từ tiếng Anh"), ("en", "When you mistype an English word")):
            with self.subTest(language=language):
                draft = backticked(paragraph, prefix).replace("{{AppName}}", "%@")
                self.assertEqual(catalog_value(catalog, key, language), draft)

    def test_q10_rows_s23_and_s24_follow_sentence_start(self) -> None:
        corrected = self.sentence_start == "corrected"
        self.assertEqual(table_row(self.engine, "S23")[2], "`Android `" if corrected else "`Androdi `")
        self.assertEqual(table_row(self.engine, "S24")[2], "`xong. Receive `" if corrected else "`xong. Recieve `")

    def test_q11_row_s26_follows_commit_keys(self) -> None:
        every = self.commit_keys == "everyCommitKey"
        expected = "`android` and the Return" if every else "`androdi` and the Return"
        self.assertEqual(table_row(self.engine, "S26")[2], expected)

    def test_the_section_15_rows_still_name_both_questions(self) -> None:
        self.assertIn("| Q10 |", self.engine)
        self.assertIn("| Q11 |", self.engine)


if __name__ == "__main__":
    unittest.main()
