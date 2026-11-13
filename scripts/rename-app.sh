#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Renames the product (spec/00-overview.md section 4; the current name is TEMPORARY).
#   1. Rewrites the two brand sources: Config/Brand.xcconfig and scripts/brand.env
#      (display name, slug, bundle IDs vn.kal.<slug> and vn.kal.<slug>.dev, site host <slug>.kal.vn).
#      APP_SUPPORT_EMAIL and APP_REPOSITORY_URL are kept as they are. The old storage folder name
#      (PLT-R903: the display name, or the slug for a non-ASCII name) is put first in
#      APP_LEGACY_STORAGE_FOLDER_NAMES so the first launch after the rename moves settings and logs
#      (ADR 0307 amendment); the new folder name is dropped from that list.
#   2. Rewrites every documented literal occurrence of the old values in tracked text files outside
#      spec/ and docs/decisions/ (historical records): old display name, bundle IDs, site host, slug.
#   3. Leaves template placeholders ({{AppName}}, {{app-slug}}, {{storage-folder}}, {{bundle-id}})
#      untouched: they are rendered from scripts/brand.env at build or publish time.
# Contract: docs/decisions/0504-publish-and-rename-contracts.md. Dry run by default; --apply writes.
#
# After a public release the bundle ID, folder names (PLT-R903) and feed URL must never change
# (PLT-R750, QA-R33): the script refuses once site/data/releases.json lists a release, unless
# --after-release is given.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/rename-app.sh "<Display Name>" <slug> [--apply] [--after-release]

  <Display Name>   new product name, for example "Xuôi"
  <slug>           ASCII slug: lowercase letters and digits (hyphens inside allowed), 2 to 32 chars

Options:
  --apply          write the changes (default: dry run that lists every file and line)
  --bundle-prefix P   bundle ID prefix (default: vn.kal)
  --domain D       parent domain of the site host (default: kal.vn)
  --after-release  allow renaming after a public release (breaks permissions and updates)
  -h, --help       show this help
EOF
}

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

# The whole body is one compound command: bash parses it completely before running it. The rewrite step can
# change this very file (a usage example may equal an old name), and bash would otherwise resume reading at
# a shifted offset after the rewrite.
{
new_name=""
new_slug=""
apply=0
after_release=0
prefix="vn.kal"
domain="kal.vn"
positional=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --apply) apply=1; shift ;;
    --after-release) after_release=1; shift ;;
    --bundle-prefix) prefix="${2:?}"; shift 2 ;;
    --domain) domain="${2:?}"; shift 2 ;;
    -*) usage >&2; exit 2 ;;
    *) positional+=("$1"); shift ;;
  esac
