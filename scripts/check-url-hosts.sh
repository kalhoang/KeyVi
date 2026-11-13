#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-App-Pending
#
# QA-R60 / PLT-R906: the shipped binary may contain URL hosts only from an allowlist (site and
# appcast host, the repository host for issue forms, the support mail domain). Any other host means a
# network endpoint was added without a decision record and an update to the privacy page.
#
# Hosts that come from scripts/brand.env (never listed in the allowlist file, so a rename or a new
# repository needs no allowlist edit):
#   APP_SITE_HOST         always allowed (site, appcast, release notes)
#   APP_REPOSITORY_URL    its host is allowed; github.com while the value is empty (PRD-R47)
#   APP_SUPPORT_EMAIL     its domain is allowed as a mailto: host when set (QA-R51)
#
# Scans every Mach-O file, property list and strings file inside an .app bundle (or a single file)
# for scheme://host and mailto:user@host references. Hosts that are XML namespace or DTD identifiers
# (never contacted) are allowed separately in scripts/url-hosts.allow.
#
# The shipped Contents/Resources/compat-rules.json is skipped: its web.urlPrefixes matchers (PLT-R503) name the sites a rule
# applies to, which is data the app compares with the focused page, never a host it contacts. Every other
# file, the binaries and Info.plist included, stays strictly checked.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/check-url-hosts.sh [--allow FILE] [--list] PATH...

PATH is an .app bundle, a binary or a directory. Fails when a URL host outside the allowlist
appears (QA-R60). From scripts/brand.env, the site host, the host of APP_REPOSITORY_URL (github.com
while empty) and the domain of APP_SUPPORT_EMAIL are always allowed. The bundle's
Contents/Resources/compat-rules.json is skipped: its URL prefixes are rule matchers, not endpoints.

Options:
  --allow FILE  allowlist (default scripts/url-hosts.allow): one host or *.suffix per line
  --list        print every host found with its status, then apply the gate
  -h, --help    show this help
Exit status: 0 clean, 1 hosts outside the allowlist, 2 usage error.
EOF
}

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_brand

allow_file="$REPO_ROOT/scripts/url-hosts.allow"
list=0
paths=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --allow) allow_file="${2:?--allow needs a value}"; shift 2 ;;
    --list) list=1; shift ;;
    -*) usage >&2; exit 2 ;;
    *) paths+=("$1"); shift ;;
  esac
done
[[ ${#paths[@]} -gt 0 ]] || { usage >&2; exit 2; }
require_cmd strings file

# Data files whose URLs are matchers, not network endpoints (see the header): only the shipped copy at this
# path inside the scanned bundle, so a file with the same name anywhere else is still checked.
skipped_relative="Contents/Resources/compat-rules.json"
skipped_paths=()

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
candidates="$workdir/files"
: >"$candidates"
for p in "${paths[@]}"; do
  [[ -e "$p" ]] || die "not found: $p"
  if [[ -d "$p" ]]; then
    p="${p%/}"
    skipped_paths+=("$p/$skipped_relative")
    find "$p" -type f \( -perm -u+x -o -name '*.plist' -o -name '*.strings' -o -name '*.dylib' \
      -o -name '*.json' -o -name '*.xcstrings' -o -name '*.loctable' \) -print >>"$candidates"
  else
    [[ "$p" == */"$skipped_relative" ]] && skipped_paths+=("$p")
    printf '%s\n' "$p" >>"$candidates"
  fi
done

hosts="$workdir/hosts"
: >"$hosts"
dump_text() {
  local f="$1" kind
  kind="$(file -b "$f" 2>/dev/null || true)"
  case "$kind" in
    *Mach-O*) strings -a "$f" ;;
    *"Apple binary property list"*) plutil -convert xml1 -o - "$f" 2>/dev/null || strings -a "$f" ;;
    *text* | *XML* | *JSON*) cat "$f" ;;
    *) return 0 ;;
  esac
}

is_skipped() {
  local skipped
  for skipped in ${skipped_paths[@]+"${skipped_paths[@]}"}; do [[ "$1" == "$skipped" ]] && return 0; done
  return 1
}

while IFS= read -r f; do
  is_skipped "$f" && continue
  dump_text "$f" \
    | LC_ALL=C grep -Eo '([A-Za-z][A-Za-z0-9+.-]*://[A-Za-z0-9.-]+|mailto:[^@[:space:]"]+@[A-Za-z0-9.-]+)' \
    | sed -E 's#^mailto:[^@]+@#mailto:#; s#^[A-Za-z][A-Za-z0-9+.-]*://##' \
    | LC_ALL=C tr '[:upper:]' '[:lower:]' >>"$hosts" || true
done <"$candidates"

py - "$allow_file" "$list" "$hosts" "$APP_SITE_HOST" "$(repository_host)" "$(support_email_domain)" <<'PY'
import sys

allow_file, list_flag, hosts_file = sys.argv[1:4]
allowed = {host.lower() for host in sys.argv[4:] if host}
suffixes = []
with open(allow_file, encoding="utf-8") as handle:
    for raw in handle:
        line = raw.split("#", 1)[0].strip().lower()
        if not line:
            continue
        if line.startswith("*."):
            suffixes.append(line[1:])
        else:
            allowed.add(line)

found = {}
with open(hosts_file, encoding="utf-8", errors="replace") as handle:
    for raw in handle:
        entry = raw.strip().rstrip(".")
        if not entry:
            continue
        mail = entry.startswith("mailto:")
        host = entry.removeprefix("mailto:")
        # Ignore format strings and placeholders such as %@ or localhost-only test schemes.
        if not host or "." not in host and host != "localhost":
            continue
        found.setdefault(host, mail)

bad = []
for host in sorted(found):
    ok = host in allowed or any(host.endswith(suffix) for suffix in suffixes) or host == "localhost"
    if list_flag == "1":
        print(f"{'ok ' if ok else 'BAD'} {'mailto:' if found[host] else ''}{host}")
    if not ok:
        bad.append(host)

for host in bad:
    print(f"check-url-hosts: host outside the allowlist: {host} (QA-R60: needs a decision record "
          f"and a /rieng-tu update)", file=sys.stderr)
print(f"check-url-hosts: {len(found)} host(s), {len(bad)} outside the allowlist", file=sys.stderr)
sys.exit(1 if bad else 0)
PY
