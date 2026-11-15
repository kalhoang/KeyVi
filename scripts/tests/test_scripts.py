# SPDX-License-Identifier: GPL-3.0-or-later
"""Self-tests for the Python release and lint scripts. Run: python3 -I scripts/tests/test_scripts.py"""
from __future__ import annotations

import datetime as dt
import json
import re
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True  # keep scripts/lib and scripts/tests free of __pycache__
sys.path.insert(0, str(Path(__file__).resolve().parent))

from support import REPO, SCRIPTS, py, run  # noqa: E402

sys.path.insert(0, str(SCRIPTS / "lib"))

import jsonschema_lite  # noqa: E402


def good_rule(rule_id: str = "terminal.default", **overrides) -> dict:
    rule = {
        "id": rule_id,
        "summary": "Terminal emulators",
        "match": {"bundleGroup": "terminals"},
        "action": {"strategy": "backspaceReplace", "params": {"interEventDelayUs": 1500}},
        "provenance": {
            "reason": "TUIs lost letters.",
            "evidence": [{"type": "scenario", "ref": "compat/terminal-tui"}],
            "tested": [{"app": "Terminal", "appVersion": "2.15", "macOS": "27.1", "date": "2026-11-01",
                        "result": "pass"}],
            "addedIn": "0.1.0",
            "reviewBy": "2027-05-01",
        },
        "test": {"scenario": "terminal.default", "automation": "automated"},
    }
    rule.update(overrides)
    return rule


def rules_doc(*rules) -> dict:
    return {
        "schemaVersion": 1,
        "rulesetVersion": "2026.11.0",
        "defaults": {"strategy": "backspaceReplace", "params": {"inlineCompletion": "none"}},
        "bundleGroups": {"terminals": ["com.apple.Terminal"]},
        "rules": list(rules),
    }


class TempDirTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def write_json(self, name: str, data) -> Path:
        path = self.tmp / name
        path.write_text(json.dumps(data), encoding="utf-8")
        return path


class JsonSchemaLiteTests(unittest.TestCase):
    SCHEMA = {
        "type": "object",
        "required": ["id", "tags"],
        "additionalProperties": False,
        "properties": {
            "id": {"type": "string", "pattern": "^[a-z.]+$"},
            "tags": {"type": "array", "items": {"enum": ["a", "b"]}, "minItems": 1, "uniqueItems": True},
            "date": {"type": "string", "format": "date"},
            "n": {"$ref": "#/$defs/small"},
        },
        "$defs": {"small": {"type": "integer", "minimum": 0, "maximum": 9}},
    }

    def test_valid_document(self):
        self.assertEqual(jsonschema_lite.validate({"id": "a.b", "tags": ["a"], "n": 3}, self.SCHEMA), [])

    def test_reports_each_violation(self):
        errors = jsonschema_lite.validate(
            {"id": "A", "tags": ["c", "c"], "date": "2026-13-01", "n": 12, "x": 1}, self.SCHEMA)
        text = "\n".join(errors)
        for fragment in ("pattern", "not one of", "unique", "valid date", "above maximum", "unexpected property"):
            self.assertIn(fragment, text)

    def test_one_of_and_bool(self):
        schema = {"oneOf": [{"type": "integer"}, {"type": "string"}]}
        self.assertEqual(jsonschema_lite.validate(3, schema), [])
        self.assertTrue(jsonschema_lite.validate(True, schema))


class CheckRulesTests(TempDirTestCase):
    def check(self, doc, *extra, matrix=None):
        rules = self.write_json("rules.json", doc)
        args = ["--rules", str(rules), "--today", "2026-11-13",
                "--matrix", str(matrix or self.tmp / "missing-matrix.json")]
        empty_schema = self.write_json("schema.json", {"type": "object"})
        return py("check-rules.py", *args, "--schema", str(empty_schema), *extra)

    def test_valid_rule_passes(self):
        result = self.check(rules_doc(good_rule()))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_provenance_and_scenario_fail(self):
        rule = good_rule()
        del rule["provenance"]["evidence"]
        rule["test"] = {"automation": "automated"}
        result = self.check(rules_doc(rule))
        self.assertEqual(result.returncode, 1)
        self.assertIn("evidence", result.stderr)
        self.assertIn("test.scenario", result.stderr)

    def test_identical_match_signatures_fail(self):
        second = good_rule("terminal.other")
        second["match"] = {"bundleGroup": "terminals"}
        result = self.check(rules_doc(good_rule(), second))
        self.assertEqual(result.returncode, 1)
        self.assertIn("PLT-R521", result.stderr)

    def test_signature_is_order_insensitive(self):
        first = good_rule("a.one", match={"bundleIds": ["x.y.a", "x.y.b"]})
        second = good_rule("a.two", match={"bundleIds": ["x.y.b", "x.y.a"]})
        result = self.check(rules_doc(first, second))
        self.assertIn("PLT-R521", result.stderr)

    def test_review_by_warns_then_blocks_release(self):
        rule = good_rule()
        rule["provenance"]["reviewBy"] = "2026-09-01"  # 73 days overdue
        warn = self.check(rules_doc(rule))
        self.assertEqual(warn.returncode, 0)
        self.assertIn("warning", warn.stderr)
        block = self.check(rules_doc(rule), "--release")
        self.assertEqual(block.returncode, 1)
        self.assertIn("blocks the release", block.stderr)

    def test_review_by_too_far_ahead(self):
        rule = good_rule()
        rule["provenance"]["reviewBy"] = "2028-01-01"
        self.assertEqual(self.check(rules_doc(rule)).returncode, 1)

    def test_title_pattern_requires_bundle_ids(self):
        rule = good_rule(match={"titlePattern": "Sheet"})
        result = self.check(rules_doc(rule))
        self.assertIn("titlePattern requires bundleIds", result.stderr)

    def test_placeholder_in_global_or_title_only_rule(self):
        global_rule = good_rule("g.rule", match={})
        global_rule["action"]["params"] = {"inlineCompletion": "placeholder"}
        title_rule = good_rule("t.rule", match={"bundleIds": ["x.y.z"], "titlePattern": "Sheet"})
        title_rule["action"]["params"] = {"inlineCompletion": "placeholder"}
        result = self.check(rules_doc(global_rule, title_rule))
        self.assertIn("global rule", result.stderr)
        self.assertIn("title-only rule", result.stderr)

    def test_paste_requires_opt_in(self):
        rule = good_rule(action={"strategy": "paste"})
        self.assertIn("PLT-R460", self.check(rules_doc(rule)).stderr)

    def test_manual_scenario_needs_matrix_row(self):
        rule = good_rule(test={"scenario": "terminal.default", "automation": "manual"})
        matrix = self.write_json("matrix.json", {"entries": [{"bundleId": "x", "matchedRuleId": "other"}]})
        self.assertEqual(self.check(rules_doc(rule), matrix=matrix).returncode, 1)
        matrix = self.write_json("matrix.json", {"entries": [{"matchedRuleId": "terminal.default"}]})
        self.assertEqual(self.check(rules_doc(rule), matrix=matrix).returncode, 0)

    def test_schema_validation_runs(self):
        rules = self.write_json("rules.json", rules_doc(good_rule()))
        schema = self.write_json("schema.json", {"type": "object", "required": ["notThere"]})
        result = py("check-rules.py", "--rules", str(rules), "--schema", str(schema), "--today", "2026-11-13")
        self.assertEqual(result.returncode, 1)
        self.assertIn("notThere", result.stderr)

    def test_missing_file_passes_unless_required(self):
        missing = str(self.tmp / "none.json")
        self.assertEqual(py("check-rules.py", "--rules", missing).returncode, 0)
        self.assertEqual(py("check-rules.py", "--rules", missing, "--require").returncode, 1)

    def test_reviewby_report_table(self):
        result = self.check(rules_doc(good_rule()), "--reviewby-report")
        self.assertIn("| `terminal.default` | 2027-05-01 |", result.stdout)


