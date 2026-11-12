#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-App-Pending
#
# Opens one GitHub issue per new fuzzing finding with the minimised input (QA-R8 nightly). A finding
# is identified by the SHA-256 of its minimised input; an open issue that already names that hash is
# not duplicated. Inputs come from the fuzzer (random bytes), never from users.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/fuzz-report-issue.sh <findings.txt> [--repo OWNER/NAME] [--dry-run]

findings.txt is written by scripts/fuzz.sh: one "<product><TAB><minimised file>" line per finding.
Needs GH_TOKEN with issues: write. --dry-run prints the issues instead of creating them.
EOF
}

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

findings=""
repo="${GITHUB_REPOSITORY:-}"
dry_run=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --repo) repo="${2:?}"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -*) usage >&2; exit 2 ;;
    *) findings="$1"; shift ;;
  esac
done
[[ -n "$findings" ]] || { usage >&2; exit 2; }
[[ -s "$findings" ]] || { info "no findings"; exit 0; }
repo_args=()
[[ -n "$repo" ]] && repo_args=(--repo "$repo")
run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"

while IFS=$'\t' read -r product file; do
  [[ -f "$file" ]] || continue
  hash="$(sha256_of "$file")"
  short="${hash:0:16}"
  title="Fuzzing finding in $product ($short)"
  if [[ $dry_run -eq 0 ]]; then
    existing="$(gh issue list ${repo_args[@]+"${repo_args[@]}"} --state open --search "$short in:title" \
      --json number --jq 'length')"
    if [[ "$existing" != "0" ]]; then
      info "already reported: $short"
      continue
    fi
  fi
  body="$(mktemp)"
  # Backticks below are Markdown code spans, not shell expansions.
  # shellcheck disable=SC2016
  {
    printf 'Nightly fuzzing (%s) found an input that crashes, hangs or trips a sanitizer.\n\n' "$product"
    printf -- '- Minimised input SHA-256: `%s`\n' "$hash"
    printf -- '- Size: %s bytes\n' "$(wc -c <"$file" | tr -d ' ')"
    printf -- '- Run: %s (artifact `fuzz-findings`)\n\n' "$run_url"
    printf 'Minimised input (hex, first 4096 bytes):\n\n```\n'
    head -c 4096 "$file" | od -An -tx1 -v | tr -s ' ' | sed 's/^ //'
    printf '```\n\nWhen fixed, add the sequence to the `crash-regressions` corpus (QA-R8) and reference this issue (QA-R3).\n'
  } >"$body"
  if [[ $dry_run -eq 1 ]]; then
    info "would open: $title"
    cat "$body"
  else
    gh issue create ${repo_args[@]+"${repo_args[@]}"} --title "$title" --body-file "$body" \
      --label bug --label area:engine
  fi
  rm -f "$body"
done <"$findings"
