# SPDX-License-Identifier: GPL-3.0-or-later
"""Self-tests for the licences of the repository and the wording of its documents (ADR 0006 and its amendment of
2026-11-15; decision 0005, decisions of 15/11/2026): the pinned licence texts, the SPDX statements, the inbound terms,
no document calling the project's own code MIT, no document describing the development tools, and no chat quote in
the decision records. Run: python3 -I scripts/tests/test_licences_and_wording.py"""
from __future__ import annotations

import hashlib
import json
import re
import sys
import unittest
from pathlib import Path

sys.dont_write_bytecode = True  # keep scripts/tests free of __pycache__
sys.path.insert(0, str(Path(__file__).resolve().parent))

from support import IMAGE_SUFFIXES, REPO, changelog_group, py, run  # noqa: E402


class LicenceTests(unittest.TestCase):
    """ADR 0006 (Pa, 2026-11-13, amended 2026-11-15): the app is GPL-3.0-or-later; the engine packages, the data
    pipeline and the reference model are MPL-2.0 (MIT until the amendment, decided before any release); every
    contribution is signed off (DCO) and is also licensed to the project under MIT, the MPL-2.0 parts as well as the
    GPL-covered ones (QA-R61, PLT-R103, PLT-R108, ENG-R109, CLR-R11)."""

    # SHA-256 of https://www.gnu.org/licenses/gpl-3.0.txt as fetched on 2026-11-13 (35,149 bytes, the verbatim text).
    GPL3_SHA256 = "3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986"
    # SHA-256 of https://www.mozilla.org/media/MPL/2.0/index.txt as fetched on 2026-11-15 (16,726 bytes, the verbatim
    # text). It has no copyright line, so the MPL-2.0 directories carry it unchanged and name their authors elsewhere.
    MPL2_SHA256 = "3f3d9e0024b1921b067d6f7f88deb4a60cbe7a78e76c64e3f1d7fc3b779b9d04"
    MPL_DIRS = ("Packages/VietnameseEngine", "Packages/VietnameseEngineFuzz", "data", "spec/reference-model")
    # The copyright line names the product: a NOTICE beside the LICENSE (literal name, rewritten by
    # scripts/rename-app.sh) outside spec/; the README in spec/reference-model (spec/ keeps brand placeholders and is
    # never rewritten by a rename).
    NOTICE_DIRS = ("Packages/VietnameseEngine", "Packages/VietnameseEngineFuzz", "data")
    # MPL-2.0 Exhibit A, as the notice of every file in those directories (the MPL allows it to live in a NOTICE or
    # LICENSE file of the directory instead of each file).
    EXHIBIT_A = ("This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of "
                 "the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.")
    # Exhibit B would forbid combining the engine with the GPL app (MPL-2.0 section 3.3, Secondary Licenses).
    EXHIBIT_B = "Incompatible With Secondary " + "Licenses"  # split so this file does not match its own search
    ADR = REPO / "docs" / "decisions" / "0006-app-licence-and-pro-edition.md"
    PENDING_ID = "LicenseRef-" + "App-Pending"  # split so this file does not match its own search
    MIT_SPDX = "SPDX-License-Identifier: " + "MIT"  # split so this file does not match its own search

    @staticmethod
    def brand_name() -> str:
        env = (REPO / "scripts" / "brand.env").read_text(encoding="utf-8")
        return re.search(r'^APP_DISPLAY_NAME="([^"]+)"$', env, re.M).group(1)

    @staticmethod
    def flat(text: str) -> str:
        return " ".join(text.split())

    @staticmethod
    def listed() -> list[str]:
        return run("git", "-C", str(REPO), "ls-files", check=True).stdout.splitlines()

    def test_root_licence_is_the_verbatim_gpl_3_text(self):
        data = (REPO / "LICENSE").read_bytes()
        self.assertTrue(data.startswith(b"                    GNU GENERAL PUBLIC LICENSE\n"
                                        b"                       Version 3, 29 June 2007\n"))
        self.assertEqual(hashlib.sha256(data).hexdigest(), self.GPL3_SHA256, "LICENSE must be byte-exact")

    def test_mpl_parts_carry_the_verbatim_mpl_2_text(self):
        for directory in self.MPL_DIRS:
            with self.subTest(directory=directory):
                data = (REPO / directory / "LICENSE").read_bytes()
                self.assertTrue(data.startswith(b"Mozilla Public License Version 2.0\n"))
                self.assertEqual(hashlib.sha256(data).hexdigest(), self.MPL2_SHA256, "LICENSE must be byte-exact")

    def test_mpl_parts_name_their_authors_and_carry_exhibit_a(self):
        copyright_line = f"Copyright (c) 2026 the {self.brand_name()} authors"
        for directory in self.NOTICE_DIRS:
            with self.subTest(directory=directory):
                text = self.flat((REPO / directory / "NOTICE").read_text(encoding="utf-8"))
                for needle in (copyright_line, self.EXHIBIT_A, "LICENSE", "SPDX-License-Identifier: MPL-2.0",
                               "section 3.3", "GPL-3.0-or-later"):
                    with self.subTest(needle=needle):
                        self.assertIn(needle, text)
        readme = self.flat((REPO / "spec" / "reference-model" / "README.md").read_text(encoding="utf-8"))
        for needle in ("Copyright (c) 2026 the {{AppName}} authors", self.EXHIBIT_A, "MPL-2.0", "`LICENSE`"):
            with self.subTest(reference_model=needle):
                self.assertIn(needle, readme)

    def test_no_mpl_part_is_marked_incompatible_with_secondary_licences(self):
        offenders = []
        for rel in self.listed():
            if not rel.startswith(tuple(f"{directory}/" for directory in self.MPL_DIRS)) or rel.endswith("/LICENSE"):
                continue  # the LICENSE files are the verbatim text, Exhibit B template included
            path = REPO / rel
            if path.suffix.lower() in IMAGE_SUFFIXES or not path.is_file():
                continue
            if self.EXHIBIT_B in path.read_text(encoding="utf-8", errors="replace"):
                offenders.append(rel)
        self.assertEqual(offenders, [], "the engine must stay combinable with the GPL app (MPL-2.0 section 3.3)")

    def test_mpl_parts_match_the_spdx_lint(self):
        lint = (REPO / "scripts" / "check-spdx.sh").read_text(encoding="utf-8")
        mpl_path = re.compile(re.search(r'MPL_PATH = re\.compile\(r"([^"]+)"\)', lint).group(1))
        excluded = re.search(r'EXCLUDED = re\.compile\((r"[^\n]+"\n\s+r"[^\n]+")\)', lint)
        self.assertIsNotNone(excluded, "check-spdx.sh no longer defines EXCLUDED")
        excluded = re.compile("".join(re.findall(r'r"([^"]*)"', excluded.group(1))))
        for directory in self.MPL_DIRS:
            with self.subTest(directory=directory):
                self.assertRegex(f"{directory}/x.py", mpl_path)
                self.assertIsNone(excluded.search(f"{directory}/x.py"), "the MPL-2.0 directories are checked")
        self.assertNotRegex("App/x.swift", mpl_path)
        self.assertIsNotNone(excluded.search("spec/x.py"), "the rest of spec/ stays out of the lint")
        for script in sorted((REPO / "spec" / "reference-model").glob("*.py")):
            with self.subTest(reference_model=script.name):
                self.assertEqual(script.read_text(encoding="utf-8").splitlines()[0],
                                 "# SPDX-License-Identifier: MPL-2.0")

    def test_no_file_still_carries_the_mit_identifier(self):
        offenders = []
        for rel in self.listed():
            if rel.startswith(("scripts/tests/", "docs/decisions/")) or Path(rel).suffix.lower() in IMAGE_SUFFIXES:
                continue  # the lint self-tests write a wrong header on purpose; decision records keep their history
            path = REPO / rel
            if path.is_file() and self.MIT_SPDX in path.read_text(encoding="utf-8", errors="replace"):
                offenders.append(rel)
        self.assertEqual(offenders, [], "the engine parts are MPL-2.0 since 2026-11-15 (ADR 0006 amendment)")

    def test_a_rename_never_touches_a_licence_text(self):
        rename = (REPO / "scripts" / "rename-app.sh").read_text(encoding="utf-8")
        excluded = re.search(r'EXCLUDED = re\.compile\((r"[^\n]+"\n\s+r"[^\n]+")\)', rename)
        self.assertIsNotNone(excluded, "rename-app.sh no longer defines EXCLUDED")
        pattern = re.compile("".join(re.findall(r'r"([^"]*)"', excluded.group(1))))
        for rel in ("LICENSE", *(f"{directory}/LICENSE" for directory in self.MPL_DIRS)):
            with self.subTest(licence=rel):
                self.assertTrue(pattern.search(rel), "the verbatim GPL and MPL texts stay byte-exact after a rename")
        for directory in self.NOTICE_DIRS:
            with self.subTest(notice=directory):
                self.assertFalse(pattern.search(f"{directory}/NOTICE"), "the copyright lines follow a rename")

    def test_no_file_still_calls_the_app_licence_pending(self):
        offenders = []
        for rel in self.listed():
            if rel.startswith("docs/decisions/") or Path(rel).suffix.lower() in IMAGE_SUFFIXES:
                continue  # decision records keep their history
            path = REPO / rel
            if path.is_file() and self.PENDING_ID in path.read_text(encoding="utf-8", errors="replace"):
                offenders.append(rel)
        self.assertEqual(offenders, [], "the app licence is GPL-3.0-or-later (ADR 0006)")

    def test_spec_open_decision_lists_record_the_licence(self):
        for rel, marker in (("spec/00-overview.md", "| 2 | App licence"), ("spec/02-platform.md", "2. App licence"),
                            ("spec/03-product.md", "2. App licence"), ("spec/04-quality-release.md", "1. App licence")):
            with self.subTest(spec=rel):
                text = (REPO / rel).read_text(encoding="utf-8")
                line = next(line for line in text.splitlines() if line.startswith(marker))
                self.assertIn("GPL-3.0-or-later", line)
                self.assertIn("0006", line)
                self.assertNotIn("not decided", line.lower())
        platform = (REPO / "spec" / "02-platform.md").read_text(encoding="utf-8")
        plt_r108 = next(line for line in platform.splitlines() if line.startswith("- **PLT-R108**"))
        for needle in ("GPL-3.0-or-later", "compat-rules.json", "injection", "MPL-2.0"):
            self.assertIn(needle, plt_r108)
        self.assertNotIn("open decision", plt_r108)
        plt_r103 = next(line for line in platform.splitlines() if line.startswith("- **PLT-R103**"))
        self.assertIn("MPL-2.0", plt_r103)
        quality = (REPO / "spec" / "04-quality-release.md").read_text(encoding="utf-8")
        qa_r61 = quality.split("QA-R61 ", 1)[1].split("\nQA-R62 ", 1)[0]
        for needle in ("Signed-off-by", "MIT", "no CLA", "MPL-2.0"):
            self.assertIn(needle, qa_r61)
        self.assertNotIn("open for Pa", qa_r61)

    def test_the_engine_requirements_state_mpl_2(self):
        """ENG-R109 and the engine licence rows of the open-decision lists follow the amendment of 2026-11-15."""
        engine = (REPO / "spec" / "01-engine.md").read_text(encoding="utf-8")
        overview = (REPO / "spec" / "00-overview.md").read_text(encoding="utf-8")
        rows = {
            "ENG-R109": next(line for line in engine.splitlines() if line.startswith("- **ENG-R109**")),
            "ENG Q1": next(line for line in engine.splitlines() if line.startswith("| Q1 |")),
            "engine intent": next(line for line in engine.splitlines() if line.startswith("| Engine licence intent")),
            "00 row 3": next(line for line in overview.splitlines() if line.startswith("| 3 | Engine licence")),
        }
        for name, line in rows.items():
            with self.subTest(row=name):
                self.assertIn("MPL-2.0", line)
                self.assertNotIn("SHOULD be MIT", line)
                self.assertNotIn("MIT stays", line)

    def test_contributing_states_dco_and_inbound_mit_without_a_cla(self):
        text = " ".join((REPO / "CONTRIBUTING.md").read_text(encoding="utf-8").split())
        for needle in ("Signed-off-by", "Developer Certificate of Origin", "https://developercertificate.org",
                       "GPL-3.0-or-later", "also licensed to the project under the MIT licence",
                       "A contribution to an MPL-2.0 part is licensed under MPL-2.0", "MPL-2.0 (SPDX `MPL-2.0`)",
                       "No contributor licence agreement", "ADR 0006", "scripts/check-dco.sh",
                       "A pull request with an unsigned commit is not merged",
                       "Permission is hereby granted, free of charge"):
            with self.subTest(needle=needle):
                self.assertIn(needle, text)
        self.assertNotIn("not accepted until", text)
        # The MIT text of the inbound grant is in CONTRIBUTING.md itself: no LICENSE file of the repository is MIT.
        self.assertNotIn("the text of [Packages/VietnameseEngine/LICENSE]", text)
        # The merge rule must not depend on the CI scope: the dco job of ci.yml checked only the engine paths when
        # ADR 0006 was written, so CONTRIBUTING.md states the rule, not what CI happens to check.
        self.assertNotIn("checks every commit of a pull request from a fork", text)

    def test_pull_request_template_asks_for_the_sign_off_and_the_inbound_licence(self):
        text = (REPO / ".github" / "pull_request_template.md").read_text(encoding="utf-8")
        section = text.split("## Sign-off and licence", 1)[1].split("\n## ", 1)[0]
        self.assertIn("Signed-off-by:", section)
        self.assertIn("MIT", section)
        self.assertIn("MPL-2.0", section)
        self.assertIn("GPL-3.0-or-later", section)
        self.assertNotIn("Not required for non-engine areas", text)
        self.assertIn("`MPL-2.0` in the engine packages", text)

    def test_adr_0006_records_the_decision(self):
        text = " ".join(self.ADR.read_text(encoding="utf-8").split())
        self.assertTrue(text.startswith("# 0006. App licence and the Pro edition"))
        for needle in ("Status: accepted", "GPL-3.0-or-later", "MIT", "Developer Certificate of Origin", "PLT-R108",
                       "compat-rules.json", "injection", "99,000 VND", "after 1.0", "lifetime", "private module",
                       "signature", "offline", "Supersedes", "0401", "withdrawn", "no paid edition",
                       "## Amendment, 15/11/2026: the engine parts are MPL-2.0", "file-level copyleft",
                       "App Store", "Secondary License", "before any release", self.MPL2_SHA256):
            with self.subTest(needle=needle):
                self.assertIn(needle, text)
        amendments = re.findall(r"^## Amendment, .+$", self.ADR.read_text(encoding="utf-8"), re.M)
        self.assertEqual(amendments, ["## Amendment, 15/11/2026: no paid edition",
                                      "## Amendment, 15/11/2026: the engine parts are MPL-2.0"])
        adr_0001 = (REPO / "docs" / "decisions" / "0001-defaults-for-open-decisions.md").read_text(encoding="utf-8")
        status = next(line for line in adr_0001.splitlines() if line.startswith("- Status:"))
        self.assertIn("0005", status)
        self.assertIn("0006", status)
        self.assertIn("superseded", status)

    def test_adr_0006_says_ci_checks_every_external_commit(self):
        # Decision 6 is in force: the dco job of ci.yml checks every path, so no manual stopgap is left in the record.
        decision = " ".join(self.ADR.read_text(encoding="utf-8").split("6. **Supersedes 0401.**", 1)[1]
                            .split("\n## ", 1)[0].split())
        self.assertIn("DCO sign-off on every commit (external pull requests)", decision)
        self.assertNotIn("until then", decision)
        self.assertNotIn("must drop", decision)

    def test_the_dco_check_covers_every_path_by_default(self):
        script = (REPO / "scripts" / "check-dco.sh").read_text(encoding="utf-8")
        self.assertNotIn("paths=(Packages/VietnameseEngine Packages/VietnameseEngineFuzz)", script)
        self.assertIn("ADR 0006", script)

    def test_the_changelog_announces_the_engine_licence(self):
        changed = changelog_group("Changed")
        self.assertIn("The typing engine packages, the word-list pipeline and the reference model are now under the "
                      "Mozilla Public License 2.0 instead of MIT; the app stays GPL-3.0-or-later.", changed)
        self.assertNotIn("the typing engine stays MIT", changed)


