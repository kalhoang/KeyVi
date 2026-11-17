# Runbook: website deployment on the Kalera Docker Swarm

Owner: Pa. Specification: PRD-R73 to PRD-R76, PLT-R1101, QA-R38, QA-R54. Decisions: [ADR 0601](../decisions/0601-static-site-generator.md) (generator), [ADR 0602](../decisions/0602-site-hosting-kalera-swarm.md) (this hosting). Pa's answers of 2026-11-13: S9 and Q11 (Kalera Swarm), Q7 (cookieless analytics), Q10 (updates and DMGs on the site host only).

The website, the Sparkle appcast, the release-notes pages, the update archives and the DMGs are served by one container image, `ghcr.io/<owner>/{{app-slug}}-site`, running as two replicas on the Kalera Docker Swarm (Portainer environment `F3D`, id 7) behind the shared Traefik (`traefik2` stack, network `traefik_public`, TLS through the Cloudflare DNS challenge). The host name is the site host, `APP_SITE_HOST` in `scripts/brand.env` (`{{app-slug}}.kal.vn`). Images are built and deployed by `.github/workflows/site-image.yml` from the branch `prod` only, never from `main` (Kalera rule). Until the first public release the deployed site is a preview: `SITE_STRICT=false`, so VERIFY badges stay visible and every response carries `X-Robots-Tag: noindex`.

Brand values never appear in the stack file or the workflow. `deploy/site/stack-env.sh` prints them from `scripts/brand.env`:

```sh
deploy/site/stack-env.sh --owner <github owner>    # SITE_HOST, SITE_SLUG, IMAGE_OWNER, IMAGE_NAME, IMAGE_TAG, IMAGE
```

## 0. Current deployment (2026-11-14)

The preview is live at the site host. State on 2026-11-15, after the repository became public, so the next maintainer does not redo it:

| Item | State |
|---|---|
| Repository | `kalhoang/{{AppName}}` (`APP_REPOSITORY_URL`), public since 15/11/2026. Branch protection on `main` and `prod` refuses force pushes and deletions. The history before publication was rewritten once (CLR-R12 amendment); the original history is the private repository `kalhoang/{{app-slug}}-original-history`, plus an offline bundle with the map of commit IDs |
| GHCR package | `{{app-slug}}-site`, **public** (Pa, 2026-11-14), so the Swarm pulls it without a registry entry |
| Actions | Only `Site` is enabled. `Site image` stays disabled until Pa finishes the two steps of the next row, and `CI`, `Diagnostics labels`, `Integration`, `Nightly`, `PR labels` and `Release` are disabled by hand until macOS runners exist (ADR 0602, S6/Q12). Re-enable one with `gh workflow enable <name>` |
| Variables and secrets | Repository variable `SITE_STRICT=false`; `IMAGE_OWNER` is unset, so the repository owner is used. Environment `site` limits deployments to `prod`. Still to do by Pa on github.com, because neither value can be copied from the earlier repository: add the environment secret `PORTAINER_WEBHOOK_URL` (the service webhook from Portainer), and in the settings of the GHCR package `{{app-slug}}-site` under "Manage Actions access" give this repository write access; then `gh workflow enable "Site image"` |
| Portainer | Stack `{{app-slug}}-site`, id 73, environment 7 (Swarm). Stack variables: `SITE_HOST`, `SITE_SLUG`, `IMAGE_OWNER=kalhoang`, `IMAGE_NAME`, `IMAGE_TAG=prod`. Service `{{app-slug}}-site_site`, 2 replicas |
| Redeploy | A push to `prod` runs `site-image.yml`, which builds and pushes the image and calls the service webhook; verified end to end on 2026-11-14 |

## 1. What is where

| File | Role |
|---|---|
| `site/static/_headers` | The only place response headers are written: CSP, HSTS, frame, referrer, permissions, caching of `appcast.xml`, `/assets/*` and `/download/*`, the strict policy of `/release-notes/*` |
| `site/config.json` | `analytics` (the self-hosted Umami; missing or empty = no analytics), `banner` (incident notice) |
| `deploy/site/build.mjs` | Builds the image content: the site (`--strict`, `--noindex`), `nginx/_headers` and `nginx/locations.conf` generated from it, release files into `/download/` |
| `deploy/site/nginx-headers.mjs` | `_headers` to nginx `location` blocks (every add_header with `always`) |
| `deploy/site/nginx.conf` | nginx main configuration: port 8080, unprivileged, relative redirects, an access log with no client address, user agent or referrer |
| `deploy/site/Dockerfile` | Two stages, base images pinned by digest; build context limited by `Dockerfile.dockerignore` |
| `deploy/site/stack.yml` | Portainer stack: 2 replicas, rolling start-first updates with rollback, read-only root file system, healthcheck, Traefik labels (`traefik.swarm.*` provider labels only) |
| `deploy/site/fetch-downloads.py` | Fetches every DMG and update archive that `site/data/releases.json` and the appcast place under `https://<site host>/download/` from its GitHub Release and checks SHA-256 and length |
| `deploy/site/check-live-headers.mjs` | Asks a running container for one file per `_headers` pattern and compares every header |
| `.github/workflows/site-image.yml` | Branch `prod`: tests, fetch, build, live header check, push, Portainer webhook |
| `.github/workflows/site.yml` | Pull requests and `main`: site and container tests and a build; never deploys |