class PlaceholderGateTests(TempDirTestCase):
    """PLT-R422: a scoped placeholder rule needs an automated scenario that declares the 1,000-edit gate. Mirrors
    compat-lint (CompatRules PlaceholderGate and LintEngine.placeholderFindings): a warning, an error with
    --release."""

    MESSAGE = "placeholder gate"

    def gate_scenario(self, **overrides) -> dict:
        scenario = {"id": "sheets.gate", "readback": "webdriver", "repeat": {"words": 1000, "timing": "burst"},
                    "expect": {"noPlaceholderResidue": True}}
        for key, value in overrides.items():
            if value is None:
                scenario.pop(key, None)
            else:
                scenario[key] = value
        return scenario

    def placeholder_rule(self, completion="placeholder", automation="automated", match=None) -> dict:
        rule = good_rule("web.sheets.cell", match=match or {"bundleIds": ["com.example.browser"],
                                                             "ax": {"domClasses": ["cell-input"]}})
        rule["action"]["params"] = {"inlineCompletion": completion}
        rule["test"] = {"scenario": "sheets.gate", "automation": automation}
        return rule

    def lint(self, rule, scenario=None, *extra):
        scenarios = self.tmp / "scenarios"
        scenarios.mkdir(exist_ok=True)
        if scenario is not None:
            (scenarios / "sheets.gate.json").write_text(json.dumps(scenario), encoding="utf-8")
        matrix = self.write_json("matrix.json", {"entries": [{"ruleId": "web.sheets.cell"}]})
        rules = self.write_json("rules.json", rules_doc(rule))
        schema = self.write_json("schema.json", {"type": "object"})
        return py("check-rules.py", "--rules", str(rules), "--schema", str(schema), "--matrix", str(matrix),
                  "--scenarios", str(scenarios), "--today", "2026-11-13", *extra)

    def test_a_declared_gate_passes_in_release_mode(self):
        for completion in ("placeholder", "axSelectionThenPlaceholder"):
            with self.subTest(completion=completion):
                result = self.lint(self.placeholder_rule(completion), self.gate_scenario(), "--release")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn(self.MESSAGE, result.stderr)

    def test_a_manual_test_warns_and_blocks_the_release(self):
        rule = self.placeholder_rule(automation="manual")
        warn = self.lint(rule, self.gate_scenario())
        self.assertEqual(warn.returncode, 0, warn.stderr)
        self.assertIn("warning: rule web.sheets.cell: placeholder gate needs an automated test (PLT-R422)",
                      warn.stderr)
        block = self.lint(rule, self.gate_scenario(), "--release")
        self.assertEqual(block.returncode, 1)
        self.assertIn("error: rule web.sheets.cell: placeholder gate needs an automated test (PLT-R422)",
                      block.stderr)

    def test_a_scenario_without_the_gate_blocks_the_release(self):
        cases = {
            "missing file": None,
            "999 words": self.gate_scenario(repeat={"words": 999, "timing": "burst"}),
            "steady timing": self.gate_scenario(repeat={"words": 1000, "timing": "steady"}),
            "no repeat": self.gate_scenario(repeat=None),
            "residue not checked": self.gate_scenario(expect={"noPlaceholderResidue": False}),
            "no expect": self.gate_scenario(expect=None),
            "human readback": self.gate_scenario(readback="human"),
            "words as text": self.gate_scenario(repeat={"words": "1000", "timing": "burst"}),
        }
        for name, scenario in cases.items():
            with self.subTest(case=name):
                warn = self.lint(self.placeholder_rule(), scenario)
                self.assertEqual(warn.returncode, 0, warn.stderr)
                self.assertIn("warning: rule web.sheets.cell: placeholder gate: scenario sheets.gate does not "
                              "declare repeat.words >= 1000, repeat.timing burst, expect.noPlaceholderResidue "
                              "true and an automatic readback (ax or webdriver) (PLT-R422)", warn.stderr)
                self.assertEqual(self.lint(self.placeholder_rule(), scenario, "--release").returncode, 1)

    def test_broad_rules_and_rules_without_placeholder_are_not_gated_here(self):
        broad = self.placeholder_rule(match={"bundleIds": ["com.example.browser"], "titlePattern": "Sheet"})
        result = self.lint(broad, None)
        self.assertIn("title-only rule (PLT-R422)", result.stderr)
        self.assertNotIn(self.MESSAGE, result.stderr, "a broad rule is rejected whatever its test")
        plain = self.placeholder_rule(completion="axSelection", automation="manual")
        self.assertNotIn(self.MESSAGE, self.lint(plain, None, "--release").stderr)

    def test_the_repository_scenarios_folder_is_the_default(self):
        result = py("check-rules.py", "--help")
        self.assertIn("--scenarios", result.stdout)
        self.assertIn("compat/scenarios", result.stdout)


