#!/usr/bin/env -S python3 -I
# SPDX-License-Identifier: LicenseRef-App-Pending
"""Stale compatibility rows report (QA-R19, PLT-R531, section 13.3).

Lists compat/matrix.json entries whose last verification is older than 120 days (they display as
"Chưa kiểm tra" on the website and in the next build) and Tier 1 entries older than 90 days (a
release blocker for Tier 1 apps). Field names follow the site loader: lastVerified (or verifiedAt,
date), tier, displayName (or name, app), bundleId.

Usage: python3 -I scripts/compat-stale-report.py [--matrix FILE] [--today YYYY-MM-DD] [--release]
--release exits 1 when a Tier 1 entry is older than 90 days (release gate, section 13.8).
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
STALE_DAYS = 120
TIER1_DAYS = 90


def entries_of(doc) -> list:
    if isinstance(doc, list):
        return doc
    if isinstance(doc, dict):
        for key in ("entries", "apps", "rows", "items"):
            if isinstance(doc.get(key), list):
                return doc[key]
    return []


def verified_date(entry: dict) -> dt.date | None:
    raw = entry.get("lastVerified") or entry.get("verifiedAt") or entry.get("date")
    try:
        return dt.date.fromisoformat(str(raw)[:10]) if raw else None
    except ValueError:
        return None


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Report stale compatibility matrix rows (QA-R19).")
    parser.add_argument("--matrix", default=str(REPO_ROOT / "compat" / "matrix.json"))
    parser.add_argument("--today")
    parser.add_argument("--release", action="store_true")
    args = parser.parse_args(argv)
    today = dt.date.fromisoformat(args.today) if args.today else dt.date.today()

    path = Path(args.matrix)
    if not path.exists():
        print(f"compat-stale-report: {path} not found; nothing to report", file=sys.stderr)
        return 0
    entries = entries_of(json.loads(path.read_text(encoding="utf-8")))
    stale, tier1 = [], []
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        name = entry.get("displayName") or entry.get("name") or entry.get("app") or entry.get("bundleId") or "?"
        date = verified_date(entry)
        age = (today - date).days if date else None
        tier = int(entry.get("tier") or 0) if str(entry.get("tier") or "0").isdigit() else 0
        row = (age if age is not None else 10**6, name, entry.get("bundleId", ""), tier, date.isoformat() if date else "never")
        if age is None or age > STALE_DAYS:
            stale.append(row)
        if tier == 1 and (age is None or age > TIER1_DAYS):
            tier1.append(row)

    def table(rows):
        out = ["| App | Bundle ID | Tier | Last verified | Age (days) |", "|---|---|---|---|---|"]
        out += [f"| {n} | `{b}` | {t or '-'} | {d} | {'n/a' if a == 10**6 else a} |" for a, n, b, t, d in sorted(rows, reverse=True)]
        return "\n".join(out)

    text = [f"### Compatibility matrix freshness ({len(entries)} entries, {today.isoformat()})", ""]
    text += [f"Entries older than {STALE_DAYS} days (shown as \"Chưa kiểm tra\"): {len(stale)}", ""]
    if stale:
        text += [table(stale), ""]
    text += [f"Tier 1 entries older than {TIER1_DAYS} days (block a release): {len(tier1)}", ""]
    if tier1:
        text += [table(tier1), ""]
    report = "\n".join(text) + "\n"
    print(report)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(report)
    return 1 if (args.release and tier1) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
