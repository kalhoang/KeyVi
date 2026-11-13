#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Checks that TRACEABILITY.md has a row for every ENG-R, ENG-T and REG identifier of spec/01-engine.md and
no row for an identifier the spec does not define. Usage: python3 -I Scripts/check-traceability.py"""

import pathlib
import re
import sys

PACKAGE = pathlib.Path(__file__).resolve().parent.parent
SPEC = PACKAGE.parent.parent / "spec" / "01-engine.md"
TABLE = PACKAGE / "TRACEABILITY.md"
IDENTIFIER = re.compile(r"\b(ENG-R\d+|ENG-T\d+|REG-\d+)\b")


def main():
    spec = set(IDENTIFIER.findall(SPEC.read_text(encoding="utf-8")))
    rows = set(re.findall(r"^\| (ENG-R\d+|ENG-T\d+|REG-\d+) \|", TABLE.read_text(encoding="utf-8"), re.MULTILINE))
    missing = sorted(spec - rows)
    unknown = sorted(rows - spec)
    for identifier in missing:
        print(f"missing row: {identifier}")
    for identifier in unknown:
        print(f"row for an identifier not in the spec: {identifier}")
    print(f"{len(spec)} identifiers in the spec, {len(rows)} rows")
    return 1 if missing or unknown else 0


if __name__ == "__main__":
    sys.exit(main())
