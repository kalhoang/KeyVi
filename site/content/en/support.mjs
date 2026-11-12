// SPDX-License-Identifier: LicenseRef-App-Pending
// English support copy (mirrors content/vi/support.mjs). Migration steps describe only what a user sees in
// the other app's own window; every such step is marked VERIFY until checked on a real install (CLR-R5).
export const support = {
  h1: "Support",
  lede: "Look for a quick answer below. If that does not help, report a bug as described at the end of the page.",
  tocLabel: "On this page",
  toc: [["faq", "FAQ"], ["troubleshooting", "Troubleshooting by symptom"], ["report", "How to report a bug"], ["response-targets", "Response targets"], ["migrate", "Moving from another input method"]],
  faqHeading: "FAQ",
  faq: [
    ["Why is there no \"type tone marks anywhere in the word\" option?", "Because it is always on and not a setting. You can type the tone key after the final consonant (<code>vietj</code>, <code>tieengs</code>), in the middle of the word, or the second <code>d</code> at the end (<code>dangd</code>) and the result is correct."],
    ["An English word still gets marks, or a Vietnamese word stays unchanged. What now?", "Open Settings, Typing. Under English restore there are two lists: \"keep as typed\" and \"keep as Vietnamese\". Add the word to the matching list and you are done. You can also report the word so it can be considered for the bundled data."],
    ["Why are there no quick consonant shortcuts (cc to ch, kk to kh)?", "Because they break ordinary words (<code>cc</code> becomes <code>ch</code>, <code>kkk</code> becomes <code>khk</code>). {{AppName}} leaves them out on purpose, even as an option."],
    ["Is the tone placed as <em>hòa</em> or <em>hoà</em>?", "The default is the traditional style (<em>hòa</em>, <em>thủy</em>, <em>khỏe</em>). The modern style (<em>hoà</em>, <em>thuỷ</em>, <em>khoẻ</em>) is one toggle away in Settings, Typing."],
    ["Are TCVN3, VNI-Windows or CP1258 supported?", "No. {{AppName}} outputs precomposed Unicode (NFC) only, which every current app reads."],
    ["What is the Vietnamese/English toggle key, and can I change it?", "By default you tap and release <kbd>Control</kbd> + <kbd>Shift</kbd>. Change it in Settings, General. If you pick a combination macOS already uses (for example Command+Space), the app accepts it but warns you which macOS feature owns it."],
    ["Does {{AppName}} work in password fields?", "Password fields are always skipped and keys go straight to the app. This is deliberate and not a setting."],
    ["What about QWERTZ, AZERTY, Dvorak or Colemak keyboards?", "They work. {{AppName}} follows the keyboard layout macOS is using, with nothing to configure."],
    ["Does the app send what I type anywhere?", "No. See the <a href=\"{{hrefPrivacy}}\">Privacy</a> page for exactly what the app stores and sends."],
    ["My Mac runs macOS 14 or older.", "{{AppName}} requires macOS 15 Sequoia or later. {{verifyHtml}} This minimum may change; see the <a href=\"{{hrefDownload}}\">Download</a> page for the current figure."],
    ["How do I uninstall?", "Quit {{AppName}} and drag the app to the Trash. To remove the data as well, see the last section of the <a href=\"{{hrefPrivacy}}#delete\">Privacy</a> page."],
  ],
  fixHeading: "Troubleshooting by symptom",
  fix: {
    permission: {
      id: "permission",
      h: "Permission is on but I still cannot type",
      html: `
<p>{{AppName}} needs permission to receive your keystrokes. The pane name depends on your macOS version:</p>
<ul>
  <li>macOS 15 and 26: System Settings &gt; Privacy &amp; Security &gt; <strong>Accessibility</strong>.</li>
  <li>macOS 27: System Settings &gt; Privacy &amp; Security &gt; <strong>Device Control and Data Access</strong> (previously Accessibility). {{verifyHtml}}</li>
</ul>
<ol class="steps">
  <li>Make sure {{AppName}} is in <code>/Applications</code> (or <code>~/Applications</code>), not running from the DMG.</li>
  <li>Turn on the switch for {{AppName}} in that pane. The app notices within a few seconds.</li>
  <li>If the switch is already on but nothing works (common after a macOS update): select {{AppName}} in the list, press the minus (-) button to remove it, then add it again. Or use the <em>Reset permission</em> button in the app, which resets only {{AppName}}'s own entry.</li>
  <li>To do it yourself in Terminal: <code>tccutil reset Accessibility {{bundleId}}</code>. Always include the bundle identifier. Never run <code>sudo tccutil reset Accessibility</code> without one, because that clears every app's permission. {{verifyHtml}} The service name may differ on macOS 27.</li>
</ol>
<p>While permission is missing your keyboard keeps typing normally; {{AppName}} just pauses and never blocks keys.</p>`,
    },
    secure: {
      id: "secure-input",
      h: "Typing is paused and the menu mentions secure input",
      html: `
<p>When an app turns on macOS <em>Secure Event Input</em>, the system stops delivering keystrokes to every background input tool, not only {{AppName}}. It is usually caused by a password field that is still open. {{AppName}} pauses only when macOS reports this mode or when the focused field really is a password field. It does not guess, and it resumes on the very first key after the mode ends.</p>
<p>The {{AppName}} menu names the app that is likely holding it (a best guess that is sometimes wrong):</p>
<ul>
  <li><strong>Terminal</strong>: turn off <em>Secure Keyboard Entry</em> in the Terminal menu.</li>
  <li><strong>iTerm2</strong>: besides the <em>Secure Keyboard Entry</em> menu item, iTerm2 turns the mode on by itself when it thinks a password prompt is showing. Turn off the menu item and look at iTerm2's password detection setting. {{verifyHtml}} The setting name and location in the current iTerm2, and whether the detection fires in command-line apps that turn off echo.</li>
  <li><strong>Browsers</strong>: click outside the password field or switch tabs.</li>
  <li><strong>Password managers</strong> and other apps: close their password entry window.</li>
  <li>Unknown app, or the menu points at <code>loginwindow</code>: lock the screen and unlock it (<kbd>Control</kbd> + <kbd>Command</kbd> + <kbd>Q</kbd>), or log out and back in.</li>
</ul>`,
    },
    conflict: {
      id: "conflicts",
      h: "Letters are doubled or missing",
      html: `
<p>Two input methods running at once make letters double or disappear. Quit the other one and stop it from starting at login. {{AppName}} warns you when it detects one, but never quits or changes other apps itself.</p>
<ol class="steps">
  <li>Quit the old input method (XKey, OpenKey, EVKey, Gõ Nhanh, PHTV or similar) from its menu bar icon.</li>
  <li>System Settings &gt; General &gt; Login Items &amp; Extensions: remove the old input method from the open-at-login list. {{verifyHtml}}</li>
  <li>If the built-in macOS <em>Vietnamese</em> input source is enabled, choose the ABC or U.S. keyboard while you use {{AppName}}.</li>
</ol>
<p>App-specific guides are in the <a href="#migrate">moving from another input method</a> section.</p>`,
    },
    app: {
      id: "app-specific",
      h: "It fails in one app only",
      html: `
<ol class="steps">
  <li>Look the app up in the <a href="{{hrefCompat}}">compatibility list</a>: it may already have a note or a workaround.</li>
  <li>Try typing in {{AppName}}'s practice field (the <em>Test in the practice field</em> button in the report flow) to see whether the problem is specific to that app or happens everywhere.</li>
  <li>In the {{AppName}} menu, the <em>With app name</em> submenu can set <em>Always English</em> or <em>Ignore this app</em> if you need to keep working right now.</li>
  <li>Report it with <em>Report a problem with this app...</em>: the report is pre-filled with the app, its version and the active rule.</li>
</ol>`,
    },
  },
  reportHeading: "How to report a bug",
  reportIntro: "The quickest way is from inside the app: the {{AppName}} menu &gt; <em>Report a problem...</em>.",
  reportSteps: [
    "Pick the app where the problem happened (your last app is preselected).",
    "Pick what happened: missing letters, doubled letters, wrong tone, cannot type Vietnamese, slow or laggy, other.",
    "Type again the example you typed and the result you expected. {{AppName}} never sends what you typed on its own.",
    "Open <em>Preview what will be sent</em> to see the exact report. Then choose <em>Open GitHub</em> (the report is copied to your clipboard for you to paste), <em>Send by email</em>, or <em>Save file...</em>.",
  ],
  reportNoGithub: "You do not need a GitHub account: the email path always works.",
  reportNever: "{{AppName}} will never ask you for verbose logs or for what you typed. Only when really needed will a maintainer invite you to record a short typing trace (60 seconds), which you review yourself before sharing.",
  channelsHeading: "Support channels",
  channels: [
    "<a href=\"{{repo}}/issues/new/choose\" rel=\"noopener\">GitHub Issues</a>: bugs and app compatibility.",
    "<a href=\"{{repo}}/discussions\" rel=\"noopener\">GitHub Discussions</a>: questions and ideas.",
    "Email <a href=\"mailto:{{email}}\">{{email}}</a> {{verifyHtml}} for anyone who does not use GitHub.",
  ],
  noDm: "Sorry, we do not offer support through private messages on social networks. Using the channels above lets everyone see the answer.",
  targetsHeading: "Response targets",
  targetsNote: "These are targets, counted in business days and best effort. This is a one-person personal project.",
  targetsCols: ["Priority", "First response", "Resolution target"],
  targets: [
    ["P0 (lost text, freeze, cannot type)", "24 hours", "Pull the update or give a workaround within 24 hours of confirmation; fix or rollback release within 72 hours"],
    ["P1", "3 days", "Next beta; next stable"],
    ["P2", "7 days", "Planned in a milestone, or labelled a known limitation with an explanation"],
    ["P3 and feature requests", "Reviewed monthly", "Answered with: accept, decline with a reason, or \"later\""],
  ],
  absence: "When Kal is away for more than a week, the website shows a notice with the expected return date.",
  migrateHeading: "Moving from another input method",
  migrateLede: "Guides for moving your macro list (and some settings) from the input method you use now. {{AppName}} imports only from a file you export yourself, and only after you press import. The app never reads another app's data on its own.",
};