## 2. One-time prerequisites (Pa)

- [ ] The repository `kalhoang/{{app-slug}}` exists (S3; private first).
- [ ] Branch `prod`, created from `main`, protected: only Pa pushes, no force push, no deletion.
- [ ] Environment `site` with the deployment branch rule "selected branches: `prod`". Its secret `PORTAINER_WEBHOOK_URL` is added in section 4 step 4; until then the workflow pushes the image and skips the redeploy with a warning.
- [ ] Repository variables: `IMAGE_OWNER` = `kalhoang` (the GHCR namespace; default: the repository owner). `IMAGE_OWNER` must equal the repository owner: the workflow pushes with `GITHUB_TOKEN`, which can publish packages only in the repository's own namespace, so its first step stops the run for any other value (publishing under another account would need a token with `write:packages` there, not set up). `SITE_STRICT` = `false` (preview until the first public release, section 8). `SITE_IMAGE_NAME` only if the image should not be called `{{app-slug}}-site`.
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
2. **Environment variables**: add each line printed by `deploy/site/stack-env.sh --owner kalhoang` (`SITE_HOST`, `SITE_SLUG`, `IMAGE_OWNER`, `IMAGE_NAME`, `IMAGE_TAG`; `IMAGE` is not used by the stack). `TRAEFIK_CERT_RESOLVER` is not needed: the shared Traefik's resolver is `cloudflare`, confirmed by the Umami stack on 2026-11-13 (its certificate for `stats.kal.vn` comes from that resolver). Set it only if traefik2's static configuration (`certificatesResolvers.<name>.acme.dnsChallenge.provider: cloudflare`) is ever renamed.
3. **Deploy the stack**. Confirm with the Swarm itself, not with Portainer's status column (it has shown stale states before): `docker service ls` lists `{{app-slug}}-site_site` with `2/2`, and `docker service ps {{app-slug}}-site_site` shows both tasks `Running` and healthy.
4. **Service webhook**: Services, `{{app-slug}}-site_site`, turn on "Service webhook", copy the URL into the GitHub secret `PORTAINER_WEBHOOK_URL` of the environment `site`. The URL redeploys the service; treat it as a secret: pipe it into `gh secret set PORTAINER_WEBHOOK_URL --env site` on standard input, never as a command-line argument.

Two Swarm traps, both met on the first deploy and both covered by `scripts/tests/test_site_deploy.py` (`StackTests`) and the comment at the top of `stack.yml`:

- **Variable interpolation follows docker/cli, not POSIX sh.** Portainer and `docker stack deploy` read `${VAR:?message}` by trying the separators in the order `:-`, `-`, `:?`, `?`, so a dash anywhere in the message turns the rest into a default value. The braced form is also greedy up to the last `}` on the line, so two `${...:?...}` forms on one line swallow each other. Symptom: `invalid reference format`, or an image name that contains part of a message. Rule: at most one default or required form per line, placed last on the line, and no dash in its message. `docker stack config -c deploy/site/stack.yml` (it needs only the CLI, no daemon) shows the rendered stack before deploying.
- **Swarm ignores the short `tmpfs:` key.** `docker compose` honours it, `docker stack deploy` drops it silently, so with `read_only: true` nginx cannot create `/tmp/client_temp` and every task exits with code 1 (`Read-only file system`). Use the long form, `volumes: - type: tmpfs, target: /tmp`, which Swarm applies.

## 5. DNS and TLS (Cloudflare)

