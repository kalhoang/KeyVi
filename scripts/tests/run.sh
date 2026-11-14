#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
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
for suite in test_scripts test_docs_and_workflows test_site_deploy test_make_vietqr test_make_app_icon test_vm_lab test_pane_names; do
  if python3 -I "$S/tests/$suite.py" >"$T/py.log" 2>&1; then ok "python $suite"; else ko "python $suite"; tail -n 40 "$T/py.log"; fi
done

echo "== site container (deploy/site, ADR 0602)"
if command -v node >/dev/null 2>&1; then
  if node "$REPO/deploy/site/test.mjs" >"$T/deploy.log" 2>&1; then ok "node deploy/site/test.mjs"; else ko "node deploy/site/test.mjs"; tail -n 40 "$T/deploy.log"; fi
else
  printf 'skip node deploy/site/test.mjs (node not installed)\n'
fi
expect 0 "help deploy/site/stack-env.sh" bash "$REPO/deploy/site/stack-env.sh" --help
expect 0 "help deploy/site/fetch-downloads.py" python3 -I "$REPO/deploy/site/fetch-downloads.py" --help

echo "== --help of every script"
for script in "$S"/*.sh "$S"/publish-release "$S"/*.py; do
  case "$(basename "$script")" in
    *.py) expect 0 "help $(basename "$script")" python3 -I "$script" --help ;;
    *) expect 0 "help $(basename "$script")" bash "$script" --help ;;
  esac
done

echo "== scripts/dev/trace-scan.sh (PLT-R904A dev recorder scanner wrapper)"
expect 0 "help dev/trace-scan.sh" bash "$S/dev/trace-scan.sh" --help
contains "help names both commands" "show N"
expect 2 "dev/trace-scan.sh without a command" bash "$S/dev/trace-scan.sh"
mkdir -p "$T/scan/home" "$T/scan/bin"
expect 0 "default folder from the brand file" env HOME="$T/scan/home" bash "$S/dev/trace-scan.sh" --print-dir
display_folder="$(sed -n 's/^APP_DISPLAY_NAME="\(.*\)"$/\1/p' "$S/brand.env")"
contains "default folder is the dev build's dev-traces" "$T/scan/home/Library/Logs/$display_folder/dev-traces"
cat >"$T/scan/bin/trace-scan" <<'SCAN'
#!/usr/bin/env bash
printf 'args:'
printf ' [%s]' "$@"
printf '\n'
SCAN
chmod +x "$T/scan/bin/trace-scan"
expect 0 "the wrapper adds the default folder" env HOME="$T/scan/home" TRACE_SCAN_BIN="$T/scan/bin/trace-scan" \
  bash "$S/dev/trace-scan.sh" summary --since 2h
contains "default --dir passed" "args: [summary] [--since] [2h] [--dir] [$T/scan/home/Library/Logs/$display_folder/dev-traces]"
expect 0 "an explicit folder is kept" env HOME="$T/scan/home" TRACE_SCAN_BIN="$T/scan/bin/trace-scan" \
  bash "$S/dev/trace-scan.sh" show 3 --dir /elsewhere
contains "explicit --dir kept" "args: [show] [3] [--dir] [/elsewhere]"
sed 's/^APP_DISPLAY_NAME=.*/APP_DISPLAY_NAME="Gõ Việt"/' "$S/brand.env" >"$T/scan/brand.env"
expect 0 "a non-ASCII name uses the slug" env HOME="$T/scan/home" BRAND_ENV="$T/scan/brand.env" \
  bash "$S/dev/trace-scan.sh" --print-dir
slug="$(sed -n 's/^APP_SLUG="\(.*\)"$/\1/p' "$S/brand.env")"
contains "slug folder" "$T/scan/home/Library/Logs/$slug/dev-traces"

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
printf '// SPDX-License-Identifier: GPL-3.0-or-later\n' >"$T/s/App/B.swift"
printf 'print(1)\n' >"$T/s/spec/model.py"
printf '#!/bin/sh\n# SPDX-License-Identifier: GPL-3.0-or-later\n' >"$T/s/scripts/tool"
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
# QA-R60: compat-rules.json is data. Its web.urlPrefixes matchers name sites the rules apply to, never hosts the
# app contacts, so the check skips that one file; the same host anywhere else still fails.
printf '{"rules": [{"match": {"web": {"urlPrefixes": ["https://docs.google.com/spreadsheets/"]}}}]}\n' \
  >"$T/u/Test.app/Contents/Resources/compat-rules.json"
expect 0 "URL prefixes in compat-rules.json are data, not endpoints" \
  env BRAND_ENV="$T/brand.env" "$S/check-url-hosts.sh" "$T/u/Test.app"
expect 0 "compat-rules.json passed as a single file is skipped too" \
  env BRAND_ENV="$T/brand.env" "$S/check-url-hosts.sh" "$T/u/Test.app/Contents/Resources/compat-rules.json"
printf '{"rules": [{"url": "https://docs.google.com/spreadsheets/"}]}\n' >"$T/u/Test.app/Contents/Resources/other.json"
expect 1 "the same host in any other file still fails" \
  env BRAND_ENV="$T/brand.env" "$S/check-url-hosts.sh" "$T/u/Test.app"
contains "host outside compat-rules.json named" "docs.google.com"
rm "$T/u/Test.app/Contents/Resources/other.json"
mkdir -p "$T/u/Test.app/Contents/Resources/Extra"
cp "$T/u/Test.app/Contents/Resources/compat-rules.json" "$T/u/Test.app/Contents/Resources/Extra/compat-rules.json"
expect 1 "only the shipped Contents/Resources/compat-rules.json is skipped, not a namesake elsewhere" \
  env BRAND_ENV="$T/brand.env" "$S/check-url-hosts.sh" "$T/u/Test.app/"
contains "namesake's host named" "docs.google.com"
expect 1 "a namesake passed as a single file is checked" \
  env BRAND_ENV="$T/brand.env" "$S/check-url-hosts.sh" "$T/u/Test.app/Contents/Resources/Extra/compat-rules.json"
rm -r "$T/u/Test.app/Contents/Resources/Extra" "$T/u/Test.app/Contents/Resources/compat-rules.json"
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
# ADR 0602 amendment: `site:` lines of the allowlist name hosts only the website may contact (the Umami
# analytics host). They are never allowed inside the app, whose only automatic traffic is the update check.
mkdir -p "$T/u/Site.app/Contents/Resources"
printf 'www.apple.com\nsite: stats.example.vn\n' >"$T/u/allow-site"
printf '{"feed": "https://testapp.example.vn/appcast.xml", "dtd": "http://www.apple.com/DTDs/x"}\n' \
  >"$T/u/Site.app/Contents/Resources/config.json"
expect 0 "site: lines do not disturb the app hosts" \
  env BRAND_ENV="$T/brand.env" "$S/check-url-hosts.sh" --allow "$T/u/allow-site" "$T/u/Site.app"
printf '{"tracker": "https://stats.example.vn/script.js"}\n' >"$T/u/Site.app/Contents/Resources/extra.json"
expect 1 "a website-only host inside the app fails" \
  env BRAND_ENV="$T/brand.env" "$S/check-url-hosts.sh" --allow "$T/u/allow-site" "$T/u/Site.app"
contains "website-only host explained" "stats.example.vn is allowed for the website only"
printf 'site: \n' >"$T/u/allow-bad"
expect 2 "an empty site: line is refused" \
  env BRAND_ENV="$T/brand.env" "$S/check-url-hosts.sh" --allow "$T/u/allow-bad" "$T/u/Site.app"

echo "== check-brand-sync.py"
cat >"$T/sync.xcconfig" <<'EOF'
// SPDX-License-Identifier: GPL-3.0-or-later
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

