# 0006. App licence and the Pro edition

- Status: accepted, 2026-11-13 (Pa approved the recommendation in the evening follow-up answers to the checklist);
  amended 2026-11-15: decision 4 (the Pro edition) is withdrawn, there is no paid edition (see the amendment below)
- Supersedes: row 2 of [0001](0001-defaults-for-open-decisions.md) (the app licence working default), item 2 of
  [0401](0401-interim-contribution-policy.md) (no external pull requests outside the engine) and the Q2, Q3 row of
  [0005](0005-pa-decisions-2026-11-13.md) ("not decided").
- Spec: QA-R61, QA-R62, PLT-R108, CLR-R11, CLR-R14, ENG-R109; `spec/00-overview.md` section 5 item 2,
  `spec/02-platform.md` section 14 item 2, `spec/03-product.md` section 18 item 2, `spec/04-quality-release.md`
  section 10 item 1.

## Context

The engine package was MPL-2.0 from the start (ENG-R109); the licence of everything else stayed open, marked
`LicenseRef-App-Pending`. QA-R61 tied the contribution sign-off to that choice: DCO alone for a permissive or a
GPL app with no relicensing plans, a CLA if Pa wanted to keep the option of a separately licensed edition. Pa
wants both a free, open app and the option of a paid Pro edition later, without asking contributors to sign a CLA.

## Decision

1. **Licences.**
   - `Packages/VietnameseEngine/`, `Packages/VietnameseEngineFuzz/`, the `data/` pipeline and
     `spec/reference-model/` stay **MPL-2.0**. Each of the three directories outside `spec/` has its own `LICENSE`
     with the verbatim MPL-2.0 text; the reference model scripts carry `SPDX-License-Identifier: MPL-2.0`.
   - Everything else (the app, AppCore, TestHost, SpikeIMK, scripts, the website, `deploy/`, `compat/`, the docs)
     is **GPL-3.0-or-later**. The root `LICENSE` is the verbatim GNU GPL version 3 text as published at
     `https://www.gnu.org/licenses/gpl-3.0.txt` (byte-exact, pinned by SHA-256 in
     `scripts/tests/test_docs_and_workflows.py`); source files carry `SPDX-License-Identifier: GPL-3.0-or-later`
     (`scripts/check-spdx.sh`, CLR-R11). "Or later" lets the project follow a future GPL version without asking
     every contributor again.
   - "The {{AppName}} authors" means Kal, the maintainer and copyright holder of the original work, and every
     contributor, as recorded by the git history and the sign-offs.
2. **Why GPL-3.0-or-later for the app.** The value of the app beyond the engine is the platform work: the
   per-app compatibility rules, the injection strategies, the diagnostics flow. A copyleft licence keeps that
   work open: anyone may study, change and redistribute it, but a redistributed derivative must stay under the
   GPL with its source. A closed competitor cannot take the rules database or the injection layer into a
   proprietary product. The engine stays permissive so that other projects, including GPL-2.0-only ones, can
   embed it (ENG-R109).
3. **Contributor terms (QA-R61).**
   - **Developer Certificate of Origin** for every contribution in every area: each commit carries
     `Signed-off-by: Name <e-mail>` (`git commit -s`), the e-mail matching the commit author. The sign-off
     certifies the DCO 1.1 (`https://developercertificate.org`), confirms the clean-room rule (CLR-R14) and
     affirms the inbound terms below. `scripts/check-dco.sh` checks every commit of a pull request by default.
   - **Inbound MIT for GPL-covered parts.** A contribution to a GPL-3.0-or-later part is licensed under
     GPL-3.0-or-later as part of the project and is **also licensed to the project under the MIT licence**.
     Contributions to the MPL-2.0 parts are MPL-2.0, as before. The MIT grant gives the copyright holder the rights a
     CLA would give for the purpose that matters here, shipping the code in a separately licensed edition,
     while contributors keep their copyright and sign nothing beyond the sign-off.
   - **No contributor licence agreement**, no CLA bot.
   - Trade-off, stated plainly in `CONTRIBUTING.md`: an MIT licence is non-exclusive, so the individual change a
     contributor wrote is available under MIT terms, while the app as a whole is distributed under the GPL.
