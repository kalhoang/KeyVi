#!/usr/bin/env -S python3 -I
# SPDX-License-Identifier: LicenseRef-App-Pending
"""Validates the shipped compatibility rules file (spec/02-platform.md section 5).

Checks:
  - JSON Schema validation against compat/schema/ (PLT-R503) when a rules schema is present
  - unique rule ids; bundleGroup references exist
  - provenance (reason, evidence, at least one passing tested entry, addedIn) and a test scenario
    with automation automated|manual (PLT-R505)
  - reviewBy present, at most 12 months ahead; warning once passed; blocking in --release mode when
    passed more than 30 days ago (PLT-R506)
  - no two rules with identical match signatures (PLT-R521)
  - titlePattern only together with bundleIds, at most 200 characters, compiles (PLT-R502)
  - inlineCompletion "placeholder" never in defaults, a global rule or a title-only rule (PLT-R422)
  - strategy "paste" requires requiresUserOptIn: true (PLT-R460)
  - manual scenarios have a row in compat/matrix.json (PLT-R531, test.automation)

Usage:
  python3 -I scripts/check-rules.py [--rules FILE] [--schema FILE] [--matrix FILE]
                                    [--release] [--today YYYY-MM-DD] [--reviewby-report]
A missing rules file passes with a notice unless --require is given.
Exit status: 0 clean (warnings allowed), 1 errors, 2 usage or parse error.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.dont_write_bytecode = True  # keep scripts/lib free of __pycache__
sys.path.insert(0, str(REPO_ROOT / "scripts" / "lib"))
from jsonschema_lite import validate  # noqa: E402

REVIEW_MAX_AHEAD_DAYS = 366
REVIEW_BLOCK_AFTER_DAYS = 30
TITLE_PATTERN_MAX = 200
NARROWING_MATCH_KEYS = ("ax", "web")


class Report:
    def __init__(self) -> None:
        self.errors: list[str] = []
        self.warnings: list[str] = []

    def error(self, message: str) -> None:
        self.errors.append(message)

    def warn(self, message: str) -> None:
        self.warnings.append(message)


def canonical(value):
    """Order-insensitive canonical form of a match object (lists are sets for matching)."""
    if isinstance(value, dict):
        return {key: canonical(value[key]) for key in sorted(value)}
    if isinstance(value, list):
        return sorted((canonical(item) for item in value), key=lambda item: json.dumps(item, sort_keys=True))
    return value


def find_schema(explicit: str | None, kind: str) -> Path | None:
    if explicit:
        return Path(explicit)
    folder = REPO_ROOT / "compat" / "schema"
    if not folder.is_dir():
        return None
    candidates = sorted(p for p in folder.glob("*.json") if kind in p.name.lower())
    return candidates[0] if candidates else None


def parse_date(value) -> dt.date | None:
    if not isinstance(value, str):
        return None
    try:
        return dt.date.fromisoformat(value[:10])
    except ValueError:
        return None


def check_provenance(rule: dict, label: str, report: Report) -> None:
    provenance = rule.get("provenance")
    if not isinstance(provenance, dict):
        report.error(f"{label}: missing provenance (PLT-R505)")
        return
    if not str(provenance.get("reason", "")).strip():
        report.error(f"{label}: provenance.reason is empty")
    evidence = provenance.get("evidence")
    if not isinstance(evidence, list) or not evidence:
        report.error(f"{label}: provenance.evidence needs at least one entry")
    tested = provenance.get("tested")
    if not isinstance(tested, list) or not any(
        isinstance(item, dict) and str(item.get("result", "")).lower() == "pass" for item in tested
    ):
        report.error(f"{label}: provenance.tested needs at least one passing entry")
    if not str(provenance.get("addedIn", "")).strip():
        report.error(f"{label}: provenance.addedIn is missing")


def check_review_by(rule: dict, label: str, today: dt.date, release: bool, report: Report) -> None:
    provenance = rule.get("provenance") if isinstance(rule.get("provenance"), dict) else {}
    raw = provenance.get("reviewBy", rule.get("reviewBy"))
    review_by = parse_date(raw)
    if review_by is None:
        report.error(f"{label}: reviewBy missing or not a date (PLT-R506)")
        return
    if (review_by - today).days > REVIEW_MAX_AHEAD_DAYS:
        report.error(f"{label}: reviewBy {raw} is more than 12 months ahead (PLT-R506)")
    overdue = (today - review_by).days
    if overdue > REVIEW_BLOCK_AFTER_DAYS and release:
        report.error(f"{label}: reviewBy {raw} passed {overdue} days ago; blocks the release (PLT-R506)")
    elif overdue > 0:
        report.warn(f"{label}: reviewBy {raw} passed {overdue} days ago (PLT-R506)")


def check_test(rule: dict, label: str, matrix_text: str | None, report: Report) -> None:
    test = rule.get("test")
    if not isinstance(test, dict) or not str(test.get("scenario", "")).strip():
        report.error(f"{label}: test.scenario is missing (PLT-R505)")
        return
    automation = test.get("automation")
    if automation not in ("automated", "manual"):
        report.error(f"{label}: test.automation must be automated or manual")
    if automation == "manual":
        rule_id = rule.get("id", "")
        if matrix_text is None:
            report.warn(f"{label}: manual scenario but compat/matrix.json is missing (PLT-R531)")
        elif f'"{rule_id}"' not in matrix_text:
            report.error(f"{label}: manual scenario without a compat/matrix.json row (PLT-R531)")


def check_match(rule: dict, label: str, groups: dict, report: Report) -> None:
    match = rule.get("match") or {}
    if not isinstance(match, dict):
        report.error(f"{label}: match must be an object")
        return
    pattern = match.get("titlePattern")
    if pattern is not None:
        if not match.get("bundleIds"):
            report.error(f"{label}: titlePattern requires bundleIds (PLT-R502)")
        if not isinstance(pattern, str) or len(pattern) > TITLE_PATTERN_MAX:
            report.error(f"{label}: titlePattern must be a string of at most {TITLE_PATTERN_MAX} characters")
        else:
            try:
                re.compile(pattern)
            except re.error as error:
                report.error(f"{label}: titlePattern does not compile ({error})")
    group = match.get("bundleGroup")
    if group is not None and group not in groups:
        report.error(f"{label}: bundleGroup '{group}' is not defined in bundleGroups")


def check_action(rule: dict, label: str, report: Report) -> None:
    action = rule.get("action")
    if not isinstance(action, dict) or "strategy" not in action:
        report.error(f"{label}: action.strategy is required")
        return
    params = action.get("params") or {}
    match = rule.get("match") or {}
    if params.get("inlineCompletion") in ("placeholder", "axSelectionThenPlaceholder"):
        narrowing = any(match.get(key) for key in NARROWING_MATCH_KEYS)
        identity = match.get("bundleIds") or match.get("bundleGroup") or match.get("engines")
        if not match:
            report.error(f"{label}: placeholder in a global rule (PLT-R422)")
        elif match.get("titlePattern") and not narrowing:
            report.error(f"{label}: placeholder in a title-only rule (PLT-R422)")
        elif not narrowing and not identity:
            report.error(f"{label}: placeholder needs a scoped match (PLT-R422)")
    if action["strategy"] == "paste" and action.get("requiresUserOptIn") is not True:
        report.error(f"{label}: strategy paste requires requiresUserOptIn: true (PLT-R460)")


def check_document(doc: dict, schema: dict | None, matrix_text: str | None, today: dt.date,
                   release: bool) -> Report:
    report = Report()
    if schema is not None:
        for message in validate(doc, schema):
            report.error(f"schema: {message}")
    defaults = doc.get("defaults") or {}
    if (defaults.get("params") or {}).get("inlineCompletion") in ("placeholder", "axSelectionThenPlaceholder"):
        report.error("defaults: placeholder must not be enabled globally (PLT-R422)")
    groups = doc.get("bundleGroups") or {}
    rules = doc.get("rules")
    if not isinstance(rules, list):
        report.error("rules must be an array")
        return report
    seen_ids: dict[str, int] = {}
    signatures: dict[str, str] = {}
    for index, rule in enumerate(rules):
        if not isinstance(rule, dict):
            report.error(f"rules[{index}]: must be an object")
            continue
        rule_id = rule.get("id")
        label = f"rule {rule_id or f'#{index}'}"
        if not isinstance(rule_id, str) or not re.fullmatch(r"[A-Za-z0-9]+([._-][A-Za-z0-9]+)*", rule_id):
            report.error(f"rules[{index}]: id missing or not dotted")
        elif rule_id in seen_ids:
            report.error(f"{label}: duplicate id (also rules[{seen_ids[rule_id]}])")
        else:
            seen_ids[rule_id] = index
        if not str(rule.get("summary", "")).strip():
            report.error(f"{label}: summary is required")
        check_provenance(rule, label, report)
        check_review_by(rule, label, today, release, report)
        check_test(rule, label, matrix_text, report)
        check_match(rule, label, groups, report)
        check_action(rule, label, report)
        signature = json.dumps(canonical(rule.get("match") or {}), sort_keys=True)
        if signature in signatures:
            report.error(f"{label}: identical match signature to rule {signatures[signature]} (PLT-R521)")
        else:
            signatures[signature] = str(rule_id)
    return report


def review_report(doc: dict, today: dt.date) -> str:
    rows = []
    for rule in doc.get("rules", []):
        if not isinstance(rule, dict):
            continue
        provenance = rule.get("provenance") if isinstance(rule.get("provenance"), dict) else {}
        raw = provenance.get("reviewBy", rule.get("reviewBy"))
        date = parse_date(raw)
        days = (date - today).days if date else None
        if days is None:
            status = "invalid"
        elif days < -REVIEW_BLOCK_AFTER_DAYS:
            status = "BLOCKS RELEASE"
        elif days < 0:
            status = "overdue"
        elif days <= 60:
            status = "due soon"
        else:
            status = "ok"
        rows.append((days if days is not None else -10**6, rule.get("id", "?"), raw, status))
    rows.sort()
    lines = ["| Rule | reviewBy | Days left | Status |", "|---|---|---|---|"]
    lines += [f"| `{rid}` | {raw} | {days if days > -10**6 else 'n/a'} | {status} |" for days, rid, raw, status in rows]
    return "\n".join(lines)


def emit(report: Report) -> None:
    annotate = bool(os.environ.get("GITHUB_ACTIONS"))
    for message in report.warnings:
        print(f"::warning::{message}" if annotate else f"warning: {message}", file=sys.stderr)
    for message in report.errors:
        print(f"::error::{message}" if annotate else f"error: {message}", file=sys.stderr)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Validate compat/rules.json (PLT-R503 to PLT-R531).")
    parser.add_argument("--rules", default=str(REPO_ROOT / "compat" / "rules.json"))
    parser.add_argument("--schema", help="rules JSON Schema (default: compat/schema/*rules*.json)")
    parser.add_argument("--matrix", default=str(REPO_ROOT / "compat" / "matrix.json"))
    parser.add_argument("--release", action="store_true", help="release gate: overdue reviewBy blocks")
    parser.add_argument("--require", action="store_true", help="fail when the rules file is missing")
    parser.add_argument("--today", help="override today's date (YYYY-MM-DD), for tests")
    parser.add_argument("--reviewby-report", action="store_true", help="print a Markdown reviewBy table")
    args = parser.parse_args(argv)

    today = dt.date.fromisoformat(args.today) if args.today else dt.date.today()
    rules_path = Path(args.rules)
    if not rules_path.exists():
        print(f"check-rules: {rules_path} not found", file=sys.stderr)
        return 1 if args.require else 0
    try:
        doc = json.loads(rules_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"check-rules: cannot parse {rules_path}: {error}", file=sys.stderr)
        return 2
    if not isinstance(doc, dict):
        print("check-rules: rules file must be a JSON object", file=sys.stderr)
        return 2

    schema_path = find_schema(args.schema, "rules")
    schema = None
    if schema_path is not None:
        try:
            schema = json.loads(schema_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            print(f"check-rules: cannot parse schema {schema_path}: {error}", file=sys.stderr)
            return 2
    else:
        print("check-rules: no rules schema in compat/schema/; schema validation skipped", file=sys.stderr)

    matrix_path = Path(args.matrix)
    matrix_text = matrix_path.read_text(encoding="utf-8") if matrix_path.exists() else None

    if args.reviewby_report:
        print(review_report(doc, today))

    report = check_document(doc, schema, matrix_text, today, args.release)
    emit(report)
    count = len(doc.get("rules", [])) if isinstance(doc.get("rules"), list) else 0
    print(f"check-rules: {count} rule(s), {len(report.errors)} error(s), {len(report.warnings)} warning(s)",
          file=sys.stderr)
    return 1 if report.errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
