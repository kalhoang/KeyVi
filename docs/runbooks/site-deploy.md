# Runbook: website deployment on the Kalera Docker Swarm

Owner: Pa. Specification: PRD-R73 to PRD-R76, PLT-R1101, QA-R38, QA-R54. Decisions: [ADR 0601](../decisions/0601-static-site-generator.md) (generator), [ADR 0602](../decisions/0602-site-hosting-kalera-swarm.md) (this hosting). Pa's answers of 2026-11-13: S9 and Q11 (Kalera Swarm), Q7 (cookieless analytics), Q10 (updates and DMGs on the site host only).

The website, the Sparkle appcast, the release-notes pages, the update archives and the DMGs are served by one container image, `ghcr.io/<owner>/{{app-slug}}-site`, running as two replicas on the Kalera Docker Swarm (Portainer environment `F3D`, id 7) behind the shared Traefik (`traefik2` stack, network `traefik_public`, TLS through the Cloudflare DNS challenge). The host name is the site host, `APP_SITE_HOST` in `scripts/brand.env` (`{{app-slug}}.kal.vn`). Images are built and deployed by `.github/workflows/site-image.yml` from the branch `prod` only, never from `main` (Kalera rule). Until the first public release the deployed site is a preview: `SITE_STRICT=false`, so VERIFY badges stay visible and every response carries `X-Robots-Tag: noindex`.

Brand values never appear in the stack file or the workflow. `deploy/site/stack-env.sh` prints them from `scripts/brand.env`:

```sh
deploy/site/stack-env.sh --owner <github owner>    # SITE_HOST, SITE_SLUG, IMAGE_OWNER, IMAGE_NAME, IMAGE_TAG, IMAGE
```

## 1. What is where

| File | Role |
|---|---|
| `site/static/_headers` | The only place response headers are written: CSP, HSTS, frame, referrer, permissions, caching of `appcast.xml`, `/assets/*` and `/download/*`, the strict policy of `/release-notes/*` |
| `site/config.json` | `analytics` (empty `posthogKey` = no analytics), `banner` (incident notice) |
| `deploy/site/build.mjs` | Builds the image content: the site (`--strict`, `--noindex`), `nginx/_headers` and `nginx/locations.conf` generated from it, release files into `/download/` |
| `deploy/site/nginx-headers.mjs` | `_headers` to nginx `location` blocks (every add_header with `always`) |
| `deploy/site/nginx.conf` | nginx main configuration: port 8080, unprivileged, relative redirects, an access log with no client address, user agent or referrer |
| `deploy/site/Dockerfile` | Two stages, base images pinned by digest; build context limited by `Dockerfile.dockerignore` |
| `deploy/site/stack.yml` | Portainer stack: 2 replicas, rolling start-first updates with rollback, read-only root file system, healthcheck, Traefik labels |
| `deploy/site/fetch-downloads.py` | Fetches every DMG and update archive that `site/data/releases.json` and the appcast place under `https://<site host>/download/` from its GitHub Release and checks SHA-256 and length |
| `deploy/site/check-live-headers.mjs` | Asks a running container for one file per `_headers` pattern and compares every header |
| `.github/workflows/site-image.yml` | Branch `prod`: tests, fetch, build, live header check, push, Portainer webhook |
| `.github/workflows/site.yml` | Pull requests and `main`: site and container tests and a build; never deploys |

## 2. One-time prerequisites (Pa)

- [ ] The repository `kalhoang/{{app-slug}}` exists (S3; private first).
- [ ] Branch `prod`, created from `main`, protected: only Pa pushes, no force push, no deletion.
- [ ] Environment `site` with the deployment branch rule "selected branches: `prod`". Its secret `PORTAINER_WEBHOOK_URL` is added in section 4 step 4; until then the workflow pushes the image and skips the redeploy with a warning.
- [ ] Repository variables: `IMAGE_OWNER` = `kalhoang` (the GHCR namespace; default: the repository owner), `SITE_STRICT` = `false` (preview until the first public release, section 8). `SITE_IMAGE_NAME` only if the image should not be called `{{app-slug}}-site`.
- [ ] GHCR package visibility, Pa's choice. **Public** is simplest: the image contains only the public website and the public release files, and the Swarm pulls it without credentials. **Private**: add a registry in Portainer (Registries, `ghcr.io`, user `kalhoang`, a personal access token with `read:packages` only) and select it for the stack.
- [ ] Cloudflare: an API token for the `kal.vn` zone (S9, pending), so that the DNS record of section 5 can be created and, if the shared Traefik's DNS challenge token does not cover `kal.vn` yet, so that it can.
- [ ] On Pa's Mac: Docker with buildx (OrbStack), `gh` logged in as `kalhoang` with the `write:packages` scope (`gh auth refresh -s write:packages`).