echo "== check-unimplemented.sh (release-build guard)"
mkdir -p "$T/x/Packages/AppCore/Sources/AppModel" "$T/x/Packages/AppCore/Sources/Diagnostics" "$T/x/App/Sources"
cat >"$T/x/Packages/AppCore/Sources/AppModel/Unimplemented.swift" <<'EOF'
public func unimplemented(_ function: StaticString = #function) -> Never { fatalError() }
EOF
cat >"$T/x/Packages/AppCore/Sources/Diagnostics/Done.swift" <<'EOF'
// Replaced the old unimplemented() body.
func ready() -> Int { 1 }  // was: unimplemented()
let label = "notunimplemented(x)".count
EOF
expect 0 "definition, comments and longer identifiers are not calls" "$S/check-unimplemented.sh" --root "$T/x"
cat >"$T/x/App/Sources/Left.swift" <<'EOF'
func later() -> Int { unimplemented() }
EOF
expect 1 "a remaining call fails the guard" "$S/check-unimplemented.sh" --root "$T/x"
contains "finding names file and line" "App/Sources/Left.swift:1:"
expect 0 "--report lists without failing" "$S/check-unimplemented.sh" --root "$T/x" --report
contains "report counts the calls" "1 call(s) left"

echo "== compat-dry-run.sh (no events, skipped until the product exists)"
D="$T/d"
mkdir -p "$D/Packages/AppCore" "$D/bin"
expect 0 "skipped without the compat-harness product" "$S/compat-dry-run.sh" --root "$D"
contains "skip reason: product" "no compat-harness product"
printf '.executable(name: "compat-harness", targets: ["CompatHarness"]),\n' >"$D/Packages/AppCore/Package.swift"
expect 0 "skipped without scenario files" "$S/compat-dry-run.sh" --root "$D"
contains "skip reason: scenarios" "no scenario files"
mkdir -p "$D/compat/scenarios"
printf '{"id": "x"}\n' >"$D/compat/scenarios/x.json"
# A fake swift records its arguments, so the test proves the harness gets --dry-run and nothing is built.
cat >"$D/bin/swift" <<'EOF'
#!/bin/sh
printf 'args: %s\n' "$*"
printf '%s\n' "${FAKE_HARNESS_OUTPUT:-plan: 1 scenario}"
exit "${FAKE_HARNESS_STATUS:-0}"
EOF
chmod +x "$D/bin/swift"
expect 0 "dry run passes when the harness plans every scenario" env PATH="$D/bin:$PATH" "$S/compat-dry-run.sh" --root "$D"
contains "harness invoked by product name with --dry-run" "compat-harness run --scenarios $D/compat/scenarios --dry-run"
expect 1 "a stub harness fails once scenarios exist" \
  env PATH="$D/bin:$PATH" FAKE_HARNESS_OUTPUT="compat-harness: not implemented" "$S/compat-dry-run.sh" --root "$D"
expect 1 "a failing harness fails" env PATH="$D/bin:$PATH" FAKE_HARNESS_STATUS=3 "$S/compat-dry-run.sh" --root "$D"
expect 1 "argument override without --dry-run is refused" \
  env PATH="$D/bin:$PATH" COMPAT_HARNESS_DRY_RUN_ARGS="run --scenarios x" "$S/compat-dry-run.sh" --root "$D"

echo "== check-dco.sh (ADR 0006: every contribution is signed off)"
G="$T/g"
mkdir -p "$G/Packages/VietnameseEngine" "$G/docs"
git -C "$G" init -q
git -C "$G" config user.name "Ada Contributor"
git -C "$G" config user.email "ada@example.org"
git -C "$G" config commit.gpgsign false
printf 'base\n' >"$G/docs/a.md"
git -C "$G" add -A && git -C "$G" commit -q -m "chore: base"
dco_base="$(git -C "$G" rev-parse HEAD)"
printf 'x\n' >"$G/Packages/VietnameseEngine/E.swift"
git -C "$G" add -A && git -C "$G" commit -q -s -m "feat: signed engine change"
printf 'doc\n' >>"$G/docs/a.md"
git -C "$G" commit -q -s -am "docs: signed change outside the engine"
expect 0 "signed commits in every area pass" "$S/check-dco.sh" --repo "$G" --base "$dco_base" --head HEAD
contains "every commit checked" "2 commit(s) touching every path, all signed off"
printf 'more\n' >>"$G/docs/a.md"
git -C "$G" commit -q -am "docs: unsigned change outside the engine"
expect 1 "an unsigned commit outside the engine fails (GPL-covered parts need the sign-off too)" \
  "$S/check-dco.sh" --repo "$G" --base "$dco_base" --head HEAD
contains "unsigned app commit named" "docs: unsigned change outside the engine"
contains "names the decision" "ADR 0006"
git -C "$G" commit -q --amend -s --no-edit
printf 'y\n' >>"$G/Packages/VietnameseEngine/E.swift"
git -C "$G" commit -q -am "fix: engine change" -m "Signed-off-by: Someone Else <else@example.org>"
expect 1 "a sign-off by someone else fails" "$S/check-dco.sh" --repo "$G" --base "$dco_base" --head HEAD
contains "expected sign-off named" "expected: Signed-off-by: Ada Contributor <ada@example.org>"
git -C "$G" commit -q --amend -s --no-edit
expect 0 "an added matching sign-off passes" "$S/check-dco.sh" --repo "$G" --base "$dco_base" --head HEAD
expect 1 "unknown revisions are rejected" "$S/check-dco.sh" --repo "$G" --base nope --head HEAD
mkdir -p "$G/Packages/VietnameseEngineFuzz"
printf 'z\n' >"$G/Packages/VietnameseEngineFuzz/F.swift"
git -C "$G" add -A && git -C "$G" commit -q -m "test: unsigned fuzz change"
expect 1 "the MPL-2.0 fuzz package is checked" "$S/check-dco.sh" --repo "$G" --base "$dco_base" --head HEAD
contains "unsigned fuzz commit named" "test: unsigned fuzz change"
expect 0 "--path limits the check" "$S/check-dco.sh" --repo "$G" --base "$dco_base" --head HEAD \
  --path Packages/VietnameseEngine --path docs

echo "== notarize.sh never accepts a submission without its log (QA-R30 step 5)"
N="$T/notary"
mkdir -p "$N/bin"
# Fake xcrun and ditto (the Linux CI job has neither): submit is Accepted; log fails until FAKE_LOG_AFTER calls,
# then writes FAKE_LOG_JSON; stapler succeeds.
cat >"$N/bin/xcrun" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "notarytool submit") printf '{"id": "sub-1", "status": "Accepted"}\n' ;;
  "notarytool log")
    count=$(( $(cat "$FAKE_LOG_COUNT" 2>/dev/null || echo 0) + 1 ))
    echo "$count" >"$FAKE_LOG_COUNT"
    [ "$count" -gt "${FAKE_LOG_AFTER:-99}" ] || { echo "Error: HTTP 500" >&2; exit 1; }
    for last; do :; done
    if [ -n "${FAKE_LOG_JSON:-}" ]; then printf '%s\n' "$FAKE_LOG_JSON" >"$last"; else printf '{"issues": null}\n' >"$last"; fi ;;
  "stapler staple" | "stapler validate") ;;
  *) exit 3 ;;
esac
EOF
printf '#!/bin/sh\nexit 0\n' >"$N/bin/ditto"
chmod +x "$N/bin/xcrun" "$N/bin/ditto"
printf 'dmg' >"$N/test.dmg"
notarize() { # notarize <expected exit> <name> [VAR=value...]
  local want="$1" name="$2"
  shift 2
  rm -f "$N/count" "$N"/notarization-*.json
  expect "$want" "$name" env PATH="$N/bin:$PATH" NOTARY_KEYCHAIN_PROFILE=test FAKE_LOG_COUNT="$N/count" \
    NOTARY_LOG_RETRY_DELAY=0 "$@" "$S/notarize.sh" "$N/test.dmg" --log-dir "$N"
}
notarize 1 "an Accepted submission whose log cannot be fetched fails"
contains "names the missing log" "notary log for test.dmg could not be fetched"
if [[ "$(cat "$N/count")" == 3 ]]; then ok "the log is fetched three times before giving up"; else ko "the log is fetched three times before giving up"; fi
notarize 0 "a log that arrives on the second try is accepted" FAKE_LOG_AFTER=1
contains "stapled" "notarised and stapled: test.dmg"
notarize 1 "an issue in the log fails" FAKE_LOG_AFTER=0 \
  FAKE_LOG_JSON='{"issues": [{"severity": "warning", "path": "x", "message": "no timestamp"}]}'
contains "issue count named" "lists 1 issue(s)"

echo "== check-pr-labels.sh (QA-R6 corpus-change, QA-R15 perf-baseline)"
L="$T/labels"
corpus="Packages/VietnameseEngine/Tests/VietnameseEngineTests/Corpus"
mkdir -p "$L/$corpus" "$L/perf"
git -C "$L" init -q
git -C "$L" config user.name "Ada Contributor"
git -C "$L" config user.email "ada@example.org"
git -C "$L" config commit.gpgsign false
printf 'vieejt\tviệt\n' >"$L/$corpus/editing.tsv"
printf 'a\tb\n' >"$L/$corpus/layouts.tsv"
printf '{"metrics": {}}\n' >"$L/perf/platform-baseline.json"
git -C "$L" add -A && git -C "$L" commit -q -m "chore: base"
label_base="$(git -C "$L" rev-parse HEAD)"
labels_check() { # labels_check <expected exit> <name> <labels>
  expect "$1" "$2" "$S/check-pr-labels.sh" --repo "$L" --base "$label_base" --head HEAD --labels "$3"
}
printf 'tieengs\ttiếng\n' >>"$L/$corpus/editing.tsv"
git -C "$L" commit -q -am "test: add a corpus case"
labels_check 0 "a new corpus case needs no label" ""
printf 'vieejt\tviet\ntieengs\ttiếng\n' >"$L/$corpus/editing.tsv"
git -C "$L" commit -q -am "test: change an expected output"
labels_check 1 "a changed expected output needs corpus-change" "bug,perf-baseline"
contains "names the corpus file" "$corpus/editing.tsv"
contains "names the label" "corpus-change"
labels_check 0 "the corpus-change label allows it" "bug,corpus-change"
git -C "$L" reset -q --hard "$label_base"
printf 'c\td\n' >"$L/$corpus/layouts.tsv"
git -C "$L" commit -q -am "test: regenerate the layout corpus"
labels_check 0 "generated corpus files are left to their generators' --check" ""
printf '{"metrics": {"T2.p99": 1}}\n' >"$L/perf/platform-baseline.json"
git -C "$L" commit -q -am "perf: new baseline"
labels_check 1 "a baseline change needs perf-baseline" "corpus-change"
contains "names the baseline" "perf/platform-baseline.json"
contains "names the perf label" "perf-baseline"
labels_check 0 "the perf-baseline label allows it" "perf-baseline"
expect 1 "unknown revisions are rejected" "$S/check-pr-labels.sh" --repo "$L" --base nope --head HEAD --labels ""