1. In the `kal.vn` zone, create the record for the site host with the same target as the other hosts this Swarm serves through Traefik (for example the record of `kal.vn`, whose `kal-profile` stack runs on the same Swarm), **proxied** (orange cloud), as Pa decided. VERIFY the target before saving.
2. SSL/TLS mode of the zone: **Full (strict)**. Traefik presents a valid certificate from the DNS challenge, so strict validation works; Flexible would send plain HTTP to the origin.
3. Traefik requests the certificate on the first HTTPS request for the host. If it stays on Traefik's default certificate, the shared DNS challenge token does not cover `kal.vn` yet (section 2) or the resolver name is wrong (section 4 step 2).
4. Cloudflare honours the origin's `Cache-Control` (`appcast.xml` 5 minutes, `/assets/*` and `/download/*` one year, pages not cached), so no cache purge is needed after a deploy: every URL under `/assets/` names the current content of its file (`?v=<content hash>`; `node site/test.mjs` checks every page), and release files under `/download/` carry their version in the name. Keep the zone's Caching Level at **Standard** (the default), which keeps the query string in the cache key.

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

**Demo frames.** The home page demos come from `site/demo/frames.json`, which the engine writes from `site/demo/script.json` (PRD-R73, design 7.4 of the [website redesign](../superpowers/specs/2026-11-16-website-redesign-design.md)); the build and the image read the committed file and need Node only. After an engine change that alters a demo, run `swift run --package-path Packages/VietnameseEngine site-demo-frames` from the repository root and commit `site/demo/frames.json` in the same commit as the engine change. `site-demo-frames --check` fails when the committed file differs from what the engine produces; it runs in the `engine-linux` job of `ci.yml` (disabled by hand for now, section 0) and in the integrator's local gate, which is the guard meanwhile. When the engine no longer produces what a sentence was meant to show, change the sentence in `script.json`, never the frames.

## 7. Analytics (Q7)

The website counts page views with Umami, self-hosted on the Kalera Swarm at `https://stats.kal.vn` ([analytics runbook](analytics.md), ADR 0602 decision 7). It is already configured:

1. `site/config.json` holds `"analytics": { "provider": "umami", "scriptUrl": "https://stats.kal.vn/script.js", "websiteId": "<uuid>" }`. The website id is public (it appears in every page). The script host must be on a `site:` line of `scripts/url-hosts.allow`.
2. What it changes, all tested by `node site/test.mjs` and `node deploy/site/test.mjs`: every website page carries one `<script defer ... data-domains="<site host>" data-do-not-track="true">` tag in its head, the site-wide CSP gains exactly `https://stats.kal.vn` in `script-src` and `connect-src`, and `/rieng-tu` and `/en/privacy/` describe Umami instead of "none". The app and the release-notes pages never load it.
3. To stop: remove `analytics` from `site/config.json` (or empty its three values) and deploy (section 6).
4. To move Umami to another host: add the host on a `site:` line of `scripts/url-hosts.allow` with a decision record, change `scriptUrl`, and deploy; the CSP follows the config.

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
| `404 page not found` from Traefik, or its default certificate | The router does not match: check `SITE_HOST`, and that the service is on `traefik_public`. A service with both `traefik.docker.*` and `traefik.swarm.*` labels is skipped by Traefik ("both Docker and Swarm labels are defined" in the Traefik log): keep `traefik.swarm.*` only |
| 502 or 503 | No healthy task: `docker service ps --no-trunc {{app-slug}}-site_site`; the container listens on 8080 and answers `/healthz`. A short 502 while the tasks roll over after a deploy is expected and clears once the new task is healthy |
| Portainer: `invalid reference format` | docker/cli interpolation broke the image or a label (section 4, first trap): check the stack with `docker stack config` |
| Tasks exit with code 1, `mkdir() "/tmp/client_temp" failed (30: Read-only file system)` | `/tmp` is not a tmpfs mount: use the long `volumes` form (section 4, second trap) |
| Certificate error | Resolver name (`TRAEFIK_CERT_RESOLVER`) or the DNS challenge token's zones |
| Image pull fails on the nodes | GHCR package private without a Portainer registry entry (section 2) |
| Image build fails with `--strict` | VERIFY markers or placeholders remain; for the preview keep `SITE_STRICT=false` |
| `check-live-headers` fails in the workflow | The container does not send a header of `_headers`. Never add headers to `nginx.conf`; change `site/static/_headers` and let the build generate the locations |
| A release file is missing | `fetch-downloads.py` failed: the GitHub Release is still a draft, or its asset does not match `releases.json` |

## 11. What stays with Pa

Creating the repository and the `prod` branch protection, the `site` environment, its secret and the variables, the GHCR visibility, the Cloudflare token and DNS record. Nobody else pushes images by hand, calls webhooks or changes Cloudflare or GHCR. Exception recorded on 2026-11-14: at Pa's request the integrator created the Portainer stack (id 73) and its service webhook, stored the webhook in the `site` environment and pushed `prod`; any later change to the stack or the webhook goes through Pa again.
