# SPDX-License-Identifier: LicenseRef-App-Pending
"""Self-tests that keep the decision records, notices and CI workflows in step with the code they describe.
Run: python3 -I scripts/tests/test_docs_and_workflows.py"""
from __future__ import annotations

import json
import re
import sys
import unittest
from pathlib import Path

sys.dont_write_bytecode = True  # keep scripts/tests free of __pycache__
sys.path.insert(0, str(Path(__file__).resolve().parent))

from support import REPO, py  # noqa: E402


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

    def test_symptom_mapping_matches_the_renderer(self):
        source = (self.DIAGNOSTICS / "IssueBlockFields.swift").read_text(encoding="utf-8")
        body = source.split("static func blockSymptom", 1)[1].split("\n    }", 1)[0]
        mapping = {}
        for cases, chip in re.findall(r"case ([^:]+): \"(\w+)\"", body):
            for case in re.findall(r"\.(\w+)", cases):
                mapping[case] = chip
        self.assertEqual(mapping["lettersOutOfOrder"], "other")
        self.assertEqual(mapping["nothingTyped"], "cannotType")
        table = self.ADR.split("### Symptom mapping", 1)[1]
        documented = dict(re.findall(r"^\| `(\w+)` \| `(\w+)` \|$", table, re.MULTILINE))
        self.assertEqual(documented, mapping)

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


if __name__ == "__main__":
    unittest.main(verbosity=1)