echo "== check-docs.py (relative links; brand placeholders in docs, literal brand values in the front door)"
K="$T/k"
mkdir -p "$K/docs/runbooks" "$K/docs/decisions" "$K/scripts"
cp "$T/brand.env" "$K/scripts/brand.env"
cat >"$K/docs/runbooks/a.md" <<'EOF'
# Runbook A

## Đặt lại quyền

## Step: one `code`

## Step: one `code`

See [b](b.md#target-heading), [Vietnamese](#đặt-lại-quyền), [second](#step-one-code-1), [dir](../decisions/),
[site](https://example.org/x), [mail](mailto:a@example.org), [template](https://{{app-slug}}.example/x) and
<a id="custom"></a>[custom](#custom).

```sh
cat [not a link](missing.md)
```
EOF
# A footnote definition is not a reference link definition (QA-R66: no false positives).
printf '# B\n\n## Target heading\n\nA note.[^1]\n\n[^1]: The footnote text.\n' >"$K/docs/runbooks/b.md"
printf '# Decision\n\nTest App was the temporary name.\n' >"$K/docs/decisions/0001-x.md"
# Front-door files write the literal brand values (ADR 0400 decision 1, amended 2026-11-13).
printf '# Readme\n\nInstall Test App from [the runbook](docs/runbooks/a.md).\n' >"$K/README.md"
expect 0 "valid links, GitHub slugs (Vietnamese, duplicates, code), footnotes and skipped links pass" \
  python3 -I "$S/check-docs.py" links --root "$K"
printf '\nBroken: [x](missing.md), [y](b.md#nope), [z](#nowhere).\n' >>"$K/docs/runbooks/a.md"
printf 'See [the policy](missing-policy.md).\n' >"$K/SECURITY.md"
expect 1 "broken file and anchors fail" python3 -I "$S/check-docs.py" links --root "$K"
contains "missing file named" "docs/runbooks/a.md:17: link target not found: missing.md"
contains "missing anchor in another file named" "no heading or anchor #nope in docs/runbooks/b.md"
contains "missing anchor in the same file named" "no heading or anchor #nowhere in docs/runbooks/a.md"
contains "front-door links checked" "SECURITY.md:1: link target not found: missing-policy.md"
expect 0 "docs placeholders and front-door literals pass; decision records may name the product" python3 -I "$S/check-docs.py" brand --root "$K"
printf 'Open Test App, then visit https://testapp.example.vn (bundle vn.example.testapp.dev).\n' >"$K/docs/runbooks/b.md"
mkdir -p "$K/docs/support"
printf 'Run testapp-notary.\n' >"$K/docs/support/c.md"
printf 'Install {{AppName}}.\n' >"$K/README.vi.md"
expect 1 "literal brand values in docs and placeholders in the front door fail" python3 -I "$S/check-docs.py" brand --root "$K"
contains "bundle ID reported first on its line" "docs/runbooks/b.md:1: literal bundle ID 'vn.example.testapp.dev'"
contains "slug reported" "docs/support/c.md:1: literal slug ({{app-slug}}) 'testapp'"
contains "front-door placeholder reported" "README.vi.md:1: placeholder {{AppName}} is shown as it is"

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
printf 'engine-fuzz-telex\t%s\n' "$T/minimized-crash-1" >"$T/findings.txt"
expect 0 "fuzz issue dry run" "$S/fuzz-report-issue.sh" "$T/findings.txt" --dry-run
contains "issue title" "Fuzzing finding in engine-fuzz-telex"
contains "hex dump" "63 72 61 73 68"

echo "== bench-compare.sh / fuzz.sh skip cleanly when targets are missing"
expect 0 "bench skips without product" "$S/bench-compare.sh" --package "$T/nopkg" --output "$T/bench.json"
expect 1 "bench --require fails without product" "$S/bench-compare.sh" --package "$T/nopkg" --require --output "$T/bench.json"
expect 0 "fuzz skips without package" "$S/fuzz.sh" --package "$T/nopkg" --out "$T/fuzz"
expect 1 "fuzz --require fails without package" "$S/fuzz.sh" --package "$T/nopkg" --require --out "$T/fuzz"
mkdir -p "$T/benchpkg"
printf '// fake package\n' >"$T/benchpkg/Package.swift"
expect 2 "bench --run needs a formatVersion 1 product" "$S/bench-compare.sh" --package "$T/benchpkg" --output "$T/bench.json"
contains "points the engine at its own gate" "Packages/VietnameseEngine/Scripts/benchmark.sh"
expect 2 "bench needs a baseline without a package" "$S/bench-compare.sh" --results "$T/bench.json" --output "$T/b2.json"

echo "== fuzz.sh builds engine-fuzz for libFuzzer and pins the method (ADR 0502)"
F="$T/fz"
mkdir -p "$F/pkg/Corpus" "$F/bin" "$F/build"
printf '// fake package\n' >"$F/pkg/Package.swift"
printf '@abc\n' >"$F/pkg/Corpus/seed.txt"
# A fake swift records the build command and points at a fake fuzzer that records its own arguments.
cat >"$F/bin/swift" <<EOF
#!/bin/sh
case "\$*" in
  *--show-bin-path*) printf '%s\n' "$F/build" ;;
  *) printf 'swift %s\n' "\$*" ;;
esac
EOF
cat >"$F/build/engine-fuzz" <<'EOF'
#!/bin/sh
printf 'fuzzer method=%s args=%s\n' "${ENGINE_FUZZ_METHOD:-mixed}" "$*"
[ -n "${FAKE_FUZZ_CRASH:-}" ] || exit 0
for arg in "$@"; do
  case "$arg" in -artifact_prefix=*) printf 'boom' >"${arg#-artifact_prefix=}crash-1" ;; esac
done
exit 1
EOF
chmod +x "$F/bin/swift" "$F/build/engine-fuzz"
expect 0 "PR fuzzing builds engine-fuzz with the libFuzzer flags" \
  env PATH="$F/bin:$PATH" "$S/fuzz.sh" --package "$F/pkg" --out "$F/out"
contains "build command" "--product engine-fuzz -Xswiftc -sanitize=fuzzer,address -Xswiftc -parse-as-library -Xswiftc -DLIBFUZZER"
contains "both methods by default" "fuzzer method=mixed"
contains "seed corpus read from Corpus/" "$F/pkg/Corpus"
contains "60 s by default" "-max_total_time=60"
contains "engine README limits" "-max_len=8192 -timeout=10"
expect 0 "nightly run pins the method" \
  env PATH="$F/bin:$PATH" "$S/fuzz.sh" --package "$F/pkg" --method telex --seconds 5 \
  --sanitizers fuzzer,address,undefined --out "$F/out"
contains "ENGINE_FUZZ_METHOD=telex" "fuzzer method=telex"
contains "nightly sanitizers" "-sanitize=fuzzer,address,undefined"
expect 1 "an unknown method is refused" env PATH="$F/bin:$PATH" "$S/fuzz.sh" --package "$F/pkg" --method qwerty
expect 1 "a crash fails and is listed" env PATH="$F/bin:$PATH" FAKE_FUZZ_CRASH=1 \
  "$S/fuzz.sh" --package "$F/pkg" --method vni --out "$F/out"
if grep -Fq "engine-fuzz-vni	$F/out/engine-fuzz-vni/minimized-crash-1" "$F/out/findings.txt"; then
  ok "findings.txt names the run and the minimised input"
else
  ko "findings.txt names the run and the minimised input"; sed 's/^/     /' "$F/out/findings.txt"
fi

echo "== coverage.sh: the drop gate fails closed when a required baseline is missing (QA-R2)"
CV="$T/cov"
mkdir -p "$CV/bin" "$CV/pkg/Sources/Lib"
printf '// swift-tools-version: 6.0\n' >"$CV/pkg/Package.swift"
touch "$CV/pkg/Sources/Lib/A.swift"
printf '{"data":[{"files":[{"filename":"%s","summary":{"lines":{"count":10,"covered":9}}}]}]}\n' \
  "$(cd "$CV/pkg" && pwd)/Sources/Lib/A.swift" >"$CV/codecov.json"
printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$CV/codecov.json" >"$CV/bin/swift"
chmod +x "$CV/bin/swift"
expect 0 "a missing optional baseline only skips the drop check" env PATH="$CV/bin:$PATH" \
  "$S/coverage.sh" --package "$CV/pkg" --min 80 --no-test --baseline "$CV/none.json" --summary-out "$CV/s.json"