done
[[ ${#positional[@]} -eq 2 ]] || { usage >&2; exit 2; }
new_name="${positional[0]}"
new_slug="${positional[1]}"

[[ -n "$new_name" && ${#new_name} -le 40 ]] || die "display name must be 1 to 40 characters"
case "$new_name" in
  *[\"\\/\$\`\;]* | *$'\n'*)
    die "display name must not contain quotes, slashes, backslashes, semicolons, \$ or backticks" ;;
esac
[[ "$new_slug" =~ ^[a-z][a-z0-9-]{0,30}[a-z0-9]$ ]] || die "slug must match ^[a-z][a-z0-9-]{0,30}[a-z0-9]$"
[[ "$prefix" =~ ^[a-z0-9]+(\.[a-z0-9-]+)*$ ]] || die "invalid bundle prefix"
[[ "$domain" =~ ^[a-z0-9-]+(\.[a-z0-9-]+)+$ ]] || die "invalid domain"

load_brand
old_name="$APP_DISPLAY_NAME"
old_slug="$APP_SLUG"
old_bundle="$APP_BUNDLE_ID_RELEASE"
old_bundle_dev="$APP_BUNDLE_ID_DEV"
old_host="$APP_SITE_HOST"
new_bundle="$prefix.$new_slug"
new_bundle_dev="$new_bundle.dev"
new_host="$new_slug.$domain"
old_folder="$(storage_folder_for "$old_name" "$old_slug")"
new_folder="$(storage_folder_for "$new_name" "$new_slug")"
old_legacy="$APP_LEGACY_STORAGE_FOLDER_NAMES"

if [[ -f "$REPO_ROOT/site/data/releases.json" ]] && [[ $after_release -eq 0 ]]; then
  count="$(py -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d.get("releases", [])) if isinstance(d, dict) else 0)' \
    "$REPO_ROOT/site/data/releases.json")"
  if [[ "$count" != "0" ]]; then
    die "a release has been published: renaming changes the bundle ID and folders (PLT-R750, PLT-R903); pass --after-release only with a migration plan"
  fi
fi

info "rename: \"$old_name\" ($old_slug) -> \"$new_name\" ($new_slug)"
info "bundle IDs: $old_bundle -> $new_bundle, $old_bundle_dev -> $new_bundle_dev; host: $old_host -> $new_host"
if [[ "$new_folder" == "$new_slug" && "$new_name" != "$new_slug" ]]; then
  info "the new name contains non-ASCII characters: folders use the slug '$new_slug' (PLT-R903)"
fi

file_list="$(mktemp)"
trap 'rm -f "$file_list"' EXIT
tracked_files >"$file_list"

py - "$REPO_ROOT" "$apply" "$file_list" \
  "$old_name" "$new_name" "$old_slug" "$new_slug" "$old_bundle" "$new_bundle" \
  "$old_bundle_dev" "$new_bundle_dev" "$old_host" "$new_host" \
  "$old_folder" "$new_folder" "$old_legacy" <<'PY'
import os
import re
import sys

(root, apply, file_list, old_name, new_name, old_slug, new_slug, old_bundle, new_bundle,
 old_dev, new_dev, old_host, new_host, old_folder, new_folder, old_legacy) = sys.argv[1:]
apply = apply == "1"


def legacy_folders() -> str:
    """ADR 0307: earlier folder names, newest first. The old folder goes first (once), the new one never
    appears, so renaming back to an earlier name does not ask the migrator to move a folder onto itself."""
    names = [name.strip() for name in old_legacy.split(";") if name.strip()]
    if old_folder != new_folder:
        names.insert(0, old_folder)
    ordered = []
    for name in names:
        if name != new_folder and name not in ordered:
            ordered.append(name)
    return ";".join(ordered)


new_legacy = legacy_folders()
print(f"legacy storage folders: {old_legacy or '(none)'} -> {new_legacy or '(none)'}", file=sys.stderr)

BRAND_FILES = {"Config/Brand.xcconfig", "scripts/brand.env"}
EXCLUDED = re.compile(r"^(spec/|docs/decisions/|\.git/|dist/|site/dist/)|(^|/)(\.build[^/]*|node_modules)/|"
                      r"\.(png|jpg|jpeg|gif|icns|ico|pdf|dmg|zip|car|ttf|otf|woff2?)$")

# Order matters: longest, most specific values first so a bundle ID is not half-rewritten by the slug.
replacements = [
    (re.escape(old_dev), new_dev),
    (re.escape(old_bundle), new_bundle),
    (re.escape(old_host), new_host),
    (re.escape(old_name), new_name),
    (r"(?<![A-Za-z0-9_])" + re.escape(old_slug) + r"(?![A-Za-z0-9_])", new_slug),
]
compiled = [(re.compile(pattern), value) for pattern, value in replacements]


def brand_line(rel, key, value):
    if rel.endswith(".env"):
        return f'{key}="{value}"'
    return f"{key} = {value}" if value else f"{key} ="


def rewrite_brand_file(rel, text):
    # Only these keys change; every other line (APP_SUPPORT_EMAIL, APP_REPOSITORY_URL, comments) is kept.
    values = {
        "APP_DISPLAY_NAME": new_name, "APP_SLUG": new_slug, "APP_BUNDLE_ID_RELEASE": new_bundle,
        "APP_BUNDLE_ID_DEV": new_dev, "APP_SITE_HOST": new_host,
        "APP_LEGACY_STORAGE_FOLDER_NAMES": new_legacy,
    }
    seen = set()
    out = []
    for line in text.splitlines(keepends=True):
        match = re.match(r"^(\s*)(APP_[A-Z_]+)(\s*=\s*)(.*?)(\r?\n?)$", line)
        if match and match.group(2) in values:
            key = match.group(2)
            seen.add(key)
            line = match.group(1) + brand_line(rel, key, values[key]) + match.group(5)
        out.append(line)
    if "APP_LEGACY_STORAGE_FOLDER_NAMES" not in seen and new_legacy:
        if out and not out[-1].endswith("\n"):
            out.append("\n")
        out.append(brand_line(rel, "APP_LEGACY_STORAGE_FOLDER_NAMES", new_legacy) + "\n")
    return "".join(out)


with open(file_list, encoding="utf-8") as handle:
    files = sorted({line.strip() for line in handle if line.strip()})

changed = 0
for rel in files:
    if EXCLUDED.search(rel):
        continue
    path = os.path.join(root, rel)
    if not os.path.isfile(path) or os.path.islink(path):
        continue
    try:
        with open(path, encoding="utf-8") as handle:
            original = handle.read()
    except UnicodeDecodeError:
        continue
    if rel in BRAND_FILES:
        updated = rewrite_brand_file(rel, original)
    else:
        updated = original
        for pattern, value in compiled:
            updated = pattern.sub(value, updated)
    if updated == original:
        continue
    changed += 1
    before = original.splitlines()
    after = updated.splitlines()
    print(f"--- {rel}")
    for number, (old_line, new_line) in enumerate(zip(before, after), 1):
        if old_line != new_line:
            print(f"  {number}: {old_line.strip()}")
            print(f"  {' ' * len(str(number))}  -> {new_line.strip()}")
    for number, new_line in enumerate(after[len(before):], len(before) + 1):
        print(f"  {number}: + {new_line.strip()}")
    if apply:
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(updated)

verb = "rewrote" if apply else "would rewrite"
print(f"rename-app: {verb} {changed} file(s)", file=sys.stderr)
PY

if [[ $apply -eq 0 ]]; then
  info "dry run: nothing written; re-run with --apply"
else
  info "done; next: review git diff, run scripts/lint.sh and scripts/run-tests.sh, regenerate the Xcode project"
fi
exit 0
}
