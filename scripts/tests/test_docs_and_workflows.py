# SPDX-License-Identifier: GPL-3.0-or-later
"""Self-tests that keep the decision records, notices and CI workflows in step with the code they describe.
Run: python3 -I scripts/tests/test_docs_and_workflows.py"""
from __future__ import annotations

import hashlib
import html
import json
import plistlib
import re
import shutil
import sys
import tempfile
import unicodedata
import unittest
from pathlib import Path

sys.dont_write_bytecode = True  # keep scripts/tests free of __pycache__
sys.path.insert(0, str(Path(__file__).resolve().parent))

import swift_source  # noqa: E402
from support import REPO, py, run  # noqa: E402


class Adr0501Tests(unittest.TestCase):
    """ADR 0501 names every key the app writes into the diagnostics block (QA-R44, PLT-R1202)."""

    ADR = (REPO / "docs" / "decisions" / "0501-diagnostics-block-format.md").read_text(encoding="utf-8")
    DIAGNOSTICS = REPO / "Packages" / "AppCore" / "Sources" / "Diagnostics"

    @classmethod
    def example_block(cls) -> str:
        return cls.ADR.split("````text\n", 1)[1].split("\n````", 1)[0]

    def emitted(self) -> tuple[set[str], set[str]]:
        """Literal keys and key-family prefixes (`"latency." + name`) written by the Swift renderer."""
        report = (self.DIAGNOSTICS / "Report.swift").read_text(encoding="utf-8")
        enum = report.split("public enum DiagnosticsBlockKey", 1)[1].split("\n}", 1)[0]
        keys = set(re.findall(r'case \w+ = "([a-z][A-Za-z0-9.]*)"', enum))
        prefixes: set[str] = set()
        for name in ("IssueBlock.swift", "IssueBlockFields.swift"):
            source = (self.DIAGNOSTICS / name).read_text(encoding="utf-8")
            keys |= set(re.findall(r'list\.add\(\s*"([a-z][A-Za-z0-9]*(?:\.[A-Za-z0-9]+)+|[a-z][A-Za-z0-9]*)"',
                                   source))
            prefixes |= set(re.findall(r'"([a-z][A-Za-z0-9]*(?:\.[A-Za-z0-9]+)*\.)"\s*\+', source))
        return keys, prefixes

    def test_every_emitted_key_is_in_the_key_reference(self):
        keys, prefixes = self.emitted()
        self.assertGreater(len(keys), 50, "the key scan found too little; did the Swift sources move?")
        self.assertTrue({"latency.", "counters.", "probe.", "health.event."} <= prefixes, prefixes)
        reference = self.ADR.split("### Key reference (v1)", 1)[1].split("### Symptom mapping", 1)[0]
        undocumented = sorted(k for k in keys if f"`{k}`" not in reference)
        self.assertEqual(undocumented, [], "document these keys in ADR 0501")
        families = sorted(p for p in prefixes if f"`{p}" not in reference)
        self.assertEqual(families, [], "document these key families in ADR 0501")

    def test_example_shows_every_always_present_key(self):
        keys, _ = self.emitted()
        lines = self.example_block().splitlines()[2:-1]  # inside the fence, after the header
        example_keys = [line.split(":", 1)[0] for line in lines]
        self.assertEqual(len(example_keys), len(set(example_keys)), "a key appears twice in the example")
        missing = sorted(k for k in keys if k not in example_keys and not k.startswith("probe."))
        self.assertEqual(missing, [], "add these keys to the ADR 0501 example")

    def renderer_symptoms(self) -> dict[str, str]:
        """`DiagnosticsReport.Symptom` case -> `report.symptom` chip, as `BlockFields.blockSymptom` maps them."""
        source = (self.DIAGNOSTICS / "IssueBlockFields.swift").read_text(encoding="utf-8")
        body = source.split("static func blockSymptom", 1)[1].split("\n    }", 1)[0]
        mapping = {}
        for cases, chip in re.findall(r"case ([^:]+): \"(\w+)\"", body):
            for case in re.findall(r"\.(\w+)", cases):
                mapping[case] = chip
        return mapping

    def test_symptom_mapping_matches_the_renderer(self):
        mapping = self.renderer_symptoms()
        self.assertEqual(mapping["lettersOutOfOrder"], "other")
        self.assertEqual(mapping["nothingTyped"], "cannotType")
        table = self.ADR.split("### Symptom mapping", 1)[1]
        documented = dict(re.findall(r"^\| `(\w+)` \| `(\w+)` \|$", table, re.MULTILINE))
        self.assertEqual(documented, mapping)

    def test_example_lists_the_keys_in_the_order_the_app_writes_them(self):
        # ADR 0501 rule 6: the order of the example is normative, so a reordered renderer must fail here.
        source = {name: (self.DIAGNOSTICS / name).read_text(encoding="utf-8")
                  for name in ("Report.swift", "IssueBlock.swift", "IssueBlockFields.swift")}
        expected = swift_source.always_present_keys(
            source["Report.swift"], source["IssueBlock.swift"], source["IssueBlockFields.swift"])
        self.assertGreater(len(expected), 80, "the order scan found too little; did the Swift sources move?")
        lines = self.example_block().splitlines()[2:-1]  # inside the fence, after the header
        example = [line.split(":", 1)[0] for line in lines]
        events = [key for key in example if re.fullmatch(r"health\.event\.\d\d", key)]
        self.assertEqual([key for key in example if key not in events], expected)
        self.assertEqual(events, [f"health.event.{number:02d}" for number in range(1, len(events) + 1)])
        self.assertEqual(example[len(example) - len(events):], events, "health.event.NN lines come last")
        self.assertIn(f"health.events: {len(events)}", lines)

    # key in the reference table -> (source file, enum, enclosing type, `;`-separated part of the value cell)
    VALUE_SETS = {
        "report.symptomDetail": ("Diagnostics/Report.swift", "Symptom", None, None),
        "app.channel": ("AppModel/Vocabulary.swift", "UpdateChannel", None, None),
        "input.method": ("AppModel/Vocabulary.swift", "TypingMethod", None, None),
        "input.sourceType": ("Diagnostics/Report.swift", "InputSourceKindCode", None, None),
        "permission.accessibility": ("AppModel/Vocabulary.swift", "PermissionState", None, None),
        "permission.health": ("Diagnostics/Report.swift", "PermissionHealthCode", None, None),
        "secureInput.holderKind": ("AppModel/HostState.swift", "Kind", "SecureInputHolder", None),
        "focus.engine": ("AppModel/Vocabulary.swift", "EngineFingerprint", None, None),
        "focus.ax": ("AppModel/Vocabulary.swift", "AXAvailability", None, None),
        "rule.source": ("AppModel/Vocabulary.swift", "DecisionSource", None, None),
        "rule.userOverrideOmitted": ("Diagnostics/Report.swift", "OmittedMatchField", None, None),
        "settings.toneStyle": ("AppModel/Vocabulary.swift", "TonePlacement", None, None),
        "settings.interfaceLanguage": ("AppModel/Vocabulary.swift", "InterfaceLanguage", None, None),
        "settings.updateChannel": ("AppModel/Vocabulary.swift", "UpdateChannel", None, None),
        "appMode.rule": ("AppModel/Vocabulary.swift", "PerAppRule", None, 1),
        "appMode.remembered": ("AppModel/Vocabulary.swift", "TypingMode", None, 2),
    }

    def reference_row(self, key: str) -> list[str]:
        reference = self.ADR.split("### Key reference (v1)", 1)[1].split("### Symptom mapping", 1)[0]
        for line in reference.splitlines():
            cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
            if line.startswith("| ") and f"`{key}`" in cells[0]:
                return cells
        self.fail(f"no key reference row for {key}")

    @staticmethod
    def literals(cell: str) -> set[str]:
        return {value for value in re.findall(r"`([^`]+)`", cell) if "<" not in value}

    def test_key_reference_value_sets_match_the_swift_enums(self):
        # ADR 0501 rule 4: a new enum case changes a v1 value set, so it must reach this record first.
        sources = REPO / "Packages" / "AppCore" / "Sources"
        for key, (path, enum, inside, part) in self.VALUE_SETS.items():
            with self.subTest(key=key, enum=enum):
                values = swift_source.enum_raw_values((sources / path).read_text(encoding="utf-8"), enum, inside)
                cell = self.reference_row(key)[1]
                self.assertEqual(self.literals(cell.split(";")[part] if part is not None else cell), set(values))
        with self.subTest(key="report.symptom"):
            self.assertEqual(self.literals(self.reference_row("report.symptom")[1]),
                             set(self.renderer_symptoms().values()))
        with self.subTest(key="probe.<profile>"):
            report = (self.DIAGNOSTICS / "Report.swift").read_text(encoding="utf-8")
            profiles = swift_source.enum_raw_values(report, "Profile", "LatencyProbeResult")
            self.assertEqual(self.literals(self.reference_row("probe.<profile>.samples")[2]), set(profiles))

    def labels(self, body: str) -> list:
        result = py("parse-diagnostics.py", "--json", env={"ISSUE_BODY": body})
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)["labels"]

    def test_example_with_every_v1_key_gets_the_same_labels(self):
        # ADR 0501 rule 4: the keys added after wave 1 are ignored by parse-diagnostics.py, the labels stay the same.
        example = self.example_block().replace("{{app-slug}}", "testapp")
        self.assertIn("report.symptomDetail: duplicatedLetters", example)
        self.assertEqual(self.labels(example),
                         ["app:com.google.Chrome", "macos:27", "arch:arm64", "method:telex"])


class NoticesTests(unittest.TestCase):
    """THIRD_PARTY_NOTICES.md and docs/provenance record every dependency, data file and asset (CLR-R6, CLR-R7,
    QA-R66)."""

    NOTICES = (REPO / "THIRD_PARTY_NOTICES.md").read_text(encoding="utf-8")
    PROVENANCE = (REPO / "docs" / "provenance" / "README.md").read_text(encoding="utf-8")
    CATALOG = REPO / "App" / "Resources" / "Assets.xcassets"

    @classmethod
    def section(cls, number: int) -> str:
        return cls.NOTICES.split(f"\n## {number}. ", 1)[1].split("\n## ", 1)[0]

    def test_every_catalog_image_is_recorded_with_its_source(self):
        image_sets = sorted(path for path in self.CATALOG.glob("*.imageset"))
        self.assertGreaterEqual(len(image_sets), 8)
        assets = self.section(4)
        for image_set in image_sets:
            with self.subTest(asset=image_set.name):
                self.assertIn(image_set.name.removesuffix(".imageset"), assets)
                self.assertIn(image_set.name.removesuffix(".imageset"), self.PROVENANCE)
                for svg in image_set.glob("*.svg"):
                    header = svg.read_text(encoding="utf-8")[:600]
                    self.assertIn("Source:", header, f"{svg} needs a source comment (CLR-R7)")
                    self.assertIn("CLR-R7", header)

    def test_status_glyph_code_is_recorded_as_original_artwork(self):
        glyph = "App/Sources/Shell/StatusGlyph.swift"
        self.assertIn("CLR-R7", (REPO / glyph).read_text(encoding="utf-8")[:600])
        self.assertIn(f"`{glyph}`", self.section(4))
        self.assertIn(f"`{glyph}`", self.PROVENANCE)

    def test_sparkle_pin_is_the_same_everywhere(self):
        resolved = json.loads((REPO / "Config" / "Package.resolved").read_text(encoding="utf-8"))
        pin = next(p for p in resolved["pins"] if p["identity"] == "sparkle")["state"]
        project = (REPO / "project.yml").read_text(encoding="utf-8")
        publish = (REPO / "scripts" / "publish-release").read_text(encoding="utf-8")
        self.assertIn(f"exactVersion: {pin['version']}", project)
        self.assertIn(f'SPARKLE_VERSION="{pin["version"]}"', publish)
        self.assertIn(f"### Sparkle {pin['version']}\n", self.NOTICES)
        self.assertIn(f"Version: **{pin['version']}**", self.NOTICES)
        self.assertIn(f"revision `{pin['revision']}`", self.NOTICES)
        self.assertEqual(re.findall(r"### Sparkle ([0-9.]+)", self.NOTICES), [pin["version"]])

    def test_every_shipped_data_file_is_covered_by_the_data_notices(self):
        data = self.section(3)
        self.assertIn("[`data/NOTICES.md`](data/NOTICES.md)", data)
        self.assertTrue((REPO / "data" / "NOTICES.md").is_file())
        resources = REPO / "Packages" / "VietnameseEngine" / "Sources" / "VietnameseEngineData" / "Resources"
        shipped = sorted(p.name for p in resources.iterdir() if p.name not in {"README.txt", "manifest.json"})
        self.assertIn("NOTICES.txt", shipped)
        missing = [name for name in shipped if f"`{name}`" not in data]
        self.assertEqual(missing, [], "list these bundled data files in THIRD_PARTY_NOTICES.md section 3")


    def test_acknowledgements_claim_matches_the_app(self):
        # ENG-R811: the SCOWL notice must reach users. The paragraph says the app shows NOTICES.txt exactly when App
        # code reads it (`Resources.bundledNotices`, called or passed as a function).
        sources = (REPO / "App" / "Sources").rglob("*.swift")
        shown = any("Resources.bundledNotices" in path.read_text(encoding="utf-8") for path in sources)
        data = " ".join(self.section(3).split())
        if shown:
            self.assertNotIn("not yet implemented", data, "App code shows NOTICES.txt now; update section 3")
            self.assertNotIn("VERIFY", data, "the About & Support pane shows NOTICES.txt; close the VERIFY")
            self.assertIn("About & Support", data)
            self.assertIn("Resources.bundledNotices()", data)
        else:
            self.assertIn("VERIFY", data)
            self.assertIn("not yet implemented", data)
            self.assertIn("ships only as a `VietnameseEngineData` resource", data)


