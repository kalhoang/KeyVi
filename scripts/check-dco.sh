#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Developer Certificate of Origin check (docs/decisions/0401-interim-contribution-policy.md, QA-R61,
# CLR-R14): every non-merge commit in BASE..HEAD that touches the MPL-2.0 engine packages must carry a
# `Signed-off-by:` trailer whose e-mail equals the commit author's e-mail (`git commit -s` writes it).
# Commits that touch neither path are not checked.
#
# Inputs: --base and --head commits (ci.yml passes the pull request's base and head SHAs), --path
# (repeatable; default Packages/VietnameseEngine and Packages/VietnameseEngineFuzz, the MPL-2.0 packages of
# CONTRIBUTING.md section 3), --repo (tests). No environment variables.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/check-dco.sh --base REV --head REV [--path PATH] [--repo DIR]

  --base REV   first commit NOT to check (the pull request base)
  --head REV   last commit to check (the pull request head)
  --path PATH  only commits touching PATH are checked; repeatable (default Packages/VietnameseEngine
               and Packages/VietnameseEngineFuzz)
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
[[ ${#paths[@]} -gt 0 ]] || paths=(Packages/VietnameseEngine Packages/VietnameseEngineFuzz)
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
done < <(git -C "$repo" rev-list --no-merges "$base..$head" -- "${paths[@]}")

if [[ ${#missing[@]} -gt 0 ]]; then
  for entry in "${missing[@]}"; do log "missing DCO sign-off: $entry"; done
  die "check-dco: ${#missing[@]} of $checked commit(s) touching ${paths[*]} lack a matching Signed-off-by (ADR 0401); amend with 'git commit --amend -s' or 'git rebase --signoff $base'"
fi
info "check-dco: $checked commit(s) touching ${paths[*]}, all signed off"