export const migrate = {
  title: "Moving from {{Other}} to {{AppName}}",
  indexNames: {
    xkey: ["XKey", "Macros, typing method, tone style, excluded apps"],
    openkey: ["OpenKey", "Macros"],
    evkey: ["EVKey", "Macros"],
    gonhanh: ["Gõ Nhanh", "Macros, per-app settings if exportable"],
    phtv: ["PHTV", "Macros"],
    macos: ["Built-in macOS Vietnamese", "Text Replacements"],
    plaintext: ["Plain text or CSV file", "Macros, the common format for any source"],
  },
  back: "Back to Support",
  stepsHeading: "Export from {{Other}}",
  importHeading: "Import into {{AppName}}",
  importSteps: [
    "Open {{AppName}}, go to Settings &gt; Macros &gt; <em>Import from file...</em> (or choose <em>Choose file...</em> at the import step during setup).",
    "Read the preview: counts of new, duplicate and invalid rows. For duplicates, choose to keep yours or use the imported one.",
    "Invalid rows are skipped with a reason; one bad row never ruins the whole import.",
  ],
  quitHeading: "Quit {{Other}} and stop it from opening at login",
  quitIntro: "Two input methods at once make letters double or vanish. Quit {{Other}} and stop it from starting at login.",
  quitSteps: [
    "Click the {{Other}} icon in the menu bar and choose quit. {{verifyHtml}} The menu item name in the current version.",
    "Open System Settings &gt; General &gt; Login Items &amp; Extensions. In the <em>Open at Login</em> list, select {{Other}} and press the minus (-) button. {{verifyHtml}} The item names on each macOS version.",
    "If {{Other}} has its own start-at-login option in its settings, turn that off too. {{verifyHtml}}",
  ],
  screenshotHolder: "Screenshots will be added once each step has been checked on a real install",
  screenshotAlt: "Illustration (placeholder): the steps to export data from {{Other}}",
  verifyNote: "The steps above describe what you see in that app's own window and have not yet been checked against the latest version. If a label differs, follow the closest one and tell us so we can fix this page.",
  pages: {
    xkey: {
      intro: "{{Other}} stores a macro list and a few settings. {{AppName}} can import: macros, typing method, tone style, the toggle key when it can be expressed, and excluded apps (as <em>Ignore</em> rules). Keys it does not recognise are skipped and listed in the summary.",
      steps: [
        "Open {{Other}}'s settings from its menu bar icon. {{verifyHtml}}",
        "Find the macro section and its export button, and save the file to the Desktop. {{verifyHtml}} The section and button names.",
        "If there is a general settings export, export one more file. {{verifyHtml}} Whether it exists, and the file format observed from a real export.",
        "Cannot find an export button? Copy the macro list into a text file using the <a href=\"{{hrefMigratePlaintext}}\">plain text template</a>.",
      ],
    },
    openkey: {
      intro: "{{Other}} lets you export its macro list. {{AppName}} imports the macros.",
      steps: [
        "Open {{Other}}'s settings. {{verifyHtml}}",
        "Find the macro section and its export button, and save the file to the Desktop. {{verifyHtml}} The section, button and file format observed from a real export.",
        "If {{AppName}} cannot read the file, switch to the <a href=\"{{hrefMigratePlaintext}}\">plain text template</a>.",
      ],
    },
    evkey: {
      intro: "{{Other}} (the legacy Mac build or a rewrite) may keep macros only inside the app. If it cannot export a file, use the plain text path.",
      steps: [
        "Open the macro list in {{Other}}'s settings. {{verifyHtml}}",
        "If there is an export button, save the file to the Desktop. {{verifyHtml}} Whether your build has an export button.",
        "If there is no export button: copy each row (shortcut, expansion) into a text file using the <a href=\"{{hrefMigratePlaintext}}\">plain text template</a>.",
      ],
    },
    gonhanh: {
      intro: "Whether {{Other}} can export data still needs to be checked. If you have an export file, {{AppName}} imports macros and, where expressible, per-app settings.",
      steps: [
        "Open {{Other}}'s settings and look for an export or backup feature. {{verifyHtml}} Whether this feature exists.",
        "If it exists, save the file to the Desktop. If not, use the <a href=\"{{hrefMigratePlaintext}}\">plain text template</a>.",
      ],
    },
    phtv: {
      intro: "{{AppName}} imports the macros from a {{Other}} export file.",
      steps: [
        "Open {{Other}}'s settings. {{verifyHtml}}",
        "Find the macro section and its export button, and save to the Desktop. {{verifyHtml}} The section, button and file format.",
        "No export button? Use the <a href=\"{{hrefMigratePlaintext}}\">plain text template</a>.",
      ],
    },
    macos: {
      intro: "The built-in macOS Vietnamese input source has nothing to import. What you can bring along is your Text Replacements list. You can keep or remove the built-in Vietnamese source. While you use {{AppName}}, choose the ABC or U.S. keyboard.",
      steps: [
        "Open System Settings &gt; Keyboard &gt; <em>Text Replacements</em>. {{verifyHtml}} The item name on each macOS version.",
        "Select the rows to bring (<kbd>Command</kbd> + <kbd>A</kbd> selects all) and drag them to the Desktop. macOS creates a <code>.plist</code> file. {{verifyHtml}}",
        "Import that <code>.plist</code> file into {{AppName}} as described above.",
      ],
      quitSteps: [
        "Open System Settings &gt; Keyboard &gt; Input Sources (or Text Input). {{verifyHtml}} The item name on each macOS version.",
        "Click Edit, and add the <em>ABC</em> or <em>U.S.</em> keyboard if it is not there.",
        "Select the built-in <em>Vietnamese</em> source and press the minus (-) button to remove it if you no longer use it. Removing it is optional; keeping it is harmless as long as you choose ABC or U.S. when typing with {{AppName}}.",
      ],
    },
    plaintext: {
      intro: "This is the general path that works for any source: a text file with one macro per line. {{AppName}} imports both formats below.",
      noQuit: true,
      html: `
<h2 id="tsv-template">Tab-separated text</h2>
<p>Each line is the shortcut, one Tab character, then the full text. A shortcut is 1 to 32 printable ASCII characters with no spaces and no Vietnamese letters (shortcuts match the keys as typed: <code>dc</code>, not <code>đc</code>). The expansion can be up to 4,000 characters.</p>
<pre><code>vn&#9;Việt Nam
dc&#9;được
tphcm&#9;Thành phố Hồ Chí Minh</code></pre>
<h2 id="csv-template">Two-column CSV</h2>
<pre><code>vn,Việt Nam
dc,được
"cam on","Cảm ơn bạn rất nhiều, hẹn gặp lại"</code></pre>
<p>UTF-8 encoding. Wrap text that contains commas in double quotes.</p>
<h2 id="own-export">{{AppName}}'s own settings export</h2>
<p>In Settings &gt; About &amp; Support you can export all settings to one JSON file, UTF-8, named like <code>{{slug}}-settings-YYYYMMDD.json</code>. The file has a <code>schemaVersion</code> field (an integer). When you import a file written by a newer version, {{AppName}} imports the fields it understands and lists the ones it skipped. When exporting you can untick macros and per-app modes, because macros may contain private text.</p>
<pre><code>{
  "schemaVersion": 1,
  "writtenBy": "(app version)",
  "settings": { },
  "appRules": [ ],
  "appModes": [ ],
  "macros": [ { "shortcut": "vn", "expansion": "Việt Nam" } ]
}</code></pre>
<p>{{verifyHtml}} The exact field names will be updated to match the first release; the snippet only illustrates the structure.</p>`,
    },
  },
};