class FrontDoorBrandTests(unittest.TestCase):
    """ADR 0400 decision 1, amended 2026-11-13: the files GitHub or the DMG shows as they are (the front door) write the
    literal display name, slug and site host of scripts/brand.env, because nothing renders them; docs/ (outside the
    decision records) keeps {{AppName}} and {{app-slug}}. `scripts/check-docs.py brand` enforces both directions and
    scripts/rename-app.sh rewrites the literal front door on a rename."""

    BRAND_ENV = ('APP_DISPLAY_NAME="Test App"\nAPP_SLUG="testapp"\nAPP_BUNDLE_ID_RELEASE="vn.example.testapp"\n'
                 'APP_BUNDLE_ID_DEV="vn.example.testapp.dev"\nAPP_SITE_HOST="testapp.example.vn"\n')
    LITERAL = "Install Test App from https://testapp.example.vn (cask testapp, bundle vn.example.testapp).\n"

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.write(self.root, "scripts/brand.env", self.BRAND_ENV)

    def tearDown(self):
        self._tmp.cleanup()

    @staticmethod
    def write(root: Path, rel: str, text: str) -> None:
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    @staticmethod
    def brand(root: Path):
        return py("check-docs.py", "brand", "--root", str(root))

    @staticmethod
    def repo_brand() -> dict[str, str]:
        env = (REPO / "scripts" / "brand.env").read_text(encoding="utf-8")
        return dict(re.findall(r'^(APP_[A-Z_]+)="([^"]*)"$', env, re.M))

    def test_docs_outside_the_decision_records_still_reject_literal_values(self):
        self.write(self.root, "docs/runbooks/a.md", "Open Test App at https://testapp.example.vn.\n")
        self.write(self.root, "docs/support/b.md", "Run `testapp-notary`.\n")
        self.write(self.root, "docs/decisions/0001-x.md", "Test App was the temporary name.\n")
        result = self.brand(self.root)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("docs/runbooks/a.md:1: literal site host 'testapp.example.vn'", result.stderr)
        self.assertIn("docs/support/b.md:1: literal slug ({{app-slug}}) 'testapp'", result.stderr)
        self.assertNotIn("docs/decisions/", result.stderr)

    def test_front_door_files_reject_every_placeholder(self):
        cases = {
            "README.md": ("# {{AppName}}\n", "{{AppName}}"),
            "README.vi.md": ("Website: `https://{{app-slug}}.kal.vn`\n", "{{app-slug}}"),
            "CONTRIBUTING.md": ("Contributing to {{AppName}}\n", "{{AppName}}"),
            "SECURITY.md": ("{{ AppName }} handles keystrokes.\n", "{{ AppName }}"),
            "CODE_OF_CONDUCT.md": ("Write to the {{app-slug}} mailbox.\n", "{{app-slug}}"),
            "THIRD_PARTY_NOTICES.md": ("Ships with the app on {{site-host}}.\n", "{{site-host}}"),
            "ARCHITECTURE.md": ("Settings live in {{storage-folder}}.\n", "{{storage-folder}}"),
            "SUPPORT.md": ("Ask about {{AppName}}.\n", "{{AppName}}"),
            ".github/pull_request_template.md": ("- [ ] No literal {{bundle-id}}.\n", "{{bundle-id}}"),
            ".github/ISSUE_TEMPLATE/bug.yml": ("name: Bug report for {{AppName}}\n", "{{AppName}}"),
            # Linked from README.md, CONTRIBUTING.md and the compatibility form; GitHub shows it as it is.
            "compat/SCRIPT.md": ("| {{AppName}} version and build, channel |\n", "{{AppName}}"),
            # GitHub shows it as it is; the site build and the appcast notes take it verbatim (2026-11-14).
            "CHANGELOG.md": ("All notable changes to {{AppName}}.\n", "{{AppName}}"),
        }
        for rel, (text, _) in cases.items():
            self.write(self.root, rel, text)
        result = self.brand(self.root)
        self.assertEqual(result.returncode, 1, result.stderr)
        for rel, (_, token) in cases.items():
            with self.subTest(file=rel):
                self.assertIn(f"{rel}:1: placeholder {token} is shown as it is", result.stderr)

    def test_front_door_files_accept_the_literal_values(self):
        for rel in ("README.md", "README.vi.md", "CONTRIBUTING.md", "SECURITY.md", "CODE_OF_CONDUCT.md",
                    "THIRD_PARTY_NOTICES.md", "ARCHITECTURE.md", "CLAUDE.md", ".github/pull_request_template.md",
                    ".github/ISSUE_TEMPLATE/bug.yml", "compat/SCRIPT.md", "CHANGELOG.md"):
            self.write(self.root, rel, self.LITERAL)
        self.write(self.root, "docs/runbooks/a.md", "Install {{AppName}} from https://{{app-slug}}.kal.vn.\n")
        result = self.brand(self.root)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_the_repository_front_door_names_the_product(self):
        brand = self.repo_brand()
        name, slug, host = brand["APP_DISPLAY_NAME"], brand["APP_SLUG"], brand["APP_SITE_HOST"]
        for rel in ("README.md", "README.vi.md"):
            with self.subTest(readme=rel):
                text = (REPO / rel).read_text(encoding="utf-8")
                self.assertEqual(text.splitlines()[0], f"# {name}")
                self.assertIn(f"`https://{host}`", text)
                # The tap owner is still a VERIFY marker; only the cask name is the brand's.
                self.assertRegex(text, r"[\w.-]+/tap/" + re.escape(slug) + "`")
        notices = (REPO / "THIRD_PARTY_NOTICES.md").read_text(encoding="utf-8")
        self.assertIn(f"ships with {name} or its website", notices, "the DMG copies this file as it is")
        for form in ("bug.yml", "compatibility.yml"):
            with self.subTest(form=form):
                text = (REPO / ".github" / "ISSUE_TEMPLATE" / form).read_text(encoding="utf-8")
                self.assertIn(f"`{slug}-diagnostics v1`", text)
                self.assertNotIn("<slug>", text)

    def test_both_readmes_state_the_current_facts(self):
        """The name is final (2026-11-13), the floor is macOS 12 (ADR 0315), the licences are decided (ADR 0006)."""
        for rel, current, stale in (
            ("README.md", ("macOS 12 Monterey or later", "Apple silicon or Intel", "GNU General Public License",
                           "Mozilla Public License 2.0 (MPL-2.0)", "Config/Brand.xcconfig", "scripts/brand.env",
                           "0315-minimum-macos-12.md"),
             ("name is temporary", "not been chosen", "macOS 15", "macOS 14", "pending confirmation",
              "MIT-licensed")),
            ("README.vi.md", ("macOS 12 Monterey trở lên", "chip Apple hoặc Intel", "GNU GPL",
                              "Giấy phép Công cộng Mozilla 2.0 (MPL-2.0)",
                              "Config/Brand.xcconfig", "scripts/brand.env", "0315-minimum-macos-12.md"),
             ("tên tạm", "chưa được chọn", "macOS 15", "macOS 14", "chờ người phát triển")),
        ):
            text = " ".join((REPO / rel).read_text(encoding="utf-8").split())
            for needle in current:
                with self.subTest(file=rel, current=needle):
                    self.assertIn(needle, text)
            for needle in stale:
                with self.subTest(file=rel, stale=needle):
                    self.assertNotIn(needle, text)
        architecture = (REPO / "ARCHITECTURE.md").read_text(encoding="utf-8")
        self.assertNotIn("name is temporary", architecture)

    def test_the_brand_sources_no_longer_call_the_name_temporary(self):
        """README.md points readers at these files; their comments must match ADR 0005 (the name is final)."""
        for rel in ("Config/Brand.xcconfig", "scripts/brand.env", "scripts/rename-app.sh"):
            with self.subTest(file=rel):
                self.assertFalse("name is temporary" in (REPO / rel).read_text(encoding="utf-8").lower(), rel)
        header = (REPO / "scripts" / "rename-app.sh").read_text(encoding="utf-8").split("\nset ", 1)[0]
        self.assertIn("front door", header, "step 3 must say the front door carries literal values")

    def test_a_rename_rewrites_the_literal_front_door(self):
        repo = self.root / "repo"
        # Only what the two scripts need: copying all of scripts/ is slow on some volumes.
        shutil.copytree(REPO / "scripts" / "lib", repo / "scripts" / "lib",
                        ignore=shutil.ignore_patterns("__pycache__"))
        for script in ("rename-app.sh", "check-docs.py"):
            shutil.copy2(REPO / "scripts" / script, repo / "scripts" / script)
        self.write(repo, "scripts/brand.env", self.BRAND_ENV)
        self.write(repo, "Config/Brand.xcconfig",
                   "APP_DISPLAY_NAME = Test App\nAPP_SLUG = testapp\nAPP_BUNDLE_ID_RELEASE = vn.example.testapp\n"
                   "APP_BUNDLE_ID_DEV = vn.example.testapp.dev\nAPP_SITE_HOST = testapp.example.vn\n")
        self.write(repo, "README.md",
                   "# Test App\n\nWebsite: `https://testapp.example.vn`, cask `OWNER/tap/testapp`.\n")
        self.write(repo, "THIRD_PARTY_NOTICES.md",
                   "Everything that ships with Test App or its website (testapp.example.vn).\n")
        run("git", "-C", str(repo), "init", "-q", check=True)
        run("git", "-C", str(repo), "add", "-A", check=True)
        result = run(str(repo / "scripts" / "rename-app.sh"), "Xuôi", "xuoi", "--bundle-prefix", "vn.example",
                     "--domain", "example.vn", "--apply")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((repo / "README.md").read_text(encoding="utf-8"),
                         "# Xuôi\n\nWebsite: `https://xuoi.example.vn`, cask `OWNER/tap/xuoi`.\n")
        self.assertEqual((repo / "THIRD_PARTY_NOTICES.md").read_text(encoding="utf-8"),
                         "Everything that ships with Xuôi or its website (xuoi.example.vn).\n")
        after = self.brand(repo)
        self.assertEqual(after.returncode, 0, after.stderr)


