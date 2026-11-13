#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-App-Pending
#
# Prints the variables of deploy/site/stack.yml and of the site image reference, from scripts/brand.env, so neither
# the stack file nor the workflow carries a brand literal (CLAUDE.md "Name (temporary)", ADR 0602). Paste the output
# into the Portainer stack's environment variables; .github/workflows/site-image.yml appends it to $GITHUB_ENV.
#
# Output, one KEY=value per line:
#   SITE_HOST      APP_SITE_HOST (the Traefik Host rule)
#   SITE_SLUG      APP_SLUG (Traefik router, service and middleware names)
#   IMAGE_OWNER    the GHCR namespace, lowercase: --owner, else $IMAGE_OWNER, else the owner of APP_REPOSITORY_URL
#   IMAGE_NAME     --image-name, else $SITE_IMAGE_NAME, else <slug>-site
#   IMAGE_TAG      --tag, else prod
#   IMAGE          ghcr.io/IMAGE_OWNER/IMAGE_NAME:IMAGE_TAG
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: deploy/site/stack-env.sh [--owner OWNER] [--image-name NAME] [--tag TAG]

Prints SITE_HOST, SITE_SLUG, IMAGE_OWNER, IMAGE_NAME, IMAGE_TAG and IMAGE for the site stack (ADR 0602), read from
scripts/brand.env (BRAND_ENV overrides the file). The owner defaults to $IMAGE_OWNER, then to the owner of
APP_REPOSITORY_URL; the image name to $SITE_IMAGE_NAME, then <slug>-site.
Exit status: 0 printed, 1 a value is missing or malformed, 2 usage error.
EOF
}

owner="${IMAGE_OWNER:-}"
image_name="${SITE_IMAGE_NAME:-}"
tag="prod"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --owner) owner="${2:?--owner needs a value}"; shift 2 ;;
    --image-name) image_name="${2:?--image-name needs a value}"; shift 2 ;;
    --tag) tag="${2:?--tag needs a value}"; shift 2 ;;
    *) usage >&2; exit 2 ;;
  esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$repo_root/scripts/lib/common.sh"
load_brand

if [[ -z "$owner" && "$APP_REPOSITORY_URL" =~ ^https://[^/]+/([^/]+)/[^/]+/?$ ]]; then
  owner="${BASH_REMATCH[1]}"
fi
[[ -n "$owner" ]] || die "no image owner: pass --owner, set IMAGE_OWNER, or set APP_REPOSITORY_URL in scripts/brand.env"
owner="$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')"
image_name="${image_name:-$APP_SLUG-site}"

[[ "$owner" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "image owner has an invalid shape: $owner"
[[ "$image_name" =~ ^[a-z0-9]+([._-][a-z0-9]+)*$ ]] || die "image name has an invalid shape: $image_name"
[[ "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || die "image tag has an invalid shape: $tag"

printf 'SITE_HOST=%s\n' "$APP_SITE_HOST"
printf 'SITE_SLUG=%s\n' "$APP_SLUG"
printf 'IMAGE_OWNER=%s\n' "$owner"
printf 'IMAGE_NAME=%s\n' "$image_name"
printf 'IMAGE_TAG=%s\n' "$tag"
printf 'IMAGE=ghcr.io/%s/%s:%s\n' "$owner" "$image_name" "$tag"
