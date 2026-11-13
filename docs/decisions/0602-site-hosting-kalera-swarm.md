# 0602. Website hosting on the Kalera Docker Swarm

- Status: accepted, 2026-11-13 (Pa's answers S9, Q7, Q10 and Q11); amended the same evening: Umami replaces PostHog
  (decision 7), Swarm services use only `traefik.swarm.*` labels (decision 5). Node architecture VERIFY on the first
  deploy.
- Scope: `site/`, `deploy/site/`, `.github/workflows/site-image.yml`, `.github/workflows/site.yml`; PRD-R73 to
  PRD-R76, PLT-R1101, QA-R38
- Runbook: [site deploy](../runbooks/site-deploy.md)

## Context

[ADR 0601](0601-static-site-generator.md) left the hosting open and kept `site.yml`'s deploy job as a placeholder.
On 2026-11-13 Pa decided: the website runs on the Kalera Docker Swarm (Portainer, Traefik on `traefik_public` with
the Cloudflare DNS challenge, images on GHCR, deploy webhooks only from a `prod` branch); the site host serves the
updates and the DMGs too (Q10); the website may use cookieless analytics (Q7: first PostHog Cloud, replaced the
same evening by a self-hosted Umami because the Kalera PostHog quota is used up); until the first public release a
preview is deployed with `SITE_STRICT=false` and `noindex`.

## Decision

1. **One container image** serves the site, the appcast, the release-notes pages, the update archives and the DMGs:
   `nginxinc/nginx-unprivileged` (stable 1.30, Alpine), pinned by digest, listening on 8080 as an unprivileged user,
   with a read-only root file system in the stack. nginx was chosen over Caddy because the image is smaller, the
   unprivileged variant is maintained upstream, and nothing here needs Caddy's automatic TLS (Traefik terminates TLS).
   The build stage is `node:22` Alpine, pinned by digest, on the build machine's platform; the nginx stage has no
   `RUN`, so a cross-platform build needs no emulation.
2. **`site/static/_headers` stays the single source of every response header.** `node site/build.mjs` writes the
   deployed copy (`site/lib/headers.mjs`): the site-wide CSP gains the analytics origin when analytics is configured, and
   `--noindex` adds `X-Robots-Tag: noindex`. `deploy/site/nginx-headers.mjs` turns that file into the nginx
   `location` blocks at image build time; `nginx.conf` itself writes no header. `deploy/site/test.mjs` proves for
   every pattern that nginx's location choice yields exactly the headers the file lists, and the image workflow
   repeats the comparison against the running container (`check-live-headers.mjs`) before it pushes anything.
   `_headers` gained HSTS, `X-Frame-Options`, immutable caching of `/download/*` and a strict
   `/release-notes/*` policy (no script, no image, the stylesheet hash only) that applies on top of the site-wide
   one. Because `/assets/*` and `/download/*` are cached for a year as `immutable`, every page URL of a file under
   `/assets/` carries its content hash (`site/lib/fingerprint.mjs` adds `?v=<hash>`) and release files carry their
   version, so a deploy never needs a cache purge.
3. **Builds and deploys only from `prod`.** `site-image.yml` runs on pushes to `prod` (and a manual run on `prod`),
   never on `main` or pull requests: tests, release files, build, live header check, push of `sha-<commit>` and
   `prod`, then the Portainer service webhook. `site.yml` keeps testing and building on pull requests and `main` and
   no longer has a deploy job. The repository owner (`IMAGE_OWNER`) and the image name (`SITE_IMAGE_NAME`, default
   `<slug>-site`) are repository variables; `IMAGE_OWNER` must equal the repository owner, because the push uses
   `GITHUB_TOKEN`, which publishes packages only in the repository's own namespace.
4. **Strict unless it is a preview.** The image build is strict (`--strict`) unless the variable `SITE_STRICT` is
   `false`; a non-strict build always sends `noindex` unless `SITE_NOINDEX=false` is passed by hand.
5. **Stack.** `deploy/site/stack.yml`: two replicas, rolling start-first updates with automatic rollback, healthcheck
   on `/healthz` (also used by Traefik), labels copied from the Kalera stacks already on this Swarm: entrypoints
   `websecure` and `web` (permanent redirect to HTTPS), resolver `cloudflare` (overridable with
   `TRAEFIK_CERT_RESOLVER`), and `traefik.swarm.network` only. The shared Traefik runs the v3 Swarm provider and
   skips a service whose labels mix `traefik.docker.*` and `traefik.swarm.*` ("both Docker and Swarm labels are
   defined", seen when the Umami stack was deployed on 2026-11-13), so a Swarm service on this cluster carries
   `traefik.swarm.*` provider labels only; `scripts/tests/test_site_deploy.py` fails on any `traefik.docker.*`
   label in a stack file. The Umami stack confirmed the resolver name `cloudflare`. Host and names come from
   stack variables printed by `deploy/site/stack-env.sh` from `scripts/brand.env`, so a rename needs no deploy file
   change.
6. **Release files are baked into the image.** `deploy/site/fetch-downloads.py` fetches every DMG of
   `site/data/releases.json` and every update archive of the appcast that lives under `https://<site host>/download/`
   from the GitHub Release `v<version>`, and checks the DMG's SHA-256 and the archive's length before the build copies
   them to `/download/`. Two replicas therefore need no shared volume, and rolling back the image rolls back the
   files with the appcast that names them.
7. **Analytics (Q7, amended 2026-11-13 evening): self-hosted Umami.** Pa's first answer was PostHog Cloud in
   cookieless mode; the Kalera PostHog free quota is used up, so the website uses **Umami 3.5.0**, self-hosted on the
   Kalera Swarm (stack `deploy/umami/stack.yml`, host `https://stats.kal.vn`, runbook
   [analytics](../runbooks/analytics.md)). Umami sets no cookie, stores nothing in the browser, keeps no IP address
   (it derives a visit identifier from a hashed IP, user agent and a monthly salt) and is GDPR-friendly without a
   consent banner (PRD-R74).
   - `site/config.json`: `"analytics": { "provider": "umami", "scriptUrl": "https://stats.kal.vn/script.js",
     "websiteId": "<uuid>" }`; the website id is public (it is in every page). Missing, or three empty values, means
     no script and no third-party origin.
   - Strict validation (`site/lib/analytics.mjs`): no unknown key (an old `posthogKey` fails), provider `umami`, the
     script an `https://<host>/<path>.js` URL without credentials, port, query or fragment on a host listed on a
     `site:` line of `scripts/url-hosts.allow`, the website id a UUID.
   - Every page that `layout.mjs` renders gets, in its head,
     `<script defer src="<scriptUrl>" data-website-id="<id>" data-domains="<site host>" data-do-not-track="true"></script>`:
     the site host comes from `scripts/brand.env`, so a copy of a page on another host counts nothing, and a browser
     that sends Do Not Track is not counted. The tracker script is loaded from the Umami host itself (no local
     loader, no subresource integrity hash: the project upgrades that server and the script changes with it).
   - The site-wide CSP (the meta tag and `_headers`) gains exactly the script origin in `script-src` and
     `connect-src` (Umami posts page views to `<origin>/api/send`). Release-notes pages are static files from
     `scripts/publish-release` with their own no-script policy and never get it.
   - `scripts/url-hosts.allow` lists the host on a `site:` line: the allowlist names every host the project's
     products contact, and `scripts/check-url-hosts.sh` fails if the app binary ever contains a website-only host.
   - This replaces "Website analytics: none" of ADR 0601 decision 5 and ADR 0001 item 18 while configured; the
     privacy page renders the state the build ships.
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

- Pa's one-time steps (repository settings, GHCR visibility, Portainer stack and webhook, Cloudflare DNS and token)
  are listed in the runbook and done by Pa by hand; the repository holds only the files. The Umami stack is already running (analytics runbook).
- The image grows with every release; a later decision can move `/download/` elsewhere without touching the site.
- VERIFY on the first deploy: the nodes' architecture (`linux/amd64` is built), the DNS record target, and whether
  `docker stack deploy` on this Swarm accepts `read_only` and `tmpfs`. The resolver name (`cloudflare`) and the
  provider (v3 Swarm) were confirmed by the Umami stack on 2026-11-13.
