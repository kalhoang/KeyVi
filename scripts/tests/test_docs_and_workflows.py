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

import swift_source  # noqa: E402
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
        """ADR 0601, PRD-R74: links, anchors, language attributes and the privacy rules are tested on every
        change; a deployed build refuses VERIFY markers and placeholder values (--strict)."""
        body = self.job("site.yml", "build")
        self.assertLess(body.index("run: node site/test.mjs"), body.index("node site/build.mjs"))
        self.assertIn("node site/build.mjs --strict", body)
        self.assertIn("vars.SITE_STRICT == 'true'", body)
        self.assertIn("vars.SITE_DEPLOY_TARGET != '' && vars.SITE_STRICT != 'false'", body)

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


if __name__ == "__main__":
    unittest.main(verbosity=1)
