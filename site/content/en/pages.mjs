// SPDX-License-Identifier: GPL-3.0-or-later
// English page copy: home, download, compatibility, changelog, privacy, donate (mirrors content/vi/pages.mjs).
// Trusted HTML; tokens like {{AppName}} are filled at build time.

export const home = {
  h1: "Type Vietnamese correctly from the first key, in every app on your Mac.",
  lede: "A Vietnamese input method for Mac. Setup takes about a minute, then you just type as usual.",
  footnote: "{{AppName}} never sends what you type anywhere and never stores what you type.",
  typedLabel: "Telex example",
  typed: [
    { keys: "tieengs Vieetj", out: "tiếng Việt" },
    { keys: "text user wifi", out: "text user wifi" },
  ],
  typedCaption: "English words stay as typed, no mode switch needed.",
  demoPlaceholder: "A 20-second recording is being prepared",
  demoCaption: "Typing Telex, automatic English restore, and per-app mode switching.",
  demoAlt: "A 20-second recording showing how typing Vietnamese works with {{AppName}}",
  downloadBtn: "Download {{AppName}} {{version}}",
  downloadSub: "{{requirement}}",
  noReleaseBtn: "No release yet",
  preRelease: "Status: in development, not publicly released yet.",
  brewLabel: "Or install with Homebrew",
  allDownloads: "All downloads and SHA-256 checksums",
  proofHeading: "Three things you can check",
  proof: [
    { h: "No data collection", p: "No telemetry, no analytics SDK, no \"anonymous usage data\". The only automatic network traffic is the update check.", link: "{{hrefPrivacy}}", linkText: "Read the privacy details" },
    { h: "Free", p: "{{AppName}} is free and always will be. No feature is locked, and the app never nags you for donations." },
    { h: "Open-source engine", p: "The Vietnamese typing engine is a Swift package under the Mozilla Public License 2.0, written from scratch from Vietnamese spelling rules, with its own test suite.", link: "{{repo}}", linkText: "Read the source", external: true },
  ],
  whyHeading: "What you will notice",
  why: [
    "English words such as <code>text</code>, <code>user</code> and <code>wifi</code> stay as typed, even when you end the word with a comma, a full stop or Enter.",
    "Slang such as <em>dzô</em> and <em>hẹo</em> types normally, because validity comes from spelling rules, not from a dictionary.",
    "When macOS blocks every input method (Secure Input), {{AppName}} tells you which app holds it and how to turn it off. It never guesses that you are typing a password.",
    "Tone marks at the end of a word still work: <code>vietj</code>, <code>tieengs</code>, <code>dangd</code>.",
    "It remembers Vietnamese or English per app: English in Terminal, Vietnamese in Zalo.",
  ],
  compatHeading: "Does your app work well?",
  compatText: "Each app is checked with a fixed script and the check date is shown.",
  compatLink: "See the compatibility list",
};

export const download = {
  h1: "Download {{AppName}}",
  lede: "A signed and notarized DMG that runs on Apple silicon and Intel.",
  stableHeading: "Stable release",
  betaHeading: "Beta release",
  betaNote: "Betas may still have bugs. You can go back to the Stable channel in Settings, under About & Support.",
  releaseDate: "Release date",
  fileHash: "SHA-256",
  button: "Download {{AppName}} {{version}} (DMG)",
  installHeading: "Install",
  install: [
    "Open the DMG and drag {{AppName}} into the Applications folder.",
    "Open {{AppName}} from Applications, not directly from the DMG.",
    "Follow the on-screen steps to grant permission. The whole process takes about a minute.",
  ],
  reqHeading: "System requirements",
  reqMacos: "{{macosRequirement}}",
  reqArch: "A Mac with Apple silicon or Intel (one build runs on both). macOS 27 runs on Apple silicon only.",
  reqExcluded: "Macs that stop at macOS Sonoma (for example the 2018 and 2019 MacBook Air and some 2017 models) are not supported.",
  reqPermission: "Permission needed: <strong>Accessibility</strong> on macOS 15 and 26, <strong>Device Control and Data Access</strong> on macOS 27. {{verifyHtml}} The pane names must be checked on each macOS version.",
  reqNoOthers: "{{AppName}} asks for no other permission (no Screen Recording, no Full Disk Access).",
  trustHeading: "Signature and notarization",
  trustBody: "Every DMG is signed with Kal's Developer ID certificate, notarized by Apple and stapled with the notarization ticket, so macOS opens it without a warning. Automatic updates use Sparkle 2 and are signed with EdDSA; the app rejects an update with a wrong signature.",
  verifyHeading: "Check the file you downloaded",
  verifyBody: "Compare the SHA-256 of the file with the value shown above, then check the signature after installing:",
  verifyHashCmd: "shasum -a 256 &lt;path to the DMG file&gt;",
  brewHeading: "Install with Homebrew",
  brewBody: "If you manage apps with Homebrew:",
  brewUpgrade: "Upgrade and uninstall:",
  archiveHeading: "Older versions",
  archiveBody: "Every published DMG is kept so you can reinstall it when needed. Your settings stay readable when you go back by one minor version.",
  archiveEmpty: "No versions yet.",
  appcastNote: "The Sparkle update feed lives permanently at {{appcastUrl}}; betas are items tagged with the <code>beta</code> channel in that same feed.",
};

