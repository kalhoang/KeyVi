# SPDX-License-Identifier: GPL-3.0-or-later
"""Self-tests that keep the decision records, notices and CI workflows in step with the code they describe.
Run: python3 -I scripts/tests/test_docs_and_workflows.py"""
from __future__ import annotations

import hashlib
import json
import plistlib
import re
import shutil
import sys
import tempfile
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
                    ".github/ISSUE_TEMPLATE/bug.yml", "compat/SCRIPT.md"):
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
                           "MPL-2.0-licensed", "Config/Brand.xcconfig", "scripts/brand.env", "0315-minimum-macos-12.md"),
             ("name is temporary", "not been chosen", "macOS 15", "macOS 14", "pending confirmation")),
            ("README.vi.md", ("macOS 12 Monterey trở lên", "chip Apple hoặc Intel", "GNU GPL", "giấy phép MPL-2.0",
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


class LicenceTests(unittest.TestCase):
    """ADR 0006 (Pa, 2026-11-13): the app is GPL-3.0-or-later, the engine packages, the data pipeline and the
    reference model are MPL-2.0, every contribution is signed off (DCO) and contributions to GPL-covered parts are also
    licensed to the project under MIT (QA-R61, PLT-R108, CLR-R11)."""

    # SHA-256 of https://www.gnu.org/licenses/gpl-3.0.txt as fetched on 2026-11-13 (35,149 bytes, the verbatim text).
    GPL3_SHA256 = "3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986"
    # spec/reference-model is MPL-2.0 too, through the SPDX header of each script and its README (spec/ keeps brand
    # placeholders and is never rewritten by scripts/rename-app.sh, so it holds no LICENSE naming the product).
    MIT_DIRS = ("Packages/VietnameseEngine", "Packages/VietnameseEngineFuzz", "data")
    # SHA-256 of the verbatim Mozilla Public License 2.0 text (https://www.mozilla.org/media/MPL/2.0/index.txt).
    MPL2_SHA256 = "3f3d9e0024b1921b067d6f7f88deb4a60cbe7a78e76c64e3f1d7fc3b779b9d04"
    ADR = REPO / "docs" / "decisions" / "0006-app-licence-and-pro-edition.md"
    PENDING_ID = "LicenseRef-" + "App-Pending"  # split so this file does not match its own search

    @staticmethod
    def brand_name() -> str:
        env = (REPO / "scripts" / "brand.env").read_text(encoding="utf-8")
        return re.search(r'^APP_DISPLAY_NAME="([^"]+)"$', env, re.M).group(1)

    def test_root_licence_is_the_verbatim_gpl_3_text(self):
        data = (REPO / "LICENSE").read_bytes()
        self.assertTrue(data.startswith(b"                    GNU GENERAL PUBLIC LICENSE\n"
                                        b"                       Version 3, 29 June 2007\n"))
        self.assertEqual(hashlib.sha256(data).hexdigest(), self.GPL3_SHA256, "LICENSE must be byte-exact")

    def test_engine_parts_carry_the_verbatim_mpl_2_text(self):
        for directory in self.MIT_DIRS:
            with self.subTest(directory=directory):
                data = (REPO / directory / "LICENSE").read_bytes()
                self.assertTrue(data.startswith(b"Mozilla Public License Version 2.0\n"))
                self.assertEqual(hashlib.sha256(data).hexdigest(), self.MPL2_SHA256, "LICENSE must be byte-exact")

    def test_mit_parts_match_the_spdx_lint(self):
        lint = (REPO / "scripts" / "check-spdx.sh").read_text(encoding="utf-8")
        mit_path = re.compile(re.search(r'MIT_PATH = re\.compile\(r"([^"]+)"\)', lint).group(1))
        for directory in self.MIT_DIRS:
            with self.subTest(directory=directory):
                self.assertRegex(f"{directory}/x.swift", mit_path)
        self.assertNotRegex("App/x.swift", mit_path)
        for script in sorted((REPO / "spec" / "reference-model").glob("*.py")):
            with self.subTest(reference_model=script.name):
                self.assertEqual(script.read_text(encoding="utf-8").splitlines()[0], "# SPDX-License-Identifier: MPL-2.0")

    def test_a_rename_never_touches_the_gpl_text(self):
        rename = (REPO / "scripts" / "rename-app.sh").read_text(encoding="utf-8")
        excluded = re.search(r'EXCLUDED = re\.compile\((r"[^\n]+"\n\s+r"[^\n]+")\)', rename)
        self.assertIsNotNone(excluded, "rename-app.sh no longer defines EXCLUDED")
        pattern = re.compile("".join(re.findall(r'r"([^"]*)"', excluded.group(1))))
        self.assertTrue(pattern.search("LICENSE"), "the verbatim GPL text must stay byte-exact after a rename")
        self.assertFalse(pattern.search("data/LICENSE"), "the engine licences follow a rename")

    def test_no_file_still_calls_the_app_licence_pending(self):
        listed = run("git", "-C", str(REPO), "ls-files", check=True).stdout.splitlines()
        offenders = []
        for rel in listed:
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
        for needle in ("GPL-3.0-or-later", "compat-rules.json", "injection"):
            self.assertIn(needle, plt_r108)
        self.assertNotIn("open decision", plt_r108)
        quality = (REPO / "spec" / "04-quality-release.md").read_text(encoding="utf-8")
        qa_r61 = quality.split("QA-R61 ", 1)[1].split("\nQA-R62 ", 1)[0]
        for needle in ("Signed-off-by", "MIT", "no CLA"):
            self.assertIn(needle, qa_r61)
        self.assertNotIn("open for Pa", qa_r61)

    def test_contributing_states_dco_and_inbound_mit_without_a_cla(self):
        text = " ".join((REPO / "CONTRIBUTING.md").read_text(encoding="utf-8").split())
        for needle in ("Signed-off-by", "Developer Certificate of Origin", "https://developercertificate.org",
                       "GPL-3.0-or-later", "also licensed to the project under the MIT licence",
                       "No contributor licence agreement", "ADR 0006", "scripts/check-dco.sh",
                       "A pull request with an unsigned commit is not merged"):
            with self.subTest(needle=needle):
                self.assertIn(needle, text)
        self.assertNotIn("not accepted until", text)
        # The merge rule must not depend on the CI scope: the dco job of ci.yml checked only the engine paths when
        # ADR 0006 was written, so CONTRIBUTING.md states the rule, not what CI happens to check.
        self.assertNotIn("checks every commit of a pull request from a fork", text)

    def test_pull_request_template_asks_for_the_sign_off_and_the_inbound_licence(self):
        text = (REPO / ".github" / "pull_request_template.md").read_text(encoding="utf-8")
        section = text.split("## Sign-off and licence", 1)[1].split("\n## ", 1)[0]
        self.assertIn("Signed-off-by:", section)
        self.assertIn("MIT", section)
        self.assertIn("GPL-3.0-or-later", section)
        self.assertNotIn("Not required for non-engine areas", text)

    def test_adr_0006_records_the_decision(self):
        text = " ".join(self.ADR.read_text(encoding="utf-8").split())
        self.assertTrue(text.startswith("# 0006. App licence and the Pro edition"))
        for needle in ("Status: accepted", "GPL-3.0-or-later", "MIT", "Developer Certificate of Origin", "PLT-R108",
                       "compat-rules.json", "injection", "99,000 VND", "after 1.0", "lifetime", "private module",
                       "signature", "offline", "Supersedes", "0401"):
            with self.subTest(needle=needle):
                self.assertIn(needle, text)
        adr_0001 = (REPO / "docs" / "decisions" / "0001-defaults-for-open-decisions.md").read_text(encoding="utf-8")
        status = next(line for line in adr_0001.splitlines() if line.startswith("- Status:"))
        self.assertIn("0005", status)
        self.assertIn("0006", status)
        self.assertIn("superseded", status)

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
        """The button reads `Mở %@` with the pane app's name (App/Resources/SystemPanes.json, PLT-R704); macOS 12
        calls it Tùy chọn Hệ thống, so the spec must not fix the label to Cài đặt hệ thống."""
        screen = self.PRODUCT.split("**Screen 2: Permission**", 1)[1].split("**Screen 3", 1)[0]
        button = next(line for line in screen.splitlines() if line.startswith("- Button:"))
        self.assertIn("`Mở {{SystemSettings}}`", button)
        self.assertIn("PLT-R704", button)
        self.assertNotIn("`Mở Cài đặt hệ thống`", button)


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


if __name__ == "__main__":
    unittest.main(verbosity=1)
