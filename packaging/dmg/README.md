# DMG assets

`scripts/make-dmg.sh` builds the distribution disk image (QA-R30 step 4): the app, an `Applications`
symlink, and an optional background, compressed as UDZO and signed with the Developer ID identity.

## Files in this folder

| File | Status | Notes |
|---|---|---|
| `background.png` | not yet provided | Optional. Copied to `.background/background.png` inside the image. Size 660 x 400 points; also provide `background@2x.png` (1320 x 800) and combine them with `tiffutil -cathidpicheck` if a Retina background is wanted. Must be original or properly licensed artwork (CLR-R7); record its source in `THIRD_PARTY_NOTICES.md`. |

## Window layout

Finder window layout (icon positions, window size, background assignment) is stored in the image's
`.DS_Store`, which Finder writes only through AppleScript in a logged-in GUI session. CI runners have no
such session, so the image currently opens with Finder's default layout: the app and the `Applications`
link side by side. When Pa wants a designed layout:

1. Mount a test image on a Mac, arrange the window by hand (or with an AppleScript), and copy the resulting
   `.DS_Store` here as `DS_Store.template`.
2. Extend `scripts/make-dmg.sh` to copy it into the staging folder as `.DS_Store` (it references the
   volume name, so regenerate it after a rename with `scripts/rename-app.sh`).

## Volume name and file name

- Volume name: `APP_DISPLAY_NAME` from `scripts/brand.env`.
- File name: `<slug>-<version>.dmg`, for example the slug from `scripts/brand.env` followed by `-1.0.0.dmg`.