class EngineLicenceWordingTests(unittest.TestCase):
    """No document calls the project's own code MIT after the amendment of 2026-11-15 (ADR 0006): the engine
    packages, the data pipeline and the reference model are MPL-2.0. MIT stays right for the inbound grant of every
    contribution, for third-party material (SCOWL's MIT/X11-style notice, Sparkle), for the list of acceptable data
    licences (CLR-R6) and for the licence label of another project in spec/05-clean-room.md. Decision records keep
    their history and are not scanned; spec/03-product.md is owned by the Settings workstream until its licence line
    follows."""

    FILES = ("README.md", "README.vi.md", "CONTRIBUTING.md", "THIRD_PARTY_NOTICES.md", "ARCHITECTURE.md", "SECURITY.md",
             "CHANGELOG.md", ".github/pull_request_template.md", "data/README.md", "data/NOTICES.md",
             "data/licenses/bundled-notices.txt", "data/inputs/tech-always.txt", "data/inputs/tech-code-only.txt",
             "data/inputs/tech-code-capitalized.txt",
             "Packages/VietnameseEngine/README.md", "Packages/VietnameseEngine/CHANGELOG.md",
             "Packages/VietnameseEngine/TRACEABILITY.md", "Packages/VietnameseEngineFuzz/README.md",
             "Packages/VietnameseEngine/Sources/VietnameseEngineData/Resources/NOTICES.txt",
             "Packages/VietnameseEngine/Tests/VietnameseEngineTests/Corpus/prose-sample.txt",
             "spec/reference-model/README.md")
    ALLOWED = re.compile(
        # The inbound grant of every contribution, and the MIT text it uses (CONTRIBUTING.md section 3).
        r"to the project under (the )?MIT|cho dự án theo giấy phép MIT|inbound MIT|MIT grant|under MIT terms|"
        r"MIT licence text of the inbound grant|^MIT License$|"
        # Third-party material and the licences CLR-R6 accepts for third-party data.
        r"MIT/X11|MIT-CMU|\(MIT, BSD, Apache-2\.0|Licence: MIT, with additional licences for code bundled inside "
        r"Sparkle|under an MIT label|"
        # The question as first asked, and the history of the change itself.
        r"Engine licence: MIT or Apache-2\.0|first version said MIT|instead of MIT")

    def scanned(self) -> list[Path]:
        paths = [REPO / rel for rel in self.FILES]
        paths += sorted((REPO / "docs").rglob("*.md"))
        paths += sorted(path for path in (REPO / "spec").glob("*.md") if path.name != "03-product.md")
        return [path for path in paths if "decisions" not in path.relative_to(REPO).parts]

    def test_no_document_calls_the_project_code_mit(self):
        offenders = []
        for path in self.scanned():
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                if re.search(r"\bMIT\b", line) and not self.ALLOWED.search(line):
                    offenders.append(f"{path.relative_to(REPO)}:{number}: {line.strip()[:120]}")
        self.assertEqual(offenders, [], "the engine parts are MPL-2.0 (ADR 0006 amendment of 2026-11-15)")


