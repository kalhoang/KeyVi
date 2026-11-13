#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Pull request label gate, run by .github/workflows/pr-labels.yml:
#   - QA-R6: a change that removes or rewrites a line of an engine corpus file (an expected output changes)
#     needs the label `corpus-change`; adding new cases does not. The generated corpus files are exempt,
#     because ci.yml already checks them against their generators (generate-layout-corpus.py and
#     extract-spec-examples.py --check).
#   - QA-R15: any change to a benchmark baseline needs the label `perf-baseline`.
#
# Inputs: --base and --head commits (the pull request's base and head SHAs; the diff is base...head),
# --labels (comma-separated label names of the pull request), --repo (tests). No environment variables.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/check-pr-labels.sh --base REV --head REV --labels LIST [--repo DIR]

  --base REV     the pull request base
  --head REV     the pull request head
  --labels LIST  comma-separated label names of the pull request (may be empty)
  --repo DIR     git repository (default: this repository)
  -h, --help     show this help
Exit status: 0 every change carries its label, 1 a label is missing.
EOF
}

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

CORPUS_DIR="Packages/VietnameseEngine/Tests/VietnameseEngineTests/Corpus/"
GENERATED_CORPUS=(layouts.tsv worked-examples.tsv commit-decisions.tsv restore-toggle.tsv commit-fixtures.tsv)
BASELINES=(
  Packages/VietnameseEngine/Benchmarks/baseline.json
  Packages/AppCore/Benchmarks/pipeline-baseline.json
  Packages/AppCore/Benchmarks/platform-baseline.json
  perf/platform-baseline.json
)

base=""
head=""
labels=""
labels_given=0
repo="$REPO_ROOT"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --base) base="${2:?--base needs a value}"; shift 2 ;;
    --head) head="${2:?--head needs a value}"; shift 2 ;;
    --labels) labels="${2-}"; labels_given=1; shift 2 ;;
    --repo) repo="${2:?--repo needs a value}"; shift 2 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ -n "$base" && -n "$head" && $labels_given -eq 1 ]] || { usage >&2; exit 2; }
require_cmd git
git -C "$repo" rev-parse --verify --quiet "$base^{commit}" >/dev/null || die "unknown base commit: $base"
git -C "$repo" rev-parse --verify --quiet "$head^{commit}" >/dev/null || die "unknown head commit: $head"

has_label() { [[ ",$labels," == *",$1,"* ]]; }
generated() {
  local name
  for name in "${GENERATED_CORPUS[@]}"; do [[ "$1" == "$CORPUS_DIR$name" ]] && return 0; done
  return 1
}

# --numstat prints "added<TAB>deleted<TAB>path"; a deleted line means an existing case changed or went away.
rewritten=()
while IFS=$'\t' read -r _ deleted path; do
  [[ -n "$path" ]] || continue
  generated "$path" && continue
  [[ "$deleted" == "0" ]] || rewritten+=("$path")
done < <(git -C "$repo" diff --numstat --no-renames "$base...$head" -- "$CORPUS_DIR")

baselines=()
while IFS= read -r path; do
  [[ -n "$path" ]] && baselines+=("$path")
done < <(git -C "$repo" diff --name-only --no-renames "$base...$head" -- "${BASELINES[@]}")

problems=()
if [[ ${#rewritten[@]} -gt 0 ]] && ! has_label corpus-change; then
  problems+=("expected outputs changed in ${rewritten[*]}: add the label corpus-change and give the reason in the description (QA-R6)")
fi
if [[ ${#baselines[@]} -gt 0 ]] && ! has_label perf-baseline; then
  problems+=("benchmark baseline changed in ${baselines[*]}: add the label perf-baseline and give the reason in the description (QA-R15)")
fi

if [[ ${#problems[@]} -gt 0 ]]; then
  for problem in "${problems[@]}"; do
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then printf '::error::%s\n' "$problem"; else log "error: $problem"; fi
  done
  exit 1
fi
info "labels ok: ${#rewritten[@]} rewritten corpus file(s), ${#baselines[@]} baseline file(s)"