contains "skip is reported" "No baseline summary available; drop check skipped."
expect 1 "a missing required baseline fails" env PATH="$CV/bin:$PATH" \
  "$S/coverage.sh" --package "$CV/pkg" --min 80 --no-test --baseline "$CV/none.json" --require-baseline \
  --summary-out "$CV/s.json"
contains "names the missing baseline" "coverage baseline $CV/none.json is missing"
printf '{"percent": 92.5}\n' >"$CV/base.json"
expect 1 "a drop of more than one point fails" env PATH="$CV/bin:$PATH" \
  "$S/coverage.sh" --package "$CV/pkg" --min 80 --no-test --baseline "$CV/base.json" --require-baseline \
  --summary-out "$CV/s.json"
contains "drop reported" "coverage dropped 2.50 points"

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
// SPDX-License-Identifier: GPL-3.0-or-later
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

echo "== run-integration.sh: live harness commands need the runner opt-in (ADR 0502)"
I="$T/ri"
mkdir -p "$I/bin"
# Runs on every host, including the Linux CI job (--no-macos). A fake swift records its arguments, so nothing
# is built and no event is ever posted.
cat >"$I/bin/swift" <<'EOF'
#!/bin/sh
printf 'swift %s\n' "$*"
EOF
chmod +x "$I/bin/swift"
# A fake uname lets the Darwin check pass on the Linux CI runner; the opt-in gate needs no macOS tool.
cat >"$I/bin/uname" <<'EOF'
#!/bin/sh
printf '%s\n' "${FAKE_UNAME:-Darwin}"
EOF
chmod +x "$I/bin/uname"
expect 1 "integration layers refuse to run off macOS" \
  env FAKE_UNAME=Linux COMPAT_HARNESS_LIVE=1 PATH="$I/bin:$PATH" "$S/run-integration.sh" compat --out "$I/out"
contains "names the macOS requirement" "integration layers need macOS"
expect 1 "compat stops before the build without COMPAT_HARNESS_LIVE" \
  env -u COMPAT_HARNESS_LIVE PATH="$I/bin:$PATH" "$S/run-integration.sh" compat --out "$I/out"
contains "names the missing opt-in" "COMPAT_HARNESS_LIVE=1 is not set"
contains "points at the runner runbook" "self-hosted-runner.md"
if grep -Fq "swift " "$T/out"; then ko "nothing is built without the opt-in"; else ok "nothing is built without the opt-in"; fi
expect 1 "soak stops without COMPAT_HARNESS_LIVE=1 exactly" \
  env COMPAT_HARNESS_LIVE=yes PATH="$I/bin:$PATH" "$S/run-integration.sh" soak --out "$I/out"
expect 0 "compat runs the harness by product name with the opt-in" \
  env COMPAT_HARNESS_LIVE=1 PATH="$I/bin:$PATH" "$S/run-integration.sh" compat --out "$I/out"
contains "agreed command line" "compat-harness run --scenarios compat/scenarios --output $I/out/compat"
expect 0 "a dry run needs no opt-in" env -u COMPAT_HARNESS_LIVE PATH="$I/bin:$PATH" \
  COMPAT_HARNESS_RUN_ARGS="run --scenarios compat/scenarios --dry-run" "$S/run-integration.sh" compat --out "$I/out"
contains "dry-run arguments passed through" "compat-harness run --scenarios compat/scenarios --dry-run"

echo "== run-integration.sh: TestHost suite, bench, soak and the hooks test build (W3-A, ADR 0502)"
# The fake swift writes formatVersion 1 results where the harness would, so the real bench-compare.sh runs.
cat >"$I/bin/swift" <<'EOF'
#!/bin/sh
printf 'swift %s\n' "$*"
out=""
prev=""
for arg in "$@"; do
  [ "$prev" = "--output" ] && out="$arg"
  prev="$arg"
done
metric='"calibrated":false,"unit":"ms","budget":100,"value":'"${FAKE_T2:-2}"
case " $* " in
  *" bench "*) printf '{"formatVersion":1,"benchmark":"platform","calibration":{"name":"r","nanoseconds":1},"metrics":{"T2.p99":{%s}}}\n' "$metric" >"$out" ;;
  *" soak "*)
    mkdir -p "$out"
    if [ -n "${FAKE_SOAK_METRICS:-}" ]; then
      printf '{"formatVersion":1,"benchmark":"platform-soak","calibration":{"name":"r","nanoseconds":1},"metrics":{"M2.growthMBPerHour":{"calibrated":false,"unit":"MB/h","budget":5,"value":%s}}}\n' \
        "$FAKE_SOAK_METRICS" >"$out/soak-metrics.json"
    fi ;;
esac
EOF
chmod +x "$I/bin/swift"
expect 0 "tests runs the TestHost suite through the harness" \
  env COMPAT_HARNESS_LIVE=1 PATH="$I/bin:$PATH" "$S/run-integration.sh" tests --out "$I/out"
contains "TestHost command line" "compat-harness run --scenarios compat/scenarios --only testhost.* --output $I/out/tests"
if grep -Fq "xcodebuild" "$T/out"; then ko "tests no longer runs xcodebuild test"; else ok "tests no longer runs xcodebuild test"; fi
expect 1 "tests needs the opt-in" env -u COMPAT_HARNESS_LIVE PATH="$I/bin:$PATH" "$S/run-integration.sh" tests --out "$I/out"
expect 0 "bench defaults to five runs and perf/platform-baseline.json" \
  env COMPAT_HARNESS_LIVE=1 PATH="$I/bin:$PATH" "$S/run-integration.sh" bench --out "$I/out"
contains "five runs by default (QA-R14)" "compat-harness bench --runs 5 --output $I/out/platform-bench.json"
if [[ -f "$I/out/platform-bench-median.json" ]]; then ok "bench writes the median"; else ko "bench writes the median"; fi
# 4 ms against the 3 ms placeholder baseline is 33 % slower: only perf/platform-baseline.json makes this fail.
expect 1 "bench compares with perf/platform-baseline.json" \
  env COMPAT_HARNESS_LIVE=1 FAKE_T2=4 PATH="$I/bin:$PATH" "$S/run-integration.sh" bench --out "$I/out"
contains "regression against the platform baseline" "T2.p99"
printf '{"formatVersion":1,"benchmark":"platform","calibration":{"name":"r","nanoseconds":1},"metrics":{"T2.p99":{"calibrated":false,"unit":"ms","value":4}}}\n' >"$I/baseline.json"
expect 0 "PLATFORM_BASELINE overrides the default" env COMPAT_HARNESS_LIVE=1 FAKE_T2=4 PLATFORM_BASELINE="$I/baseline.json" \
  COMPAT_HARNESS_BENCH_RUNS=1 PATH="$I/bin:$PATH" "$S/run-integration.sh" bench --out "$I/out"
contains "COMPAT_HARNESS_BENCH_RUNS sets the runs" "compat-harness bench --runs 1 --output"
expect 1 "COMPAT_HARNESS_BENCH_RUNS must be a positive integer" \
  env COMPAT_HARNESS_LIVE=1 COMPAT_HARNESS_BENCH_RUNS=0 PATH="$I/bin:$PATH" "$S/run-integration.sh" bench --out "$I/out"
expect 0 "soak without M2 skips the comparison" \
  env COMPAT_HARNESS_LIVE=1 PATH="$I/bin:$PATH" "$S/run-integration.sh" soak --out "$I/out"
if [[ -f "$I/out/soak/soak-metrics-median.json" ]]; then ko "no soak comparison without M2"; else ok "no soak comparison without M2"; fi
expect 0 "soak compares M2 with the baseline" \
  env COMPAT_HARNESS_LIVE=1 FAKE_SOAK_METRICS=1 PATH="$I/bin:$PATH" "$S/run-integration.sh" soak --out "$I/out"
if [[ -f "$I/out/soak/soak-metrics-median.json" ]]; then ok "soak writes the M2 median"; else ko "soak writes the M2 median"; fi
expect 1 "soak fails on M2 growth over the baseline" \
  env COMPAT_HARNESS_LIVE=1 FAKE_SOAK_METRICS=9 PATH="$I/bin:$PATH" "$S/run-integration.sh" soak --out "$I/out"

# build: fake xcodegen, xcodebuild and ditto record their arguments and lay out the products xcodebuild would.
cat >"$I/bin/xcodegen" <<'EOF'
#!/bin/sh
printf 'xcodegen %s\n' "$*"
EOF
cat >"$I/bin/xcodebuild" <<'EOF'
#!/bin/sh
printf 'xcodebuild %s\n' "$*"
. "$FAKE_BRAND_ENV"
derived=""
config=""
scheme=""
prev=""
for arg in "$@"; do
  case "$prev" in
    -derivedDataPath) derived="$arg" ;;
    -configuration) config="$arg" ;;
    -scheme) scheme="$arg" ;;
  esac
  prev="$arg"
