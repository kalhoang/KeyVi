#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""QA-R2: line coverage of the engine core target (Sources/VietnameseEngine) from the JSON that
`swift test --enable-code-coverage` writes (llvm-cov export format). Fails below the threshold.

Usage: python3 -I Scripts/coverage.py CODECOV.json [--threshold 95] [--files]
"""

import argparse
import json
import sys

CORE = "/Sources/VietnameseEngine/"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("codecov")
    parser.add_argument("--threshold", type=float, default=95.0)
    parser.add_argument("--files", action="store_true", help="print every file")
    args = parser.parse_args()
    with open(args.codecov, encoding="utf-8") as handle:
        data = json.load(handle)
    files = [f for f in data["data"][0]["files"] if CORE in f["filename"]]
    if not files:
        print("no core sources in the coverage data")
        return 1
    count = sum(f["summary"]["lines"]["count"] for f in files)
    covered = sum(f["summary"]["lines"]["covered"] for f in files)
    regions = sum(f["summary"]["regions"]["count"] for f in files)
    regions_covered = sum(f["summary"]["regions"]["covered"] for f in files)
    if args.files:
        for f in sorted(files, key=lambda f: f["summary"]["lines"]["percent"]):
            lines = f["summary"]["lines"]
            print(f"{lines['percent']:7.2f} %  {lines['count'] - lines['covered']:3} missed  "
                  f"{f['filename'].split(CORE)[1]}")
    percent = 100.0 * covered / count
    print(f"engine core line coverage: {percent:.2f} % ({covered} of {count} lines, {len(files)} files); "
          f"regions {100.0 * regions_covered / regions:.2f} %; threshold {args.threshold:.0f} % (QA-R2)")
    return 0 if percent >= args.threshold else 1


if __name__ == "__main__":
    sys.exit(main())
