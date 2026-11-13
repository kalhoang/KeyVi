#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Downloads the raw sources listed in data/inputs/english/SOURCES.tsv and data/inputs/legal/SOURCES.tsv
# into data/cache/ (gitignored) and verifies each file against its pinned SHA-256 (ENG-R810).
#
# usage: data/fetch.sh [--verify-only] [--force]
#   --verify-only  do not download; only check the files already in data/cache/
#   --force        download again even when a cached file already matches
#
# After a successful fetch, `lexicon-builder import scowl` and `lexicon-builder import legal` regenerate
# the committed inputs; `git diff --stat data/` then shows whether anything changed upstream.
set -euo pipefail

data_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cache_dir="$data_dir/cache"
verify_only=false
force=false
for argument in "$@"; do
  case "$argument" in
    --verify-only) verify_only=true ;;
    --force) force=true ;;
    *) echo "usage: $0 [--verify-only] [--force]" >&2; exit 2 ;;
  esac
done

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

failures=0
checked=0
for sources in "$data_dir/inputs/english/SOURCES.tsv" "$data_dir/inputs/legal/SOURCES.tsv"; do
  while IFS=$'\t' read -r id file url sha256 bytes _rest; do
    [[ -z "$id" || "$id" == \#* || "$id" == "id" ]] && continue
    target="$cache_dir/$file"
    checked=$((checked + 1))
    if [[ -f "$target" && "$force" == false && "$(sha256_of "$target")" == "$sha256" ]]; then
      echo "ok       $file"
      continue
    fi
    if [[ "$verify_only" == true ]]; then
      echo "MISSING  $file (or checksum mismatch)" >&2
      failures=$((failures + 1))
      continue
    fi
    mkdir -p "$(dirname "$target")"
    partial="$target.partial"
    if ! curl --fail --silent --show-error --location --retry 3 --max-time 300 --output "$partial" "$url"; then
      echo "FAILED   $file: download error from $url" >&2
      rm -f "$partial"
      failures=$((failures + 1))
      continue
    fi
    actual="$(sha256_of "$partial")"
    if [[ "$actual" != "$sha256" ]]; then
      echo "FAILED   $file: SHA-256 $actual, pinned $sha256 (upstream changed; review before re-pinning)" >&2
      mv "$partial" "$target.mismatch"
      failures=$((failures + 1))
      continue
    fi
    mv "$partial" "$target"
    echo "fetched  $file ($bytes bytes)"
  done < "$sources"
done

echo "$checked sources checked, $failures failed"
[[ "$failures" -eq 0 ]]
