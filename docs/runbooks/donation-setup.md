# Runbook: donation setup

Owner: the maintainer. Specification: PRD-R56 to PRD-R61, spec/03-product.md section 13, open decision 19 (donation account details and the public sponsor list).

{{AppName}} is free. Donations are a tip jar, never a nag. This runbook sets up the three channels that the specification allows: VietQR (Napas) to Pa's personal bank account, a MoMo QR, and GitHub Sponsors.

## What is allowed, and what is not

Entry points, and only these (PRD-R57): the `Ủng hộ {{AppName}}...` menu item, the donation block in About & Support, the website `/ung-ho` page, the GitHub repository Sponsor button, and one plain line at the bottom of the release notes on the website (not in the in-app update window).

Forbidden (PRD-R58): popups, timers, counters, "you have typed N words" messages, badges, features locked behind donating, donation prompts in onboarding, during updates or after a crash or bug report.

Not used:

- **Polar.sh** must not be used for donations: its acceptable-use policy prohibits donations and sponsorship. It is only an option if a paid product is ever sold (PRD-R60).
- **Buy Me a Coffee** is not used: Vietnam is not a payout country (PRD-R60).

## Standard copy

Vietnamese (draft from PRD-R59): `{{AppName}} miễn phí và sẽ luôn miễn phí. Nếu thấy có ích, bạn có thể ủng hộ để Kal có thêm thời gian làm tiếp.`

English equivalent: `{{AppName}} is free and always will be. If you find it useful, you can support it so Kal has more time to keep building.`

The block shows the QR codes, the account name as plain text, and the GitHub Sponsors link. The QR images are bundled assets (app resources and website static files), never fetched at runtime.

## 1. VietQR (Napas 247)

1. Use Pa's **personal** bank account. Open the banking app, find "Mã QR nhận tiền" (or the equivalent), and create a static QR for the account without a fixed amount. Alternatively, generate a static VietQR from the bank's own tool.
2. Export the QR as a square PNG (at least 1024 x 1024 px, high contrast, quiet zone kept). Name it `donate-vietqr.png`.
3. Scan it with **two different banking apps** and confirm that both show the right bank and the right **account holder name**. A wrong QR in a public build is not recoverable for users who already installed it.
4. Decide what is printed beside the QR as text: the account holder name (required by PRD-R59), and whether to also show the bank name and account number. This is Pa's privacy choice (VERIFY).

## 2. MoMo

1. In the MoMo app, open "Nhận tiền" and create the personal receiving QR, with no fixed amount.
2. Export it as `donate-momo.png` and scan-test it with a second phone.
3. Show the name that MoMo displays when the QR is scanned.

## 3. GitHub Sponsors

1. Apply for GitHub Sponsors on Pa's personal account (Settings, Sponsorship). Approval, Stripe or bank payout setup and tax details take time; start early. Check that payouts are available for Vietnam (VERIFY current availability).
2. When approved, put the handle in `.github/FUNDING.yml` (currently a placeholder; VERIFY handle). The Sponsor button then appears on the repository page.
3. Use the sponsor profile URL for the in-app and website links.

## 4. Where the files go

| Asset | Used by | Notes |
|---|---|---|
| `donate-vietqr.png`, `donate-momo.png` | App (About & Support) and website `/ung-ho` | Place them where the app track and the site track expect their resources (VERIFY the paths with `App/` and `site/static/`) |
| Sponsor URL | App, website, `.github/FUNDING.yml` | One value, copied everywhere |

Record each image in `THIRD_PARTY_NOTICES.md` section 4 as original work with its source (CLR-R7). The QR images contain account data by design and are public once released; do not commit them before Pa confirms the details (VERIFY).

## 5. Optional: public thank-you list (PRD-R61)

Pa's choice. If used, only sponsors who opt in appear on the website. No donor data is stored in the app, and the app never asks who donated.

## 6. Pre-release check (before the first public build)

- [ ] Both QR codes scan correctly in two apps each and show the expected name.
- [ ] The account name text next to the QR matches the bank's account holder name.
- [ ] `.github/FUNDING.yml` has the confirmed handle.
- [ ] The in-app block and `/ung-ho` show the same content.
- [ ] No donation prompt appears in onboarding, during an update, or after a bug report.
- [ ] Open decision 19 is answered and recorded in an ADR.
