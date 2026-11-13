# Runbook: website analytics (Umami)

Owner: Pa. Specification: PRD-R74 (no trackers, cookieless aggregate numbers), PRD-R76 (success metrics without telemetry). Decision: [ADR 0602](../decisions/0602-site-hosting-kalera-swarm.md) decision 7 (Pa's answer Q7 and its follow-up of 2026-11-13). Website side: [site deploy](site-deploy.md) section 7.

The website counts page views with **Umami 3.5.0**, self-hosted by the project. Umami sets no cookie, stores nothing in the browser and keeps no IP address: it derives a visit identifier from a one-way hash of the IP address, the user agent, the website id and a salt that rotates monthly, and records the approximate country and city, the browser, the operating system and the device type. Browsers that send Do Not Track are not counted (`data-do-not-track="true"` on the tag). The app never contacts Umami, and neither do the release-notes pages shown in the app's update window.

## 1. What runs where

| Item | Value |
|---|---|
| Stack file | `deploy/umami/stack.yml` (the file deployed in Portainer; keep both in step) |
| Portainer | Stack `{{app-slug}}-umami`, stack id 72, in environment `F3D` (id 7), the Kalera Docker Swarm |
| Service | `{{app-slug}}-umami_umami`, one replica, image `ghcr.io/umami-software/umami:3.5.0`, port 3000, healthcheck `GET /api/heartbeat` |
| Public host | `https://stats.kal.vn` (Cloudflare record proxied; TLS from the shared Traefik, resolver `cloudflare`) |
| Database | `{{app-slug}}_umami` on the shared PostgreSQL 18 server at `10.148.0.2` (private network; the server's `pg_hba.conf` already admits the Swarm subnet `10.148.0.0/20`) |
| Secrets | Portainer stack environment only: `DATABASE_URL` (the PostgreSQL URL of `{{app-slug}}_umami`) and `APP_SECRET` (random, signs Umami's login tokens). Copies in Pa's Keychain: `KEYVI_UMAMI_DB_PASSWORD`, `KEYVI_UMAMI_APP_SECRET` |
| Admin login | `https://stats.kal.vn`, user `admin`; the password is in Pa's Keychain item `KEYVI_UMAMI_ADMIN_PASSWORD` (Umami's default password was replaced on the first login) |
| Website entry | Name {{AppName}}, domain: the site host; its website id is in `site/config.json` (`analytics.websiteId`, public by design) |
| Vendor calls | None: `DISABLE_TELEMETRY=1` and `DISABLE_UPDATES=1` stop Umami's anonymous telemetry and update check |

Read a secret without printing it (it goes to the clipboard):

```sh
kal-secret get KEYVI_UMAMI_ADMIN_PASSWORD | pbcopy
```

Never paste a secret into the stack file, a commit, an issue or a log.

## 2. Health checks

```sh
curl -sS -o /dev/null -w '%{http_code}\n' https://stats.kal.vn/api/heartbeat   # 200
curl -sSI https://stats.kal.vn/script.js | grep -iE '^(HTTP|content-type|cache-control)'
```

In Portainer, the service shows `1/1` and its task is healthy; confirm with the Swarm itself (`docker service ps {{app-slug}}-umami_umami`), not only Portainer's status column. Then open a website page in a private window (Do Not Track off) and check that the visit appears in the Umami dashboard's realtime view.

## 3. Upgrade

1. Read the Umami release notes (`https://github.com/umami-software/umami/releases`) from the running version to the target, for database migrations, removed environment variables and tracker changes. Umami runs its database migrations when the new container starts.
2. Back up the database first (section 4). An image rollback does not undo a migration; the dump does.
3. Change the image tag in `deploy/umami/stack.yml` (an exact version, never `latest`) in a pull request; `scripts/tests/test_site_deploy.py` checks the stack file.
4. Portainer, environment `F3D`, Stacks, `{{app-slug}}-umami`, Editor: paste the new file, keep the environment variables, **Update the stack** with "Re-pull image". The update is start-first with rollback on failure.
5. Section 2 checks, then log in as `admin` and look at yesterday's numbers.
6. Purge the Cloudflare cache of `https://stats.kal.vn/script.js` (Cloudflare dashboard, zone `kal.vn`, Caching, Custom Purge, by URL). Umami serves the tracker with `cache-control: public, max-age=31536000, must-revalidate` and Cloudflare caches it, so without a purge visitors keep the old tracker.
7. If the website's tag needs new attributes for the new version, change `site/lib/analytics.mjs` and its tests in the same pull request as the stack file.

## 4. Backup and restore

The data is small (one row per page view). Take a logical dump before every upgrade and keep it with the other database backups. The shared server's scheduled logical backup covers this database only if it dumps every database on the server: VERIFY that `{{app-slug}}_umami` appears in its next snapshot.

On the database host (SSH alias `s4` on Pa's Mac), as the `postgres` operating-system user:

```sh
ssh s4 "sudo -u postgres pg_dump --format=custom --dbname={{app-slug}}_umami" > "umami-$(date +%Y%m%d-%H%M).dump"
pg_restore --list "umami-<stamp>.dump" | head      # the archive parses
```

Restore (stop the service first: Portainer, the service, scale to 0; scale back to 1 afterwards):

```sh
ssh s4 "sudo -u postgres pg_restore --clean --if-exists --dbname={{app-slug}}_umami" < "umami-<stamp>.dump"
```

## 5. Traefik labels on this Swarm

The shared Traefik (`traefik2` stack, network `traefik_public`) runs the v3 **Swarm** provider. A service whose labels mix `traefik.docker.*` and `traefik.swarm.*` is skipped entirely; the Traefik log says "both Docker and Swarm labels are defined" and the host answers with Traefik's 404 and its default certificate. Rules for every stack on this Swarm (the website stack included):

- Labels go under `deploy.labels` (service labels), not container labels.
- Use `traefik.swarm.network: traefik_public`, never `traefik.docker.network`, and no other `traefik.docker.*` label.
- Name routers, services and middlewares uniquely per stack (here the `{{app-slug}}-umami` prefix).
- Certificates: `tls.certresolver: cloudflare` (DNS challenge for the `kal.vn` zone).

`scripts/tests/test_site_deploy.py` fails when a stack file under `deploy/` carries a `traefik.docker.*` label.

## 6. Changing what is collected

- What the tracker sends for each page view: the page address and the page title, the host name, the referring page, the screen size and the browser language. `/rieng-tu` lists the same fields (PRD-R74); `site/test.mjs` checks the page title is named there.
- The tag on the website is built only by `site/lib/analytics.mjs` (the attributes `data-website-id`, `data-domains` with the site host, `data-do-not-track="true"`). Any new attribute that collects more (for example `data-performance` or `data-errors`) needs a decision record and a `/rieng-tu` update in the same pull request (QA-R60).
- Turning analytics off: remove `analytics` from `site/config.json` and deploy the website; the CSP and the privacy page follow.
- Deleting the collected data: Umami, Settings, Websites, {{AppName}}, Data, Reset (irreversible; take a dump first if the numbers may be needed).
- A new host for Umami: a `site:` line in `scripts/url-hosts.allow`, a decision record, a new `scriptUrl`, and the stack's `Host()` rules.