done
name="TestHost"
[ "$scheme" = "App" ] && name="$APP_DISPLAY_NAME"
dir="$derived/Build/Products/$config/$name.app/Contents/MacOS"
mkdir -p "$dir"
printf 'binary %s\n' "${FAKE_BINARY_TEXT:-}" >"$dir/$name"
chmod +x "$dir/$name"
EOF
cat >"$I/bin/ditto" <<'EOF'
#!/bin/sh
cp -R "$1" "$2"
EOF
# Fake process table: $FAKE_PROCESS_FILE holds the executable path of one running process (absent: none). pgrep
# matches its pattern against that path; pkill -TERM ends it unless FAKE_IGNORES_TERM is set, pkill -KILL unless
# FAKE_UNKILLABLE is set.
cat >"$I/bin/pgrep" <<'EOF'
#!/bin/sh
for last; do :; done
[ -f "${FAKE_PROCESS_FILE:-/nonexistent}" ] && grep -Eq -- "$last" "$FAKE_PROCESS_FILE"
EOF
cat >"$I/bin/pkill" <<'EOF'
#!/bin/sh
printf 'pkill %s\n' "$*"
for last; do :; done
{ [ -f "${FAKE_PROCESS_FILE:-/nonexistent}" ] && grep -Eq -- "$last" "$FAKE_PROCESS_FILE"; } || exit 1
case "$1" in
  -TERM) [ -n "${FAKE_IGNORES_TERM:-}" ] && exit 0 ;;
  -KILL) [ -n "${FAKE_UNKILLABLE:-}" ] && exit 0 ;;
esac
[ -d "${FAKE_INSTALLED_APP:-/nonexistent}" ] && printf 'ended while the old copy was installed\n'
rm -f "$FAKE_PROCESS_FILE"
EOF
chmod +x "$I/bin/xcodegen" "$I/bin/xcodebuild" "$I/bin/ditto" "$I/bin/pgrep" "$I/bin/pkill"
marker="$(sed -n 's/^HOOKS_MARKER="\(.*\)"$/\1/p' "$S/run-integration.sh")"
display_name="$(. "$S/brand.env" && printf '%s' "$APP_DISPLAY_NAME")"
expect 1 "build needs the opt-in" env -u COMPAT_HARNESS_LIVE FAKE_BRAND_ENV="$S/brand.env" PATH="$I/bin:$PATH" \
  INTEGRATION_APP_DIR="$I/apps" INTEGRATION_DERIVED_DATA="$I/dd" "$S/run-integration.sh" build --out "$I/out"
if grep -Fq "xcodebuild " "$T/out"; then ko "build stops before xcodebuild without the opt-in"; else ok "build stops before xcodebuild without the opt-in"; fi
expect 0 "build installs the hooks test build and TestHost" env COMPAT_HARNESS_LIVE=1 FAKE_BRAND_ENV="$S/brand.env" \
  FAKE_BINARY_TEXT="$marker" PATH="$I/bin:$PATH" INTEGRATION_APP_DIR="$I/apps" INTEGRATION_DERIVED_DATA="$I/dd" \
  "$S/run-integration.sh" build --out "$I/out"
contains "the app uses the Integration configuration" "-scheme App -configuration Integration -derivedDataPath $I/dd"
if [[ -e "$I/out/DerivedData" || -e "$I/out/Build" ]]; then ko "derived data stays out of the uploaded output"; else ok "derived data stays out of the uploaded output"; fi
contains "TestHost is built too" "-scheme TestHost -configuration Debug"
contains "package targets build for the active architecture only" \
  "-disableAutomaticPackageResolution ONLY_ACTIVE_ARCH=YES build"
if grep -Fq "pkill" "$T/out"; then ko "nothing is terminated when no copy runs"; else ok "nothing is terminated when no copy runs"; fi
contains "package versions stay pinned (PLT-R910)" "-disableAutomaticPackageResolution"
if [[ -x "$I/apps/$display_name.app/Contents/MacOS/$display_name" && -d "$I/apps/TestHost.app" ]]; then
  ok "both apps installed at the fixed path"
else
  ko "both apps installed at the fixed path"
fi
if grep -Fq "CODE_SIGN_IDENTITY=" "$T/out"; then
  ko "the default build keeps the identity of Config/Integration.xcconfig"
else
  ok "the default build keeps the identity of Config/Integration.xcconfig"
fi
# INTEGRATION_CODE_SIGN_IDENTITY=- (the tart VM, integration-suite.md section 10): ad hoc, hardened runtime off.
expect 0 "an ad-hoc test build needs no Apple Development identity" env COMPAT_HARNESS_LIVE=1 \
  INTEGRATION_CODE_SIGN_IDENTITY=- FAKE_BRAND_ENV="$S/brand.env" FAKE_BINARY_TEXT="$marker" PATH="$I/bin:$PATH" \
  INTEGRATION_APP_DIR="$I/apps" INTEGRATION_DERIVED_DATA="$I/dd" "$S/run-integration.sh" build --out "$I/out"
contains "ad hoc without the hardened runtime for the app" "-scheme App -configuration Integration -derivedDataPath $I/dd -disableAutomaticPackageResolution ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= OTHER_CODE_SIGN_FLAGS= ENABLE_HARDENED_RUNTIME=NO build"
contains "TestHost stays as it is" "-scheme TestHost -configuration Debug -derivedDataPath $I/dd -disableAutomaticPackageResolution ONLY_ACTIVE_ARCH=YES build"
contains "the ad-hoc build is named" "ad hoc"
expect 1 "only - is accepted as an override identity" env COMPAT_HARNESS_LIVE=1 \
  INTEGRATION_CODE_SIGN_IDENTITY="Apple Development" FAKE_BRAND_ENV="$S/brand.env" FAKE_BINARY_TEXT="$marker" \
  PATH="$I/bin:$PATH" INTEGRATION_APP_DIR="$I/apps" INTEGRATION_DERIVED_DATA="$I/dd" "$S/run-integration.sh" build \
  --out "$I/out"
contains "names the accepted value" "INTEGRATION_CODE_SIGN_IDENTITY accepts only -"
if grep -Fq "xcodebuild " "$T/out"; then ko "a bad identity stops before xcodebuild"; else ok "a bad identity stops before xcodebuild"; fi
build_with_running() { # build_with_running <expected exit> <name> <running executable> [VAR=value...]
  local want="$1" name="$2" running="$3"
  shift 3
  printf '%s\n' "$running" >"$I/running"
  expect "$want" "$name" env COMPAT_HARNESS_LIVE=1 FAKE_BRAND_ENV="$S/brand.env" FAKE_BINARY_TEXT="$marker" \
    FAKE_PROCESS_FILE="$I/running" INTEGRATION_QUIT_TIMEOUT=1 "$@" PATH="$I/bin:$PATH" INTEGRATION_APP_DIR="$I/apps" \
    INTEGRATION_DERIVED_DATA="$I/dd" "$S/run-integration.sh" build --out "$I/out"
}
build_with_running 0 "build ends the copy still running from the installed path" \
  "$I/apps/$display_name.app/Contents/MacOS/$display_name" FAKE_INSTALLED_APP="$I/apps/$display_name.app"
contains "SIGTERM by a pattern anchored on the path" "pkill -TERM -f -- ^"
contains "metacharacters of the installed path escaped" "/apps/$display_name\.app/Contents/MacOS/"
contains "ended before the replacement" "ended while the old copy was installed"
if [[ -f "$I/running" ]]; then ko "the stale copy is gone"; else ok "the stale copy is gone"; fi
build_with_running 0 "a copy that ignores SIGTERM is killed after the wait" \
  "$I/apps/TestHost.app/Contents/MacOS/TestHost" FAKE_IGNORES_TERM=1
contains "SIGKILL after the bounded wait" "pkill -KILL -f -- ^"
contains "SIGKILL for the TestHost path" "/apps/TestHost\.app/Contents/MacOS/"
build_with_running 1 "build stops when the stale copy survives" \
  "$I/apps/$display_name.app/Contents/MacOS/$display_name" FAKE_IGNORES_TERM=1 FAKE_UNKILLABLE=1
contains "names the surviving copy" "is still running"
build_with_running 0 "a process elsewhere is left alone" "/Applications/$display_name.app/Contents/MacOS/$display_name"
if grep -Fq "pkill" "$T/out"; then ko "only the installed path is matched"; else ok "only the installed path is matched"; fi
rm -f "$I/running"
expect 1 "build refuses a test build without the hooks" env COMPAT_HARNESS_LIVE=1 FAKE_BRAND_ENV="$S/brand.env" \
  PATH="$I/bin:$PATH" INTEGRATION_APP_DIR="$I/apps" INTEGRATION_DERIVED_DATA="$I/dd" \
  "$S/run-integration.sh" build --out "$I/out"
contains "names the missing condition" "INTEGRATION_HOOKS missing"

