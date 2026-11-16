#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Runs every hosted test layer with one command (QA-R1 layers 1 to 4 plus repository checks):
#   engine build + unit + corpus + property tests, the W11 collision corpus gate (QA-R68, its own layer
#   so that a failure names it), engine coverage gate (95 %), AppCore tests and coverage gate (80 %),
#   data reproducibility check, script self-tests, and optionally the engine benchmark gate and the
#   unsigned app build. Layers 5 to 7 (integration, compatibility, upgrade)
#   need granted permissions and run on the self-hosted runner (.github/workflows/integration.yml).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/run-tests.sh [options]

Options:
  --coverage      enforce the coverage gates (engine >= 95 %, AppCore >= 80 %, QA-R2)
  --bench         run the engine benchmark gate (scripts/bench-compare.sh)
  --app           generate the Xcode project, build the app (universal Debug, unsigned) and run UpdaterTests
  --lint          run scripts/lint.sh first
  --only LIST     comma-separated subset: engine,collision,appcore,data,scripts,bench,app
                  (collision: the QA-R68 gate, Packages/VietnameseEngine CollisionCorpusTests; the
                  engine layer runs it itself when the collision layer is not selected)
  --scratch NAME  use .build-NAME scratch paths (parallel builds, see CLAUDE.md)
  -h, --help      show this help
Layers whose package or project does not exist yet are skipped with a notice.
EOF
}

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

coverage=0
bench=0
app=0
lint=0
only=""
scratch=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --coverage) coverage=1; shift ;;
    --bench) bench=1; shift ;;
    --app) app=1; shift ;;
    --lint) lint=1; shift ;;
    --only) only=",${2:?},"; shift 2 ;;
    --scratch) scratch="${2:?}"; shift 2 ;;
    *) usage >&2; exit 2 ;;
  esac
done

cd "$REPO_ROOT"
engine="Packages/VietnameseEngine"
appcore="Packages/AppCore"
failed=()

wanted() { [[ -z "$only" || "$only" == *",$1,"* ]]; }
scratch_args() {
  if [[ -n "$scratch" ]]; then
    printf '%s\n' --scratch-path "$1/.build-$scratch"
  fi
}
step() {
  local name="$1"
  shift
  info "$name"
  if ! "$@"; then
    failed+=("$name")
  fi
}

# The QA-R68 gate's test target (spec/01-engine.md 13.11, ENG-R876, ENG-R877), as a swift test filter.
collision_filter='CollisionCorpusTests\.'

engine_tests() {
  local args=()
  while IFS= read -r a; do args+=("$a"); done < <(scratch_args "$engine")
  swift build --package-path "$engine" ${args[@]+"${args[@]}"}
  if [[ $coverage -eq 1 ]]; then
    # The coverage run includes the collision gate, so its coverage counts.
    scripts/coverage.sh --package "$engine" --min 95 \
      --exclude '^Sources/(lexicon-builder|engine-benchmark|site-demo-frames|VietnameseEngineTesting)/' \
      ${args[@]+"${args[@]}"}
  elif wanted collision; then
    swift test --package-path "$engine" ${args[@]+"${args[@]}"} --skip "$collision_filter"
  else
    swift test --package-path "$engine" ${args[@]+"${args[@]}"}
  fi
}

collision_gate() {
  local args=()
  while IFS= read -r a; do args+=("$a"); done < <(scratch_args "$engine")
  swift test --package-path "$engine" ${args[@]+"${args[@]}"} --filter "$collision_filter"
}

appcore_tests() {
  local args=()
  while IFS= read -r a; do args+=("$a"); done < <(scratch_args "$appcore")
  if [[ $coverage -eq 1 ]]; then
    scripts/coverage.sh --package "$appcore" --min 80 \
      --exclude '^Sources/(CompatHarness|TestSupport)/' ${args[@]+"${args[@]}"}
  else
    swift test --package-path "$appcore" ${args[@]+"${args[@]}"}
  fi
}

data_check() {
  local args=()
  while IFS= read -r a; do args+=("$a"); done < <(scratch_args "$engine")
  swift run --package-path "$engine" ${args[@]+"${args[@]}"} lexicon-builder check
}

app_build() {
  local xcodegen_bin
  xcodegen_bin="$(scripts/install-xcodegen.sh --prefer-system)"
  "$xcodegen_bin/xcodegen" generate
  xcodebuild -project App.xcodeproj -scheme App -configuration Debug \
    -destination 'generic/platform=macOS' -disableAutomaticPackageResolution ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY='' build
  # The Sparkle wrapper tests, as in ci.yml (no TEST_HOST: nothing launches the app).
  xcodebuild -project App.xcodeproj -scheme App -configuration Debug -destination 'platform=macOS' \
    -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY='' test -only-testing:UpdaterTests
}

if [[ $lint -eq 1 ]]; then
  step lint scripts/lint.sh
fi
if wanted engine; then
  if [[ -f "$engine/Package.swift" ]]; then step engine engine_tests; else info "engine: not present, skipped"; fi
fi
if wanted collision; then
  if [[ ! -d "$engine/Tests/CollisionCorpusTests" ]]; then
    info "collision: not present, skipped"
  elif [[ $coverage -eq 1 ]] && wanted engine; then
    info "collision: run by the engine coverage layer"
  else
    step collision collision_gate
  fi
fi
if wanted appcore; then
  if [[ -f "$appcore/Package.swift" ]]; then step appcore appcore_tests; else info "appcore: not present, skipped"; fi
fi
if wanted data; then
  if [[ -f "$engine/Package.swift" ]]; then step data data_check; else info "data: skipped"; fi
fi
if wanted scripts; then
  step scripts scripts/tests/run.sh
fi
if [[ $bench -eq 1 ]] && wanted bench; then
  step bench scripts/bench-compare.sh
fi
if [[ $app -eq 1 ]] && wanted app; then
  if [[ -f project.yml ]]; then step app app_build; else info "app: project.yml not present, skipped"; fi
fi

if [[ ${#failed[@]} -gt 0 ]]; then
  die "failed layers: ${failed[*]}"
fi
info "all requested layers passed"
