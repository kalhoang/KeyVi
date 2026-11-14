#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Render-only screenshots of the Settings window (W8-D). Builds the SettingsSnapshots test bundle (project.yml) and
# runs it: every pane in vi and en, light and dark, at the minimum and a larger size, drawn offscreen with
# cacheDisplay. Safe on a developer's own Mac: no app is launched, no window is shown, no event tap, permission
# request or synthetic event, and the run ends by itself. PNGs land in OUT/LABEL/ with OUT/index.md listing them.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/snapshots/settings.sh [--label NAME] [--baseline] [--out DIR] [--derived-data DIR] [--jobs N]
                                    [--only TEXT] [--no-generate]

  --label NAME         folder name for this run under OUT (default: after)
  --baseline           build the driver for sources older than the redesign (SETTINGS_SNAPSHOT_BASELINE)
  --out DIR            output folder (default: $TMPDIR/settings-snapshots)
  --derived-data DIR   xcodebuild derived data (default: /tmp/settings-snapshots-dd)
  --jobs N             xcodebuild -jobs (default: 3)
  --only TEXT          render only the images whose name contains TEXT (keeps the other images of the label)
  --no-generate        skip xcodegen generate (App.xcodeproj already current)
  -h, --help           show this help
EOF
}

label="after"
baseline=0
out="${TMPDIR:-/tmp}/settings-snapshots"
derived="/tmp/settings-snapshots-dd"
jobs=3
generate=1
only=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --label) label="${2:?--label needs a value}"; shift 2 ;;
    --baseline) baseline=1; shift ;;
    --out) out="${2:?--out needs a value}"; shift 2 ;;
    --derived-data) derived="${2:?--derived-data needs a value}"; shift 2 ;;
    --jobs) jobs="${2:?--jobs needs a value}"; shift 2 ;;
    --only) only="${2:?--only needs a value}"; shift 2 ;;
    --no-generate) generate=0; shift ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ "$label" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "error: --label takes letters, digits, '.', '_' or '-'" >&2; exit 2; }
[[ "$jobs" =~ ^[0-9]+$ ]] || { echo "error: --jobs takes a number" >&2; exit 2; }

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo"
[[ "$generate" == 0 ]] || xcodegen generate --quiet

# The test process writes into a temporary folder on the boot volume (xctest may not reach every volume); the
# images are copied to OUT afterwards.
staging="$(mktemp -d "${TMPDIR:-/tmp}/settings-snapshots-run.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
conditions=""
[[ "$baseline" == 0 ]] || conditions="SETTINGS_SNAPSHOT_BASELINE"

TEST_RUNNER_SNAPSHOT_OUTPUT="$staging" TEST_RUNNER_SNAPSHOT_LABEL="$label" TEST_RUNNER_SNAPSHOT_ONLY="$only" \
  xcodebuild -project App.xcodeproj -scheme SettingsSnapshots -configuration Debug \
  -derivedDataPath "$derived" -jobs "$jobs" CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY='' \
  SNAPSHOT_CONDITIONS="$conditions" test

[[ -f "$staging/$label/manifest.txt" ]] || { echo "error: the snapshot run wrote no manifest" >&2; exit 1; }
mkdir -p "$out/$label"
[[ -n "$only" ]] || find "$out/$label" -maxdepth 1 -name '*.png' -delete
cp "$staging/$label/"*.png "$out/$label/"

# index.md: one section per label folder, one line per image.
{
  echo "# Settings window snapshots"
  echo
  echo "Rendered offscreen by scripts/snapshots/settings.sh, at 2x."
  echo "Names: pane-language-appearance-size[-advanced][-macos12-layout]."
  echo
  echo "The window is drawn as an inactive window: switches and the sidebar highlight are gray, where the active"
  echo "window on screen uses the accent colour. The sidebar highlight is a stand-in drawn by the tool, because"
  echo "offscreen capture cannot draw the system's selection material. The app icon in About is the test runner's,"
  echo "and the VietQR code is blank: both come from the app's own bundle, which the test bundle is not."
  echo "Images named macos12-layout show the macOS 12 fallback layout drawn with this Mac's controls."
  for folder in "$out"/*/; do
    run="$(basename "$folder")"
    echo
    echo "## $run"
    echo
    find "$folder" -maxdepth 1 -name '*.png' -exec basename {} \; | LC_ALL=C sort | while IFS= read -r png; do
      echo "- [$png]($run/$png)"
    done
  done
} >"$out/index.md"
count="$(find "$staging/$label" -maxdepth 1 -name '*.png' | wc -l | tr -d ' ')"
echo "wrote $count images to $out/$label (index: $out/index.md)"
