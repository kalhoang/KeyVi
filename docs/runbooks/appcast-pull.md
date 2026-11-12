# Runbook: pull an appcast item

Owner: the maintainer. Specification: QA-R38 step 1, QA-R54, SECURITY.md.

Purpose: stop further automatic installs of a bad release as fast as possible. This is the first action for a confirmed P0, within 1 hour. It is also the only P0 action available while Pa is unavailable (QA-R54).

What it does and does not do: it stops new automatic installs after the next update check (daily). It does not remove the app from machines that already installed it, and Sparkle does not downgrade them. Follow [rollback](rollback.md) afterwards.

## Fast path (a few minutes)

1. Create a branch and remove the item.

   ```sh
   git switch -c fix/pull-appcast-X.Y.Z origin/main
   ```

   Open `site/static/appcast.xml` and delete the whole `<item>...</item>` element whose `<sparkle:shortVersionString>` is the bad version. Delete only that item.

2. Check the file is still valid XML and the right item is gone.

   ```sh
   xmllint --noout site/static/appcast.xml
   grep -c "<item>" site/static/appcast.xml
   grep -n "shortVersionString" site/static/appcast.xml
   ```

3. Point the website back at the last good release: edit `site/data/releases.json` so the latest stable (or beta) entry is the previous good one, or remove the bad entry.

4. Commit and merge.

   ```sh
   git commit -am "fix: pull appcast item X.Y.Z"
   git push -u origin fix/pull-appcast-X.Y.Z
   gh pr create --fill --label P0
   ```

   `site.yml` deploys the website and appcast on push to `main` when `site/` changes. Branch protection on `main` requires checks; when time matters, Pa as repository administrator may merge with the override, using a rebase merge (`gh pr merge --admin --rebase`). Never use a squash merge: the early history must stay intact (CLR-R12).

5. Verify the live feed (do not trust the deploy log).

   ```sh
   source scripts/brand.env
   curl -sSf "https://$APP_SITE_HOST/appcast.xml" | grep -c "shortVersionString"
   curl -sSf "https://$APP_SITE_HOST/appcast.xml" | grep "X.Y.Z" || echo "pulled"
   curl -sI "https://$APP_SITE_HOST/appcast.xml" | grep -i "cache-control\|age\|last-modified"
   ```

   If a CDN or proxy caches the feed, purge it (the hosting is defined by the site track; VERIFY the cache TTL and purge method, and record them here).

6. Revert the Homebrew cask in the tap to the previous good version and mark the GitHub Release as a draft or pre-release.

## If the pipeline is down (emergency path)

The appcast is a static file served from `{{app-slug}}.kal.vn` (a domain Pa controls, PRD-R75). If CI or `site.yml` cannot run, build and upload the site manually (`node site/build.mjs`, then upload `site/dist` using the deployment method documented by the site track; VERIFY and write the exact command here when it exists). Then do step 5.

## After pulling

1. Open or update the pinned issue and the website banner ([rollback](rollback.md) section 2).
2. Record the time of confirmation and the time of the pull. The target is under 1 hour.
3. Re-adding an item later (after a fix) is a normal publish: new build number, [release](release.md) section 7. Never re-add a pulled item with the same build number.

## Absence mode (QA-R54)

When Pa is unavailable for more than a week: website banner plus pinned issue with the expected return date. P0 handling is limited to this runbook. Pa may choose to give one trusted person repository admin access and this runbook for that period (a suggestion, not a decision).
