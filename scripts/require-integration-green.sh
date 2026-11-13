#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Release gate (QA-R30 step 1): the latest integration.yml run on the tagged commit must be green.
# Waits while a run on that commit is queued or in progress (the tag push itself starts one).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/require-integration-green.sh <commit-sha> [--workflow FILE] [--timeout-minutes N]
                                            [--repo OWNER/NAME]

Uses the GitHub CLI (GH_TOKEN with actions: read). Fails when there is no run for the commit after
the wait, or when the latest completed run did not succeed.
Defaults: --workflow integration.yml, --timeout-minutes 150.
EOF
}

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

sha=""
workflow="integration.yml"
timeout_min=150
repo="${GITHUB_REPOSITORY:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --workflow) workflow="${2:?}"; shift 2 ;;
    --timeout-minutes) timeout_min="${2:?}"; shift 2 ;;
    --repo) repo="${2:?}"; shift 2 ;;
    -*) usage >&2; exit 2 ;;
    *) sha="$1"; shift ;;
  esac
done
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "a full 40-character commit SHA is required"
[[ "$timeout_min" =~ ^[0-9]+$ ]] || die "--timeout-minutes must be an integer"
require_cmd gh
repo_args=()
[[ -n "$repo" ]] && repo_args=(--repo "$repo")

deadline=$(($(date +%s) + timeout_min * 60))
while :; do
  latest="$(gh run list ${repo_args[@]+"${repo_args[@]}"} --workflow "$workflow" --commit "$sha" \
    --limit 20 --json databaseId,status,conclusion,createdAt,event,url \
    --jq 'sort_by(.createdAt) | last // empty | [.databaseId, .status, (.conclusion // ""), .url] | @tsv')"
  if [[ -z "$latest" ]]; then
    state="none"
  else
    IFS=$'\t' read -r run_id status conclusion url <<<"$latest"
    state="$status"
  fi
  if [[ "$state" == "completed" ]]; then
    if [[ "$conclusion" == "success" ]]; then
      info "integration run $run_id on $sha succeeded ($url)"
      exit 0
    fi
    die "latest integration run $run_id on $sha concluded '$conclusion' ($url); fix it or re-run it before releasing"
  fi
  if (($(date +%s) >= deadline)); then
    if [[ "$state" == "none" ]]; then
      die "no $workflow run found for $sha; start one (workflow_dispatch on the tag) and re-run the release"
    fi
    die "integration run $run_id on $sha still '$state' after ${timeout_min} minutes"
  fi
  info "integration status for $sha: $state; waiting"
  sleep 60
done
