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

echo "== check-dco.sh (ADR 0401)"
G="$T/g"
mkdir -p "$G/Packages/VietnameseEngine" "$G/docs"
git -C "$G" init -q
git -C "$G" config user.name "Ada Contributor"
git -C "$G" config user.email "ada@example.org"
git -C "$G" config commit.gpgsign false
printf 'base\n' >"$G/docs/a.md"
git -C "$G" add -A && git -C "$G" commit -q -m "chore: base"
dco_base="$(git -C "$G" rev-parse HEAD)"
printf 'doc\n' >>"$G/docs/a.md"
git -C "$G" commit -q -am "docs: unsigned change outside the engine"
printf 'x\n' >"$G/Packages/VietnameseEngine/E.swift"
git -C "$G" add -A && git -C "$G" commit -q -s -m "feat: signed engine change"
expect 0 "signed engine commits pass; other paths are not checked" "$S/check-dco.sh" --repo "$G" --base "$dco_base" --head HEAD
contains "one engine commit checked" "1 commit(s) touching Packages/VietnameseEngine Packages/VietnameseEngineFuzz"
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
expect 1 "the MPL-2.0 fuzz package is checked by default" "$S/check-dco.sh" --repo "$G" --base "$dco_base" --head HEAD
contains "unsigned fuzz commit named" "test: unsigned fuzz change"
expect 0 "--path limits the check" "$S/check-dco.sh" --repo "$G" --base "$dco_base" --head HEAD \
  --path Packages/VietnameseEngine

echo "== check-docs.py (relative links and brand literals in docs)"
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
printf '# Readme\n\nInstall {{AppName}} from [the runbook](docs/runbooks/a.md).\n' >"$K/README.md"
expect 0 "valid links, GitHub slugs (Vietnamese, duplicates, code), footnotes and skipped links pass" \
  python3 -I "$S/check-docs.py" links --root "$K"
printf '\nBroken: [x](missing.md), [y](b.md#nope), [z](#nowhere).\n' >>"$K/docs/runbooks/a.md"
expect 1 "broken file and anchors fail" python3 -I "$S/check-docs.py" links --root "$K"
contains "missing file named" "docs/runbooks/a.md:17: link target not found: missing.md"
contains "missing anchor in another file named" "no heading or anchor #nope in docs/runbooks/b.md"
contains "missing anchor in the same file named" "no heading or anchor #nowhere in docs/runbooks/a.md"
expect 0 "placeholders pass; decision records may name the product" python3 -I "$S/check-docs.py" brand --root "$K"
printf 'Open Test App, then visit https://testapp.example.vn (bundle vn.example.testapp.dev).\n' >"$K/docs/runbooks/b.md"
printf 'Run testapp-notary.\n' >"$K/CONTRIBUTING.md"
expect 1 "literal brand values in docs fail" python3 -I "$S/check-docs.py" brand --root "$K"
contains "bundle ID reported first on its line" "docs/runbooks/b.md:1: literal bundle ID 'vn.example.testapp.dev'"
contains "slug reported" "CONTRIBUTING.md:1: literal slug ({{app-slug}}) 'testapp'"

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
  expect 0 "build-release dry run" bash -c "cd '$M' && touch project.yml && scripts/build-release.sh 1.2.3 1020399 --dry-run"
  contains "archive command" "MARKETING_VERSION=1.2.3"
  contains "no base entitlements" "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO"

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