export const compat = {
  h1: "App compatibility",
  lede: "This list is generated from the verification data that ships with the app. Each row shows the status, a note and the date of the last check.",
  legendHeading: "What the statuses mean",
  staleNote: "Any entry not re-verified within 120 days automatically shows as \"Not yet verified\".",
  jumpLabel: "Jump to group",
  empty: "No verification data yet.",
  filterLabels: { category: "App group", status: "Status", all: "All", shown: "Showing {n} apps" },
  cols: { app: "App", status: "Status", notes: "Notes", verified: "Last verified", macos: "macOS" },
  staleDetail: "The last result ({{date}}) is older than 120 days.",
  neverVerified: "Never verified",
  issuesLabel: "Related issues:",
  reportHeading: "Report an app",
  reportBody: "Is your app missing, or does the result not match what you see? Send a compatibility report. A maintainer confirms it before the status changes to \"Works\".",
  reportLink: "Send a compatibility report",
  reportEmail: "No GitHub account? Email {{email}}.",
};

export const changelog = {
  h1: "Changelog",
  lede: "The changes you can see in each release, grouped by app.",
  donateLine: "{{AppName}} is free. If you find it useful, you can <a href=\"{{hrefDonate}}\">chip in so Kal has more time to keep building it</a>.",
};

export const donate = {
  h1: "Donate to {{AppName}}",
  thanks: "{{AppName}} is free and always will be. If you find it useful, you can chip in so Kal has more time to keep building it.",
  promise: "Donating is a tip jar, nothing more. No feature is locked, and the app never shows a donation prompt.",
  // Pa's decision S8: a bank VietQR code only; the bank name and the account number are shown, never the holder's name.
  vietqr: { h: "VietQR (Napas)", alt: "VietQR code for a donation transfer to LioBank account 688688678", bankLabel: "Bank", bankValue: "LioBank", accountLabel: "Account number", accountValue: "688688678", how: "Open your banking app and choose scan QR. It shows the recipient's name so you can check it before you confirm." },
  sponsors: { h: "GitHub Sponsors", body: "If you use GitHub, you can sponsor monthly or once.", link: "Open GitHub Sponsors" },
  privacy: "The app stores no donor information. The money goes straight from your account to the receiving account, with no one in between.",
};