class LookaheadRevisionLintTests(TempDirTestCase):
    """PLT-R357: the two compat-lint errors for `features.lookaheadRevision` (CompatRules LintEngine.revisionFindings),
    with the same codes and messages: the flag on a strategy that cannot carry a revision, and the flag left on where
    the restore key is off (PLT-R353: the restore key is how a revision is undone)."""

    STRATEGY_CODE = "lookaheadRevisionWithoutEditStrategy"
    STRATEGY_MESSAGE = "lookaheadRevision needs strategy backspaceReplace or selectReplace"
    HOTKEY_CODE = "lookaheadRevisionWithoutRestoreHotkey"
    HOTKEY_MESSAGE = "restoreHotkey is false, so lookaheadRevision must be false too"

    def lint(self, strategy: str, features: dict):
        action = {"strategy": strategy, "features": features}
        if strategy == "paste":
            action["requiresUserOptIn"] = True
        rules = self.write_json("rules.json", rules_doc(good_rule(action=action)))
        schema = self.write_json("schema.json", {"type": "object"})
        return py("check-rules.py", "--rules", str(rules), "--schema", str(schema), "--today", "2026-11-13",
                  "--matrix", str(self.tmp / "missing-matrix.json"))

    def test_the_flag_needs_an_edit_strategy(self):
        for strategy in ("axReplace", "paste", "passThrough"):
            with self.subTest(strategy=strategy):
                result = self.lint(strategy, {"lookaheadRevision": True})
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(f"error: rule terminal.default: {self.STRATEGY_CODE}: {self.STRATEGY_MESSAGE}",
                              result.stderr)
        for strategy in ("backspaceReplace", "selectReplace"):
            with self.subTest(strategy=strategy):
                result = self.lint(strategy, {"lookaheadRevision": True})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn(self.STRATEGY_CODE, result.stderr)

    def test_an_unset_or_false_flag_on_another_strategy_passes(self):
        for features in ({}, {"lookaheadRevision": False}):
            with self.subTest(features=features):
                result = self.lint("axReplace", features)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("lookaheadRevision", result.stderr)

    def test_the_restore_key_off_needs_the_flag_off(self):
        for strategy in ("backspaceReplace", "selectReplace"):
            for features in ({"restoreHotkey": False}, {"restoreHotkey": False, "lookaheadRevision": True}):
                with self.subTest(strategy=strategy, features=features):
                    result = self.lint(strategy, features)
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertIn(f"error: rule terminal.default: {self.HOTKEY_CODE}: {self.HOTKEY_MESSAGE}",
                                  result.stderr)
            with self.subTest(strategy=strategy, features="flag off"):
                result = self.lint(strategy, {"restoreHotkey": False, "lookaheadRevision": False})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn(self.HOTKEY_CODE, result.stderr)

    def test_the_restore_key_check_applies_only_to_edit_strategies(self):
        """Resolution turns the flag off on other strategies anyway, as in the Swift linter."""
        result = self.lint("axReplace", {"restoreHotkey": False})
        self.assertEqual(result.returncode, 0, result.stderr)
        both = self.lint("axReplace", {"restoreHotkey": False, "lookaheadRevision": True})
        self.assertIn(self.STRATEGY_CODE, both.stderr)
        self.assertNotIn(self.HOTKEY_CODE, both.stderr)

    def test_codes_and_messages_are_the_swift_linters(self):
        engine = (REPO / "Packages/AppCore/Sources/CompatRules/LintEngine.swift").read_text(encoding="utf-8")
        lint = (REPO / "Packages/AppCore/Sources/CompatRules/Lint.swift").read_text(encoding="utf-8")
        for code, message in ((self.STRATEGY_CODE, self.STRATEGY_MESSAGE), (self.HOTKEY_CODE, self.HOTKEY_MESSAGE)):
            with self.subTest(code=code):
                self.assertRegex(lint, rf"\bcase {code}\b")
                self.assertRegex(engine, rf'\.{code},\s*"{re.escape(message)}"')

    def test_the_shipped_rules_pass(self):
        result = py("check-rules.py", "--matrix", str(self.tmp / "missing-matrix.json"))
        self.assertNotIn("lookaheadRevision", result.stderr)


class ForwardDeleteTests(TempDirTestCase):
    def test_clean_rules(self):
        path = self.write_json("rules.json", rules_doc(good_rule()))
        self.assertEqual(py("check-no-forward-delete.py", str(path)).returncode, 0)

    def test_detects_forward_delete(self):
        rule = good_rule()
        rule["action"]["params"]["deleteKey"] = "forwardDelete"
        rule["action"]["params"]["keyCode"] = 117
        path = self.write_json("rules.json", rules_doc(rule))
        result = py("check-no-forward-delete.py", str(path))
        self.assertEqual(result.returncode, 1)
        self.assertIn("terminal.default", result.stdout)

    def test_provenance_text_may_mention_it(self):
        rule = good_rule()
        rule["provenance"]["reason"] = "Outlook deleted the next character, the signature of a forward delete."
        path = self.write_json("rules.json", rules_doc(rule))
        self.assertEqual(py("check-no-forward-delete.py", str(path)).returncode, 0)