class WorkflowCoverageTests(unittest.TestCase):
    """The CI gates the engine, data and platform tracks rely on stay in the workflows (QA-R2, QA-R5, QA-R8,
    QA-R14, ENG-R810, ENG-R1201, PLT-R822; docs/decisions/0506-ci-coverage-after-the-engine-merge.md)."""

    WORKFLOWS = REPO / ".github" / "workflows"

    @classmethod
    def job(cls, workflow: str, job_id: str) -> str:
        text = (cls.WORKFLOWS / workflow).read_text(encoding="utf-8")
        body = text.split(f"\n  {job_id}:\n", 1)[1]
        end = re.search(r"\n  [a-z][a-z0-9-]*:\n", body)  # the next job at the same indentation
        return body[: end.start()] if end else body

    def assert_runs(self, workflow: str, job_id: str, *commands: str) -> None:
        body = self.job(workflow, job_id)
        for command in commands:
            with self.subTest(workflow=workflow, job=job_id, command=command):
                self.assertIn(command, body)

    def test_linux_engine_job_checks_generators_traceability_build_tests_and_fuzzing(self):
        self.assertIn("image: swift:6.4.2-noble@sha256:", self.job("ci.yml", "engine-linux"))
        self.assert_runs(
            "ci.yml", "engine-linux",
            'python3 -I "$ENGINE/Scripts/generate-letter-table.py" --check',
            'python3 -I "$ENGINE/Scripts/extract-spec-examples.py" --check',
            'python3 -I "$ENGINE/Scripts/generate-layout-corpus.py" --check',
            'python3 -I "$ENGINE/Scripts/check-traceability.py"',
            'swift build --package-path "$ENGINE"',
            'swift test --package-path "$ENGINE"',
            "scripts/fuzz.sh --seconds 60 --sanitizers fuzzer,address --out .build/fuzz-out --require")

    def test_pinned_data_inputs_and_bundled_data_are_checked(self):
        self.assert_runs(
            "ci.yml", "macos-tests",
            "(cd data && shasum -a 256 -c inputs/MANIFEST.sha256)",
            'swift run --package-path "$ENGINE" lexicon-builder check')

    def test_coverage_gates_and_compat_lint(self):
        self.assert_runs(
            "ci.yml", "macos-tests",
            'scripts/coverage.sh --package "$ENGINE" --min 95',
            'python3 -I "$ENGINE/Scripts/coverage.py" "$(swift test --package-path "$ENGINE" --show-codecov-path)"',
            'scripts/coverage.sh --package "$APPCORE" --min 80',
            'swift run --package-path "$APPCORE" compat-lint')

    def test_benchmarks_run_on_a_fixed_runner_class_and_keep_their_json(self):
        body = self.job("ci.yml", "benchmarks")
        self.assertIn("runs-on: xcode-27", body)
        self.assert_runs(
            "ci.yml", "benchmarks",
            '"$ENGINE/Scripts/benchmark.sh" "$PWD/.build/bench/engine.json"',
            'PIPELINE_BENCH_OUTPUT="$PWD/.build/bench/pipeline/run-$run.json"',
            'swift test --package-path "$APPCORE" -c release --filter PipelineBenchmark',
            "--threshold 25",
            "--baseline Packages/AppCore/Benchmarks/pipeline-baseline.json",
            "path: .build/bench/")
        self.assertNotIn("bench-compare.sh --output", self.job("ci.yml", "macos-tests"))

    def test_macos_app_job_runs_the_updater_tests_after_a_pinned_build(self):
        """QA-R3, QA-R22: the Sparkle wrapper tests (UpdaterTests: PLT-R1105 relaunch gate, PLT-R104 and the
        built bundle's SU* keys) run on every pull request and in release.yml, which reuses ci.yml. Package
        versions stay pinned to Config/Package.resolved (PLT-R910, ADR 0301)."""
        body = self.job("ci.yml", "macos-app")
        build = body.index("ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY='' build")
        test = body.index("test -only-testing:UpdaterTests")
        self.assertLess(build, test)
        commands = "\n".join(line for line in body.splitlines() if not line.lstrip().startswith("#"))
        self.assertEqual(commands.count("-disableAutomaticPackageResolution"), 2, "build and test steps")
        self.assertIn("-destination 'platform=macOS'", body)
        self.assertIn("-resultBundlePath .build/UpdaterTests.xcresult", body)
        self.assertRegex(body, r"if: failure\(\)[^\n]*\n(?:[^\n]*\n){0,3}\s*uses: actions/upload-artifact@")
        self.assertIn("path: .build/UpdaterTests.xcresult", body)
        run_tests = (REPO / "scripts" / "run-tests.sh").read_text(encoding="utf-8")
        self.assertIn("test -only-testing:UpdaterTests", run_tests)

    def test_coverage_drop_gate_fails_closed_when_the_baseline_download_fails(self):
        """QA-R2: the 1-point drop gate may skip only when main has no green run yet, never on a failed
        download or an expired artifact."""
        body = self.job("ci.yml", "macos-tests")
        self.assertIn("id: baseline", body)
        self.assertIn('echo "found=true" >> "$GITHUB_OUTPUT"', body)
        self.assertIn('echo "found=false" >> "$GITHUB_OUTPUT"', body)
        self.assertEqual(
            body.count("REQUIRE_BASELINE: ${{ github.event_name == 'pull_request' && "
                       "steps.baseline.outputs.found != 'false' }}"), 2)
        self.assertEqual(body.count('[[ "$REQUIRE_BASELINE" == true ]] && require=(--require-baseline)'), 2)

    def test_pull_requests_need_a_label_to_change_corpus_or_baselines(self):
        """QA-R6 (corpus-change) and QA-R15 (perf-baseline) are checked again on every label change, in a workflow
        of its own so a label never re-runs or cancels the CI suite."""
        text = (self.WORKFLOWS / "pr-labels.yml").read_text(encoding="utf-8")
        self.assertRegex(text, r"pull_request:\n\s+types: \[opened, synchronize, reopened, labeled, unlabeled\]")
        self.assertNotIn("labeled", (self.WORKFLOWS / "ci.yml").read_text(encoding="utf-8"))
        body = self.job("pr-labels.yml", "labels")
        self.assertIn("if: github.event_name == 'pull_request'", body)
        self.assertIn("LABELS: ${{ join(github.event.pull_request.labels.*.name, ',') }}", body)
        self.assertIn('scripts/check-pr-labels.sh --base "$BASE_SHA" --head "$HEAD_SHA" --labels "$LABELS"', body)

    def test_site_workflow_runs_the_site_tests_and_a_strict_build_for_deployment(self):
        """ADR 0601, ADR 0602, PRD-R74: links, anchors, language attributes and the privacy rules are tested on
        every change; the deployed image (site-image.yml, branch prod) refuses VERIFY markers and placeholder values
        unless SITE_STRICT is false, and a non-strict image is a noindex preview."""
        body = self.job("site.yml", "build")
        self.assertLess(body.index("run: node site/test.mjs"), body.index("node site/build.mjs"))
        self.assertIn("node site/build.mjs --strict", body)
        self.assertIn("STRICT: ${{ vars.SITE_STRICT == 'true' }}", body)
        image = self.job("site-image.yml", "image")
        self.assertIn("SITE_STRICT: ${{ vars.SITE_STRICT == 'false' && 'false' || 'true' }}", image)
        self.assertIn('--build-arg SITE_STRICT="$SITE_STRICT"', image)
        dockerfile = (REPO / "deploy" / "site" / "Dockerfile").read_text(encoding="utf-8")
        self.assertIn("ARG SITE_STRICT=true", dockerfile)
        self.assertIn("ARG SITE_NOINDEX=auto", dockerfile)
        text = (self.WORKFLOWS / "site.yml").read_text(encoding="utf-8")
        for path in ("App/Resources/Localization/**", "Packages/AppCore/Sources/InputHost/Integration/ShellActions.swift",
                     "Packages/AppCore/Sources/SettingsStore/ExportImport.swift"):
            with self.subTest(path=path):
                self.assertEqual(text.count(f'- "{path}"'), 2, "push and pull_request paths")

    def test_nightly_thread_sanitizer_suppresses_only_the_settings_store_executor_report(self):
        """SettingsStore runs on a DispatchSerialQueue executor (PLT-R1003); TSan sees no ordering between its
        jobs on different GCD worker threads and reports a race that cannot happen. The suppression is scoped to
        SettingsStore and passed to the nightly step only."""
        body = self.job("nightly.yml", "sanitizers-macos")
        step = body.split("AppCore tests with ThreadSanitizer", 1)[1].split("- name:", 1)[0]
        match = re.search(r'TSAN_OPTIONS: "suppressions=\$\{\{ github\.workspace \}\}/([^"]+)"', step)
        self.assertIsNotNone(match, "TSAN_OPTIONS with a suppressions file")
        suppressions = REPO / match.group(1)
        lines = [line for line in suppressions.read_text(encoding="utf-8").splitlines()
                 if line.strip() and not line.startswith("#")]
        self.assertEqual(lines, ["race:SettingsStore."])
        self.assertIn('swift test --package-path "$APPCORE" --sanitize=thread', step)

    def test_release_and_nightly_run_the_compatibility_release_lint(self):
        """PLT-R422, PLT-R506, QA-R19: compat-lint's release-gated findings (VERIFY tested dates, unverified manual
        matrix rows, placeholder rules without their 1,000-edit gate) block a release and show up every night."""
        build = self.job("release.yml", "build")
        self.assertLess(build.index("python3 -I scripts/check-rules.py --release"),
                        build.index("run: swift run --package-path Packages/AppCore compat-lint --release"))
        self.assertLess(build.index("compat-lint --release"), build.index("scripts/build-release.sh"),
                        "the gate runs before anything is built or signed")
        nightly = self.job("nightly.yml", "compat-release-lint")
        self.assertIn("runs-on: xcode-27", nightly)
        self.assertIn('run: swift run --package-path "$APPCORE" compat-lint --release', nightly)

    def test_nightly_builds_and_keeps_the_engine_docc_archive(self):
        """QA-R66, ADR 0402 item 3: the engine API documentation archive is built every night and uploaded as the
        artifact engine-api-docc for 30 days, with the command CONTRIBUTING.md documents."""
        body = self.job("nightly.yml", "engine-docc")
        self.assertIn("name: Engine API docs (DocC, QA-R66)", body)
        self.assertIn("runs-on: xcode-27", body)
        self.assertIn("working-directory: Packages/VietnameseEngine", body)
        self.assertIn("xcodebuild docbuild -scheme VietnameseEngine -destination 'generic/platform=macOS' "
                      "-derivedDataPath .build/docc", body)
        self.assertIn("name: engine-api-docc", body)
        self.assertIn("path: Packages/VietnameseEngine/.build/docc/Build/Products/Debug/VietnameseEngine.doccarchive",
                      body)
        self.assertIn("if-no-files-found: error", body)
        self.assertIn("retention-days: 30", body)

    def test_nightly_fuzzes_each_method_for_thirty_minutes(self):
        body = self.job("nightly.yml", "fuzz")
        self.assertIn("image: swift:6.4.2-noble@sha256:", body)
        self.assertIn("method: [telex, vni]", body)
        self.assertIn('--seconds 1800 --sanitizers fuzzer,address,undefined', body)
        self.assertIn('--method "$METHOD" --out ".build/fuzz-out" --require', body)

    def test_nightly_campaign_runs_100_million_events_with_a_date_seed(self):
        body = self.job("nightly.yml", "property")
        self.assertIn('ENGINE_FUZZ_EVENTS: "100000000"', body)
        self.assertIn("ENGINE_FUZZ_SEED: ${{ steps.seed.outputs.seed }}", body)
        self.assertIn('seed="$(date -u +%Y%m%d)"', body)
        self.assertIn('swift test --package-path "$ENGINE" -c release --filter "$ENGINE_PROPERTY_FILTER"', body)
        self.assertRegex(body, r'ENGINE_PROPERTY_FILTER: "[^"]*Fuzz[^"]*"')  # selects FuzzTests

    def test_integration_jobs_build_the_hooks_test_build_first(self):
        """W3-A: every self-hosted job installs the INTEGRATION_HOOKS build of the checked-out commit before the
        harness runs; the push job runs one bench run, the nightly job five (QA-R14, ADR 0502)."""
        for job_id in ("integration", "nightly"):
            body = self.job("integration.yml", job_id)
            with self.subTest(job=job_id):
                build = body.index("scripts/run-integration.sh build --out .build/integration")
                self.assertLess(build, body.index("scripts/run-integration.sh tests --out .build/integration"))
                self.assertNotIn("COMPAT_HARNESS_LIVE", body)  # the opt-in comes from the runner's .env only
        self.assertIn('COMPAT_HARNESS_BENCH_RUNS: "1"', self.job("integration.yml", "integration"))
        self.assertNotIn("COMPAT_HARNESS_BENCH_RUNS", self.job("integration.yml", "nightly"))
        self.assertIn("scripts/run-integration.sh soak --out .build/integration", self.job("integration.yml", "nightly"))

    BUDGET = re.compile(r"# Budget in minutes \([^)]*\): ((?:[a-z]+ \d+ \+ )*[a-z]+ \d+) = (\d+)\.")

    def test_integration_jobs_fit_their_step_budget(self):
        """W3-A review: each self-hosted job states its step budget, the terms add up, and the timeout leaves at
        least 10 % on top, so the nightly five-run bench (QA-R14) is never killed by the job timeout."""
        for job_id in ("integration", "nightly"):
            body = self.job("integration.yml", job_id)
            with self.subTest(job=job_id):
                budget = self.BUDGET.search(body)
                self.assertIsNotNone(budget, "budget comment missing")
                terms = [int(term.split()[1]) for term in budget.group(1).split(" + ")]
                self.assertEqual(sum(terms), int(budget.group(2)))
                timeout = int(re.search(r"^\s*timeout-minutes: (\d+)$", body, re.M).group(1))
                self.assertGreaterEqual(timeout, int(budget.group(2)) * 1.1)
        nightly = self.job("integration.yml", "nightly")
        self.assertIn("soak 498", nightly)  # docs/runbooks/integration-suite.md: about 8.3 hours
        self.assertLess(
            nightly.index("scripts/run-integration.sh bench --out .build/integration"),
            nightly.index("scripts/run-integration.sh soak --out .build/integration"),
            "the bench runs before the soak, so an overrunning soak never loses it")


