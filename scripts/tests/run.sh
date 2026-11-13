#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-App-Pending
#
# Self-tests for the repository scripts: Python unit tests plus shell-level checks of the lints and
# the release tooling against temporary fixtures. Fixtures are generated at run time in a temporary
# directory so they never trip the repository-wide lints.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/tests/run.sh [--no-macos]

  --no-macos   skip tests that need macOS tools (codesign, hdiutil, ditto, PlistBuddy)
EOF
}

no_macos=0
case "${1:-}" in
  -h | --help) usage; exit 0 ;;
  --no-macos) no_macos=1 ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac
[[ "$(uname -s)" == "Darwin" ]] || no_macos=1

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
S="$REPO/scripts"
T="$(mktemp -d)"
trap '[[ -n "${KEEP_TEST_DIR:-}" ]] || rm -rf "$T"' EXIT
unset GITHUB_ACTIONS GITHUB_STEP_SUMMARY || true

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
ko() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
expect() { # expect <exit code> <name> <command...>
  local want="$1" name="$2" got=0
  shift 2
  "$@" >"$T/out" 2>&1 || got=$?
  if [[ "$got" == "$want" ]]; then ok "$name"; else ko "$name (exit $got, want $want)"; sed 's/^/     /' "$T/out" | tail -n 20; fi
}
contains() { # contains <name> <needle> (in the last command's output)
  if grep -Fq -- "$2" "$T/out"; then ok "$1"; else ko "$1 (missing: $2)"; sed 's/^/     /' "$T/out" | tail -n 20; fi
}

echo "== Python unit tests"
if python3 -I "$S/tests/test_scripts.py" >"$T/py.log" 2>&1; then ok "python unit tests"; else ko "python unit tests"; tail -n 40 "$T/py.log"; fi

