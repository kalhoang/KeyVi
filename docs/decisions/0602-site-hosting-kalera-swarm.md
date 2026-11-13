# 0602. Website hosting on the Kalera Docker Swarm

- Status: accepted, 2026-11-13 (Pa's answers S9, Q7, Q10 and Q11; resolver name and node architecture VERIFY on the
  first deploy)
- Scope: `site/`, `deploy/site/`, `.github/workflows/site-image.yml`, `.github/workflows/site.yml`; PRD-R73 to
  PRD-R76, PLT-R1101, QA-R38
- Runbook: [site deploy](../runbooks/site-deploy.md)

## Context

[ADR 0601](0601-static-site-generator.md) left the hosting open and kept `site.yml`'s deploy job as a placeholder.
On 2026-11-13 Pa decided: the website runs on the Kalera Docker Swarm (Portainer, Traefik on `traefik_public` with
the Cloudflare DNS challenge, images on GHCR, deploy webhooks only from a `prod` branch); the site host serves the
updates and the DMGs too (Q10); the website may use PostHog Cloud analytics in cookieless mode, configured by a key
that is empty until Pa provides one (Q7); until the first public release a preview is deployed with
`SITE_STRICT=false` and `noindex`.

## Decision

1. **One container image** serves the site, the appcast, the release-notes pages, the update archives and the DMGs:
   `nginxinc/nginx-unprivileged` (stable 1.30, Alpine), pinned by digest, listening on 8080 as an unprivileged user,
   with a read-only root file system in the stack. nginx was chosen over Caddy because the image is smaller, the
   unprivileged variant is maintained upstream, and nothing here needs Caddy's automatic TLS (Traefik terminates TLS).
   The build stage is `node:22` Alpine, pinned by digest, on the build machine's platform; the nginx stage has no
   `RUN`, so a cross-platform build needs no emulation.
2. **`site/static/_headers` stays the single source of every response header.** `node site/build.mjs` writes the
   deployed copy (`site/lib/headers.mjs`): the site-wide CSP gains the analytics origins when a key is set, and
   `--noindex` adds `X-Robots-Tag: noindex`. `deploy/site/nginx-headers.mjs` turns that file into the nginx
   `location` blocks at image build time; `nginx.conf` itself writes no header. `deploy/site/test.mjs` proves for
   every pattern that nginx's location choice yields exactly the headers the file lists, and the image workflow
   repeats the comparison against the running container (`check-live-headers.mjs`) before it pushes anything.
   `_headers` gained HSTS, `X-Frame-Options`, immutable caching of `/download/*` and a strict
   `/release-notes/*` policy (no script, no image, the stylesheet hash only) that applies on top of the site-wide
   one. Because `/assets/*` and `/download/*` are cached for a year as `immutable`, every page URL of a file under
   `/assets/` carries its content hash (`site/lib/fingerprint.mjs` adds `?v=<hash>`; the analytics loader has the hash
   in its file name) and release files carry their version, so a deploy never needs a cache purge.
3. **Builds and deploys only from `prod`.** `site-image.yml` runs on pushes to `prod` (and a manual run on `prod`),
   never on `main` or pull requests: tests, release files, build, live header check, push of `sha-<commit>` and
   `prod`, then the Portainer service webhook. `site.yml` keeps testing and building on pull requests and `main` and
   no longer has a deploy job. The repository owner (`IMAGE_OWNER`) and the image name (`SITE_IMAGE_NAME`, default
   `<slug>-site`) are repository variables.
4. **Strict unless it is a preview.** The image build is strict (`--strict`) unless the variable `SITE_STRICT` is
   `false`; a non-strict build always sends `noindex` unless `SITE_NOINDEX=false` is passed by hand.
5. **Stack.** `deploy/site/stack.yml`: two replicas, rolling start-first updates with automatic rollback, healthcheck
   on `/healthz` (also used by Traefik), labels copied from the Kalera stacks already on this Swarm: entrypoints
   `websecure` and `web` (permanent redirect to HTTPS), resolver `cloudflare` (overridable with
   `TRAEFIK_CERT_RESOLVER`), and both `traefik.swarm.network` and `traefik.docker.network`. Host and names come from
   stack variables printed by `deploy/site/stack-env.sh` from `scripts/brand.env`, so a rename needs no deploy file
   change.
6. **Release files are baked into the image.** `deploy/site/fetch-downloads.py` fetches every DMG of
   `site/data/releases.json` and every update archive of the appcast that lives under `https://<site host>/download/`
   from the GitHub Release `v<version>`, and checks the DMG's SHA-256 and the archive's length before the build copies
   them to `/download/`. Two replicas therefore need no shared volume, and rolling back the image rolls back the
   files with the appcast that names them.
7. **Analytics (Q7).** `site/config.json` `analytics.posthogKey` empty means no script and no third-party origin. A
   key (validated as `phc_` plus letters and digits) and a PostHog Cloud host (US or EU only) make the build write the
   local loader `assets/analytics.<content hash>.js` and add it to every page that `layout.mjs` renders; the loader starts PostHog in
   cookieless mode with page views only. Release-notes pages are static files from `scripts/publish-release` and never
   get it. This replaces "Website analytics: none" of ADR 0601 decision 5 and ADR 0001 item 18 for builds that set a
   key; the privacy page renders the state the build ships.
8. **Access log without personal data.** nginx logs the time, method, path without the query string, status and size
   only, which is enough to count appcast requests and downloads per day (PRD-R76).

## Alternatives considered

- Cloudflare Pages or GitHub Pages: no server to run, but Pa chose the Kalera Swarm, and the release files (Q10) would
  need another host or a size exception.
- A Swarm volume for `/download/`: smaller images, but two replicas on several nodes would need shared storage and a
  separate upload step; reconsider when the image size matters.
- Writing the headers by hand in `nginx.conf`: two sources that drift; a test can catch the drift, generation removes
  it.

## Consequences

- Pa's one-time steps (repository settings, GHCR visibility, Portainer stack and webhook, Cloudflare DNS and token,
  PostHog project) are listed in the runbook and done by Pa by hand; the repository holds only the files.
- The image grows with every release; a later decision can move `/download/` elsewhere without touching the site.
- VERIFY on the first deploy: the resolver name in traefik2's configuration, the provider (v3 swarm or v2 docker),
  the nodes' architecture (`linux/amd64` is built), the DNS record target, the PostHog organisation's region, and
  whether `docker stack deploy` on this Swarm accepts `read_only` and `tmpfs`.