if [[ $no_macos -eq 0 ]]; then
  echo "== macOS release tooling (ad-hoc signed fake app)"
  M="$T/mac"
  mkdir -p "$M"
  cp -R "$R/scripts" "$M/scripts"
  cp "$T/brand.env" "$M/scripts/brand.env"
  mkdir -p "$M/Config" "$M/packaging"
  cp "$REPO/Config/Signing.xcconfig" "$M/Config/"
  cp -R "$REPO/packaging/homebrew" "$M/packaging/"
  cp "$REPO/LICENSE" "$REPO/THIRD_PARTY_NOTICES.md" "$M/"
  # publish-release inlines the release-notes stylesheet into each notes page (PLT-R906).
  mkdir -p "$M/site/static/assets"
  cp "$REPO/site/static/assets/release-notes.css" "$M/site/static/assets/"
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
<key>SUPublicEDKey</key><string>pfIShU4dEXqPd5ObYNfDBiQWcXozk7estwzTnF9BamQ=</string>
</dict></plist>
EOF
  printf '#!/bin/sh\nexit 0\n' >"$app/Contents/MacOS/Test"
  chmod +x "$app/Contents/MacOS/Test"
  codesign --force --sign - "$app" >/dev/null 2>&1
  expect 0 "make-dmg (unsigned)" "$M/scripts/make-dmg.sh" "$app" --no-sign
  dmg="$M/dist/testapp-1.2.3/testapp-1.2.3.dmg"
  if [[ -f "$dmg" ]]; then ok "DMG created"; else ko "DMG created"; fi
  if hdiutil imageinfo "$dmg" >/dev/null 2>&1; then ok "DMG is a valid image"; else ko "DMG is a valid image"; fi
  # GPL-3.0 section 4 (ADR 0006): the DMG carries the licence text and the third-party notices. A fake hdiutil
  # records the staging folder instead of building a second image.
  mkdir -p "$M/fakebin"
  cat >"$M/fakebin/hdiutil" <<'EOF'
#!/bin/sh
[ "$1" = create ] || exit 0
while [ $# -gt 0 ]; do
  if [ "$1" = -srcfolder ]; then ls -A "$2" >"$FAKE_DMG_LIST"; cmp -s "$2/LICENSE.txt" "$FAKE_LICENSE" && echo same >>"$FAKE_DMG_LIST"; fi
  shift
done
EOF
  chmod +x "$M/fakebin/hdiutil"
  expect 0 "make-dmg stages the licence files" env PATH="$M/fakebin:$PATH" FAKE_DMG_LIST="$M/staged" \
    FAKE_LICENSE="$REPO/LICENSE" "$M/scripts/make-dmg.sh" "$app" --no-sign --out "$M/listed.dmg"
  for staged in "Test App.app" Applications LICENSE.txt THIRD_PARTY_NOTICES.txt same; do
    if grep -qx "$staged" "$M/staged" 2>/dev/null; then ok "DMG contains $staged"; else ko "DMG contains $staged"; fi
  done
  mv "$M/LICENSE" "$M/LICENSE.off"
  expect 1 "make-dmg refuses to build without the licence" env PATH="$M/fakebin:$PATH" FAKE_DMG_LIST="$M/staged" \
    FAKE_LICENSE="$REPO/LICENSE" "$M/scripts/make-dmg.sh" "$app" --no-sign --out "$M/listed.dmg"
  contains "names the missing licence" "LICENSE is missing at the repository root"
  mv "$M/LICENSE.off" "$M/LICENSE"
  codesign --force --sign - "$dmg" >/dev/null 2>&1
  ditto -c -k --sequesterRsrc --keepParent "$app" "$M/dist/testapp-1.2.3/testapp-1.2.3.zip"
  (cd "$M" && git init -q && git add -A)
  expect 0 "publish-release dry run" "$M/scripts/publish-release" 1.2.3 --skip-attestation --skip-gatekeeper
  contains "appcast item printed" "<sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>"
  contains "phased rollout for stable" "<sparkle:phasedRolloutInterval>86400</sparkle:phasedRolloutInterval>"
  # ADR 0304 amendment: one bilingual release-notes page, linked once, without xml:lang variants.
  contains "single release-notes link" \
    "<sparkle:releaseNotesLink>https://testapp.example.vn/release-notes/1.2.3/</sparkle:releaseNotesLink>"
  if grep -q 'xml:lang' "$T/out"; then ko "no xml:lang variants in the appcast item"; else ok "no xml:lang variants in the appcast item"; fi
  contains "notes page links the Vietnamese changelog" 'href="https://testapp.example.vn/nhat-ky-thay-doi/#v1.2.3"'
  contains "notes page links the English changelog" 'href="https://testapp.example.vn/en/changelog/#v1.2.3"'
  contains "notes page carries the release notes" "<li>First public test</li>"
  contains "releases.json entry printed" "\"dmgUrl\": \"https://testapp.example.vn/download/testapp-1.2.3.dmg\""
  contains "cask rendered" "cask \"testapp\" do"
  # shellcheck disable=SC2088 # literal text in the rendered cask, not a path to expand
  contains "zap uses the folder rule" "~/Library/Application Support/Test App"
  if [[ ! -e "$M/site/static/appcast.xml" && ! -e "$M/site/data/releases.json" && ! -e "$M/site/static/release-notes" ]]; then
    ok "dry run leaves the repository untouched"
  else
    ko "dry run wrote into the repository"
  fi
  expect 1 "--skip-gatekeeper refused with --apply" "$M/scripts/publish-release" 1.2.3 --apply --skip-gatekeeper --skip-attestation
  expect 1 "beta version needs --beta" "$M/scripts/publish-release" 1.3.0-beta.1 --skip-attestation --skip-gatekeeper
  # PRD-R51 and QA-R32: release notes are checked before sign_update can prompt for the keychain.
  printf '#!/bin/sh\n: >"%s"\nexit 1\n' "$T/sign-called" >"$T/fake-sign-update"
  chmod +x "$T/fake-sign-update"
  expect 1 "--apply without Vietnamese notes fails" env SPARKLE_SIGN_UPDATE="$T/fake-sign-update" \
    "$M/scripts/publish-release" 1.2.3 --apply --skip-attestation
  contains "missing Vietnamese notes named" "no Vietnamese notes for 1.2.3"
  if [[ -e "$T/sign-called" ]]; then ko "missing notes fail before sign_update"; else ok "missing notes fail before sign_update"; fi
  cp "$M/CHANGELOG.md" "$T/changelog-short.md"
  printf '## [1.2.3] - 2026-11-13\n- a\n- b\n- c\n- d\n- e\n- f\n' >"$M/CHANGELOG.md"
  expect 1 "notes above five visible lines are refused" env SPARKLE_SIGN_UPDATE="$T/fake-sign-update" \
    "$M/scripts/publish-release" 1.2.3 --sign-in-dry-run --skip-attestation --skip-gatekeeper
  contains "long notes cite PRD-R51" "PRD-R51 allows at most 5"
  if [[ -e "$T/sign-called" ]]; then ko "long notes fail before sign_update"; else ok "long notes fail before sign_update"; fi
  cp "$T/changelog-short.md" "$M/CHANGELOG.md"

  echo "== publish-release: the signing key is the one installed apps trust (QA-R33, PLT-R1102)"
  K="$T/sparkle-bin"
  mkdir -p "$K"
  app_key="pfIShU4dEXqPd5ObYNfDBiQWcXozk7estwzTnF9BamQ="
  old_key="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
  # Fakes: generate_keys prints FAKE_KEYCHAIN_KEY (and fails without -p: it must never create a key);
  # sign_update signs with a fixed signature and fails --verify when FAKE_VERIFY_FAILS is set.
  cat >"$K/generate_keys" <<'EOF'
#!/bin/sh
printf 'generate_keys %s\n' "$*" >>"$FAKE_SPARKLE_LOG"
case " $* " in *" -p "*) ;; *) exit 9 ;; esac
printf '%s\n' "$FAKE_KEYCHAIN_KEY"
EOF
  cat >"$K/sign_update" <<'EOF'
#!/bin/sh
printf 'sign_update %s\n' "$*" >>"$FAKE_SPARKLE_LOG"
case " $* " in
  *" --verify "*) [ -z "${FAKE_VERIFY_FAILS:-}" ]; exit ;;