class ParseDiagnosticsTests(unittest.TestCase):
    BODY = """### Ứng dụng
Google Chrome 156

### Khối chẩn đoán
```text
testapp-diagnostics v1
app.version: 0.1.0
app.build: 10001
report.bundleId: com.google.Chrome
focus.bundleId: com.apple.Terminal
macos.version: 27.1 (26B12)
hw.arch: arm64
input.method: telex
```
"""

    def labels(self, body: str) -> dict:
        result = py("parse-diagnostics.py", "--json", env={"ISSUE_BODY": body})
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_labels_from_block(self):
        self.assertEqual(self.labels(self.BODY)["labels"],
                         ["app:com.google.Chrome", "macos:27", "arch:arm64", "method:telex"])

    def test_focus_bundle_fallback_and_vni_intel(self):
        body = "```\nx-diagnostics v1\nfocus.bundleId: com.apple.TextEdit\nhw.arch: x86_64\ninput.method: VNI\n```"
        self.assertEqual(self.labels(body)["labels"], ["app:com.apple.TextEdit", "arch:x86_64", "method:vni"])

    def test_hostile_values_are_ignored(self):
        body = ("```\ntestapp-diagnostics v1\nreport.bundleId: $(rm -rf /)\nmacos.version: abc\n"
                "hw.arch: sparc\ninput.method: telex; echo\n```")
        self.assertEqual(self.labels(body)["labels"], [])

    def test_no_block_and_unknown_version(self):
        self.assertFalse(self.labels("no diagnostics here")["found"])
        result = self.labels("```\ntestapp-diagnostics v2\nhw.arch: arm64\n```")
        self.assertTrue(result["found"])
        self.assertEqual(result["labels"], [])

    def test_block_ends_at_fence(self):
        body = "```\ntestapp-diagnostics v1\nhw.arch: arm64\n```\ninput.method: vni\n"
        self.assertEqual(self.labels(body)["labels"], ["arch:arm64"])

    def test_unfenced_paste_still_parses(self):
        # ADR 0501 "Issue forms": no render: option, so a paste of the inner lines arrives without a fence.
        body = ("### Khối chẩn đoán\n\ntestapp-diagnostics v1\nhw.arch: arm64\ninput.method: telex\n\n"
                "### Có lỗi trong ô gõ thử không?\n\nNo, only in the app above\n")
        self.assertEqual(self.labels(body)["labels"], ["arch:arm64", "method:telex"])


class IssueFormTests(unittest.TestCase):
    """QA-R43 and ADR 0501: the diagnostics textarea keeps the pasted fence (no render:) and names the header."""

    @staticmethod
    def field(form: str, field_id: str) -> str:
        text = (REPO / ".github" / "ISSUE_TEMPLATE" / form).read_text(encoding="utf-8")
        items = text.split("\n  - type: ")
        matches = [item for item in items if f"\n    id: {field_id}\n" in item]
        assert len(matches) == 1, f"{form}: expected one field with id {field_id}"
        return matches[0]

    def test_diagnostics_field_has_no_render_and_names_the_header(self):
        # The forms are front-door files (ADR 0400 decision 1, amended 2026-11-13): GitHub shows them as they are, so
        # they name the header with the literal slug of scripts/brand.env; scripts/rename-app.sh rewrites it.
        slug = re.search(r'^APP_SLUG="([^"]+)"$', (SCRIPTS / "brand.env").read_text(encoding="utf-8"), re.M).group(1)
        for form in ("bug.yml", "compatibility.yml"):
            with self.subTest(form=form):
                field = self.field(form, "diagnostics")
                self.assertTrue(field.startswith("textarea\n"), field[:40])
                self.assertNotIn("render:", field)
                self.assertIn(f"`{slug}-diagnostics v1`", field)


