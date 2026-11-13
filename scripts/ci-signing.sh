#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Temporary signing material for the release job (QA-R31, PLT-R1103). Runs only inside the GitHub
# environment `release`. Nothing is printed: the generated keychain password is masked, files are
# written with mode 0600 under $RUNNER_TEMP and removed by `cleanup` (always run it, if: always()).
#
#   setup    creates a temporary keychain, imports the Developer ID Application identity, writes the
#            App Store Connect API key file, exports SIGNING_KEYCHAIN and ASC_API_KEY_PATH to
#            $GITHUB_ENV
#   cleanup  deletes the keychain, restores the user keychain search list, removes the key file
#
# Required secrets for setup (environment `release`):
#   DEVELOPER_ID_P12_BASE64    base64 of the exported Developer ID Application identity (.p12)
#   DEVELOPER_ID_P12_PASSWORD  password of that .p12
#   ASC_API_KEY_P8_BASE64      base64 of AuthKey_<id>.p8 (App Store Connect API key, Developer role)
#   ASC_API_KEY_ID, ASC_API_ISSUER_ID are passed straight to scripts/notarize.sh
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/ci-signing.sh setup|cleanup

Creates or removes the temporary release keychain and API key file (CI only; see header).
EOF
}

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

cmd="${1:-}"
case "$cmd" in
  -h | --help) usage; exit 0 ;;
  setup | cleanup) ;;
  *) usage >&2; exit 2 ;;
esac

temp="${RUNNER_TEMP:?RUNNER_TEMP is not set (CI only)}"
keychain="$temp/release-signing.keychain-db"
key_file="$temp/asc-api-key.p8"
p12_file="$temp/developer-id.p12"

if [[ "$cmd" == "cleanup" ]]; then
  rm -f "$p12_file" "$key_file"
  if [[ -f "$keychain" ]]; then
    security delete-keychain "$keychain" || warn "could not delete $keychain"
  fi
  login="$HOME/Library/Keychains/login.keychain-db"
  if [[ -f "$login" ]]; then
    security list-keychains -d user -s "$login"
  fi
  info "signing material removed"
  exit 0
fi

: "${DEVELOPER_ID_P12_BASE64:?missing secret DEVELOPER_ID_P12_BASE64}"
: "${DEVELOPER_ID_P12_PASSWORD:?missing secret DEVELOPER_ID_P12_PASSWORD}"
: "${ASC_API_KEY_P8_BASE64:?missing secret ASC_API_KEY_P8_BASE64}"
: "${GITHUB_ENV:?GITHUB_ENV is not set (CI only)}"
require_cmd security openssl base64

umask 077
keychain_password="$(openssl rand -hex 32)"
printf '::add-mask::%s\n' "$keychain_password"

printf '%s' "$DEVELOPER_ID_P12_BASE64" | base64 --decode >"$p12_file"
printf '%s' "$ASC_API_KEY_P8_BASE64" | base64 --decode >"$key_file"

security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$p12_file" -k "$keychain" -P "$DEVELOPER_ID_P12_PASSWORD" -f pkcs12 \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null
rm -f "$p12_file"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" >/dev/null
existing=()
while IFS= read -r k; do
  k="${k//\"/}"
  k="${k#"${k%%[![:space:]]*}"}"
  [[ -n "$k" ]] && existing+=("$k")
done < <(security list-keychains -d user)
security list-keychains -d user -s "$keychain" ${existing[@]+"${existing[@]}"}

load_team_id
identities="$(security find-identity -v -p codesigning "$keychain")"
if ! grep -q "Developer ID Application: .*($APP_TEAM_ID)" <<<"$identities"; then
  die "the imported identity is not a Developer ID Application identity for team $APP_TEAM_ID"
fi

{
  printf 'SIGNING_KEYCHAIN=%s\n' "$keychain"
  printf 'ASC_API_KEY_PATH=%s\n' "$key_file"
} >>"$GITHUB_ENV"
info "temporary keychain ready"
