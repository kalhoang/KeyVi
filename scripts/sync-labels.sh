#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Synchronises repository labels (QA-R45) from .github/labels.yml with the GitHub CLI.
# Dry run by default; --apply creates or updates labels; --prune also deletes labels that are not in
# the file (except app:*, macos:*, arch:* and method:* labels created by the diagnostics workflow).
#
# File format (a strict YAML subset, parsed without third-party modules):
#   - name: bug
#     color: d73a4a
#     description: Something does not work
# Keys: name (required), color (6 hex digits, required), description (optional, single line).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/sync-labels.sh [--file FILE] [--repo OWNER/NAME] [--apply] [--prune]

  --file FILE   label definitions (default .github/labels.yml)
  --repo R      repository (default: current gh repository)
  --apply       create or update labels (default: dry run, prints the plan)
  --prune       with --apply, delete labels missing from the file (auto labels are kept)
  -h, --help    show this help
EOF
}

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

file="$REPO_ROOT/.github/labels.yml"
repo=""
apply=0
prune=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --file) file="${2:?}"; shift 2 ;;
    --repo) repo="${2:?}"; shift 2 ;;
    --apply) apply=1; shift ;;
    --prune) prune=1; shift ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ -f "$file" ]] || die "label file not found: $file"

plan="$(mktemp)"
trap 'rm -f "$plan"' EXIT
py - "$file" >"$plan" <<'PY'
import re
import sys

labels = []
current = None
with open(sys.argv[1], encoding="utf-8") as handle:
    for number, raw in enumerate(handle, 1):
        line = raw.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = re.match(r"^(-\s+|\s+)(name|color|description):\s*(.*)$", line)
        if not match:
            raise SystemExit(f"labels.yml:{number}: unsupported syntax: {line!r}")
        prefix, key, value = match.groups()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        if prefix.startswith("-"):
            current = {}
            labels.append(current)
        if current is None:
            raise SystemExit(f"labels.yml:{number}: key outside a list item")
        current[key] = value

names = set()
for label in labels:
    name = label.get("name", "")
    color = label.get("color", "").lstrip("#").lower()
    if not name or len(name) > 50:
        raise SystemExit(f"labels.yml: invalid name {name!r}")
    if not re.fullmatch(r"[0-9a-f]{6}", color):
        raise SystemExit(f"labels.yml: invalid color for {name!r}")
    if name in names:
        raise SystemExit(f"labels.yml: duplicate label {name!r}")
    names.add(name)
    description = label.get("description", "").replace("\t", " ")[:100]
    print(f"{name}\t{color}\t{description}")
PY

count="$(wc -l <"$plan" | tr -d ' ')"
info "$count label(s) in $(basename "$file")"
repo_args=()
if [[ $apply -eq 1 ]]; then
  require_cmd gh
  [[ -n "$repo" ]] && repo_args=(--repo "$repo")
fi

while IFS=$'\t' read -r name color description; do
  if [[ $apply -eq 1 ]]; then
    gh label create "$name" --color "$color" --description "$description" --force ${repo_args[@]+"${repo_args[@]}"} >/dev/null
    log "synced: $name"
  else
    log "would sync: $name (#$color) $description"
  fi
done <"$plan"

if [[ $prune -eq 1 ]]; then
  if [[ $apply -eq 0 ]]; then
    info "dry run: --prune has effect only with --apply"
  else
    while IFS= read -r existing; do
      case "$existing" in
        app:* | macos:* | arch:* | method:*) continue ;;
      esac
      if ! grep -Fxq -- "$existing" <<<"$(cut -f1 "$plan")"; then
        gh label delete "$existing" --yes ${repo_args[@]+"${repo_args[@]}"}
        log "deleted: $existing"
      fi
    done < <(gh label list --limit 500 --json name --jq '.[].name' ${repo_args[@]+"${repo_args[@]}"})
  fi
fi
[[ $apply -eq 1 ]] || info "dry run complete; re-run with --apply to change labels"