class PublishHelpersTests(TempDirTestCase):
    SIG = "A" * 86 + "=="

    def helper(self, *args):
        return py("lib/publish_helpers.py", *args)

    def insert(self, appcast, version, build, channel="stable", **extra):
        args = ["appcast-insert", "--appcast", str(appcast), "--app-name", "Test App",
                "--site-url", "https://example.test/", "--version", version, "--build", str(build),
                "--minimum-system-version", "15.0", "--channel", channel,
                "--url", f"https://example.test/download/test-{version}.zip", "--length", "1234",
                "--signature", self.SIG, "--notes-url", f"https://example.test/release-notes/{version}/",
                "--date", "2026-11-13T10:00:00+00:00"]
        for key, value in extra.items():
            args += [f"--{key.replace('_', '-')}"] + ([] if value is True else [str(value)])
        return self.helper(*args)

    def test_appcast_items(self):
        appcast = self.tmp / "appcast.xml"
        self.assertEqual(self.insert(appcast, "0.1.0", 10099).returncode, 0)
        beta = self.insert(appcast, "0.2.0-beta.1", 20001, channel="beta")
        self.assertEqual(beta.returncode, 0, beta.stderr)
        text = appcast.read_text(encoding="utf-8")
        self.assertIn("<sparkle:channel>beta</sparkle:channel>", text)
        self.assertIn("<sparkle:phasedRolloutInterval>86400</sparkle:phasedRolloutInterval>", text)
        self.assertIn('sparkle:edSignature="' + self.SIG + '"', text)
        # ADR 0304 amendment: one bilingual page per release, no xml:lang variants.
        self.assertIn("<sparkle:releaseNotesLink>https://example.test/release-notes/0.1.0/</sparkle:releaseNotesLink>",
                      text)
        self.assertEqual(text.count("<sparkle:releaseNotesLink"), 2)
        self.assertNotIn("xml:lang", text)
        self.assertLess(text.index("0.2.0-beta.1"), text.index("<sparkle:shortVersionString>0.1.0"))
        import xml.etree.ElementTree as ET
        ET.fromstring(text.split("\n", 1)[1])

    def test_appcast_rejects_duplicates_lower_builds_and_http(self):
        appcast = self.tmp / "appcast.xml"
        self.insert(appcast, "0.2.0", 20099)
        self.assertEqual(self.insert(appcast, "0.2.0", 20099).returncode, 1)
        self.assertEqual(self.insert(appcast, "0.1.9", 10999).returncode, 1)
        result = self.insert(appcast, "0.1.0-beta.1", 10001, channel="stable")
        self.assertEqual(result.returncode, 1)
        # A stable hotfix below a newer beta is allowed (QA-R28): beta users keep the beta.
        self.insert(appcast, "0.3.0-beta.1", 30001, channel="beta")
        self.assertEqual(self.insert(appcast, "0.2.1", 20199).returncode, 0)

    def test_critical_and_no_phasing(self):
        appcast = self.tmp / "appcast.xml"
        self.insert(appcast, "1.0.0", 1000099, critical=True, phased_interval=0, minimum_autoupdate_version=10099)
        text = appcast.read_text(encoding="utf-8")
        self.assertIn("<sparkle:criticalUpdate", text)
        self.assertNotIn("phasedRolloutInterval", text)
        self.assertIn("<sparkle:minimumAutoupdateVersion>10099<", text)

    def test_releases_json(self):
        path = self.tmp / "releases.json"
        common = ["--build", "10099", "--channel", "stable", "--date", "2026-11-13",
                  "--dmg-url", "https://example.test/d.dmg", "--sha256", "a" * 64, "--size", "10",
                  "--minimum-system-version", "15.0", "--notes-vi", "Sửa lỗi", "--notes-en", "Fixes"]
        self.assertEqual(self.helper("releases-add", "--file", str(path), "--version", "0.1.0", *common).returncode, 0)
        self.assertEqual(self.helper("releases-add", "--file", str(path), "--version", "0.1.0", *common).returncode, 1)
        doc = json.loads(path.read_text(encoding="utf-8"))
        entry = doc["releases"][0]
        self.assertEqual((entry["version"], entry["dmgUrl"], entry["notes"]["vi"]), ("0.1.0", "https://example.test/d.dmg", "Sửa lỗi"))
        common[-1:] = ["Fixes in {{AppName}}", "--app-name", "Test App"]
        self.assertEqual(self.helper("releases-add", "--file", str(path), "--version", "0.2.0", *common).returncode, 0)
        doc = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(doc["releases"][0]["notes"]["en"], "Fixes in Test App")
        # {{AppNameTM}} is the name with APP_TRADEMARK_SIGN (Pa, 15/11/2026); without a sign it is the bare name.
        common[-3:] = ["About {{AppNameTM}}", "--app-name", "Test App", "--trademark-sign", "™"]
        self.assertEqual(self.helper("releases-add", "--file", str(path), "--version", "0.3.0", *common).returncode, 0)
        common[-5:] = ["About {{AppNameTM}}", "--app-name", "Test App"]
        self.assertEqual(self.helper("releases-add", "--file", str(path), "--version", "0.4.0", *common).returncode, 0)
        notes = {entry["version"]: entry["notes"]["en"] for entry in json.loads(path.read_text(encoding="utf-8"))["releases"]}
        self.assertEqual((notes["0.3.0"], notes["0.4.0"]), ("About Test App™", "About Test App"))

    def notes_page(self, out, notes_vi="### Đã sửa\n- Sửa lỗi lặp chữ trong **Chrome**",
                   notes_en="### Fixed\n- Fixed doubled letters in **Chrome**", *extra):
        return self.helper("release-notes-page", "--out", str(out), "--app-name", "Test App",
                           "--version", "1.2.3", "--notes-vi", notes_vi, "--notes-en", notes_en,
                           "--changelog-url-vi", "https://example.test/nhat-ky-thay-doi/#v1.2.3",
                           "--changelog-url-en", "https://example.test/en/changelog/#v1.2.3", *extra)

    def test_release_notes_page_is_one_bilingual_page(self):
        # ADR 0304 amendment and PRD-R51: Vietnamese first, then English, each with a link to the changelog.
        out = self.tmp / "release-notes" / "1.2.3" / "index.html"
        result = self.notes_page(out)
        self.assertEqual(result.returncode, 0, result.stderr)
        page = out.read_text(encoding="utf-8")
        self.assertTrue(page.startswith("<!doctype html>\n<html lang=\"vi\">"))
        self.assertEqual(page.count("<h1>"), 1)
        self.assertIn("<h1>Test App 1.2.3</h1>", page)
        self.assertLess(page.index('<section lang="vi"'), page.index('<section lang="en"'))
        self.assertIn('<a href="https://example.test/nhat-ky-thay-doi/#v1.2.3">', page)
        self.assertIn('<a href="https://example.test/en/changelog/#v1.2.3">', page)
        self.assertIn("<strong>Chrome</strong>", page)
        self.assertIn("Content-Security-Policy", page)
        # The page is what the in-app update window shows: no donation line (PRD-R57), no scripts.
        for forbidden in ("ung-ho", "donate", "<script", "{{"):
            self.assertNotIn(forbidden, page)

    def test_release_notes_page_loads_nothing_plt_r906(self):
        """PLT-R906: the update window shows the notes without loading anything else, so the stylesheet is inline
        and the page's CSP allows exactly that block (its SHA-256) and nothing else."""
        import base64
        import hashlib
        out = self.tmp / "self-contained.html"
        result = self.notes_page(out)
        self.assertEqual(result.returncode, 0, result.stderr)
        page = out.read_text(encoding="utf-8")
        for forbidden in ("<link", "<script", "<img", "url(", "@import", "src="):
            self.assertNotIn(forbidden, page)
        style = re.search(r"<style>(.*?)</style>", page, re.S)
        self.assertIsNotNone(style, "inline stylesheet")
        css = (REPO / "site" / "static" / "assets" / "release-notes.css").read_text(encoding="utf-8")
        self.assertEqual(style.group(1), css)
        digest = base64.b64encode(hashlib.sha256(css.encode("utf-8")).digest()).decode("ascii")
        self.assertIn(f"default-src 'none'; style-src 'sha256-{digest}'; img-src 'none';", page)

    def test_beta_soak_qa_r29(self):
        """QA-R29: a stable X.Y.Z needs its latest X.Y.Z-beta.N listed at least 72 hours (three days) earlier."""
        path = self.write_json("releases.json", {"schemaVersion": 1, "releases": [
            {"version": "1.3.0-beta.1", "channel": "beta", "date": "2026-11-01"},
            {"version": "1.2.3-beta.2", "channel": "beta", "date": "2026-11-11"},
            {"version": "1.2.3-beta.1", "channel": "beta", "date": "2026-11-09"},
            {"version": "1.2.2", "channel": "stable", "date": "2026-11-01"},
        ]})

        def soak(version, today, file=path):
            return self.helper("beta-soak", "--file", str(file), "--version", version, "--hours", "72",
                               "--today", today)

        self.assertEqual(soak("1.2.3", "2026-11-14").returncode, 0, "the latest beta is three days old")
        late = soak("1.2.3", "2026-11-13")
        self.assertEqual(late.returncode, 1, "beta.1 is old enough, but beta.2 is what becomes stable")
        self.assertIn("the latest beta 1.2.3-beta.2 is from 2026-11-11", late.stderr)
        self.assertEqual(soak("1.2.2", "2026-11-13").returncode, 1, "a beta of another version does not count")
        missing = soak("1.2.3", "2026-11-13", file=self.tmp / "none.json")
        self.assertEqual(missing.returncode, 1)
        self.assertIn("no 1.2.3-beta.N listed", missing.stderr)
        self.assertNotEqual(soak("1.2.3-beta.3", "2026-11-13").returncode, 0, "only stable versions are checked")

    def test_release_notes_page_escapes_and_fills_tokens(self):
        out = self.tmp / "page.html"
        result = self.notes_page(out, "- <script>alert(1)</script> trong {{AppName}}",
                                 "- [link](javascript:alert) and [ok](https://example.test/a)")
        self.assertEqual(result.returncode, 0, result.stderr)
        page = out.read_text(encoding="utf-8")
        self.assertIn("&lt;script&gt;alert(1)&lt;/script&gt; trong Test App", page)
        self.assertNotIn("javascript", page)
        self.assertIn("<li>link and ", page)
        self.assertIn('<a href="https://example.test/a">ok</a>', page)

    def test_release_notes_page_rejects_dashes_tokens_and_republishing(self):
        out = self.tmp / "page.html"
        self.assertEqual(self.notes_page(out, "- Sửa lỗi \u2014 Chrome").returncode, 1)
        self.assertEqual(self.notes_page(out, "- {{Unknown}}").returncode, 1)
        self.assertFalse(out.exists())
        self.assertEqual(self.notes_page(out).returncode, 0)
        self.assertEqual(self.notes_page(out).returncode, 1, "a published page is never overwritten")

    def test_release_notes_page_refuses_more_than_five_lines_prd_r51(self):
        # PRD-R51 is a MUST: at most five visible lines, the rest stays behind the changelog link.
        out = self.tmp / "long.html"
        result = self.notes_page(out, "\n".join(f"- dòng {i}" for i in range(7)))
        self.assertEqual(result.returncode, 1)
        self.assertIn("PRD-R51", result.stderr)
        self.assertFalse(out.exists())
        five = "### Đã sửa\n" + "\n".join(f"- dòng {i}" for i in range(5))
        self.assertEqual(self.notes_page(out, five).returncode, 0, "headings do not count as visible lines")
        english = self.notes_page(self.tmp / "long-en.html", "- một dòng", "\n".join(f"- line {i}" for i in range(6)))
        self.assertEqual(english.returncode, 1)
        self.assertIn("en notes", english.stderr)

    def test_release_notes_page_check_validates_without_writing(self):
        # publish-release runs --check before signing, so bad notes fail before the keychain prompt.
        def check(notes_vi):
            return self.helper("release-notes-page", "--check", "--app-name", "Test App", "--version", "1.2.3",
                               "--notes-vi", notes_vi, "--notes-en", "- Fixed")
        self.assertEqual(check("- Sửa lỗi").returncode, 0)
        self.assertEqual(check("\n".join(f"- dòng {i}" for i in range(6))).returncode, 1)
        self.assertEqual(check("- Sửa lỗi \u2013 Chrome").returncode, 1)
        self.assertEqual(check("- {{Unknown}}").returncode, 1)
        self.assertEqual(list(self.tmp.iterdir()), [])
        no_out = self.helper("release-notes-page", "--app-name", "Test App", "--version", "1.2.3",
                             "--notes-vi", "- a", "--notes-en", "- b")
        self.assertNotEqual(no_out.returncode, 0, "--out is required unless --check")

    def test_render_cask_and_zap(self):
        out = self.tmp / "cask.rb"
        result = self.helper(
            "render-cask", "--template", str(REPO / "packaging/homebrew/Casks/cask.rb.template"),
            "--zap", str(SCRIPTS / "zap-paths.txt"), "--folder", "Test App", "--bundle-id", "vn.example.test",
            "--out", str(out), "--slug", "testapp", "--app-name", "Test App", "--version", "1.2.3",
            "--sha256", "b" * 64, "--url", "https://example.test/testapp-1.2.3.dmg",
            "--site-host", "example.test", "--desc", "Vietnamese input method")
        self.assertEqual(result.returncode, 0, result.stderr)
        cask = out.read_text(encoding="utf-8")
        self.assertIn('cask "testapp" do', cask)
        self.assertIn('depends_on macos: ">= :sequoia"', cask)
        self.assertIn("auto_updates true", cask)
        self.assertIn('"~/Library/Application Support/Test App"', cask)
        self.assertIn('"~/Library/Preferences/vn.example.test.plist"', cask)
        self.assertIn('url "https://example.test/appcast.xml"', cask)
        self.assertNotIn("TEMPLATE:", cask)
        self.assertNotIn("{{", cask)

    def test_changelog_notes(self):
        changelog = self.tmp / "CHANGELOG.md"
        changelog.write_text("# Changelog\n\n## [1.1.0] - 2026-12-01\n- New\n\n## [1.0.0] - 2026-11-13\n- First\n",
                             encoding="utf-8")
        result = self.helper("changelog-notes", "--file", str(changelog), "--version", "1.0.0")
        self.assertEqual(result.stdout.strip(), "- First")