## 3. First deploy by hand: build and push

Run from the repository root on Pa's Mac, by hand: nothing automated runs these steps (no push, no deploy).

```sh
eval "$(deploy/site/stack-env.sh --owner kalhoang --tag prod | sed 's/^/export /')"
python3 -I deploy/site/fetch-downloads.py --out deploy/site/downloads --repo "kalhoang/$SITE_SLUG"   # nothing to fetch before the first release
docker build -f deploy/site/Dockerfile --platform linux/amd64 --build-arg SITE_STRICT=false -t "$IMAGE" .
```

The build stage runs on the Mac's own platform and the nginx stage only copies files, so building `linux/amd64` on Apple silicon needs no emulation. VERIFY the architecture of the Swarm nodes once (`docker node ls`, then `docker node inspect --format '{{.Description.Platform.Architecture}}' <node>`): if a node is `aarch64`, build with `--platform linux/amd64,linux/arm64` and `--push` instead.

Check the image locally before pushing (the same check the workflow runs):

```sh
docker run -d --name site-check --read-only --tmpfs /tmp -p 127.0.0.1:8080:8080 "$IMAGE"
docker cp site-check:/etc/nginx/site/_headers /tmp/site-headers
docker exec site-check find /srv/site -type f | sed 's#^/srv/site##' > /tmp/site-files.txt
node deploy/site/check-live-headers.mjs --base http://127.0.0.1:8080 --headers /tmp/site-headers --files /tmp/site-files.txt
docker rm -f site-check
```

Push:

```sh
gh auth token | docker login ghcr.io -u kalhoang --password-stdin
docker push "$IMAGE"
docker logout ghcr.io
```

## 4. Create the stack in Portainer

1. Portainer, environment `F3D`, **Stacks**, **Add stack**. Name: `{{app-slug}}-site`. Build method: Web editor; paste `deploy/site/stack.yml`.
2. **Environment variables**: add each line printed by `deploy/site/stack-env.sh --owner kalhoang` (`SITE_HOST`, `SITE_SLUG`, `IMAGE_OWNER`, `IMAGE_NAME`, `IMAGE_TAG`; `IMAGE` is not used by the stack). Add `TRAEFIK_CERT_RESOLVER` only if the shared Traefik's resolver is not called `cloudflare`: VERIFY in the `traefik2` stack's static configuration (`certificatesResolvers.<name>.acme.dnsChallenge.provider: cloudflare`). The Kalera PA stack uses `cloudflare`; the Kalera dashboard's stack file defaults to `letsencrypt`.
3. **Deploy the stack**. Confirm with the Swarm itself, not with Portainer's status column (it has shown stale states before): `docker service ls` lists `{{app-slug}}-site_site` with `2/2`, and `docker service ps {{app-slug}}-site_site` shows both tasks `Running` and healthy.
4. **Service webhook**: Services, `{{app-slug}}-site_site`, turn on "Service webhook", copy the URL into the GitHub secret `PORTAINER_WEBHOOK_URL` of the environment `site`. The URL redeploys the service; treat it as a secret.

## 5. DNS and TLS (Cloudflare)

1. In the `kal.vn` zone, create the record for the site host with the same target as the other hosts this Swarm serves through Traefik (for example the record of `kal.vn`, whose `kal-profile` stack runs on the same Swarm), **proxied** (orange cloud), as Pa decided. VERIFY the target before saving.
2. SSL/TLS mode of the zone: **Full (strict)**. Traefik presents a valid certificate from the DNS challenge, so strict validation works; Flexible would send plain HTTP to the origin.
3. Traefik requests the certificate on the first HTTPS request for the host. If it stays on Traefik's default certificate, the shared DNS challenge token does not cover `kal.vn` yet (section 2) or the resolver name is wrong (section 4 step 2).
4. Cloudflare honours the origin's `Cache-Control` (`appcast.xml` 5 minutes, `/assets/*` and `/download/*` one year, pages not cached), so no cache purge is needed after a deploy: every URL under `/assets/` names the current content of its file (`?v=<content hash>`, or the hash in the file name for the analytics loader; `node site/test.mjs` checks every page), and release files under `/download/` carry their version in the name. Keep the zone's Caching Level at **Standard** (the default), which keeps the query string in the cache key.

Checks after the first deploy:

```sh
source scripts/brand.env
curl -sSI "https://$APP_SITE_HOST/" | grep -iE '^(strict-transport-security|content-security-policy|x-frame-options|x-robots-tag):'
curl -sS "https://$APP_SITE_HOST/appcast.xml" | xmllint --noout -
curl -sSI "http://$APP_SITE_HOST/" | grep -iE '^(HTTP|location)'      # a permanent redirect to https
curl -sS "https://$APP_SITE_HOST/healthz"                              # ok
```

