# shellcheck shell=bash
# SPDX-License-Identifier: LicenseRef-App-Pending
#
# Shared helpers for the repository scripts. Source it; do not execute it.
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#
# Brand values (display name, slug, bundle IDs, site host) come only from scripts/brand.env,
# never from literals in scripts (CLAUDE.md "Name (temporary)").

if [[ -n "${_COMMON_SH_LOADED:-}" ]]; then
  return 0
fi
_COMMON_SH_LOADED=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

log() { printf '%s\n' "$*" >&2; }
info() { printf '==> %s\n' "$*" >&2; }
warn() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    printf '::warning::%s\n' "$*" >&2
  else
    printf 'warning: %s\n' "$*" >&2
  fi
}
die() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    printf '::error::%s\n' "$*" >&2
  else
    printf 'error: %s\n' "$*" >&2
  fi
  exit 1
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
  done
}

# Loads scripts/brand.env into APP_DISPLAY_NAME, APP_SLUG, APP_BUNDLE_ID_RELEASE,
# APP_BUNDLE_ID_DEV, APP_SITE_HOST and validates their shape. The optional APP_SUPPORT_EMAIL,
# APP_REPOSITORY_URL and APP_LEGACY_STORAGE_FOLDER_NAMES default to empty ("not decided yet") and are
# validated when set. BRAND_ENV may point elsewhere (tests and scripts/rename-app.sh use that).
load_brand() {
  local file="${BRAND_ENV:-$REPO_ROOT/scripts/brand.env}"
  [[ -f "$file" ]] || die "brand file not found: $file"
  # Optional keys must come from the file, never from a stale environment.
  unset APP_SUPPORT_EMAIL APP_REPOSITORY_URL APP_LEGACY_STORAGE_FOLDER_NAMES
  # shellcheck source=../brand.env
  source "$file"
  : "${APP_DISPLAY_NAME:?missing in $file}" "${APP_SLUG:?missing in $file}"
  : "${APP_BUNDLE_ID_RELEASE:?missing in $file}" "${APP_BUNDLE_ID_DEV:?missing in $file}"
  : "${APP_SITE_HOST:?missing in $file}"
  APP_SUPPORT_EMAIL="${APP_SUPPORT_EMAIL:-}"
  APP_REPOSITORY_URL="${APP_REPOSITORY_URL:-}"
  APP_LEGACY_STORAGE_FOLDER_NAMES="${APP_LEGACY_STORAGE_FOLDER_NAMES:-}"
  [[ "$APP_SLUG" =~ ^[a-z][a-z0-9-]*[a-z0-9]$ ]] || die "APP_SLUG has an invalid shape: $APP_SLUG"
  [[ "$APP_BUNDLE_ID_RELEASE" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || die "APP_BUNDLE_ID_RELEASE invalid"
  [[ "$APP_SITE_HOST" =~ ^[a-z0-9-]+(\.[a-z0-9-]+)+$ ]] || die "APP_SITE_HOST invalid"
  if [[ -n "$APP_SUPPORT_EMAIL" && ! "$APP_SUPPORT_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[a-z0-9-]+(\.[a-z0-9-]+)+$ ]]; then
    die "APP_SUPPORT_EMAIL invalid (expected user@domain with a lowercase domain): $APP_SUPPORT_EMAIL"
  fi
  if [[ -n "$APP_REPOSITORY_URL" && ! "$APP_REPOSITORY_URL" =~ ^https://[a-z0-9-]+(\.[a-z0-9-]+)+/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    die "APP_REPOSITORY_URL invalid (expected https://<host>/<owner>/<repo>): $APP_REPOSITORY_URL"
  fi
  APP_STORAGE_FOLDER="$(storage_folder_for "$APP_DISPLAY_NAME" "$APP_SLUG")"
  export APP_DISPLAY_NAME APP_SLUG APP_BUNDLE_ID_RELEASE APP_BUNDLE_ID_DEV APP_SITE_HOST APP_STORAGE_FOLDER
  export APP_SUPPORT_EMAIL APP_REPOSITORY_URL APP_LEGACY_STORAGE_FOLDER_NAMES
}

# Host of APP_REPOSITORY_URL, or github.com while the repository is not decided (QA-R60: the issue forms
# live on GitHub, PRD-R47). Call after load_brand.
repository_host() {
  local rest="${APP_REPOSITORY_URL#https://}"
  if [[ -n "$APP_REPOSITORY_URL" ]]; then
    printf '%s' "${rest%%/*}"
  else
    printf 'github.com'
  fi
}

# Domain of APP_SUPPORT_EMAIL, or nothing when the address is not set. Call after load_brand.
support_email_domain() {
  if [[ -n "$APP_SUPPORT_EMAIL" ]]; then
    printf '%s' "${APP_SUPPORT_EMAIL##*@}"
  fi
}

# PLT-R903: folder names use the display name, or the slug when the display name contains
# non-ASCII characters. The choice is permanent once a release has shipped.
storage_folder_for() {
  local name="$1" slug="$2"
  if LC_ALL=C grep -q '[^ -~]' <<<"$name"; then
    printf '%s' "$slug"
  else
    printf '%s' "$name"
  fi
}

# Team ID from Config/Signing.xcconfig (public information, PLT-R750).
load_team_id() {
  local file="$REPO_ROOT/Config/Signing.xcconfig"
  [[ -f "$file" ]] || die "signing config not found: $file"
  APP_TEAM_ID="$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([A-Z0-9]*\).*/\1/p' "$file" | head -n1)"
  [[ "$APP_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || die "DEVELOPMENT_TEAM missing or invalid in $file"
  export APP_TEAM_ID
}

# Python is always run isolated (-I) so a stray module in the working directory is never imported.
py() { python3 -I "$@"; }

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

# Downloads URL to DEST and verifies the SHA-256 (PLT-R910: every downloaded tool is verified).
fetch_verified() {
  local url="$1" expected="$2" dest="$3" actual
  require_cmd curl
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 -o "$dest" "$url"
  actual="$(sha256_of "$dest")"
  if [[ "$actual" != "$expected" ]]; then
    rm -f "$dest"
    die "checksum mismatch for $url (expected $expected, got $actual)"
  fi
}

# Lists Swift files under DIR (tracked plus untracked-not-ignored; find outside git).
# Note: scripts stay compatible with bash 3.2 (the macOS /bin/bash): no mapfile, no
# associative arrays, and empty arrays are expanded as ${a[@]+"${a[@]}"}.
swift_files_in() {
  local dir="$1"
  if git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    (cd "$dir" && git ls-files --cached --others --exclude-standard -- '*.swift')
  else
    (cd "$dir" && find . -name '*.swift' -not -path '*/.build*' -not -path './.git/*' | sed 's|^\./||')
  fi
}

# Lists tracked files (falls back to find when not in a git checkout).
tracked_files() {
  if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$REPO_ROOT" ls-files --cached --others --exclude-standard
  else
    (cd "$REPO_ROOT" && find . -type f -not -path './.git/*' | sed 's|^\./||')
  fi
}