IMAGE_SUFFIXES = {".svg", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".icns", ".heic", ".tif", ".tiff"}


def tracked_images() -> list[Path]:
    listed = run("git", "-C", str(REPO), "ls-files", check=True).stdout.splitlines()
    return [REPO / rel for rel in listed if Path(rel).suffix.lower() in IMAGE_SUFFIXES]


def asset_key(path: Path) -> str:
    """The name an asset is recorded under: the image set name inside an asset catalog, else the repo path."""
    image_set = next((part for part in path.parts if part.endswith(".imageset")), None)
    return image_set.removesuffix(".imageset") if image_set else path.relative_to(REPO).as_posix()


class AssetRecordTests(unittest.TestCase):
    """Every tracked image, in any asset catalog or on the website, has a source record (CLR-R7, spec/05 section 5
    acceptance: THIRD_PARTY_NOTICES lists every asset with its licence)."""

    NOTICES = (REPO / "THIRD_PARTY_NOTICES.md").read_text(encoding="utf-8")
    PROVENANCE = (REPO / "docs" / "provenance" / "README.md").read_text(encoding="utf-8")

    @classmethod
    def assets_section(cls) -> str:
        return cls.NOTICES.split("\n## 4. ", 1)[1].split("\n## ", 1)[0]

    @classmethod
    def provenance_section(cls) -> str:
        return cls.PROVENANCE.split("\n## 7. ", 1)[1].split("\n## ", 1)[0]

    def test_every_tracked_image_is_recorded_in_both_files(self):
        images = tracked_images()
        self.assertGreaterEqual(len(images), 13, "the image scan found too little; did git ls-files fail?")
        for key in sorted({asset_key(path) for path in images}):
            with self.subTest(asset=key):
                self.assertIn(f"`{key}`", self.assets_section(), "record it in THIRD_PARTY_NOTICES.md section 4")
                self.assertIn(f"`{key}`", self.provenance_section(), "record it in docs/provenance section 7")

    def test_placeholder_images_are_recorded_as_placeholders(self):
        # Every placeholder image was replaced by final artwork on 2026-11-13 (W4-B), so the set may be empty; an
        # image that still calls itself a placeholder must be recorded as one.
        placeholders = sorted({asset_key(p) for p in tracked_images() if "placeholder" in self.header(p).lower()
                               or p.stem == "placeholder"})
        entries = self.assets_section().split("\n### ")[1:]  # one subsection per asset group
        for key in placeholders:
            with self.subTest(asset=key):
                records = [entry for entry in entries if f"`{key}`" in entry]
                self.assertTrue(records and all("placeholder" in entry.lower() for entry in records),
                                f"THIRD_PARTY_NOTICES.md section 4 must call {key} a placeholder")

    # Pa's own artwork as supplied on 2026-11-13 (decision S7, commit 51d7e9e), by SHA-256. These files are the
    # product owner's originals: the project never edits them, so they cannot carry the source comment that every
    # other SVG has. Their record is THIRD_PARTY_NOTICES.md section 4 and docs/provenance section 7. The exemption
    # holds only while a file is byte-identical to the original; an edited copy is project work and needs the comment.
    PA_ORIGINALS = {
        "assets/keyvi_menubar_on_light.svg": "08659e8153c5e8b39c84514e40de56b6cbeb5300ef0f7ac9e265bf1cab01b115",
        "assets/keyvi_menubar_on_dark.svg": "b5633ee09b67ab8b88b1c2ee344f9ea765e2e7859c53014ba8f9c1e300635385",
        "assets/keyvi_menubar_off_light.svg": "3d7151fb9a1af9efc2bbb209f8e90bf8f8cc8065e11f94a7a98178cbf1cfad4d",
        "assets/keyvi_menubar_off_dark.svg": "d03e3d8ce33ac4541161a1533b8dcc4a0f5384200c013332e6c2da2f2e07fbfd",
    }

    @classmethod
    def is_pa_original(cls, rel: str, content: bytes) -> bool:
        digest = cls.PA_ORIGINALS.get(rel)
        return digest is not None and hashlib.sha256(content).hexdigest() == digest

    def test_every_svg_carries_a_source_comment(self):
        for path in (p for p in tracked_images() if p.suffix.lower() == ".svg"):
            if self.is_pa_original(path.relative_to(REPO).as_posix(), path.read_bytes()):
                continue
            with self.subTest(svg=path.relative_to(REPO).as_posix()):
                header = self.header(path)
                self.assertIn("Source:", header, "add a source comment (CLR-R7)")
                self.assertIn("CLR-R7", header)

    def test_pa_originals_are_exempt_only_while_byte_identical(self):
        for rel in self.PA_ORIGINALS:
            with self.subTest(original=rel):
                original = (REPO / rel).read_bytes()
                self.assertTrue(self.is_pa_original(rel, original), f"{rel} changed: add a source comment or restore it")
                self.assertFalse(self.is_pa_original(rel, original + b"\n"), "an edited copy loses the exemption")
                self.assertFalse(self.is_pa_original("site/static/" + Path(rel).name, original),
                                 "a copy elsewhere is project work and needs the comment")

    @staticmethod
    def header(path: Path) -> str:
        return path.read_text(encoding="utf-8", errors="replace")[:600] if path.suffix.lower() == ".svg" else ""


class RunbookReleaseBranchTests(unittest.TestCase):
    """Runbook commands only create release branches that release.yml accepts, and quote build numbers that
    scripts/build-number.sh prints (QA-R25, QA-R26, QA-R38, QA-R39)."""

    RUNBOOKS = sorted((REPO / "docs" / "runbooks").glob("*.md"))

    @classmethod
    def accepted_branch(cls) -> re.Pattern:
        workflow = (REPO / ".github" / "workflows" / "release.yml").read_text(encoding="utf-8")
        pattern = re.search(r"grep -Eq '(\^ \*origin/\(main\|release/[^']+)'", workflow)
        assert pattern, "release.yml no longer checks the tagged commit's branch with grep -Eq"
        return re.compile(pattern.group(1))

    def test_every_release_branch_in_the_runbooks_passes_the_release_gate(self):
        accepted = self.accepted_branch()
        found = 0
        for runbook in self.RUNBOOKS:
            for branch in re.findall(r"(?<![\w./-])(release/[0-9][^\s`'\")]*)", runbook.read_text(encoding="utf-8")):
                found += 1
                with self.subTest(runbook=runbook.name, branch=branch):
                    self.assertRegex(f"  origin/{branch}", accepted,
                                     "release.yml only accepts tags on origin/main or origin/release/x.y")
        self.assertGreater(found, 0, "no concrete release branch found; the rollback example should name one")

    def test_quoted_build_numbers_match_the_script(self):
        quoted = []
        for runbook in self.RUNBOOKS:
            quoted += re.findall(r"`scripts/build-number\.sh (v?[0-9][^`]*)` prints `(\d+)`",
                                 runbook.read_text(encoding="utf-8"))
        self.assertGreater(len(quoted), 0)
        for version, number in quoted:
            with self.subTest(version=version):
                result = run("bash", str(REPO / "scripts" / "build-number.sh"), version)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), number)

    def test_rollback_never_chooses_the_build_number_by_hand(self):
        rollback = (REPO / "docs" / "runbooks" / "rollback.md").read_text(encoding="utf-8")
        self.assertNotRegex(rollback, r"CFBundleVersion\s*=\s*highest")
        self.assertIn("scripts/build-number.sh", rollback)


class ManagedMacsDocTests(unittest.TestCase):
    """IT administrator documentation lists the PPPC services with the code requirement and the macOS 27 note
    (PLT-R760)."""

    DOC = REPO / "docs" / "support" / "managed-macs.md"
    BUNDLE_ID = "vn.kal.{{app-slug}}"
    TEAM_ID = "TEAM_ID"  # the placeholder the doc uses; valid inside the XML example as written

    @classmethod
    def requirement(cls) -> str:
        """The default designated requirement that scripts/verify-release.sh enforces (PLT-R750)."""
        verify = (REPO / "scripts" / "verify-release.sh").read_text(encoding="utf-8")
        template = re.search(r"printf '(identifier \"%s\" and anchor apple generic[^']*)\\n'", verify)
        assert template, "verify-release.sh no longer prints the expected designated requirement"
        return template.group(1).replace("%s", cls.BUNDLE_ID, 1).replace("%s", cls.TEAM_ID, 1)

    def test_doc_names_the_three_services_the_requirement_and_the_macos_27_note(self):
        text = self.DOC.read_text(encoding="utf-8")
        for needle in ("`Accessibility`", "`PostEvent`", "`ListenEvent`", "com.apple.TCC.configuration-profile-policy",
                       "Device Control and Data Access", "Declarative Device Management",
                       "com.apple.configuration.app.settings", "APP_BUNDLE_ID_RELEASE", "designated-requirement.txt",
                       "VERIFY", self.requirement()):
            with self.subTest(needle=needle):
                self.assertIn(needle, text)

    def test_example_profile_is_a_valid_plist_for_exactly_those_services(self):
        text = self.DOC.read_text(encoding="utf-8")
        example = text.split("```xml\n", 1)[1].split("\n```", 1)[0]
        profile = plistlib.loads(example.encode("utf-8"))
        payload = profile["PayloadContent"][0]
        self.assertEqual(payload["PayloadType"], "com.apple.TCC.configuration-profile-policy")
        services = payload["Services"]
        self.assertEqual(set(services), {"Accessibility", "PostEvent", "ListenEvent"})
        expected = self.requirement()
        for name, entries in services.items():
            with self.subTest(service=name):
                self.assertEqual(len(entries), 1)
                entry = entries[0]
                self.assertEqual(entry["Identifier"], self.BUNDLE_ID)
                self.assertEqual(entry["IdentifierType"], "bundleID")
                self.assertEqual(entry["CodeRequirement"], expected)
                self.assertFalse("Allowed" in entry and "Authorization" in entry, "use one of the two keys")
        # Apple's PPPC reference: a profile cannot grant ListenEvent, it can only deny it or let a standard user
        # approve it.
        self.assertEqual(services["ListenEvent"][0]["Authorization"], "AllowStandardUserToSetSystemService")

    def test_traceability_points_plt_r760_at_the_doc(self):
        traceability = (REPO / "docs" / "architecture" / "traceability.md").read_text(encoding="utf-8")
        row = next(line for line in traceability.splitlines() if line.startswith("| PLT-R760 |"))
        self.assertIn("docs/support/managed-macs.md", row)