esac
for last; do :; done
printf 'sparkle:edSignature="%s" length="%s"\n' "$(printf 'S%.0s' $(seq 86))==" "$(stat -f %z "$last")"
EOF
  chmod +x "$K/generate_keys" "$K/sign_update"
  publish_signed() { # publish_signed <expected exit> <name> <keychain key> [publish-release options...]
    local want="$1" name="$2" key="$3"
    shift 3
    : >"$K/log"
    expect "$want" "$name" env SPARKLE_SIGN_UPDATE="$K/sign_update" FAKE_SPARKLE_LOG="$K/log" FAKE_KEYCHAIN_KEY="$key" \
      "$M/scripts/publish-release" 1.2.3 --sign-in-dry-run --skip-attestation --skip-gatekeeper "$@"
  }
  publish_signed 1 "a keychain key other than the app's SUPublicEDKey is refused" "$old_key"
  contains "names the mismatch" "does not match the SUPublicEDKey"
  if grep -q '^sign_update' "$K/log"; then ko "nothing is signed with the wrong key"; else ok "nothing is signed with the wrong key"; fi
  publish_signed 0 "the app's own key signs" "$app_key" --sparkle-account release
  if grep -qx 'generate_keys --account release -p' "$K/log"; then
    ok "the public half is read with -p for the chosen account"
  else
    ko "the public half is read with -p for the chosen account"; sed 's/^/     /' "$K/log"
  fi
  if grep -q '^sign_update --account release ' "$K/log" && grep -q '^sign_update --verify ' "$K/log"; then
    ok "signed and verified with the same account"
  else
    ko "signed and verified with the same account"; sed 's/^/     /' "$K/log"
  fi
  FAKE_VERIFY_FAILS=1 publish_signed 1 "a failed sign_update --verify is fatal" "$app_key"
  contains "names the verification" "sign_update --verify rejected the signature"
  publish_signed 0 "a key rotation release (R1) is signed with the old key" "$old_key" --rotating-from-key "$old_key"
  contains "the rotation is announced" "key rotation: signing with the old key"
  publish_signed 1 "--rotating-from-key still has to match the keychain key" "$app_key" --rotating-from-key "$old_key"
  publish_signed 1 "a malformed --rotating-from-key is refused" "$app_key" --rotating-from-key "not-a-key"
  expect 1 "an unpinned sign_update from another project's DerivedData is never used" \
    grep -q 'Library/Developer/Xcode/DerivedData' "$M/scripts/publish-release"

  echo "== publish-release: a stable release needs 72 hours on beta (QA-R29)"
  expect 0 "a dry run of a stable without a beta warns" "$M/scripts/publish-release" 1.2.3 --skip-attestation --skip-gatekeeper
  contains "the QA-R29 warning" "QA-R29: no 1.2.3-beta.N on the beta channel for at least 72 hours"
  printf -- '- Sửa lỗi\n' >"$T/notes-vi.md"
  rm -f "$T/sign-called"
  expect 1 "--apply refuses a stable without 72 hours on beta" env SPARKLE_SIGN_UPDATE="$T/fake-sign-update" \
    "$M/scripts/publish-release" 1.2.3 --apply --skip-attestation --notes-vi "$T/notes-vi.md"
  contains "the QA-R29 error" "QA-R29: no 1.2.3-beta.N on the beta channel for at least 72 hours"
  if [[ -e "$T/sign-called" ]]; then ko "QA-R29 fails before sign_update"; else ok "QA-R29 fails before sign_update"; fi
  expect 0 "--p0-hotfix skips the beta period" "$M/scripts/publish-release" 1.2.3 --p0-hotfix --skip-attestation \
    --skip-gatekeeper
  contains "the hotfix is named" "P0 hotfix: QA-R29 beta period skipped, phased rollout off (QA-R35)"
  if grep -q 'phasedRolloutInterval' "$T/out"; then ko "a P0 hotfix is not phased"; else ok "a P0 hotfix is not phased"; fi
  mkdir -p "$M/site/data"
  printf '{"schemaVersion": 1, "releases": [{"version": "1.2.3-beta.2", "channel": "beta", "date": "%s"}]}\n' \
    "$(date -u -v-4d +%Y-%m-%d)" >"$M/site/data/releases.json"
  expect 0 "a beta four days old satisfies QA-R29" "$M/scripts/publish-release" 1.2.3 --skip-attestation --skip-gatekeeper
  if grep -q 'QA-R29' "$T/out"; then ko "no QA-R29 warning after the beta period"; else ok "no QA-R29 warning after the beta period"; fi
  rm -f "$M/site/data/releases.json"

  expect 0 "build-release dry run" bash -c "cd '$M' && touch project.yml && scripts/build-release.sh 1.2.3 1020399 --dry-run"
  contains "archive command" "MARKETING_VERSION=1.2.3"
  contains "no base entitlements" "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO"
  # PLT-R910, ADR 0301: the committed Package.resolved is the only source of package versions.
  contains "package versions stay pinned in the release archive" "-disableAutomaticPackageResolution"
  contains "dry run announces the nested re-sign" "remove Sparkle.framework XPCServices"

  echo "== build-release.sh re-signs Sparkle's helpers inside out (PLT-R750, PLT-R908, PLT-R909)"
  # Fake xcodegen, xcodebuild and codesign: the archive holds an app that embeds a Sparkle.framework laid out like
  # the pinned 2.10.1 one; codesign records every signing call and answers --display with FAKE_AUTHORITY.
  BR="$T/br"
  mkdir -p "$BR/bin"
  cat >"$BR/bin/xcodegen" <<'EOF'
#!/bin/sh
exit 0
EOF
  cat >"$BR/bin/xcodebuild" <<'EOF'
#!/bin/sh
case " $* " in *" archive "*) ;; *) echo "Xcode 27.2"; exit 0 ;; esac
archive=""; version=""; build=""; prev=""
for arg in "$@"; do
  [ "$prev" = "-archivePath" ] && archive="$arg"
  case "$arg" in MARKETING_VERSION=*) version="${arg#*=}" ;; CURRENT_PROJECT_VERSION=*) build="${arg#*=}" ;; esac
  prev="$arg"
done
app="$archive/Products/Applications/Test App.app/Contents"
fw="$app/Frameworks/Sparkle.framework"
mkdir -p "$app/MacOS" "$fw/Versions/B/XPCServices/Installer.xpc/Contents/MacOS" \
  "$fw/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS" "$fw/Versions/B/Updater.app/Contents/MacOS"
printf 'binary\n' >"$app/MacOS/Test"
printf 'binary\n' >"$fw/Versions/B/Sparkle"
printf 'binary\n' >"$fw/Versions/B/Autoupdate"
ln -s B "$fw/Versions/Current"
ln -s Versions/Current/Sparkle "$fw/Sparkle"
ln -s Versions/Current/Autoupdate "$fw/Autoupdate"
ln -s Versions/Current/XPCServices "$fw/XPCServices"
cat >"$app/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$build</string>
</dict></plist>
PLIST
EOF
  cat >"$BR/bin/codesign" <<'EOF'
#!/bin/sh
case " $* " in
  *" --display "*) printf 'Executable=x\nAuthority=%s\nAuthority=Developer ID Certification Authority\n' "$FAKE_AUTHORITY" >&2 ;;
  *)
    for last; do :; done
    printf 'codesign %s\n' "$*" >>"$FAKE_CODESIGN_LOG"
    printf '%s\n' "$last" >>"$FAKE_CODESIGN_LOG.targets" ;;
esac
EOF
  chmod +x "$BR/bin/xcodegen" "$BR/bin/xcodebuild" "$BR/bin/codesign"
  team="$(sed -n 's/^DEVELOPMENT_TEAM = //p' "$M/Config/Signing.xcconfig")"
  authority="Developer ID Application: Test Person ($team)"
  : >"$BR/codesign.log"
  : >"$BR/codesign.log.targets"
  expect 0 "signed release build" env PATH="$BR/bin:$PATH" FAKE_CODESIGN_LOG="$BR/codesign.log" \
    FAKE_AUTHORITY="$authority" "$M/scripts/build-release.sh" 1.2.3 1020399 --keychain "$BR/ci.keychain" --out "$BR/out"
  fw="$BR/out/Test App.app/Contents/Frameworks/Sparkle.framework"
  if [[ ! -e "$fw/Versions/B/XPCServices" && ! -L "$fw/XPCServices" ]]; then
    ok "unused XPC services removed from the shipped framework (PLT-R909)"
  else
    ko "unused XPC services removed from the shipped framework (PLT-R909)"
  fi
  if [[ -d "$BR/out/App.xcarchive/Products/Applications/Test App.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" ]]; then
    ok "the archive itself is left as Xcode wrote it"
  else
    ko "the archive itself is left as Xcode wrote it"
  fi
  signed="$(sed "s#^$BR/out/##" "$BR/codesign.log.targets")"
  expected_order="$(printf '%s\n' "Test App.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" \
    "Test App.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" \
    "Test App.app/Contents/Frameworks/Sparkle.framework" "Test App.app")"
  if [[ "$signed" == "$expected_order" ]]; then
    ok "helpers, then the framework, then the app are signed, in that order"
  else
    ko "helpers, then the framework, then the app are signed, in that order"; sed 's/^/     /' "$BR/codesign.log"
  fi
  if [[ "$(grep -c -F -- "--force --sign $authority --options runtime --timestamp --keychain $BR/ci.keychain" "$BR/codesign.log")" == 4 ]]; then
    ok "every re-sign uses the app's Developer ID, hardened runtime, a secure timestamp and the CI keychain"
  else
    ko "every re-sign uses the app's Developer ID, hardened runtime, a secure timestamp and the CI keychain"
    sed 's/^/     /' "$BR/codesign.log"
  fi
  if grep -q -- '--deep' "$BR/codesign.log"; then ko "no --deep (Sparkle documentation)"; else ok "no --deep (Sparkle documentation)"; fi
  if grep -F -- "--preserve-metadata=identifier,entitlements,flags $BR/out/Test App.app" "$BR/codesign.log" >/dev/null; then
    ok "the app keeps its identifier and flags when re-sealed"
  else
    ko "the app keeps its identifier and flags when re-sealed"
  fi
  expect 1 "a build Xcode did not sign with Developer ID is refused" env PATH="$BR/bin:$PATH" \
    FAKE_CODESIGN_LOG="$BR/codesign.log" FAKE_AUTHORITY="Apple Development: Test Person (ABCDE12345)" \
    "$M/scripts/build-release.sh" 1.2.3 1020399 --out "$BR/out2"
  contains "names the expected identity" "not signed with Developer ID Application for team $team"

  echo "== notarize.sh credential choice (dry run, nothing is submitted)"
  expect 0 "notarize dry run with the default profile" env -u NOTARY_KEYCHAIN_PROFILE -u ASC_API_KEY_PATH \
    "$M/scripts/notarize.sh" "$dmg" --dry-run
  contains "default keychain profile is <slug>-notary" 'notarytool keychain profile "testapp-notary"'
  expect 0 "NOTARY_KEYCHAIN_PROFILE overrides the default" env -u ASC_API_KEY_PATH NOTARY_KEYCHAIN_PROFILE=pa-notary \
    "$M/scripts/notarize.sh" "$app" --dry-run
  contains "profile from the environment" 'notarytool keychain profile "pa-notary"'
  contains "an app is zipped for submission" "would zip Test App.app"
  printf 'not a real key' >"$T/AuthKey_TEST.p8"
  expect 0 "API key environment wins" env ASC_API_KEY_PATH="$T/AuthKey_TEST.p8" ASC_API_KEY_ID=K ASC_API_ISSUER_ID=I \
    "$M/scripts/notarize.sh" "$dmg" --dry-run
  contains "API key source named" "App Store Connect API key (ASC_API_KEY_PATH"
  expect 1 "API key path without its ID is refused" env -u ASC_API_KEY_ID ASC_API_KEY_PATH="$T/AuthKey_TEST.p8" \
    "$M/scripts/notarize.sh" "$dmg" --dry-run

  echo "== make-dmg.sh retries a busy hdiutil"
  mkdir -p "$T/fakebin"
  cat >"$T/fakebin/hdiutil" <<'EOF'
