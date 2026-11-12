#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-App-Pending
#
# PLT-R902: the logging API is typed and string interpolation into log calls is forbidden, so typed
# content can never reach a log by accident (PLT-R901, ENG-R1220). Flags Swift lines where a log-like
# call receives a string literal containing `\(`:
#   os_log(...), os_signpost(...), NSLog(...), print(...) / debugPrint(...) in shipped targets,
#   <something>log<something>.<level>(...) such as logger.info, log.event, Self.log.error.
#
# Exemptions (docs/decisions/0505-lint-contracts.md):
#   - test code: */Tests/*, *Tests/*, */Fixtures/*
#   - executables that print to a terminal by design (lexicon-builder, benchmark, CompatHarness,
#     fuzz drivers): print(...) is allowed there, log calls are still checked
#   - inside Packages/AppCore/Sources/Diagnostics/ only, a line carrying
#     `lint:allow-log-interpolation <reason>` (the typed logger's own os_log bridge)
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/lint-log-interpolation.sh [--root DIR] [FILE...]

Fails when string interpolation is passed to a log call (PLT-R902).
Options:
  --root DIR   repository root to scan (default: this repository)
  -h, --help   show this help
Exit status: 0 clean, 1 findings, 2 usage error.
EOF
}

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

root="$REPO_ROOT"
files=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --root) root="${2:?--root needs a value}"; shift 2 ;;
    --) shift; files+=("$@"); break ;;
    -*) usage >&2; exit 2 ;;
    *) files+=("$1"); shift ;;
  esac
done

if [[ ${#files[@]} -eq 0 ]]; then
  while IFS= read -r f; do files+=("$f"); done < <(swift_files_in "$root")
fi
if [[ ${#files[@]} -eq 0 ]]; then
  info "lint-log-interpolation: no Swift files"
  exit 0
fi

py - "$root" "${files[@]}" <<'PY'
import os
import re
import sys

root, *files = sys.argv[1:]

TEST_PATH = re.compile(r"(^|/)(Tests|[A-Za-z]+Tests|Fixtures|fixtures)/|(^|/)\.build[^/]*/")
CLI_PATH = re.compile(r"(^|/)Sources/(lexicon-builder|[A-Za-z-]*[Bb]enchmark[A-Za-z-]*|CompatHarness|"
                      r"[A-Za-z-]*[Ff]uzz[A-Za-z-]*)/|^Packages/VietnameseEngineFuzz/")
DIAGNOSTICS_PATH = re.compile(r"^Packages/AppCore/Sources/Diagnostics/")
MARKER = re.compile(r"lint:allow-log-interpolation\s+\S+")

# A log-like call on this line followed (anywhere later on the line) by a literal with \( ... ).
LOG_CALL = re.compile(
    r"(\bos_log\s*\(|\bos_signpost\s*\(|\bNSLog\s*\(|"
    r"\b\w*[Ll]og(?:ger)?\w*\s*\.\s*(?:trace|debug|info|notice|warning|error|critical|fault|log|"
    r"event|record|health|write)\s*\()"
)
PRINT_CALL = re.compile(r"(?<![\w.])(print|debugPrint|dump)\s*\(")
INTERPOLATION = re.compile(r'"[^"\n]*\\\(')



def strip_comment(line):
    """Returns the code part of a line: everything before a // that is not inside a string."""
    in_string = False
    escaped = False
    for index, char in enumerate(line):
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
        elif char == '"':
            in_string = True
        elif line.startswith("//", index):
            return line[:index]
    return line


findings = 0
for rel in files:
    rel = rel.removeprefix("./")
    if TEST_PATH.search(rel):
        continue
    try:
        with open(os.path.join(root, rel), encoding="utf-8") as handle:
            lines = handle.readlines()
    except (OSError, UnicodeDecodeError) as error:
        print(f"{rel}: cannot read ({error})", file=sys.stderr)
        findings += 1
        continue
    is_cli = bool(CLI_PATH.search(rel))
    for number, line in enumerate(lines, 1):
        code = strip_comment(line)
        if not code:
            continue
        hits = []
        for call in LOG_CALL.finditer(code):
            if INTERPOLATION.search(code, call.end()):
                hits.append("log call")
                break
        if not is_cli:
            for call in PRINT_CALL.finditer(code):
                if INTERPOLATION.search(code, call.end()):
                    hits.append(f"{call.group(1)}()")
                    break
        if not hits:
            continue
        if DIAGNOSTICS_PATH.search(rel) and MARKER.search(line):
            continue
        print(f"{rel}:{number}: string interpolation passed to {hits[0]} (PLT-R902: use the typed "
              f"logging API with enumerated fields)")
        findings += 1

if findings:
    print(f"lint-log-interpolation: {findings} finding(s)", file=sys.stderr)
    sys.exit(1)
print("lint-log-interpolation: clean", file=sys.stderr)
PY
