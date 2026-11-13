# SPDX-License-Identifier: LicenseRef-App-Pending
"""Self-tests for the Python release and lint scripts. Run: python3 -I scripts/tests/test_scripts.py"""
from __future__ import annotations

import datetime as dt
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPTS = REPO / "scripts"
sys.dont_write_bytecode = True  # keep scripts/lib free of __pycache__
sys.path.insert(0, str(SCRIPTS / "lib"))

import jsonschema_lite  # noqa: E402


def run(*args: str, env: dict | None = None, check: bool = False) -> subprocess.CompletedProcess:
    merged = dict(os.environ)
    merged.pop("GITHUB_ACTIONS", None)
    merged.pop("GITHUB_STEP_SUMMARY", None)
    merged.update(env or {})
    return subprocess.run(list(args), capture_output=True, text=True, env=merged, check=check)


def py(script: str, *args: str, env: dict | None = None) -> subprocess.CompletedProcess:
    return run(sys.executable, "-I", str(SCRIPTS / script), *args, env=env)


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
        for form in ("bug.yml", "compatibility.yml"):
            with self.subTest(form=form):
                field = self.field(form, "diagnostics")
                self.assertTrue(field.startswith("textarea\n"), field[:40])
                self.assertNotIn("render:", field)
                self.assertIn("`<slug>-diagnostics v1`", field)


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
        # The page is what the in-app update window shows: no donation line (PRD-R57), no scripts or styles.
        for forbidden in ("ung-ho", "donate", "<script", "<style", "{{"):
            self.assertNotIn(forbidden, page)

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

    def compare(self, baseline, *results):
        args = ["bash", str(SCRIPTS / "bench-compare.sh"), "--baseline", str(baseline),
                "--output", str(self.tmp / "median.json")]
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


if __name__ == "__main__":
    unittest.main(verbosity=1)