4. **Pro edition** (withdrawn on 15/11/2026; kept here as it was decided, see the amendment below).
   - Only after 1.0, never before. Price: **99,000 VND** for a **lifetime** licence.
   - It never locks correct Vietnamese typing: the free GPL app always includes the complete engine, every
     typing method, the compatibility rules, the secure-input behaviour, diagnostics and updates. Pro may only
     add conveniences on top. A missing or invalid Pro licence changes nothing about typing.
   - Pro code lives in a **separate private module** (its own package or repository) that the public
     repository never depends on, never imports and never references by path. The public build stays complete
     and buildable without it.
   - Licence keys are verified **offline** by a **signature**: a signed licence payload checked against a public
     key compiled into the Pro module. There is no activation server, no phone-home and no new network endpoint
     (PLT-R906, QA-R60); the privacy page stays true.
   - The Pro binary combines GPL-covered code with private code, so it may only contain GPL-covered code that
     the copyright holder owns or received under the inbound MIT grant. Consequences: no third-party GPL code is
     accepted into the app (permissive dependencies only, as CLR-R6 and QA-R24 already require), and every
     external contribution must carry the sign-off.
   - Payment: Polar.sh is an option only for a paid product (PRD-R60); the payment path is a later decision.
5. **PLT-R108 consequences.**
   - `compat/rules.json` (shipped as `compat-rules.json`), `compat/matrix.json`, the injection layer
     (`Packages/AppCore/Sources/Injection/`) and the diagnostics flow are GPL-3.0-or-later. A competitor may reuse
     them only under the GPL: an open-source GPL-compatible project can, a proprietary one cannot.
   - The rules database gets no separate licence notice: it is covered by the root `LICENSE` (JSON has no comment
     syntax for an SPDX header, and `scripts/check-spdx.sh` checks source files only). If Pa later wants the rules
     freely reusable, a `compat/LICENSE` with a permissive licence can be added by a new decision; the inbound
     MIT grant makes that possible for contributed rules too.
6. **Supersedes 0401.** External pull requests are accepted in every area, under the terms above. The `dco`
   job of `.github/workflows/ci.yml` (`DCO sign-off on every commit (external pull requests)`) runs
   `scripts/check-dco.sh` without `--path` arguments, so it checks every commit of a pull request from a fork
   (the script defaults to every path); `scripts/tests/test_docs_and_workflows.py` fails if the step gains a
   `--path` again. The maintainer's own branches stay unchecked so the existing history is never rewritten
   (CLR-R12). `CONTRIBUTING.md` states the merge rule (a pull request with an unsigned commit is not merged)
   rather than the CI scope.

## Amendment, 15/11/2026: no paid edition

On reflection, the product owner withdrew the paid edition: the app stays free and is funded by donations and
sponsorships, because sales would bring in little.

- Decision 4 is withdrawn: there is no paid edition, no Pro module, no licence key and no payment path. Every
  feature, current and future, ships in the free GPL app.
- The project is funded by donations and sponsorships only (the donation block of About & Support and the website,
  PRD-R56 to PRD-R61; Polar.sh stays out because it does not allow donations).
- The licences (decision 1), the DCO sign-off and the inbound MIT grant (decision 3) do not change. The grant costs
  contributors nothing and keeps the project able to change its licence later without asking every contributor again;
  for the same reason third-party GPL code is still not accepted.

## Consequences

- `LicenseRef-App-Pending` is gone outside the decision records: spec, docs, `CONTRIBUTING.md`, the pull request
  template, `THIRD_PARTY_NOTICES.md` and the README name GPL-3.0-or-later and MPL-2.0;
  `scripts/tests/test_docs_and_workflows.py` (`LicenceTests`) fails if the old identifier returns.
- `scripts/rename-app.sh` never rewrites the root `LICENSE`, so the GPL text stays byte-exact after a rename;
  the `LICENSE` files of the engine parts name the product and follow a rename.
- Every conveyed copy carries the licence (GPL-3.0 section 4): `scripts/make-dmg.sh` puts `LICENSE.txt` (the root
  `LICENSE`) and `THIRD_PARTY_NOTICES.txt` next to the app in the DMG and refuses to build without them
  (`scripts/tests/run.sh` checks the staging folder).
- The app shows its own licence as an Appropriate Legal Notice (GPL-3.0 section 0): the Licences panel of About &
  Support (`Giấy phép và ghi công`) gains a row `{{AppName}}: GPL-3.0-or-later` that opens the bundled licence
  text, and the root `LICENSE` is copied into the app bundle as a resource. That row, its English translation and
  the resource belong to the App workstream (`App/`, `project.yml`); until they land the DMG files and the website
  carry the notice.
- Decision 4 is withdrawn (amendment of 15/11/2026): no Pro code, payment path or licence key is planned. Bringing a
  paid edition back would need a new decision record.