## 6. Every later deploy (CI)

1. Changes reach `main` through pull requests; `site.yml` runs the site and container tests and a build, and never deploys.
2. To deploy, fast-forward `prod` to the `main` commit (never force):

   ```sh
   git fetch origin
   git push origin origin/main:prod
   ```

3. `site-image.yml` then runs the tests, fetches the release files, builds the image, starts it and runs the live header check, pushes `sha-<commit>` and `prod`, and calls the Portainer webhook. The Swarm pulls `prod` and replaces the two replicas one at a time (start-first; a failing healthcheck rolls back).
4. Roll back the site: in Portainer, the service's **Rollback**, or set `IMAGE_TAG` to a previous `sha-<commit>` and update the stack.

## 7. Analytics (optional, Q7)

1. In PostHog Cloud, organisation "Kalera", create a project for the website. Region (US or EU): VERIFY the organisation's region; it decides `posthogHost`.
2. Project settings: turn on **cookieless tracking** (Web analytics) and **Discard client IP data**. Both are required for what the privacy page states.
3. In `site/config.json`, set `analytics.posthogKey` to the project API key (`phc_...`; it is public by design) and `analytics.posthogHost` to `https://us.i.posthog.com` or `https://eu.i.posthog.com`. Pull request, then deploy (section 6).
4. What changes, all tested by `node site/test.mjs`: every website page loads `/assets/analytics.<content hash>.js` (cookieless mode, page views only), the site-wide CSP gains exactly the two PostHog hosts, and `/rieng-tu` and `/en/privacy/` describe the analytics instead of "none". The app and the release-notes pages never load it.
5. To stop: empty `posthogKey` and deploy.

## 8. Preview until the first public release

`SITE_STRICT=false` builds the preview: the build accepts VERIFY markers and placeholder values (`OWNER` in `site/config.json`) and every response sends `X-Robots-Tag: noindex`. At the first public release:

1. Resolve every VERIFY badge and placeholder (`node site/build.mjs --strict` must pass).
2. Set the repository variable `SITE_STRICT` to `true` (or delete it) and deploy. The image build now fails if a marker comes back.
3. Check that `curl -sSI "https://$APP_SITE_HOST/"` no longer shows `x-robots-tag`.

## 9. Releases and incidents

- `scripts/publish-release` writes archive and DMG URLs under `https://<site host>/download/` (ADR 0504). The image build fetches those files from the GitHub Release `v<version>` and checks the DMG against the SHA-256 in `site/data/releases.json` and the archive against the appcast length, so un-draft the GitHub Release before moving `prod` ([release](release.md) section 7). Every DMG stays downloadable (QA-R38) because every release in `releases.json` is fetched again for each image. The image grows with each release; when its size matters, move `/download/` to a volume or the Kalera CDN in a new decision.
- Pulling an appcast item, the website banner and rollback: [appcast pull](appcast-pull.md), [rollback](rollback.md#website-banner). Each is a commit on `main` followed by section 6 step 2.
- If GitHub Actions is down: section 3 (build and push from Pa's Mac), then Portainer, the service, **Update the service** with "Re-pull image".

## 10. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `404 page not found` from Traefik, or its default certificate | The router does not match: check `SITE_HOST`, and that the service is on `traefik_public`. If traefik2 runs the v2 docker provider, check it reads `traefik.docker.network` (both labels are set) |
| 502 or 503 | No healthy task: `docker service ps --no-trunc {{app-slug}}-site_site`; the container listens on 8080 and answers `/healthz` |
| Certificate error | Resolver name (`TRAEFIK_CERT_RESOLVER`) or the DNS challenge token's zones |
| Image pull fails on the nodes | GHCR package private without a Portainer registry entry (section 2) |
| Image build fails with `--strict` | VERIFY markers or placeholders remain; for the preview keep `SITE_STRICT=false` |
| `check-live-headers` fails in the workflow | The container does not send a header of `_headers`. Never add headers to `nginx.conf`; change `site/static/_headers` and let the build generate the locations |
| A release file is missing | `fetch-downloads.py` failed: the GitHub Release is still a draft, or its asset does not match `releases.json` |

## 11. What stays with Pa

Creating the repository and the `prod` branch protection, the `site` environment, its secret and the variables, the GHCR visibility, the Portainer stack and its webhook, the Cloudflare token and DNS record, the PostHog project, and the first build and push. Nobody else pushes images, calls webhooks or changes Cloudflare, Portainer or GHCR.
