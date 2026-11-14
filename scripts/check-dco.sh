#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Developer Certificate of Origin check (docs/decisions/0006-app-licence-and-pro-edition.md, QA-R61,
# CLR-R14): every non-merge commit in BASE..HEAD must carry a `Signed-off-by:` trailer whose e-mail
# equals the commit author's e-mail (`git commit -s` writes it). The sign-off certifies the DCO 1.1 and
# affirms the inbound terms of CONTRIBUTING.md section 3 (every contribution, to an MPL-2.0 or a
# GPL-3.0-or-later part, is also licensed to the project under MIT), so it applies to every area of the
# repository.
#
# Inputs: --base and --head commits (ci.yml passes the pull request's base and head SHAs), --path
# (repeatable; limits the check to commits touching those paths; default: every path), --repo (tests).
# No environment variables.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/check-dco.sh --base REV --head REV [--path PATH] [--repo DIR]

  --base REV   first commit NOT to check (the pull request base)
  --head REV   last commit to check (the pull request head)
  --path PATH  only commits touching PATH are checked; repeatable (default: every commit)
  --repo DIR   git repository (default: this repository)
  -h, --help   show this help
Exit status: 0 every checked commit is signed off, 1 a sign-off is missing or does not match.
EOF
}

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

base=""
head=""
paths=()
repo="$REPO_ROOT"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --base) base="${2:?--base needs a value}"; shift 2 ;;
    --head) head="${2:?--head needs a value}"; shift 2 ;;
    --path) paths+=("${2:?--path needs a value}"); shift 2 ;;
    --repo) repo="${2:?--repo needs a value}"; shift 2 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ -n "$base" && -n "$head" ]] || { usage >&2; exit 2; }
require_cmd git
git -C "$repo" rev-parse --verify --quiet "$base^{commit}" >/dev/null || die "unknown base commit: $base"
git -C "$repo" rev-parse --verify --quiet "$head^{commit}" >/dev/null || die "unknown head commit: $head"

lower() { LC_ALL=C tr '[:upper:]' '[:lower:]'; }

checked=0
missing=()
while IFS= read -r commit; do
  [[ -n "$commit" ]] || continue
  checked=$((checked + 1))
  author="$(git -C "$repo" show -s --format='%an <%ae>' "$commit")"
  author_email="$(git -C "$repo" show -s --format='%ae' "$commit" | lower)"
  signoffs="$(git -C "$repo" show -s --format='%(trailers:key=Signed-off-by,valueonly)' "$commit")"
  matched=0
  while IFS= read -r line; do
    email="$(sed -n 's/.*<\([^>]*\)>.*/\1/p' <<<"$line" | lower)"
    [[ -n "$email" && "$email" == "$author_email" ]] && matched=1
  done <<<"$signoffs"
  if [[ $matched -eq 0 ]]; then
    missing+=("$(git -C "$repo" show -s --format='%h %s' "$commit") (expected: Signed-off-by: $author)")
  fi
done < <(git -C "$repo" rev-list --no-merges "$base..$head" -- ${paths[@]+"${paths[@]}"})

scope="every path"
[[ ${#paths[@]} -eq 0 ]] || scope="${paths[*]}"
if [[ ${#missing[@]} -gt 0 ]]; then
  for entry in "${missing[@]}"; do log "missing DCO sign-off: $entry"; done
  die "check-dco: ${#missing[@]} of $checked commit(s) touching $scope lack a matching Signed-off-by (ADR 0006, CONTRIBUTING.md section 3); amend with 'git commit --amend -s' or 'git rebase --signoff $base'"
fi
info "check-dco: $checked commit(s) touching $scope, all signed off"