class EngineApiDocsTests(unittest.TestCase):
    """The engine API documentation (DocC) has a documented command and a nightly artifact (QA-R66)."""

    COMMAND = "xcodebuild docbuild -scheme VietnameseEngine"

    def test_contributing_documents_the_docc_command(self):
        contributing = (REPO / "CONTRIBUTING.md").read_text(encoding="utf-8")
        commands = contributing.split("\n## 4. ", 1)[1].split("\n## ", 1)[0]
        self.assertIn(self.COMMAND, commands)
        self.assertIn("VietnameseEngine.doccarchive", commands)

    def test_traceability_names_the_docc_decision(self):
        traceability = (REPO / "docs" / "architecture" / "traceability.md").read_text(encoding="utf-8")
        row = next(line for line in traceability.splitlines() if line.startswith("| QA-R66 |"))
        self.assertIn("DocC", row)
        self.assertTrue((REPO / "docs" / "decisions" / "0402-engine-api-docs.md").is_file())


class IntegrationHooksBuildTests(unittest.TestCase):
    """The INTEGRATION_HOOKS code exists only in the runner's test build (ADR 0502, "Integration hooks"): one
    configuration sets the condition, every hooks file compiles only under it, and the marker verify-release.sh
    looks for is the one the code carries."""

    HOOKS = REPO / "App" / "Sources" / "IntegrationHooks"
    MARKER_LINE = re.compile(r'^HOOKS_MARKER="(.+)"$', re.M)

    def swift_marker(self) -> str:
        source = (self.HOOKS / "IntegrationHooksApp.swift").read_text(encoding="utf-8")
        return re.search(r'static let marker = "([^"]+)"', source).group(1)

    def test_scripts_look_for_the_marker_the_code_carries(self):
        marker = self.swift_marker()
        self.assertGreater(len(marker.encode()), 15)  # longer strings live in __TEXT, never inline in a register
        for script in ("verify-release.sh", "run-integration.sh"):
            with self.subTest(script=script):
                text = (REPO / "scripts" / script).read_text(encoding="utf-8")
                self.assertEqual(self.MARKER_LINE.search(text).group(1), marker)

    def test_the_marker_appears_only_in_the_hooks_code(self):
        marker = self.swift_marker()
        roots = [REPO / "App", REPO / "Packages", REPO / "TestHost", REPO / "SpikeIMK"]
        found = sorted(
            str(path.relative_to(REPO)) for root in roots for path in root.rglob("*.swift")
            if ".build" not in path.parts and marker in path.read_text(encoding="utf-8"))
        self.assertEqual(found, ["App/Sources/IntegrationHooks/IntegrationHooksApp.swift"])

    def test_every_hooks_file_compiles_only_under_the_condition(self):
        files = sorted(self.HOOKS.glob("*.swift"))
        self.assertTrue(files)
        for path in files:
            lines = [line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
            code = [line for line in lines if not line.startswith("//")]
            with self.subTest(file=path.name):
                self.assertEqual(code[0], "#if INTEGRATION_HOOKS")
                self.assertEqual(code[-1], "#endif")

    def test_composition_uses_the_hooks_only_under_the_condition(self):
        for path in sorted((REPO / "App" / "Sources" / "Composition").glob("*.swift")):
            depth = []
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                stripped = line.strip()
                if stripped.startswith("#if"):
                    depth.append(stripped == "#if INTEGRATION_HOOKS")
                elif stripped.startswith("#endif"):
                    depth.pop()
                elif stripped.startswith("#else"):
                    depth[-1] = False
                elif re.search(r"\b(integrationHooks|IntegrationHooksApp|startIntegrationHooks)\b", stripped):
                    with self.subTest(file=path.name, line=number):
                        self.assertIn(True, depth, stripped)

    def test_only_the_integration_configuration_sets_the_condition(self):
        config = REPO / "Config"
        integration = (config / "Integration.xcconfig").read_text(encoding="utf-8")
        self.assertRegex(integration, r"(?m)^SWIFT_ACTIVE_COMPILATION_CONDITIONS = .*\bINTEGRATION_HOOKS\b")
        self.assertRegex(integration, r"(?m)^APP_BUNDLE_ID = \$\(APP_BUNDLE_ID_DEV\)$")
        self.assertRegex(integration, r"(?m)^CODE_SIGN_IDENTITY = \$\(CODE_SIGN_IDENTITY_DEV\)$")
        for name in sorted(path.name for path in config.glob("*.xcconfig")):
            if name == "Integration.xcconfig":
                continue
            with self.subTest(config=name):
                self.assertNotIn("INTEGRATION_HOOKS", (config / name).read_text(encoding="utf-8"))
        project = (REPO / "project.yml").read_text(encoding="utf-8")
        self.assertIn("  Integration: Config/Integration.xcconfig", project)
        self.assertIn("  Release: Config/Release.xcconfig", project)
        settings = "\n".join(line for line in project.splitlines() if not line.lstrip().startswith("#"))
        self.assertNotIn("INTEGRATION_HOOKS", settings)  # set by the xcconfig only, never per target
        build = (REPO / "scripts" / "build-release.sh").read_text(encoding="utf-8")
        self.assertNotIn("Integration", build)


class DevRecorderBuildTests(unittest.TestCase):
    """PLT-R904A, ADR 0007 (Pa, 2026-11-14): the dev builds' typing recorder exists only in the Debug configuration.
    AppCore defines DEV_RECORDER for Debug only, the App target adds it for Debug only and leaves the recorder's
    files out of Release and Integration by name, every recorder file compiles only under the condition, and the
    marker verify-release.sh looks for is the one the recorder carries."""

    MARKER_LINE = re.compile(r'^DEV_RECORDER_MARKER="(.+)"$', re.M)
    DIAGNOSTICS = REPO / "Packages" / "AppCore" / "Sources" / "Diagnostics" / "DevRecorder.swift"

    def swift_marker(self) -> str:
        source = self.DIAGNOSTICS.read_text(encoding="utf-8")
        return re.search(r'static let buildMarker = "([^"]+)"', source).group(1)

    def recorder_files(self) -> list[Path]:
        roots = [REPO / "App" / "Sources", REPO / "Packages" / "AppCore" / "Sources"]
        return sorted(
            path for root in roots for path in root.rglob("*.swift")
            if "DevRecorder" in path.name and ".build" not in path.parts)

    def test_verify_release_looks_for_the_marker_the_recorder_carries(self):
        marker = self.swift_marker()
        self.assertGreater(len(marker.encode()), 15)  # longer strings live in __TEXT, never inline in a register
        text = (REPO / "scripts" / "verify-release.sh").read_text(encoding="utf-8")
        self.assertEqual(self.MARKER_LINE.search(text).group(1), marker)
        self.assertIn("DevRecorder.strings", text)

    def test_every_recorder_file_compiles_only_under_the_condition(self):
        files = self.recorder_files()
        self.assertGreaterEqual(len(files), 10)
        for path in files:
            lines = [line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
            code = [line for line in lines if not line.startswith("//")]
            with self.subTest(file=str(path.relative_to(REPO))):
                self.assertEqual(code[0], "#if DEV_RECORDER")
                self.assertEqual(code[-1], "#endif")

    def test_appcore_defines_the_condition_for_debug_only(self):
        manifest = (REPO / "Packages" / "AppCore" / "Package.swift").read_text(encoding="utf-8")
        defines = re.findall(r'\.define\("DEV_RECORDER"[^)]*\)\)?', manifest)
        self.assertEqual(defines, ['.define("DEV_RECORDER", .when(configuration: .debug))'])

    def test_the_app_adds_the_condition_in_debug_and_drops_the_files_elsewhere(self):
        project = (REPO / "project.yml").read_text(encoding="utf-8")
        self.assertIn("        Debug:\n          SWIFT_ACTIVE_COMPILATION_CONDITIONS: $(inherited) DEV_RECORDER\n", project)
        self.assertIn('        Release:\n          EXCLUDED_SOURCE_FILE_NAMES: "*DevRecorder*"\n', project)
        self.assertIn('        Integration:\n          EXCLUDED_SOURCE_FILE_NAMES: "*DevRecorder*"\n', project)
        self.assertEqual(project.count("DEV_RECORDER"), 2)  # the Debug setting and its comment
        for name in sorted(path.name for path in (REPO / "Config").glob("*.xcconfig")):
            with self.subTest(config=name):
                self.assertNotIn("DEV_RECORDER", (REPO / "Config" / name).read_text(encoding="utf-8"))
        build = (REPO / "scripts" / "build-release.sh").read_text(encoding="utf-8")
        self.assertNotRegex(build, r"-configuration\s+Debug")
        self.assertTrue((REPO / "App" / "Resources" / "Localization" / "DevRecorder.xcstrings").is_file())


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


class SpecFollowUpTests(unittest.TestCase):
    """Wave 4 cross-track requests applied to the spec and the decision records (Pa's answers S8, Q8, Q6, S7)."""

    PRODUCT = (REPO / "spec" / "03-product.md").read_text(encoding="utf-8")

    @classmethod
    def requirement(cls, rid: str) -> str:
        return cls.PRODUCT.split(f"\n{rid} ", 1)[1].split("\nPRD-R", 1)[0]

    def test_donation_block_is_bank_vietqr_only(self):
        text = self.requirement("PRD-R59")
        for needle in ("VietQR", "LioBank", "account number", "holder name", "No MoMo", "GitHub Sponsors",
                       "sponsor page exists"):
            with self.subTest(needle=needle):
                self.assertIn(needle, text)
        self.assertNotIn("VERIFY", text)
        overview = (REPO / "spec" / "00-overview.md").read_text(encoding="utf-8")
        funding = next(line for line in overview.splitlines() if line.startswith("| Funding |"))
        self.assertIn("VietQR", funding)
        self.assertIn("GitHub Sponsors once", funding)
        adr = (REPO / "docs" / "decisions" / "0400-documentation-decisions.md").read_text(encoding="utf-8")
        row = next(line for line in adr.splitlines() if line.startswith("| 8 |"))
        for needle in ("VietQR", "bank name", "account number", "holder name never", "no MoMo", "S8"):
            with self.subTest(row8=needle):
                self.assertIn(needle, row)

    def test_menu_bar_glyphs_are_coloured_and_told_apart_without_colour(self):
        r9 = self.requirement("PRD-R9")
        r10 = self.requirement("PRD-R10")
        self.assertNotIn("monochrome", r9 + r10)
        self.assertIn("not a template", r9)
        for needle in ("emerald dot", "letter opacity", "badge shape", "VoiceOver"):
            with self.subTest(needle=needle):
                self.assertIn(needle, r10)

    def test_onboarding_names_the_macos_12_permission_path(self):
        screen = self.PRODUCT.split("**Screen 2: Permission**", 1)[1].split("**Screen 3", 1)[0]
        self.assertIn("System Preferences > Security & Privacy > Privacy > Accessibility", screen)
        self.assertIn("Tùy chọn Hệ thống > Bảo mật & Quyền riêng tư > Quyền riêng tư > Trợ năng", screen)
        self.assertIn("macOS 12", screen)

    def test_onboarding_button_takes_the_pane_app_name_from_the_table(self):
        """The button reads `Mở %@` with the name of the first permission pane still missing, from the PLT-R704
        table (Pa, 2026-11-14, PLT-R705), so the spec never fixes the label to one pane or to Cài đặt hệ thống."""
        screen = self.PRODUCT.split("**Screen 2: Permission**", 1)[1].split("**Screen 3", 1)[0]
        button = next(line for line in screen.splitlines() if line.startswith("- Button:"))
        self.assertIn("`Mở {{Pane}}`", button)
        self.assertIn("PLT-R704", button)
        self.assertNotIn("`Mở Cài đặt hệ thống`", button)


class TraceabilityTests(unittest.TestCase):
    """docs/architecture/traceability.md cites only tests that exist, and the wave 5 rows name their evidence
    (decision 0005: Q14, Q16, Q38, Q43, Q48, ENG-R906, ENG-R1103; ADR 0315)."""

    TEXT = (REPO / "docs" / "architecture" / "traceability.md").read_text(encoding="utf-8")

    @classmethod
    def row(cls, identifier: str) -> str:
        return next(line for line in cls.TEXT.splitlines() if line.startswith(f"| {identifier} |"))

    def test_every_cited_test_exists_in_the_tree(self):
        listed = run("git", "-C", str(REPO), "ls-files", "*.swift", check=True).stdout.split()
        names: set[str] = set()
        for relative in listed:
            path = REPO / relative
            names.add(path.stem)
            names |= set(re.findall(r"\b(?:struct|class|enum|extension)\s+([A-Z]\w*Tests)\b",
                                    path.read_text(encoding="utf-8", errors="replace")))
        cited = set(re.findall(r"`([A-Z][A-Za-z0-9]*Tests)(?:\.swift)?`", self.TEXT))
        self.assertGreaterEqual(len(cited), 15, "the scan found too few cited tests")
        self.assertEqual(sorted(cited - names), [], "traceability.md cites tests that do not exist")

    def test_wave_5_rows_name_their_evidence(self):
        expected = {
            "PLT-R1205": ("MisbehavesPanelFocus", "MisbehavesFocusTracker", "MisbehavesRetarget", "`MisbehavesPanel`",
                          "MisbehavesFocusTests"),
            "PLT-R905": ("`TypingTraceConfirmation`", "TypingTraceConfirmationTests"),
            "PLT-R398C": ("SecureInputHintCopyTests",),
            "PLT-R107": ("scripts/vm/smoke-macos12.sh", "macOS 12.7.6 smoke test PASS 2026-11-13",
                         "arm64 + x86_64 under Rosetta", "ADR 0315"),
            "PLT-R520": ("GamesPrecedenceTests",),
            "PLT-R353": ("RestoreHotkeyExclusionTests", "RestoreHotkeyDefaultTests"),
            "PRD-R18": ("RestoreHotkeyDefaultTests",),
            "ENG-R906": ("KeyPipelineCapsLockTests",),
            "ENG-R862": ("PerAppLearningTests", "ADR 0320"),
            "ENG-R1103": ("MacroEditorTests", "MacroEngineAgreementTests", "ADR 0321"),
        }
        for identifier, needles in expected.items():
            row = self.row(identifier)
            for needle in needles:
                with self.subTest(identifier=identifier, needle=needle):
                    self.assertIn(needle, row)


class AccessibilityAuditDocTests(unittest.TestCase):
    """docs/runbooks/accessibility-audit.md follows the wave 5 fixes: the misbehaves panel takes keyboard focus
    outside the guided test (PLT-R1205 step 6, Q43) and the typing trace confirmation states the chosen duration
    (PLT-R905), so neither is an open finding any more."""

    TEXT = (REPO / "docs" / "runbooks" / "accessibility-audit.md").read_text(encoding="utf-8")

    def test_the_misbehaves_step_checks_keyboard_focus_per_step(self):
        section = " ".join(self.TEXT.split("### 3.8 ", 1)[1].split("\n### ", 1)[0].split())
        step = section.split(" 3. ", 1)[1].split(" 4. ", 1)[0]
        for needle in ("PLT-R1205 step 6", "takes keyboard focus when it opens and in its final step",
                       "Full Keyboard Access", "symptom chips", "cannot become key",
                       "the problem field keeps the focus", "Do you see 'đá â'?", "VoiceOver"):
            with self.subTest(needle=needle):
                self.assertIn(needle, step)
        self.assertNotIn("non-activating on purpose", step)

    def test_the_wave_5_fixes_are_no_longer_open_findings(self):
        findings = self.TEXT.split("## 9. Findings for other owners", 1)[1]
        open_items = [line for line in findings.splitlines() if line.startswith("- ")]
        for line in open_items:
            with self.subTest(line=line):
                self.assertNotIn("Typing trace confirmation", line)
                self.assertNotIn("not reachable by keyboard focus", line)

    def test_the_browser_secure_input_hints_are_not_an_open_finding(self):
        """Q40 (decision 0005) added the browser rows to `secureInputHints`, Cốc Cốc's on 2026-11-14 (W7-B)."""
        findings = self.TEXT.split("## 9. Findings for other owners", 1)[1]
        open_items = [line for line in findings.splitlines() if line.startswith("- ")]
        for line in open_items:
            with self.subTest(line=line):
                self.assertNotIn("Browser rows for", line)
                self.assertNotIn("Cốc Cốc", line)
        flat = " ".join(findings.split())
        self.assertIn("Q40", flat)
        rules = json.loads((REPO / "compat" / "rules.json").read_text(encoding="utf-8"))
        browsers = [hint for hint in rules["secureInputHints"] if hint["hintKey"] == "browser.passwordField"]
        self.assertEqual(len(browsers), 7, "update section 9 when the browser rows change")
        for name in ("Safari", "Google Chrome", "Microsoft Edge", "Firefox", "Arc", "Brave", "Cốc Cốc"):
            with self.subTest(browser=name):
                self.assertIn(name, flat)


class Wave5StatusTests(unittest.TestCase):
    """Wave 5 implemented the decisions that the spec and decision 0005 marked as later work (Q14, Q16, Q43, Q48,
    ENG-R906, ENG-R1103), so no record still says "later wave" for them."""

    SPEC = REPO / "spec"
    ADR_0005 = (REPO / "docs" / "decisions" / "0005-pa-decisions-2026-11-13.md").read_text(encoding="utf-8")

    @staticmethod
    def flat(text: str) -> str:
        return " ".join(text.split())

    def test_the_spec_no_longer_defers_any_decision_to_a_later_wave(self):
        for path in sorted(self.SPEC.glob("*.md")):
            with self.subTest(path=path.name):
                self.assertNotIn("later wave", self.flat(path.read_text(encoding="utf-8")))

    def test_eng_r862_cites_the_per_app_learning_decision(self):
        engine = (self.SPEC / "01-engine.md").read_text(encoding="utf-8")
        row = next(line for line in engine.splitlines() if line.startswith("- **ENG-R862**"))
        self.assertIn("docs/decisions/0320-per-app-learned-words.md", row)
        self.assertTrue((REPO / "docs" / "decisions" / "0320-per-app-learned-words.md").is_file())

    def test_decision_0005_marks_the_wave_5_items_implemented(self):
        rows = {
            "| Q14 |": "Q14", "| Q16 |": "Q16", "| Q43 |": "Q43", "| Q48 |": "Q48",
            "| Telex bracket keys and case |": "ENG-R906", "| Macro digit shadowing |": "ENG-R1103",
        }
        lines = self.ADR_0005.splitlines()
        for prefix, label in rows.items():
            row = next(line for line in lines if line.startswith(prefix))
            with self.subTest(item=label):
                self.assertIn("implemented (wave 5, W5-", row)
                self.assertNotIn("implementation wave 5", row)
                self.assertNotIn("Implementation: wave 5", row)
        later = self.flat(self.ADR_0005.split("## Implemented later", 1)[1].split("\n## ", 1)[0])
        for item in ("Q14", "Q16", "Q43", "Q48", "ENG-R906", "ENG-R1103"):
            with self.subTest(section="Implemented later", item=item):
                self.assertIn(item, later)
        self.assertIn("Implemented in wave 5", later)
        consequences = self.flat(self.ADR_0005.split("## Consequences", 1)[1])
        self.assertNotIn("until the wave lands", consequences)
        self.assertIn("implemented in wave 5", consequences)

    def test_decision_0103_notes_that_digits_now_count(self):
        adr = (REPO / "docs" / "decisions" / "0103-engine-commit-history-macros.md").read_text(encoding="utf-8")
        row = next(line for line in adr.splitlines() if line.startswith("| Shadowed triggers (ENG-R1103) |"))
        decision = row.split("|")[2]
        self.assertIn("since decision 0005", decision)
        self.assertIn("0321", decision)
        self.assertIn("trailing main-row digit", decision)
        self.assertNotIn("digits do not count", decision)
        self.assertIn("superseded", row)


class ITerm2SentenceTests(unittest.TestCase):
    """Q38 and ADR 0400 item 15: the app (Status.xcstrings), the support page and the support replies give the same
    iTerm2 advice: turn off the menu item iTerm2 > Secure Keyboard Entry, or finish or cancel the pending password
    prompt. No setting name is quoted and nothing is left to VERIFY (PLT-R398C)."""

    REPLIES = (REPO / "docs" / "support" / "replies.md").read_text(encoding="utf-8")
    ADR_0400 = (REPO / "docs" / "decisions" / "0400-documentation-decisions.md").read_text(encoding="utf-8")

    def reply_step(self, language: str) -> str:
        section = self.REPLIES.split(f"### {language}\n")
        steps = [line for part in section[1:] for line in part.split("\n### ", 1)[0].splitlines()
                 if "**iTerm2:**" in line]
        self.assertTrue(steps, f"no iTerm2 step in the {language} replies")
        return steps[0]

    def test_the_replies_name_the_menu_item_and_the_pending_prompt(self):
        cases = {
            "Vietnamese": ("iTerm2 > Secure Keyboard Entry", "hủy", "lời nhắc mật khẩu đang chờ"),
            "English": ("iTerm2 > Secure Keyboard Entry", "finish or cancel", "password prompt it is waiting for"),
        }
        for language, needles in cases.items():
            step = self.reply_step(language)
            for needle in needles:
                with self.subTest(language=language, needle=needle):
                    self.assertIn(needle, step)
            with self.subTest(language=language, check="no VERIFY"):
                self.assertNotIn("VERIFY", step)
                self.assertNotIn("automatic option", step)

    def test_decision_0400_item_15_says_the_page_and_the_app_agree(self):
        closed = " ".join(self.ADR_0400.split("- **15** (Q38):", 1)[1].split("\n- **", 1)[0].split())
        self.assertIn("the support page and the app use the same sentence", closed)
        self.assertNotIn("until then", closed)
        row = next(line for line in self.ADR_0400.splitlines() if line.startswith("| 15 |"))
        self.assertIn("Decided (Q38)", row)

    def test_decision_0005_q38_no_longer_requests_the_copy(self):
        adr = (REPO / "docs" / "decisions" / "0005-pa-decisions-2026-11-13.md").read_text(encoding="utf-8")
        row = next(line for line in adr.splitlines() if line.startswith("| Q38 |"))
        self.assertNotIn("requested from their owners", row)
        self.assertIn("SecureInputHintCopyTests", row)
        self.assertIn("site/content/vi/support.mjs", row)


class IntegratorDecisionTests(unittest.TestCase):
    """Decisions the integrator took under Pa's delegation after wave 5, recorded in ADR 0400."""

    ADR_0400 = (REPO / "docs" / "decisions" / "0400-documentation-decisions.md").read_text(encoding="utf-8")

    def section(self) -> str:
        marker = "Decided by the integrator under Pa's delegation"
        self.assertIn(marker, self.ADR_0400)
        return " ".join(self.ADR_0400.split(marker, 1)[1].split("\n## ", 1)[0].split())

    def test_the_four_delegated_decisions_are_recorded(self):
        text = self.section()
        for needle in ("THIRD_PARTY_NOTICES.txt", "full", "analytics", "noindex", "data-domains", "ad-hoc",
                       "TCC grant", "Apple Development", "Q9", "hủy", "two sentences"):
            with self.subTest(needle=needle):
                self.assertIn(needle, text)

    def test_the_dmg_decision_matches_make_dmg(self):
        script = (REPO / "scripts" / "make-dmg.sh").read_text(encoding="utf-8")
        self.assertIn("THIRD_PARTY_NOTICES.md", script)
        self.assertIn("THIRD_PARTY_NOTICES.txt", script)

    def test_the_analytics_decision_matches_the_site(self):
        config = json.loads((REPO / "site" / "config.json").read_text(encoding="utf-8"))
        self.assertTrue(config["analytics"].get("websiteId"), "the analytics block stays filled")
        tracker = (REPO / "site" / "lib" / "analytics.mjs").read_text(encoding="utf-8")
        self.assertIn('data-domains="${esc(siteHost)}"', tracker)


class ChangelogTests(unittest.TestCase):
    """CHANGELOG.md, Unreleased: the user-visible changes of wave 5 and the licence (QA-R66, QA-R67; ADR 0006,
    ADR 0320, ADR 0321, decision 0005 Q14, Q43)."""

    TEXT = (REPO / "CHANGELOG.md").read_text(encoding="utf-8")

    def unreleased(self) -> str:
        return self.TEXT.split("## [Unreleased]", 1)[1].split("\n## [", 1)[0]

    def group(self, name: str) -> str:
        return " ".join(self.unreleased().split(f"### {name}\n", 1)[1].split("\n### ", 1)[0].split())

    def test_the_groups_follow_keep_a_changelog(self):
        groups = re.findall(r"^### (.+)$", self.unreleased(), re.M)
        order = ["Added", "Changed", "Deprecated", "Removed", "Fixed", "Security", "Known issues"]
        self.assertEqual(groups, [name for name in order if name in groups], "groups out of order or unknown")
        self.assertGreaterEqual(set(groups), {"Added", "Changed", "Fixed"})

    def test_wave_5_entries(self):
        expected = {
            "Changed": ("only in the app where you taught it", "stay global", "Settings > Typing",
                        "Escape restores the last word", "terminals, code editors, games and remote desktop apps",
                        "launchers such as Spotlight, Raycast and Alfred",
                        "trailing digit", "`k` and `k1`", "delete or rename one of the pair",
                        "GPL-3.0-or-later", "LICENSE", "THIRD_PARTY_NOTICES"),
            "Fixed": ("This app misbehaves", "keyboard"),
        }
        for group, needles in expected.items():
            text = self.group(group)
            for needle in needles:
                with self.subTest(group=group, needle=needle):
                    self.assertIn(needle, text)

    def test_the_escape_exclusions_name_the_same_families_everywhere(self):
        """D8, PLT-R353, decision 0005 Q14, the traceability row and the changelog name the launchers too: compat
        rules `launcher.spotlight` and `launcher.overlayPanels` set `features.restoreHotkey: false` (QA-R66)."""
        rules = json.loads((REPO / "compat" / "rules.json").read_text(encoding="utf-8"))
        off = {
            rule["id"] for rule in rules["rules"]
            if rule.get("action", {}).get("features", {}).get("restoreHotkey") is False
        }
        self.assertGreaterEqual(off, {"launcher.spotlight", "launcher.overlayPanels"})
        needle = "launchers such as Spotlight, Raycast and Alfred"
        product = (REPO / "spec" / "03-product.md").read_text(encoding="utf-8")
        platform = (REPO / "spec" / "02-platform.md").read_text(encoding="utf-8")
        adr = (REPO / "docs" / "decisions" / "0005-pa-decisions-2026-11-13.md").read_text(encoding="utf-8")
        matrix = (REPO / "docs" / "architecture" / "traceability.md").read_text(encoding="utf-8")
        places = {
            "D8": next(line for line in product.splitlines() if line.startswith("| D8 |")),
            "PLT-R353": next(line for line in platform.splitlines() if line.startswith("- **PLT-R353**")),
            "Q14": next(line for line in adr.splitlines() if line.startswith("| Q14 |")),
            "traceability": next(line for line in matrix.splitlines() if line.startswith("| PLT-R353 |")),
            "changelog": self.group("Changed"),
        }
        for name, text in places.items():
            with self.subTest(place=name):
                self.assertIn(needle, " ".join(text.split()))

    def test_no_placeholder_or_dash_in_the_entries(self):
        """CHANGELOG.md is part of the front door since 2026-11-14 (ADR 0400 decision 1 amendment): GitHub shows it as
        it is, so it writes the display name of scripts/brand.env instead of {{AppName}}."""
        text = self.unreleased()
        self.assertNotRegex(text, r"\{\{\s*[A-Za-z][\w-]*\s*\}\}")
        self.assertIn(FrontDoorBrandTests.repo_brand()["APP_DISPLAY_NAME"], text)
        self.assertNotIn("\u2014", text)
        self.assertNotIn("\u2013", text)


class ScriptSuiteTests(unittest.TestCase):
    """scripts/tests/run.sh runs every Python suite, and every runner label of the workflows is one actionlint knows
    (GitHub-hosted) or one scripts/actionlint.yaml declares (ci.yml runs actionlint with that file)."""

    RUN_SH = (REPO / "scripts" / "tests" / "run.sh").read_text(encoding="utf-8")
    HOSTED = re.compile(r"^(ubuntu|macos|windows)-[\w.-]+$|^(self-hosted|linux|macos|macOS|windows|x64|arm|arm64|ARM64)$")

    def test_the_suite_loop_runs_every_python_test_file(self):
        loop = re.search(r"^for suite in ([^;]+); do$", self.RUN_SH, re.M)
        self.assertIsNotNone(loop, "run.sh no longer has the Python suite loop")
        listed = set(loop.group(1).split())
        files = {path.stem for path in (REPO / "scripts" / "tests").glob("test_*.py")}
        self.assertGreaterEqual(listed, {"test_make_vietqr", "test_make_app_icon"})
        self.assertEqual(sorted(files - listed), [], "add these suites to the loop of scripts/tests/run.sh")
        self.assertEqual(sorted(listed - files), [], "the loop names a suite that does not exist")

    def test_every_runner_label_is_declared_for_actionlint(self):
        config = (REPO / "scripts" / "actionlint.yaml").read_text(encoding="utf-8")
        declared = set(re.findall(r"^\s+- ([\w.-]+)$", config.split("self-hosted-runner:", 1)[1], re.M))
        self.assertGreaterEqual(declared, {"xcode-27", "tcc-granted"})
        labels = set()
        for workflow in sorted((REPO / ".github" / "workflows").glob("*.yml")):
            for value in re.findall(r"^\s+runs-on: (.+)$", workflow.read_text(encoding="utf-8"), re.M):
                if "${{" in value:
                    continue
                labels |= {label.strip() for label in value.strip("[] ").split(",")}
        custom = {label for label in labels if not self.HOSTED.match(label)}
        self.assertGreaterEqual(custom, {"xcode-27", "tcc-granted"}, "the label scan found too little")
        self.assertEqual(sorted(custom - declared), [], "declare these labels in scripts/actionlint.yaml")

    def test_the_default_actionlint_config_mirrors_the_ci_one(self):
        # actionlint without -config-file reads .github/actionlint.yaml; ci.yml passes scripts/actionlint.yaml.
        def labels(path: Path) -> list[str]:
            text = path.read_text(encoding="utf-8")
            return sorted(re.findall(r"^\s+- ([\w.-]+)$", text.split("self-hosted-runner:", 1)[1], re.M))

        default = labels(REPO / ".github" / "actionlint.yaml")
        self.assertEqual(default, labels(REPO / "scripts" / "actionlint.yaml"))
        self.assertEqual(default, ["tcc-granted", "xcode-27"])

    def test_the_ci_dco_step_checks_every_path(self):
        # ADR 0006 decision 6: external pull requests are accepted in every area, so the DCO step checks every commit.
        ci = (REPO / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
        step = ci.split("scripts/check-dco.sh", 1)[1].split("\n      - ", 1)[0]
        self.assertNotIn("--path", step)

    def test_the_release_adr_names_the_dco_check_as_ci_runs_it(self):
        # Branch protection (ADR 0503) requires the check by its job name, so a renamed job must be renamed there too.
        ci = (REPO / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
        name = re.search(r"^  dco:\n    name: (.+)$", ci, re.M).group(1)
        self.assertEqual(name, "DCO sign-off on every commit (external pull requests)")
        adr = " ".join((REPO / "docs" / "decisions" / "0503-release-pipeline.md").read_text(encoding="utf-8").split())
        self.assertIn(f"`{name}`", adr)
        self.assertNotIn("sign-off on engine commits", adr)


def modern_tone_words(text: str) -> list[str]:
    """Words written with the modern tone placement (decision 0005 Q13 makes the traditional one the default): the
    cluster oa, oe or uy at the end of a word with the tone on its second vowel (`hoá`, `khoẻ`, `tuỳ`). A following
    letter makes the syllable closed or a triphthong, where both styles mark the second vowel (`hoàn`, `xoắn`,
    `ngoài`, `khuỷu`); after `q` the `u` belongs to the onset `qu`, so `quý` is right in both styles."""
    found = []
    for word in re.findall(r"[^\W\d_]+", unicodedata.normalize("NFC", text)):
        lower = word.lower()
        if len(lower) < 2 or lower[-1] not in MODERN_TONE_SECOND_VOWELS.get(lower[-2], ""):
            continue
        if lower[-2] == "u" and lower[:-2].endswith("q"):
            continue
        found.append(word)
    return found


MODERN_TONE_SECOND_VOWELS = {"o": "áàảãạéèẻẽẹ", "u": "ýỳỷỹỵ"}
SWIFT_STRING_LITERAL = re.compile(r'"(?:[^"\\\n]|\\.)*"')


class TonePlacementTests(unittest.TestCase):
    """The app catalogs and the replies users receive (docs/support) use the traditional tone placement of decision
    0005 Q13 (`hòa`, `thủy`, `xóa`, `tùy`, `khóa`), like the website (`site/test.mjs` checks the site). Only the
    tone placement setting shows the modern style, as its examples (integrator decision 2026-11-14, Q13 row)."""

    CATALOGS = REPO / "App" / "Resources" / "Localization"
    SUPPORT = REPO / "docs" / "support"
    # The tone placement setting (PRD-R24, PRD-R25, D2) shows the modern style on purpose.
    SETTING_EXAMPLES = {"hoà", "thuỷ", "khoẻ"}
    SETTING_KEYS = {"settings.typing.tone.explanation", "settings.typing.tone.modern"}
    SWIFT_ROOTS = ("Packages/AppCore/Sources", "App/Sources")

    def test_the_check_flags_modern_placement_only(self):
        modern = "hoá hoà hoạ khoá khoẻ xoá Xoá loè toả tuỳ thuỷ huỷ luỹ Thuỵ HOÁ"
        self.assertEqual(modern_tone_words(modern), modern.split())
        legitimate = ("hòa hóa khóa khỏe xóa tùy thủy hủy hoàn xoắn khuyết hoặc khoảng toán ngoài loại xoáy ngoằn "
                      "khuỷu huỳnh quý quỳ quỷ quỹ quỵ Quý quá quà của thuở huế giữa")
        self.assertEqual(modern_tone_words(legitimate), [])
        self.assertEqual(modern_tone_words(unicodedata.normalize("NFD", "tự xoá")), ["xoá"], "decomposed input")

    def test_the_catalogs_use_traditional_placement(self):
        offenders = []
        examples_seen = set()
        for path in sorted(self.CATALOGS.glob("*.xcstrings")):
            strings = json.loads(path.read_text(encoding="utf-8"))["strings"]
            for key, entry in strings.items():
                for language, unit in entry.get("localizations", {}).items():
                    words = modern_tone_words(unit.get("stringUnit", {}).get("value", ""))
                    if key in self.SETTING_KEYS:
                        examples_seen |= {word for word in words if word in self.SETTING_EXAMPLES}
                        words = [word for word in words if word not in self.SETTING_EXAMPLES]
                    offenders += [f"{path.name}: {key} [{language}]: {word}" for word in words]
        self.assertEqual(offenders, [])
        self.assertEqual(examples_seen, self.SETTING_EXAMPLES, "the setting's examples moved: update the allowlist")

    def test_the_support_replies_use_traditional_placement(self):
        files = sorted(path for path in self.SUPPORT.rglob("*") if path.is_file())
        self.assertGreaterEqual(len(files), 2)
        offenders = []
        for path in files:
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                offenders += [f"{path.relative_to(REPO)}:{number}: {word}" for word in modern_tone_words(line)]
        self.assertEqual(offenders, [])

    def test_the_swift_string_literals_use_traditional_placement(self):
        # Vietnamese text built in Swift (for example the readable typing trace of Diagnostics) reaches users without
        # a catalog. Comments are skipped: they may name both styles on purpose.
        offenders = []
        for root in self.SWIFT_ROOTS:
            for path in sorted((REPO / root).rglob("*.swift")):
                relative = str(path.relative_to(REPO))
                for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                    if line.lstrip().startswith("//"):
                        continue
                    for literal in SWIFT_STRING_LITERAL.findall(line):
                        offenders += [f"{relative}:{number}: {word}" for word in modern_tone_words(literal)]
        self.assertEqual(offenders, [])

    def test_the_decision_is_recorded_in_q13(self):
        adr = (REPO / "docs" / "decisions" / "0005-pa-decisions-2026-11-13.md").read_text(encoding="utf-8")
        row = " ".join(next(line for line in adr.splitlines() if line.startswith("| Q13 |")).split())
        for needle in ("2026-11-14", "website", "docs/support", "site/test.mjs", "TonePlacementTests"):
            with self.subTest(needle=needle):
                self.assertIn(needle, row)


class EngineTraceabilityTests(unittest.TestCase):
    """Packages/VietnameseEngine/TRACEABILITY.md and docs/architecture/traceability.md cite tests that exist, down to
    the function where they name one, and the host halves of ENG-R906, ENG-R1103 and ENG-R862 and the PRD-R36 guided
    slot name their AppCore evidence."""

    ENGINE = (REPO / "Packages" / "VietnameseEngine" / "TRACEABILITY.md").read_text(encoding="utf-8")
    PLATFORM = (REPO / "docs" / "architecture" / "traceability.md").read_text(encoding="utf-8")

    @staticmethod
    def row(text: str, identifier: str) -> str:
        return next(line for line in text.splitlines() if line.startswith(f"| {identifier} |"))

    @staticmethod
    def suites() -> dict[str, list[str]]:
        """Test suite name to the text of every tracked Swift file that declares or extends it."""
        listed = run("git", "-C", str(REPO), "ls-files", "*.swift", check=True).stdout.split()
        result: dict[str, list[str]] = {}
        for relative in listed:
            path = REPO / relative
            text = path.read_text(encoding="utf-8", errors="replace")
            names = set(re.findall(r"\b(?:struct|class|enum|extension)\s+([A-Z]\w*Tests)\b", text)) | {path.stem}
            for name in names:
                result.setdefault(name, []).append(text)
        return result

    def test_every_cited_suite_and_function_exists(self):
        suites = self.suites()
        for label, text in (("TRACEABILITY.md", self.ENGINE), ("traceability.md", self.PLATFORM)):
            cited = set(re.findall(r"`([A-Z][A-Za-z0-9]*Tests)(?:\.swift)?(?:\.[A-Za-z_]\w*)?`", text))
            self.assertEqual(sorted(cited - suites.keys()), [], f"{label} cites suites that do not exist")
            missing = [
                f"{suite}.{function}" for suite, function in re.findall(r"`([A-Z][A-Za-z0-9]*Tests)\.([a-z_]\w*)`", text)
                if function != "swift"
                and not any(re.search(rf"\bfunc\s+{function}\b", body) for body in suites.get(suite, []))
            ]
            self.assertEqual(missing, [], f"{label} cites test functions that do not exist")

    def test_the_engine_rows_name_the_host_evidence(self):
        expected = {
            "ENG-R906": ("AppCore", "`KeyPipelineCapsLockTests`"),
            "ENG-R1103": ("AppCore", "`MacroEditorTests`", "`MacroEngineAgreementTests`", "ADR 0321"),
        }
        for identifier, needles in expected.items():
            row = self.row(self.ENGINE, identifier)
            for needle in needles:
                with self.subTest(identifier=identifier, needle=needle):
                    self.assertIn(needle, row)

    def test_the_platform_rows_name_the_test_functions(self):
        expected = {
            "ENG-R862": "`HostPerAppLearningTests.aWordTypedBeforeTheFocusMovesBelongsToTheAppWhereItWasTyped`",
            "PRD-R36": "`GuidedOverrideSlotTests.onlyThePlainChoicesAreSelectable`",
        }
        for identifier, needle in expected.items():
            with self.subTest(identifier=identifier):
                self.assertIn(needle, self.row(self.PLATFORM, identifier))


class CocCocTests(unittest.TestCase):
    """Decision 0005 Q40: Cốc Cốc (Chromium based) gets the browser secure-input hint and a notVerified matrix row.
    Its bundle identifier comes from the vendor's installer, read by the integrator on 2026-11-14 from the mounted
    image without running the app."""

    BUNDLE_ID = "com.coccoc.Coccoc"
    SOURCE = ("files.coccoc.com/browser/mac/coccoc.dmg", "a3d0a7f2722bc0365646c9d72b4900e371311df6542da737fe5da4a5c6273c97",
              "152.0.7977.124", "477H9TWJ76", "2026-11-14")
    RULES = json.loads((REPO / "compat" / "rules.json").read_text(encoding="utf-8"))
    ADR = (REPO / "docs" / "decisions" / "0005-pa-decisions-2026-11-13.md").read_text(encoding="utf-8")

    def test_the_secure_input_hint_row(self):
        self.assertIn({"bundleId": self.BUNDLE_ID, "hintKey": "browser.passwordField"}, self.RULES["secureInputHints"])

    def test_the_chromium_rule_notes_name_the_browser_and_its_source(self):
        rule = next(rule for rule in self.RULES["rules"] if rule["id"] == "browser.chromium.addressBar")
        notes = rule["provenance"]["notes"]
        for needle in ("Cốc Cốc", self.BUNDLE_ID, "files.coccoc.com", "PLT-R510"):
            with self.subTest(needle=needle):
                self.assertIn(needle, notes)

    def test_the_matrix_row_is_not_verified(self):
        matrix = json.loads((REPO / "compat" / "matrix.json").read_text(encoding="utf-8"))
        rows = [entry for entry in matrix["entries"] if entry["bundleId"] == self.BUNDLE_ID]
        self.assertEqual(len(rows), 1)
        self.assertEqual(
            {key: rows[0].get(key) for key in ("displayName", "category", "ruleId", "status", "issues")},
            {"displayName": "Cốc Cốc", "category": "browser", "ruleId": "browser.chromium.addressBar",
             "status": "notVerified", "issues": []})

    def test_decision_0005_records_the_identifier_and_its_source(self):
        q40 = " ".join(next(line for line in self.ADR.splitlines() if line.startswith("| Q40 |")).split())
        self.assertNotIn("not added yet", q40)
        self.assertIn("Cốc Cốc", q40)
        table_row = " ".join(next(line for line in self.ADR.splitlines() if line.startswith("| Cốc Cốc |")).split())
        self.assertIn(f"`{self.BUNDLE_ID}`", table_row)
        for needle in self.SOURCE:
            with self.subTest(needle=needle):
                self.assertIn(needle, table_row)
        found = " ".join(self.ADR.split("## Found while applying the decisions", 1)[1].split("\n## ", 1)[0].split())
        self.assertNotIn("Cốc Cốc", found, "the identifier is confirmed now")


class SecureInputSupportPageTests(unittest.TestCase):
    """Decision 0005 Q38 and Q40 (PLT-R397): the support page's Secure Input list quotes the sentences the menu shows
    (Status.xcstrings) for iTerm2 and for browsers, word for word, so the two cannot drift apart again."""

    STATUS = json.loads((REPO / "App" / "Resources" / "Localization" / "Status.xcstrings").read_text(encoding="utf-8"))
    # Site language, the label the site puts in bold, the catalog key and the label the catalog sentence starts with.
    CASES = (
        ("vi", "Trình duyệt", "secureInputHint.browser.passwordField", "Trình duyệt: "),
        ("en", "Browsers", "secureInputHint.browser.passwordField", "Browser: "),
        ("vi", "iTerm2", "secureInputHint.iterm2.secureKeyboardEntry", ""),
        ("en", "iTerm2", "secureInputHint.iterm2.secureKeyboardEntry", ""),
        ("vi", "Terminal", "secureInputHint.terminal.secureKeyboardEntry", "Terminal: "),
        ("en", "Terminal", "secureInputHint.terminal.secureKeyboardEntry", "Terminal: "),
    )
    # Terminal's menu item as a Vietnamese macOS 12.7.6 and 27.2 show it (MainMenu 511.title, docs/runbooks/vm-test-lab.md
    # section 10), quoted next to the English name so both readers find it.
    TERMINAL_ITEM_VI = "Nhập dùng Bàn phím An Toàn (Secure Keyboard Entry)"

    def page_sentence(self, language: str, label: str) -> str:
        page = (REPO / "site" / "content" / language / "support.mjs").read_text(encoding="utf-8")
        prefix = f"<li><strong>{label}</strong>: "
        lines = [line.strip() for line in page.splitlines() if line.strip().startswith(prefix)]
        self.assertEqual(len(lines), 1, f"one {label} item on the {language} support page")
        item = lines[0].removeprefix(prefix).removesuffix("</li>")
        return html.unescape(re.sub(r"</?(em|strong)>", "", item))

    def test_the_page_quotes_the_menu_sentences(self):
        for language, label, key, catalog_label in self.CASES:
            with self.subTest(language=language, label=label):
                catalog = self.STATUS["strings"][key]["localizations"][language]["stringUnit"]["value"]
                self.assertTrue(catalog.startswith(catalog_label))
                self.assertEqual(self.page_sentence(language, label), catalog.removeprefix(catalog_label))

    def test_terminal_is_named_by_both_menu_titles_everywhere(self):
        catalog = self.STATUS["strings"]["secureInputHint.terminal.secureKeyboardEntry"]["localizations"]["vi"]
        replies = (REPO / "docs" / "support" / "replies.md").read_text(encoding="utf-8")
        reply = next(line for line in replies.splitlines() if line.startswith("2. **Terminal:**") and "menu Terminal" in line)
        for where, text in (("catalog", catalog["stringUnit"]["value"]), ("site", self.page_sentence("vi", "Terminal")),
                            ("replies", reply.replace("**", ""))):
            with self.subTest(where=where):
                self.assertIn(self.TERMINAL_ITEM_VI, text)



class PaneNameCopyTests(unittest.TestCase):
    """PLT-R701: pane names differ by macOS version (App/Resources/SystemPanes.json, checked against the Apple tables in
    docs/runbooks/vm-test-lab.md section 10), so fixed copy either names no pane or spells it as the newest table."""

    PANES = json.loads((REPO / "App" / "Resources" / "SystemPanes.json").read_text(encoding="utf-8"))

    def test_the_input_monitoring_button_strings_name_no_pane(self):
        catalog = json.loads((REPO / "App" / "Resources" / "Localization" / "Onboarding.xcstrings")
                             .read_text(encoding="utf-8"))["strings"]
        names = {entry["names"][language]["inputMonitoring"].casefold()
                 for entry in self.PANES["entries"] for language in ("en", "vi")}
        for kind in ("accessibilityHint", "accessibilityLabel"):
            for language, unit in catalog[f"onboarding.control.openInputMonitoringPane.{kind}"]["localizations"].items():
                with self.subTest(kind=kind, language=language):
                    value = unit["stringUnit"]["value"].casefold()
                    self.assertFalse([name for name in names if name in value])

    def test_the_login_items_pane_is_spelled_as_system_panes_json(self):
        newest = next(e for e in self.PANES["entries"] if "max" not in e["macOS"])["names"]["vi"]["loginItems"]
        page = html.unescape((REPO / "site" / "content" / "vi" / "support.mjs").read_text(encoding="utf-8"))
        self.assertNotIn("tiện ích mở rộng", page)
        self.assertGreaterEqual(page.count(f"Cài đặt chung > {newest}"), 2)


class W7bCopyTests(unittest.TestCase):
    """The Apps pane names the guided test's state with the term of the menu and Diagnostics (integrator decision
    2026-11-14, decision 0005 Q44 row; GuidedStateCopyTests checks the catalogs), and the changelog lists both
    user-visible changes of W7-B with the literal name (front door, ADR 0400 decision 1)."""

    def test_the_decision_is_recorded_in_q44(self):
        adr = (REPO / "docs" / "decisions" / "0005-pa-decisions-2026-11-13.md").read_text(encoding="utf-8")
        row = " ".join(next(line for line in adr.splitlines() if line.startswith("| Q44 |")).split())
        for needle in ("2026-11-14", "Theo kết quả thử tự động", "Set by the guided test", "GuidedStateCopyTests"):
            with self.subTest(needle=needle):
                self.assertIn(needle, row)

    def test_the_changelog_lists_the_changes(self):
        log = ChangelogTests()
        expected = {"Changed": ("Apps pane", "Theo kết quả thử tự động", "Set by the guided test"),
                    "Added": ("Cốc Cốc", "Secure Input")}
        for group, needles in expected.items():
            text = log.group(group)
            for needle in needles:
                with self.subTest(group=group, needle=needle):
                    self.assertIn(needle, text)


if __name__ == "__main__":
    unittest.main(verbosity=1)