class BenchCompareTests(TempDirTestCase):
    def result(self, name, calibration, p50, p99, budget=True):
        metrics = {"event.p50": {"value": p50, "unit": "ns"}, "event.p99": {"value": p99, "unit": "ns"}}
        if budget:
            metrics["event.p50"]["budget"] = 5000
            metrics["event.p99"]["budget"] = 25000
        return self.write_json(name, {"formatVersion": 1, "benchmark": "engine",
                                      "calibration": {"name": "ref", "nanoseconds": calibration},
                                      "metrics": metrics})

    def compare(self, baseline, *results, extra=()):
        args = ["bash", str(SCRIPTS / "bench-compare.sh"), "--baseline", str(baseline),
                "--output", str(self.tmp / "median.json"), *extra]
        for item in results:
            args += ["--results", str(item)]
        return run(*args)

    def test_within_threshold_after_calibration(self):
        baseline = self.result("baseline.json", 1000, 1000, 5000)
        # This machine is twice as slow (calibration 2000): 2100 ns is +5 % after scaling.
        runs = [self.result(f"r{i}.json", 2000, 2100, 10000) for i in range(5)]
        result = self.compare(baseline, *runs)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

    def test_regression_over_20_percent_fails(self):
        baseline = self.result("baseline.json", 1000, 1000, 5000)
        runs = [self.result(f"r{i}.json", 1000, 1300, 5000) for i in range(5)]
        result = self.compare(baseline, *runs)
        self.assertEqual(result.returncode, 1)
        self.assertIn("REGRESSION", result.stdout)

    def test_over_budget_fails(self):
        baseline = self.result("baseline.json", 1000, 7000, 5000)
        runs = [self.result(f"r{i}.json", 1000, 7000, 5000) for i in range(3)]
        result = self.compare(baseline, *runs)
        self.assertEqual(result.returncode, 1)
        self.assertIn("OVER BUDGET", result.stdout)

    def test_median_is_used(self):
        baseline = self.result("baseline.json", 1000, 1000, 5000)
        runs = [self.result("a.json", 1000, 1000, 5000), self.result("b.json", 1000, 9000, 5000),
                self.result("c.json", 1000, 1050, 5000)]
        self.assertEqual(self.compare(baseline, *runs).returncode, 0)

    def pipeline_run(self, name, t1_p99, calibration=1000):
        # PLT-R820 pipeline benchmark: platform metrics are not calibrated, T1.p99 has the 100 us gate.
        return self.write_json(name, {"formatVersion": 1, "benchmark": "pipeline",
                                      "calibration": {"name": "reference-loop", "nanoseconds": calibration},
                                      "metrics": {"T1.p99": {"value": t1_p99, "unit": "ns", "budget": 100000,
                                                             "calibrated": False}}})

    def test_summary_names_the_benchmark(self):
        baseline = self.pipeline_run("baseline.json", 40000)
        result = self.compare(baseline, *[self.pipeline_run(f"r{i}.json", 41000) for i in range(3)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("### Pipeline benchmark (median of 3 runs)", result.stdout)
        self.assertNotIn("Engine benchmark", result.stdout)

    def test_pipeline_gate_at_25_percent_plt_r822(self):
        baseline = self.pipeline_run("baseline.json", 40000)
        args = ["--threshold", "25"]
        ok = self.compare(baseline, *[self.pipeline_run(f"a{i}.json", 49000) for i in range(5)], extra=args)
        self.assertEqual(ok.returncode, 0, ok.stdout + ok.stderr)  # +22.5 %, uncalibrated
        slow = self.compare(baseline, *[self.pipeline_run(f"b{i}.json", 51000) for i in range(5)], extra=args)
        self.assertEqual(slow.returncode, 1)
        self.assertIn("REGRESSION", slow.stdout)

    def test_without_a_baseline_the_budget_still_gates(self):
        missing = self.tmp / "no-baseline.json"
        within = self.compare(missing, self.pipeline_run("w.json", 120000), extra=["--threshold", "25"])
        self.assertEqual(within.returncode, 0, within.stdout + within.stderr)
        self.assertIn("baseline not found", within.stderr)
        over = self.compare(missing, self.pipeline_run("o.json", 130000), extra=["--threshold", "25"])
        self.assertEqual(over.returncode, 1)
        self.assertIn("OVER BUDGET", over.stdout)
        self.assertIn("exceeds the scaled budget", over.stderr)

    def test_update_baseline(self):
        baseline = self.tmp / "Benchmarks" / "baseline.json"
        run_file = self.result("r.json", 1000, 1000, 5000)
        result = run("bash", str(SCRIPTS / "bench-compare.sh"), "--baseline", str(baseline), "--results",
                     str(run_file), "--update-baseline", "--output", str(self.tmp / "m.json"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("referenceCalibration", baseline.read_text(encoding="utf-8"))


class MetricsTests(TempDirTestCase):
    def test_compute_from_fixture(self):
        data = {
            "repo": "o/r", "since": "2026-10-01", "until": "2026-10-31",
            "closed": [
                {"number": 1, "created_at": "2026-10-01T00:00:00Z", "closed_at": "2026-10-05T00:00:00Z",
                 "user": "u1", "labels": ["bug", "P1", "verified"]},
                {"number": 2, "created_at": "2026-10-02T00:00:00Z", "closed_at": "2026-10-20T00:00:00Z",
                 "user": "u2", "labels": ["compat", "P2", "closed-unverified", "reopened"]},
            ],
            "opened": [
                {"number": 1, "created_at": "2026-10-01T00:00:00Z", "closed_at": None, "user": "u1",
                 "labels": ["bug", "P1"]},
                {"number": 2, "created_at": "2026-10-02T00:00:00Z", "closed_at": None, "user": "u2",
                 "labels": ["compat", "resolution:setting-workaround"]},
            ],
            "details": {
                "1": {"events": [{"event": "labeled", "label": "fixed-in-beta", "created_at": "2026-10-03T00:00:00Z"}],
                      "comments": [{"author_association": "OWNER", "user": "pa", "created_at": "2026-10-01T06:00:00Z"}]},
                "2": {"events": [], "comments": [{"author_association": "NONE", "user": "x",
                                                   "created_at": "2026-10-02T01:00:00Z"}]},
            },
        }
        fixture = self.write_json("dump.json", data)
        result = py("metrics.py", "--fixture", str(fixture), "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        metrics = json.loads(result.stdout)
        self.assertEqual(metrics["reopenRate"], 0.5)
        self.assertEqual(metrics["verifiedCloses"], 1)
        self.assertEqual(metrics["unverifiedCloses"], 1)
        self.assertEqual(metrics["medianFirstResponseHours"], 6.0)
        self.assertEqual(metrics["medianTimeToFixHours"]["P1"], 48.0)
        self.assertEqual(metrics["medianTimeToFixHours"]["P2"], 432.0)
        self.assertEqual(metrics["compatShare"], 0.5)
        self.assertEqual(metrics["settingWorkarounds"], 1)
        markdown = py("metrics.py", "--fixture", str(fixture)).stdout
        self.assertIn("Reopen rate: 50.0 %", markdown)


class CompatStaleTests(TempDirTestCase):
    def test_stale_and_tier1(self):
        today = dt.date(2026, 11, 13)
        matrix = self.write_json("matrix.json", {"entries": [
            {"displayName": "Old", "bundleId": "a.b.old", "tier": 2, "lastVerified": "2026-06-01"},
            {"displayName": "T1", "bundleId": "a.b.t1", "tier": 1, "lastVerified": "2026-07-20"},
            {"displayName": "Fresh", "bundleId": "a.b.fresh", "tier": 1, "lastVerified": "2026-11-01"},
        ]})
        args = ["--matrix", str(matrix), "--today", today.isoformat()]
        report = py("compat-stale-report.py", *args)
        self.assertEqual(report.returncode, 0)
        self.assertIn("| Old |", report.stdout)
        self.assertIn("| T1 |", report.stdout)
        self.assertNotIn("| Fresh |", report.stdout)
        self.assertEqual(py("compat-stale-report.py", *args, "--release").returncode, 1)


class MatrixSchemaTests(TempDirTestCase):
    """compat/schema/matrix.schema.json is the source of truth for the matrix (QA-R17, compat/SCRIPT.md 5)."""

    SCHEMA = json.loads((REPO / "compat" / "schema" / "matrix.schema.json").read_text(encoding="utf-8"))

    def test_script_example_and_site_sample_follow_the_schema(self):
        script = (REPO / "compat" / "SCRIPT.md").read_text(encoding="utf-8")
        section = script[script.index("## 5. Add or update a row"):script.index("## 6. Cadence")]
        example = json.loads(section.split("```json\n", 1)[1].split("\n```", 1)[0])
        self.assertEqual(jsonschema_lite.validate(example, self.SCHEMA), [])
        sample = json.loads((REPO / "site" / "fixtures" / "matrix.json").read_text(encoding="utf-8"))
        self.assertEqual(jsonschema_lite.validate(sample, self.SCHEMA), [])

    def test_check_matrix(self):
        entry = {"bundleId": "com.example.A", "displayName": "A", "category": "chat", "status": "notVerified",
                 "issues": []}
        good = self.write_json("good.json", {"schemaVersion": 1, "entries": [entry]})
        self.assertEqual(py("check-matrix.py", "--matrix", str(good)).returncode, 0)
        works = dict(entry, status="works")
        bad = self.write_json("bad.json", {"schemaVersion": 1, "entries": [works, dict(entry, macOSVersion="27")]})
        result = py("check-matrix.py", "--matrix", str(bad))
        self.assertEqual(result.returncode, 1)
        self.assertIn("missing required property 'lastVerified'", result.stderr)  # works needs the evidence
        self.assertIn("unexpected property 'macOSVersion'", result.stderr)
        self.assertIn("bundleId com.example.A already used", result.stderr)
        self.assertEqual(py("check-matrix.py", "--matrix", str(self.tmp / "none.json")).returncode, 0)
        self.assertEqual(py("check-matrix.py", "--matrix", str(self.tmp / "none.json"), "--require").returncode, 1)
        # Scoped rows (web apps, in-app modes) may share a bundleId with the app row, never with each other.
        web = dict(entry, scope="webApp", displayName="Docs (web)")
        scoped = self.write_json("scoped.json", {"schemaVersion": 1, "entries": [entry, web, dict(web, displayName="Sheets (web)")]})
        self.assertEqual(py("check-matrix.py", "--matrix", str(scoped)).returncode, 0)
        twice = self.write_json("twice.json", {"schemaVersion": 1, "entries": [entry, web, web]})
        result = py("check-matrix.py", "--matrix", str(twice))
        self.assertEqual(result.returncode, 1)
        self.assertIn("scope webApp 'Docs (web)' already used", result.stderr)


class DependencyAuditTests(TempDirTestCase):
    def test_unpinned_dependency_fails_offline(self):
        package = self.tmp / "Pkg"
        package.mkdir()
        (package / "Package.swift").write_text('.package(url: "https://github.com/a/b", exact: "1.0.0")\n')
        (package / "Package.resolved").write_text(json.dumps({"pins": [
            {"identity": "b", "location": "https://github.com/a/b", "state": {"branch": "main", "revision": "abc"}},
            {"identity": "c", "location": "https://github.com/a/c", "state": {"version": "1.2.3", "revision": "def"}},
        ], "version": 2}))
        result = py("dependency-audit.py", "--offline", "--root", str(self.tmp))
        self.assertEqual(result.returncode, 1)
        self.assertIn("branch or revision", result.stderr)
        self.assertIn("| c | 1.2.3 | ok |", result.stdout)

    def test_the_app_may_pin_sparkle_only_plt_r104(self):
        """Config/Package.resolved is the app's resolved file (project.yml copies it into the generated project);
        any runtime dependency other than Sparkle fails the audit."""
        config = self.tmp / "Config"
        config.mkdir()
        (config / "Package.resolved").write_text(json.dumps({"pins": [
            {"identity": "sparkle", "location": "https://github.com/sparkle-project/Sparkle",
             "state": {"version": "2.10.1", "revision": "abc"}},
            {"identity": "extra", "location": "https://github.com/a/extra", "state": {"version": "1.0.0", "revision": "def"}},
        ], "version": 3}))
        result = py("dependency-audit.py", "--offline", "--root", str(self.tmp))
        self.assertEqual(result.returncode, 1)
        self.assertIn("Config/Package.resolved: extra is a runtime dependency of the app", result.stderr)
        self.assertIn("| sparkle | 2.10.1 | ok |", result.stdout)
        self.assertEqual(py("dependency-audit.py", "--offline").returncode, 0, "the repository's own pins pass")


if __name__ == "__main__":
    unittest.main(verbosity=1)