export const privacy = {
  h1: "Privacy",
  lede: "The principle: what you type never leaves your Mac and is never written to disk, except in one case you start yourself (a typing trace for a bug report, described below). The only automatic network traffic is the update check.",
  updated: "Last updated: 13 Nov 2026. This page is kept with the source code; any new network connection must be added here before it ships.",
  // The "This website" analytics line: `off` when site/config.json has no PostHog key, `posthog` when it has one.
  analytics: {
    off: "<strong>Visitor analytics: none.</strong> No Google Analytics, no third-party measurement, no tracking pixels.",
    posthog: "<strong>Visitor analytics: PostHog Cloud in cookieless mode.</strong> The pages of this website (not the app, not the release-notes pages) load PostHog's measurement library from <code>{{analyticsAssets}}</code> and send page views to <code>{{analyticsHost}}</code>. No cookies, nothing stored in your browser, no session recording, no click tracking, no user profiles. To count visitors without identifying you, PostHog computes a hash of your IP address and browser with a value that changes every day; the IP address is not stored. No advertising and no other third party.",
  },
  html: `
<h2 id="summary">Summary</h2>
<ul>
  <li>No telemetry, no analytics service, no crash-reporting SDK, no remotely loaded configuration or rules.</li>
  <li>No web view that loads remote content. Release notes are shown without loading external resources.</li>
  <li>Password fields and the macOS secure input mode are always skipped. This is not a setting.</li>
  <li>One permission is needed: Accessibility (macOS 15 and 26) or Device Control and Data Access (macOS 27). If macOS asks for more, the app says why. There is no Screen Recording, Automation or Full Disk Access.</li>
  <li>When permission is missing, your keyboard keeps typing normally (the app lets keys through and holds nothing back).</li>
</ul>

<h2 id="stored">What the app stores on your Mac</h2>
<div class="table-wrap"><table>
<thead><tr><th scope="col">Data</th><th scope="col">Location</th><th scope="col">Notes</th></tr></thead>
<tbody>
<tr><th scope="row">Settings, per-app rules, per-app Vietnamese/English memory, macros</th><td><code>~/Library/Application Support/{{AppName}}/</code></td><td>Only the choices you made yourself. The folder is readable only by you. Macros are text you wrote and may contain private text.</td></tr>
<tr><th scope="row">Settings backups</th><td><code>~/Library/Application Support/{{AppName}}/backups/</code></td><td>The newest 5 are kept so a damaged file can be recovered.</td></tr>
<tr><th scope="row">App health log</th><td><code>~/Library/Logs/{{AppName}}/</code></td><td>Content-free events only (key class, result codes, timings). At most 5 files of 1 MB, kept 14 days.</td></tr>
<tr><th scope="row">Typing trace (only when you press start)</th><td><code>~/Library/Logs/{{AppName}}/captures/</code></td><td>See the section below. Deleted after 24 hours and excluded from Time Machine backups.</td></tr>
<tr><th scope="row">Update state (Sparkle)</th><td><code>~/Library/Preferences/{{bundleId}}.plist</code> and <code>~/Library/Caches/{{bundleId}}/</code></td><td>Managed by the system by default.</td></tr>
</tbody></table></div>
<p>Files are written atomically (write a temporary file, then rename) so an update or power loss does not corrupt your settings. The full list of paths to delete is in "Delete your data" below.</p>

<h2 id="sent">What the app sends</h2>
<p>One thing only: the <strong>update check</strong>, every 24 hours (you can turn it off in Settings).</p>
<ul>
  <li>The app fetches <code>https://{{host}}/appcast.xml</code> over HTTPS, then downloads the update from the same server when you agree or when automatic updates are on. {{verifyHtml}} If update archives are also hosted on GitHub Releases, this page will say so.</li>
  <li>As with any web request, the server sees your IP address and the app name and version. The app does not send a system profile (that Sparkle feature is disabled).</li>
  <li>An update must carry a valid EdDSA signature or the app refuses to install it.</li>
  <li>There is no other network request. The release pipeline includes an automated check that the shipped binary contains only the declared server addresses.</li>
</ul>

<h2 id="diagnostics">What diagnostics contain and do not contain</h2>
<p>When you press <em>Report a problem...</em>, the app builds a text report and shows you <strong>exactly what would be sent</strong> before you copy or save it. A report is never sent automatically.</p>
<h3>In the report</h3>
<ul>
  <li>App version, build and update channel.</li>
  <li>macOS version, hardware class (Apple silicon or Intel), keyboard layout, enabled input sources (IDs only).</li>
  <li>Permission states, Secure Input state and the app that is likely holding it.</li>
  <li>The app you were typing in (identifier and version) and the compatibility rule that applied.</li>
  <li>Non-content settings (typing method, toggles), timing statistics, the last 50 health events, other input apps that are running.</li>
  <li>Recent key classes (letter, digit, backspace, modifier), never the key value.</li>
</ul>
<h3>Never in the report</h3>
<ul>
  <li>What you typed, words, field values, clipboard contents.</li>
  <li>Window titles, web addresses, file paths in your home folder (other than {{AppName}}'s own folders).</li>
  <li>Macro contents (only the count).</li>
  <li>Your per-app memory list, except the entry for the app you are reporting.</li>
</ul>

<h2 id="trace">Typing trace (optional, started by you)</h2>
<p>This is the only case where what you type touches the disk, and you can see it happening. It helps reproduce hard bugs that a report alone cannot explain.</p>
<ul>
  <li>It starts only when you press the button in the Diagnostics window and confirm.</li>
  <li>Default 60 seconds, at most 180 seconds, then it stops by itself. A different menu bar icon and a countdown panel with a Stop button stay visible the whole time.</li>
  <li>Nothing is recorded while macOS secure input is on or a password field is focused.</li>
  <li>Stored locally, excluded from backups, deleted after 24 hours or as soon as you export or discard it. You can read a human-friendly version before sharing. It is never uploaded automatically.</li>
</ul>

<h2 id="clipboard">Clipboard</h2>
<p>The app writes to your clipboard only when you press <em>Open GitHub</em> in the report sheet (so you can paste the report into GitHub), and the sheet says so before it does. The only other case is the "paste" compatibility mode that you turn on yourself for one specific app; it saves and restores the clipboard around each paste and is explained when you enable it.</p>

<h2 id="website">This website</h2>
<ul>
  <li>{{analyticsHtml}}</li>
  <li>No cookies and no tracking storage. Fonts are the ones already on your device; code, images, updates and the installer (DMG) are all served from this site's own server.</li>
  <li>The web server logs each request with only the time, method, path (without the query part), result code and size; it does not log IP addresses, browsers or referring pages. From this log we count, each day, the requests to <code>appcast.xml</code> to estimate how many Macs run the app, and the downloads of each file; only the daily totals are kept.</li>
  <li>Connections pass through Cloudflare and the server's router before they reach the web server; like on any website, these layers see your IP address while they handle the request. {{verifyHtml}} Check how long these two layers keep their logs before publishing.</li>
  <li>Homebrew install counts come from Homebrew's public counter.</li>
</ul>

<h2 id="feedback">Bug reports and support</h2>
<p>When you open a GitHub issue or send an email, what you write is your choice and is covered by the policy of GitHub or your email provider. {{AppName}} never sends what you typed on its own.</p>

<h2 id="donations">Donations</h2>
<p>The app does not store or send donor information. The money moves between you and your bank or GitHub, under their own policies.</p>

<h2 id="delete">Delete your data</h2>
<p>Quit {{AppName}}, drag the app to the Trash, then delete the folders listed in the table above. If you installed with Homebrew, one command does it all:</p>
<pre><code>brew uninstall --cask --zap {{slug}}</code></pre>
`,
};
