# syntax=docker/dockerfile:1
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Website image for the Kalera Docker Swarm (ADR 0602, docs/runbooks/site-deploy.md). Build from the repository root:
#   docker build -f deploy/site/Dockerfile --platform linux/amd64 --build-arg SITE_STRICT=false -t <image> .
# Stage 1 builds the static site and the nginx locations generated from its _headers (deploy/site/build.mjs). It
# runs on the build machine's own platform: its output is the same for every target. Stage 2 is nginx as an
# unprivileged user, with no RUN step, so a cross-platform build needs no emulation.
# SITE_STRICT=true (default) refuses VERIFY markers and placeholder config (ADR 0601); SITE_STRICT=false builds the
# preview, which sends X-Robots-Tag: noindex unless SITE_NOINDEX=false. Base images are pinned by digest; update
# the tag and the digest together.

FROM --platform=$BUILDPLATFORM node:22.23.5-alpine3.24@sha256:1314fb30ec37592d5845e5a160d522c0e680972aa534549940b8d73bde88481a AS build
WORKDIR /src
COPY scripts/brand.env scripts/brand.env
COPY compat/matrix.json compat/matrix.json
COPY CHANGELOG*.md ./
COPY site/ site/
COPY deploy/site/ deploy/site/
ARG SITE_STRICT=true
ARG SITE_NOINDEX=auto
ARG SOURCE_DATE_EPOCH
RUN node deploy/site/build.mjs --out /out --strict "$SITE_STRICT" --noindex "$SITE_NOINDEX" --downloads deploy/site/downloads

FROM nginxinc/nginx-unprivileged:1.30.6-alpine3.24@sha256:f5116ed4606f3eb015dd4a8e28cb9b351476dc0ad4bc6e9f93b19cec130cdf03
COPY deploy/site/nginx.conf /etc/nginx/nginx.conf
COPY --from=build /out/nginx/ /etc/nginx/site/
COPY --from=build /out/html/ /srv/site/
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1