echo "== --help of every script"
for script in "$S"/*.sh "$S"/publish-release "$S"/*.py; do
  case "$(basename "$script")" in
    *.py) expect 0 "help $(basename "$script")" python3 -I "$script" --help ;;
    *) expect 0 "help $(basename "$script")" bash "$script" --help ;;
  esac
done

echo "== build-number.sh"
for pair in "0.1.0-beta.1:10001" "0.1.0:10099" "1.4.1:1040199" "v2.0.0-beta.12:2000012"; do
  got="$("$S/build-number.sh" "${pair%%:*}")"
  if [[ "$got" == "${pair##*:}" ]]; then ok "build number ${pair%%:*}"; else ko "build number ${pair%%:*} ($got)"; fi
done
expect 1 "build number rejects 1.2" "$S/build-number.sh" 1.2
expect 1 "build number rejects minor 100" "$S/build-number.sh" 1.100.0

echo "== lint-bundle-ids.sh"
mkdir -p "$T/b/App/Sources" "$T/b/App/Tests"
cat >"$T/b/App/Sources/Bad.swift" <<'EOF'
let target = "com.example.Editor"
EOF
cat >"$T/b/App/Sources/Good.swift" <<'EOF'
let layout = "com.apple.keylayout.ABC"
let file = "rules.json"
let pasteType = "org.nspasteboard.ConcealedType"
let own = "vn.example.thing" // lint:allow-bundle-id test-only justification
// A comment may mention com.example.Editor freely.
EOF
cat >"$T/b/App/Tests/Fixture.swift" <<'EOF'
let fixture = "com.google.Chrome"
EOF
expect 1 "bundle-id literal is found" "$S/lint-bundle-ids.sh" --root "$T/b"
contains "finding names the file" "App/Sources/Bad.swift:1"
rm "$T/b/App/Sources/Bad.swift"
expect 0 "allowlist, marker, comments and tests are exempt" "$S/lint-bundle-ids.sh" --root "$T/b"

echo "== lint-log-interpolation.sh"
mkdir -p "$T/l/Packages/AppCore/Sources/InputHost" "$T/l/Packages/VietnameseEngine/Sources/lexicon-builder"
cat >"$T/l/Packages/AppCore/Sources/InputHost/Bad.swift" <<'EOF'
func f(text: String) {
    logger.info("typed \(text)")
}
EOF
cat >"$T/l/Packages/AppCore/Sources/InputHost/Print.swift" <<'EOF'
func g(x: Int) { print("value \(x)") }
EOF
cat >"$T/l/Packages/AppCore/Sources/InputHost/Url.swift" <<'EOF'
func h(x: Int) { Self.log.error("https://example.test/\(x)") }
EOF
cat >"$T/l/Packages/AppCore/Sources/InputHost/Good.swift" <<'EOF'
func ok(event: HealthEvent) {
    logger.record(.tapTimeout, count: 3)
    let s = "plain \(1)"  // not a log call
    // logger.info("\(commented)")
}
EOF
cat >"$T/l/Packages/VietnameseEngine/Sources/lexicon-builder/main.swift" <<'EOF'
print("wrote \(count) entries")
EOF
expect 1 "log interpolation is found" "$S/lint-log-interpolation.sh" --root "$T/l"
contains "logger.info flagged" "InputHost/Bad.swift:2"
contains "print flagged in product code" "InputHost/Print.swift:1"
contains "interpolation after // in a string flagged" "InputHost/Url.swift:1"
rm "$T"/l/Packages/AppCore/Sources/InputHost/{Bad,Print,Url}.swift
expect 0 "typed calls, comments and CLI prints pass" "$S/lint-log-interpolation.sh" --root "$T/l"

echo "== check-spdx.sh"
mkdir -p "$T/s/Packages/VietnameseEngine/Sources" "$T/s/App" "$T/s/scripts" "$T/s/spec"
printf '// SPDX-License-Identifier: MPL-2.0\n' >"$T/s/Packages/VietnameseEngine/Sources/A.swift"
printf '// SPDX-License-Identifier: LicenseRef-App-Pending\n' >"$T/s/App/B.swift"
printf 'print(1)\n' >"$T/s/spec/model.py"
printf '#!/bin/sh\n# SPDX-License-Identifier: LicenseRef-App-Pending\n' >"$T/s/scripts/tool"
expect 0 "correct headers pass, spec/ excluded" "$S/check-spdx.sh" --root "$T/s"
printf '// SPDX-License-Identifier: MIT\n' >"$T/s/App/B.swift"
printf '#!/bin/sh\necho hi\n' >"$T/s/scripts/tool2"
expect 1 "wrong licence and missing header fail" "$S/check-spdx.sh" --root "$T/s"
contains "wrong licence reported" "App/B.swift: SPDX licence MIT"
contains "missing header reported" "scripts/tool2: missing"

echo "== check-url-hosts.sh"
cat >"$T/brand.env" <<'EOF'
APP_DISPLAY_NAME="Test App"
APP_SLUG="testapp"
APP_BUNDLE_ID_RELEASE="vn.example.testapp"
APP_BUNDLE_ID_DEV="vn.example.testapp.dev"
APP_SITE_HOST="testapp.example.vn"
EOF
mkdir -p "$T/u/Test.app/Contents/Resources"
printf '{"feed": "https://testapp.example.vn/appcast.xml", "repo": "https://github.com/o/r", "dtd": "http://www.apple.com/DTDs/x"}\n' \
  >"$T/u/Test.app/Contents/Resources/config.json"
expect 0 "allowed hosts pass" env BRAND_ENV="$T/brand.env" "$S/check-url-hosts.sh" "$T/u/Test.app"
printf '{"tracker": "https://telemetry.example.com/collect", "mail": "mailto:help@elsewhere.example"}\n' \
  >"$T/u/Test.app/Contents/Resources/extra.json"
expect 1 "unknown host fails" env BRAND_ENV="$T/brand.env" "$S/check-url-hosts.sh" "$T/u/Test.app"
contains "unknown host named" "telemetry.example.com"
contains "mail host checked" "elsewhere.example"
rm "$T/u/Test.app/Contents/Resources/extra.json"
# QA-R60: the repository host and the support mail domain come from brand.env, not the allowlist.
cp "$T/brand.env" "$T/brand-repo.env"
printf 'APP_REPOSITORY_URL="https://git.example.org/o/r"\nAPP_SUPPORT_EMAIL="help@mail.example.vn"\n' >>"$T/brand-repo.env"
expect 1 "github.com is no longer allowed once APP_REPOSITORY_URL names another host" \
  env BRAND_ENV="$T/brand-repo.env" "$S/check-url-hosts.sh" "$T/u/Test.app"
contains "default GitHub host reported" "github.com"
printf '{"repo": "https://git.example.org/o/r/issues/new", "mail": "mailto:help@mail.example.vn"}\n' \
  >"$T/u/Test.app/Contents/Resources/config.json"
expect 0 "repository host and support mail domain from brand.env pass" \
  env BRAND_ENV="$T/brand-repo.env" "$S/check-url-hosts.sh" "$T/u/Test.app"
expect 1 "support mail domain is not allowed while APP_SUPPORT_EMAIL is empty" \
  env BRAND_ENV="$T/brand.env" "$S/check-url-hosts.sh" "$T/u/Test.app"
contains "mail domain reported" "mail.example.vn"
printf 'APP_REPOSITORY_URL="http://insecure.example/o/r"\n' >>"$T/brand-repo.env"
expect 1 "brand values are validated (https repository URL)" \
  env BRAND_ENV="$T/brand-repo.env" "$S/check-url-hosts.sh" "$T/u/Test.app"
contains "invalid repository URL named" "APP_REPOSITORY_URL invalid"

echo "== check-brand-sync.py"
cat >"$T/sync.xcconfig" <<'EOF'
// SPDX-License-Identifier: LicenseRef-App-Pending
APP_DISPLAY_NAME = Test App
APP_SLUG = testapp
// The URL is written with $() because // starts an xcconfig comment.
APP_REPOSITORY_URL = https:/$()/github.com/o/testapp
APP_LEGACY_STORAGE_FOLDER_NAMES =
EOF
cat >"$T/sync.env" <<'EOF'
# comment
APP_DISPLAY_NAME="Test App"
APP_SLUG="testapp"
APP_REPOSITORY_URL="https://github.com/o/testapp"
APP_LEGACY_STORAGE_FOLDER_NAMES=""
EOF
expect 0 "brand files in sync (xcconfig URL escape understood)" \
  python3 -I "$S/check-brand-sync.py" --xcconfig "$T/sync.xcconfig" --env "$T/sync.env"
printf 'APP_SUPPORT_EMAIL="help@example.vn"\n' >>"$T/sync.env"
expect 1 "a key filled in one brand file only fails" \
  python3 -I "$S/check-brand-sync.py" --xcconfig "$T/sync.xcconfig" --env "$T/sync.env"
contains "missing key named" "APP_SUPPORT_EMAIL is in brand.env but missing from Brand.xcconfig"
printf 'APP_SUPPORT_EMAIL = help@example.org\n' >>"$T/sync.xcconfig"
expect 1 "different values fail" \
  python3 -I "$S/check-brand-sync.py" --xcconfig "$T/sync.xcconfig" --env "$T/sync.env"
contains "difference named" "APP_SUPPORT_EMAIL differs"

echo "== check-rules / forward delete on a missing rules file"
expect 0 "check-rules passes when compat/rules.json is absent" python3 -I "$S/check-rules.py" --rules "$T/none.json"
expect 0 "forward-delete passes when absent" python3 -I "$S/check-no-forward-delete.py" "$T/none.json"

echo "== sync-labels.sh (dry run)"
cat >"$T/labels.yml" <<'EOF'
# test labels
- name: bug
  color: d73a4a
  description: Something does not work
- name: "area:engine"
  color: "#0e8a16"
  description: Typing engine
EOF
expect 0 "labels dry run" "$S/sync-labels.sh" --file "$T/labels.yml"
contains "label planned" "would sync: area:engine (#0e8a16) Typing engine"
printf -- '- name: bad\n  colour: 123456\n' >"$T/bad-labels.yml"
expect 1 "invalid label file rejected" "$S/sync-labels.sh" --file "$T/bad-labels.yml"

echo "== fuzz-report-issue.sh (dry run)"
printf 'crash' >"$T/minimized-crash-1"
printf 'fuzz-telex\t%s\n' "$T/minimized-crash-1" >"$T/findings.txt"
expect 0 "fuzz issue dry run" "$S/fuzz-report-issue.sh" "$T/findings.txt" --dry-run
contains "issue title" "Fuzzing finding in fuzz-telex"
contains "hex dump" "63 72 61 73 68"

echo "== bench-compare.sh / fuzz.sh skip cleanly when targets are missing"
expect 0 "bench skips without product" "$S/bench-compare.sh" --package "$T/nopkg" --output "$T/bench.json"
expect 1 "bench --require fails without product" "$S/bench-compare.sh" --package "$T/nopkg" --require --output "$T/bench.json"
expect 0 "fuzz skips without package" "$S/fuzz.sh" --package "$T/nopkg" --out "$T/fuzz"

echo "== rename-app.sh in a scratch copy"
R="$T/repo"
mkdir -p "$R/Config" "$R/docs/decisions" "$R/spec"
cp -R "$S" "$R/scripts"
cp "$T/brand.env" "$R/scripts/brand.env"
cat >>"$R/scripts/brand.env" <<'EOF'
APP_SUPPORT_EMAIL="help@example.vn"
APP_REPOSITORY_URL="https://github.com/o/testapp"
APP_LEGACY_STORAGE_FOLDER_NAMES=""
EOF
cat >"$R/Config/Brand.xcconfig" <<'EOF'
// SPDX-License-Identifier: LicenseRef-App-Pending
APP_DISPLAY_NAME = Test App
APP_SLUG = testapp
APP_BUNDLE_ID_RELEASE = vn.example.testapp
APP_BUNDLE_ID_DEV = vn.example.testapp.dev
APP_SITE_HOST = testapp.example.vn
APP_SUPPORT_EMAIL = help@example.vn
APP_REPOSITORY_URL = https:/$()/github.com/o/testapp
APP_LEGACY_STORAGE_FOLDER_NAMES =
EOF
printf 'Install Test App from https://testapp.example.vn (cask testapp, bundle vn.example.testapp).\nKeep {{AppName}} and testappx.\n' >"$R/README.md"
printf 'Test App was the temporary name.\n' >"$R/docs/decisions/0001-x.md"
printf '{{AppName}} Test App\n' >"$R/spec/00.md"
(cd "$R" && git init -q && git add -A)
expect 2 "rename needs two arguments" "$R/scripts/rename-app.sh" OnlyOne
expect 1 "rename rejects a bad slug" "$R/scripts/rename-app.sh" "New" "Bad_Slug"
expect 1 "rename rejects ; in the name (legacy folder separator, ADR 0307)" "$R/scripts/rename-app.sh" "A;B" ab
expect 0 "rename dry run" "$R/scripts/rename-app.sh" "Xuôi" xuoi --bundle-prefix vn.example --domain example.vn
contains "dry run lists README" "--- README.md"
contains "dry run shows the legacy folder" "legacy storage folders: (none) -> Test App"
if grep -q "Test App" "$R/README.md"; then ok "dry run writes nothing"; else ko "dry run wrote files"; fi
if grep -q '^APP_LEGACY_STORAGE_FOLDER_NAMES=""$' "$R/scripts/brand.env"; then
  ok "dry run leaves brand.env alone"
else
  ko "dry run leaves brand.env alone"
fi
expect 0 "rename apply" "$R/scripts/rename-app.sh" "Xuôi" xuoi --bundle-prefix vn.example --domain example.vn --apply
if grep -q '^APP_DISPLAY_NAME="Xuôi"$' "$R/scripts/brand.env"; then ok "brand.env rewritten"; else ko "brand.env rewritten"; fi
if grep -q '^APP_BUNDLE_ID_DEV = vn.example.xuoi.dev$' "$R/Config/Brand.xcconfig"; then ok "xcconfig rewritten"; else ko "xcconfig rewritten"; fi
# ADR 0307 amendment: the old folder name (ASCII display name) goes into the legacy list of both files.
if grep -q '^APP_LEGACY_STORAGE_FOLDER_NAMES="Test App"$' "$R/scripts/brand.env" &&
  grep -q '^APP_LEGACY_STORAGE_FOLDER_NAMES = Test App$' "$R/Config/Brand.xcconfig"; then
  ok "old folder name appended to APP_LEGACY_STORAGE_FOLDER_NAMES"
else
  ko "old folder name appended to APP_LEGACY_STORAGE_FOLDER_NAMES"
fi
# shellcheck disable=SC2016 # the xcconfig URL escape $() is literal text
if grep -q '^APP_SUPPORT_EMAIL="help@example.vn"$' "$R/scripts/brand.env" &&
  grep -q '^APP_REPOSITORY_URL="https://github.com/o/testapp"$' "$R/scripts/brand.env" &&
  grep -q '^APP_SUPPORT_EMAIL = help@example.vn$' "$R/Config/Brand.xcconfig" &&
  grep -qF 'APP_REPOSITORY_URL = https:/$()/github.com/o/testapp' "$R/Config/Brand.xcconfig"; then
  ok "support email and repository URL kept (old slug inside the URL untouched)"
else
  ko "support email and repository URL kept"
fi
expect 0 "brand files still in sync after a rename" python3 -I "$R/scripts/check-brand-sync.py" \
  --xcconfig "$R/Config/Brand.xcconfig" --env "$R/scripts/brand.env"
if grep -q 'Install Xuôi from https://xuoi.example.vn (cask xuoi, bundle vn.example.xuoi)' "$R/README.md"; then
  ok "README literals rewritten"
else
  ko "README literals rewritten"
fi
if grep -q '{{AppName}} and testappx' "$R/README.md"; then ok "placeholders and longer words untouched"; else ko "placeholders untouched"; fi
if grep -q 'Test App was' "$R/docs/decisions/0001-x.md"; then ok "decision records untouched"; else ko "decision records untouched"; fi
if grep -q 'Test App' "$R/spec/00.md"; then ok "spec untouched"; else ko "spec untouched"; fi
# A non-ASCII name stores its folders under the slug (PLT-R903), so the slug is what becomes legacy.
expect 0 "second rename" "$R/scripts/rename-app.sh" "Zeta Gõ" zetago --bundle-prefix vn.example --domain example.vn --apply
if grep -q '^APP_LEGACY_STORAGE_FOLDER_NAMES="xuoi;Test App"$' "$R/scripts/brand.env"; then
  ok "legacy list is newest first and uses the slug for a non-ASCII name"
else
  ko "legacy list is newest first and uses the slug for a non-ASCII name"
fi
expect 0 "rename back to an earlier name" "$R/scripts/rename-app.sh" "Test App" testapp \
  --bundle-prefix vn.example --domain example.vn --apply
if grep -q '^APP_LEGACY_STORAGE_FOLDER_NAMES = zetago;xuoi$' "$R/Config/Brand.xcconfig"; then
  ok "the current folder is never listed as legacy"
else
  ko "the current folder is never listed as legacy"
fi
mkdir -p "$R/site/data"
printf '{"releases":[{"version":"0.1.0"}]}\n' >"$R/site/data/releases.json"
expect 1 "rename refused after a release" "$R/scripts/rename-app.sh" "Other" other

if [[ $no_macos -eq 0 ]]; then
  echo "== macOS release tooling (ad-hoc signed fake app)"
  M="$T/mac"
  mkdir -p "$M"
  cp -R "$R/scripts" "$M/scripts"
  cp "$T/brand.env" "$M/scripts/brand.env"
  mkdir -p "$M/Config" "$M/packaging"
  cp "$REPO/Config/Signing.xcconfig" "$M/Config/"
  cp -R "$REPO/packaging/homebrew" "$M/packaging/"
  printf '# Changelog\n\n## [1.2.3] - 2026-11-13\n- First public test\n' >"$M/CHANGELOG.md"
  app="$M/dist/testapp-1.2.3/Test App.app"
  mkdir -p "$app/Contents/MacOS"
  cat >"$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>vn.example.testapp</string>
<key>CFBundleExecutable</key><string>Test</string>
<key>CFBundleShortVersionString</key><string>1.2.3</string>
<key>CFBundleVersion</key><string>1020399</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
EOF
  printf '#!/bin/sh\nexit 0\n' >"$app/Contents/MacOS/Test"
  chmod +x "$app/Contents/MacOS/Test"
  codesign --force --sign - "$app" >/dev/null 2>&1
  expect 0 "make-dmg (unsigned)" "$M/scripts/make-dmg.sh" "$app" --no-sign
  dmg="$M/dist/testapp-1.2.3/testapp-1.2.3.dmg"
  if [[ -f "$dmg" ]]; then ok "DMG created"; else ko "DMG created"; fi
  if hdiutil imageinfo "$dmg" >/dev/null 2>&1; then ok "DMG is a valid image"; else ko "DMG is a valid image"; fi
  codesign --force --sign - "$dmg" >/dev/null 2>&1
  ditto -c -k --sequesterRsrc --keepParent "$app" "$M/dist/testapp-1.2.3/testapp-1.2.3.zip"
  (cd "$M" && git init -q && git add -A)
  expect 0 "publish-release dry run" "$M/scripts/publish-release" 1.2.3 --skip-attestation --skip-gatekeeper
  contains "appcast item printed" "<sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>"
  contains "phased rollout for stable" "<sparkle:phasedRolloutInterval>86400</sparkle:phasedRolloutInterval>"
  contains "release notes vi link" "https://testapp.example.vn/nhat-ky-thay-doi/#v1.2.3"
  contains "releases.json entry printed" "\"dmgUrl\": \"https://testapp.example.vn/download/testapp-1.2.3.dmg\""
  contains "cask rendered" "cask \"testapp\" do"
  # shellcheck disable=SC2088 # literal text in the rendered cask, not a path to expand
  contains "zap uses the folder rule" "~/Library/Application Support/Test App"
  if [[ ! -e "$M/site/static/appcast.xml" && ! -e "$M/site/data/releases.json" ]]; then
    ok "dry run leaves the repository untouched"
  else
    ko "dry run wrote into the repository"
  fi
  expect 1 "--skip-gatekeeper refused with --apply" "$M/scripts/publish-release" 1.2.3 --apply --skip-gatekeeper --skip-attestation
  expect 1 "beta version needs --beta" "$M/scripts/publish-release" 1.3.0-beta.1 --skip-attestation --skip-gatekeeper
  expect 0 "build-release dry run" bash -c "cd '$M' && touch project.yml && scripts/build-release.sh 1.2.3 1020399 --dry-run"
  contains "archive command" "MARKETING_VERSION=1.2.3"
  contains "no base entitlements" "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO"
fi

echo
echo "scripts self-test: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