class DevelopmentWordingTests(unittest.TestCase):
    """The documents state processes, not the tools the project is written with (decision of the product owner,
    15/11/2026, decision 0005 "Decisions of 15/11/2026"). Kept on purpose: CLAUDE.md and AGENTS.md and the
    sentences that cite them as the home of a rule, the acceptance of AI-assisted contributions (QA-R64), the
    clean-room evidence of spec/05-clean-room.md and docs/provenance/ (not scanned), Claude Code as a terminal app
    users type in (and the CLI agents of the terminal rules), and the technical senses of "agent" (user agent, guest
    agent, launch agents, SSH agent).

    docs/architecture/contracts.md is scanned as a whole, including the code blocks that
    docs/architecture/tools/sync_contracts.py copies from the sources of AppCore, the App, TestHost and SpikeIMK, so a
    comment there that names the development tools fails this test too: reword it in the source file, then run
    sync_contracts.py."""

    PATTERN = re.compile(r"\bAI\b|\bLLMs?\b|\b[Aa]gents?\b|Claude|Anthropic")
    # A match is kept only when one of these phrases covers it, so a line that also cites CLAUDE.md is still checked.
    ALLOWED = re.compile(
        r"Claude Code|AI-assisted|AI assistan|AI answers|AI attribution|AI rewriting|AI coding tools|"
        r"AI session that worked on this repository|agent instructions|CLI agents|"
        r"user agent|guest agent|launch agents|no agent,", re.I)

    @staticmethod
    def scanned() -> list[Path]:
        paths = [REPO / rel for rel in ("ARCHITECTURE.md", "CONTRIBUTING.md", "README.md", "README.vi.md",
                                        "data/README.md")]
        paths += sorted(path for path in (REPO / "docs").rglob("*.md") if "provenance" not in path.parts)
        paths += sorted(path for path in (REPO / "spec").glob("*.md") if path.name != "05-clean-room.md")
        return paths

    def offenders(self, named_texts) -> list[str]:
        found = []
        for name, text in named_texts:
            for number, line in enumerate(text.splitlines(), 1):
                kept = [allowed.span() for allowed in self.ALLOWED.finditer(line)]
                for match in self.PATTERN.finditer(line):
                    if not any(start <= match.start() and match.end() <= end for start, end in kept):
                        found.append(f"{name}:{number}: {line.strip()[:120]}")
                        break
        return found

    def test_no_document_says_the_project_is_built_by_agents(self):
        texts = [(path.relative_to(REPO), path.read_text(encoding="utf-8")) for path in self.scanned()]
        self.assertEqual(self.offenders(texts), [])

    def test_the_guard_catches_the_wording_it_replaced(self):
        old = ("The word AI on its own.\n"
               "Agents, plural, at the start of a line.\n"
               "An agent next to a cited file (CLAUDE.md \"Commands\").\n")
        self.assertEqual(len(self.offenders([("old", old)])), 3)
        kept = ("Agent instructions are in [CLAUDE.md](CLAUDE.md) and [AGENTS.md](AGENTS.md).\n"
                "AI-assisted contributions are welcome under exactly the same rules.\n"
                "TUIs (Claude Code, Kiro CLI) lost letters; the tart guest agent starts the harness.\n")
        self.assertEqual(self.offenders([("kept", kept)]), [])

    def test_decision_records_quote_no_chat_message(self):
        """Decision records keep each decision, its date and its evidence, but state what the product owner asked or
        decided in neutral English; Vietnamese stays only as product copy, test examples or quoted legal text."""
        decisions = sorted((REPO / "docs" / "decisions").glob("*.md"))
        chat = re.compile(r"\(Pa: \"|Pa: \"|asked by Pa: |, verbatim\)|\b(con|pa) (có thể|nghĩ|xài)\b|"
                          r"được không\?|hông bao nhiêu|nhớ behavior")
        found = [f"{path.name}:{number}" for path in decisions
                 for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1) if chat.search(line)]
        self.assertEqual(found, [])


if __name__ == "__main__":
    unittest.main(verbosity=1)