#!/bin/sh
# Fails the first "create" like a busy disk image subsystem, then succeeds.
case "$1" in
  create)
    if [ ! -f "$FAKE_HDIUTIL_STATE" ]; then : >"$FAKE_HDIUTIL_STATE"; echo "hdiutil: create failed - Resource busy" >&2; exit 1; fi
    for last; do :; done
    : >"$last" ;;
esac
exit 0
EOF
  chmod +x "$T/fakebin/hdiutil"
  expect 0 "make-dmg succeeds after one busy hdiutil create" env PATH="$T/fakebin:$PATH" \
    FAKE_HDIUTIL_STATE="$T/hdiutil-state" "$M/scripts/make-dmg.sh" "$app" --no-sign --out "$T/retry.dmg"
  contains "retry announced" "hdiutil create failed (attempt 1); retrying"

  echo "== verify-release.sh: Sparkle public key gate (ADR 0304)"
  # The ad-hoc app fails the Developer ID checks anyway; only the key check's own result matters here.
  expect 1 "verify-release with a missing previous requirement file" "$M/scripts/verify-release.sh" --app "$app" \
    --pre-notarization --previous-dr "$T/no-such-dr.txt"
  contains "missing previous requirement named" "previous designated requirement file not found"
  expect 1 "verify-release on an ad-hoc test app" "$M/scripts/verify-release.sh" --app "$app" --pre-notarization
  contains "public key present passes" "ok: Sparkle public EdDSA key (SUPublicEDKey)"
  contains "an app without nested code passes the nested-code check" "ok: nested code signed with Developer ID"
  # ADR 0502: the marker proves the App-side hooks adapter is absent, not every hooks type (AppCore's hook server
  # and watcher are linked into every configuration, unused without the adapter); the label says exactly that.
  contains "a build without the hooks passes the hooks check" "ok: no integration hooks adapter (INTEGRATION_HOOKS test build marker)"
  # PLT-R750, PLT-R908: an ad-hoc helper inside the bundle (as Sparkle ships its helpers) must fail before
  # notarisation; codesign --verify --deep --strict alone accepts it.
  nested="$M/nested/$(basename "$app")"
  mkdir -p "$M/nested"
  cp -R "$app" "$nested"
  cp /usr/bin/true "$nested/Contents/MacOS/helper"
  codesign --force --sign - "$nested/Contents/MacOS/helper" >/dev/null 2>&1
  # A data-only bundle (like a SwiftPM resource bundle) holds no code: the app's seal covers it as resources.
  mkdir -p "$nested/Contents/Resources/Data.bundle/Contents/Resources"
  printf 'data\n' >"$nested/Contents/Resources/Data.bundle/Contents/Resources/words.txt"
  codesign --force --sign - "$nested" >/dev/null 2>&1
  expect 1 "verify-release fails on an ad-hoc nested executable" "$M/scripts/verify-release.sh" --app "$nested" \
    --pre-notarization
  contains "deep verification alone accepts it" "ok: codesign --verify --deep --strict"
  contains "nested code check fails" "FAILED: nested code signed with Developer ID"
  contains "names the nested file" "Contents/MacOS/helper: not signed with Developer ID"
  if grep -q 'Data.bundle' "$T/out"; then ko "a data-only bundle is not nested code"; else ok "a data-only bundle is not nested code"; fi
  # W3-A, ADR 0502: an app built with the INTEGRATION_HOOKS condition carries the marker; a release must not.
  hooked="$M/hooked/$(basename "$app")"
  mkdir -p "$M/hooked"
  cp -R "$app" "$hooked"
  printf '# %s\n' "$(sed -n 's/^HOOKS_MARKER="\(.*\)"$/\1/p' "$M/scripts/verify-release.sh")" \
    >>"$hooked/Contents/MacOS/Test"
  codesign --force --sign - "$hooked" >/dev/null 2>&1
  expect 1 "verify-release fails on integration hooks code" "$M/scripts/verify-release.sh" --app "$hooked" --pre-notarization
  contains "hooks code reported" "FAILED: no integration hooks adapter (INTEGRATION_HOOKS test build marker)"
  contains "names the file" "integration hooks adapter found in: $hooked/Contents/MacOS/Test"
  # PLT-R904A, ADR 0007: a Debug build carries the dev recorder's marker in its code and its string table; a
  # release must carry neither.
  contains "a build without the recorder passes the recorder check" "ok: no dev recorder (DEV_RECORDER marker and string table, PLT-R904A)"
  recorded="$M/recorded/$(basename "$app")"
  mkdir -p "$M/recorded"
  cp -R "$app" "$recorded"
  printf '# %s\n' "$(sed -n 's/^DEV_RECORDER_MARKER="\(.*\)"$/\1/p' "$M/scripts/verify-release.sh")" \
    >>"$recorded/Contents/MacOS/Test"
  codesign --force --sign - "$recorded" >/dev/null 2>&1
  expect 1 "verify-release fails on dev recorder code" "$M/scripts/verify-release.sh" --app "$recorded" --pre-notarization
  contains "recorder code reported" "FAILED: no dev recorder (DEV_RECORDER marker and string table, PLT-R904A)"
  contains "names the recorder file" "dev recorder code found in: $recorded/Contents/MacOS/Test"
  tabled="$M/tabled/$(basename "$app")"
  mkdir -p "$M/tabled"
  cp -R "$app" "$tabled"
  mkdir -p "$tabled/Contents/Resources/vi.lproj"
  printf '"devRecorder.mark" = "x";\n' >"$tabled/Contents/Resources/vi.lproj/DevRecorder.strings"
  codesign --force --sign - "$tabled" >/dev/null 2>&1
  expect 1 "verify-release fails on the dev recorder string table" "$M/scripts/verify-release.sh" --app "$tabled" \
    --pre-notarization
  contains "names the string table" "dev recorder string table found: $tabled/Contents/Resources/vi.lproj/DevRecorder.strings"
  /usr/libexec/PlistBuddy -c 'Set :SUPublicEDKey ""' "$app/Contents/Info.plist"
  codesign --force --sign - "$app" >/dev/null 2>&1
  expect 1 "verify-release fails without SUPublicEDKey" "$M/scripts/verify-release.sh" --app "$app" --pre-notarization
  contains "empty public key reported" "FAILED: Sparkle public EdDSA key (SUPublicEDKey)"
  contains "points at the runbook note" "Runbook note: filling SPARKLE_PUBLIC_ED_KEY"
  rm -f "$M/dist/testapp-1.2.3/testapp-1.2.3.zip"
  ditto -c -k --sequesterRsrc --keepParent "$app" "$M/dist/testapp-1.2.3/testapp-1.2.3.zip"
  expect 1 "publish-release refuses an archive without SUPublicEDKey" \
    "$M/scripts/publish-release" 1.2.3 --skip-attestation --skip-gatekeeper
  contains "publish names the missing key" "SUPublicEDKey is empty or malformed"
fi

echo
echo "scripts self-test: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
