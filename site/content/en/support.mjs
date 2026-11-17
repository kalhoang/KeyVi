// SPDX-License-Identifier: GPL-3.0-or-later
// English support copy (mirrors content/vi/support.mjs). Migration steps describe only what a user sees in
// the other app's own window; every such step is marked VERIFY until checked on a real install (CLR-R5).
// {{AppNameTM}} as in content/en/pages.mjs: the first prose mention of a block, never headings, FAQ questions,
// on-screen steps (open, quit, its menu, a list or folder), paths or identifiers.
export const support = {
  h1: "Support",
  lede: "Look for a quick answer below. If that does not help, report a bug as described at the end of the page.",
  tocLabel: "On this page",
  toc: [["faq", "FAQ"], ["troubleshooting", "Troubleshooting by symptom"], ["report", "How to report a bug"], ["response-targets", "Response targets"], ["migrate", "Moving from another input method"]],
  faqHeading: "FAQ",
  faq: [
    ["Why is there no \"type tone marks anywhere in the word\" option?", "Because it is always on and not a setting. You can type the tone key after the final consonant (<code>vieetj</code>, <code>tieengs</code>), in the middle of the word, or the second <code>d</code> at the end (<code>dangd</code>) and the result is correct."],
    ["An English word still gets marks, or a Vietnamese word stays unchanged. What now?", "Open Settings, Typing. Under English restore there are two lists: \"keep as typed\" and \"keep as Vietnamese\". Add the word to the matching list and you are done. You can also report the word so it can be considered for the bundled data."],
    ["Why are there no quick consonant shortcuts (cc to ch, kk to kh)?", "Because they break ordinary words (<code>cc</code> becomes <code>ch</code>, <code>kkk</code> becomes <code>khk</code>). {{AppNameTM}} leaves them out on purpose, even as an option."],
    ["Is the tone placed as <em>hòa</em> or <em>hoà</em>?", "The default is the traditional style (<em>hòa</em>, <em>thủy</em>, <em>khỏe</em>). The modern style (<em>hoà</em>, <em>thuỷ</em>, <em>khoẻ</em>) is one toggle away in Settings, Typing."],
    ["Are TCVN3, VNI-Windows or CP1258 supported?", "No. {{AppNameTM}} outputs precomposed Unicode (NFC) only, which every current app reads."],
    ["What is the Vietnamese/English toggle key, and can I change it?", "By default you tap and release <kbd>Control</kbd> + <kbd>Shift</kbd>. Change it in Settings, General. If you pick a combination macOS already uses (for example Command+Space), the app accepts it but warns you which macOS feature owns it. See <a href=\"#macos-shortcuts\">how to turn off that macOS shortcut</a>."],
    ["Escape restores the word I just typed. In which apps is it off?", "Press <kbd>Escape</kbd> right after a word and {{AppNameTM}} puts back exactly the keys you typed; press it again and Escape works as usual, so it still closes dialogs. {{AppName}} turns this off on its own where Escape has a job of its own: terminals (Terminal, iTerm2 and others) and the terminal inside code editors; Visual Studio Code and the editors built on it (VSCodium, Cursor and others); JetBrains IDEs and Android Studio; Xcode, Nova, BBEdit, Sublime Text, Zed, Emacs and MacVim; remote desktop and virtual machine apps, including Chrome Remote Desktop in the browser; games; Spotlight, Raycast and Alfred. To turn the key off everywhere or choose another key, open Settings, Typing."],
    ["Why does {{AppName}} pause when I pick a Japanese, Chinese or Korean keyboard?", "When you select an input source that does not use Latin letters (Japanese, Chinese, Korean and similar), {{AppNameTM}} pauses on its own and dims its menu bar icon, so your keys go straight to that input method: typing <code>kore</code> in a Japanese input method does not turn into <code>kỏe</code>. Select the ABC or U.S. keyboard again and {{AppName}} types Vietnamese again. This is deliberate and not a setting."],
    ["Does {{AppName}} work in password fields?", "Password fields are always skipped and keys go straight to the app. This is deliberate and not a setting."],
    ["What about QWERTZ, AZERTY, Dvorak or Colemak keyboards?", "They work. {{AppNameTM}} follows the keyboard layout macOS is using, with nothing to configure."],
    ["Does the app send what I type anywhere?", "No. See the <a href=\"{{hrefPrivacy}}\">Privacy</a> page for exactly what the app stores and sends."],
    ["My Mac runs macOS 11 or older.", "{{AppNameTM}} requires macOS 12 Monterey or later, on Apple silicon or Intel. See the <a href=\"{{hrefDownload}}\">Download</a> page for the current figure."],
    ["How do I uninstall?", "Quit {{AppName}} and drag the app to the Trash. To remove the data as well, see the last section of the <a href=\"{{hrefPrivacy}}#delete\">Privacy</a> page."],
  ],
  fixHeading: "Troubleshooting by symptom",
  fix: {
    permission: {
      id: "permission",
      h: "Permission is on but I still cannot type",
      html: `
<p>{{AppNameTM}} needs permission to receive your keystrokes. The pane name depends on your macOS version:</p>
<ul>
  <li>macOS 12: System Preferences &gt; Security &amp; Privacy &gt; Privacy &gt; <strong>Accessibility</strong> (click the lock to make changes).</li>
  <li>macOS 13 to 26: System Settings &gt; Privacy &amp; Security &gt; <strong>Accessibility</strong>.</li>
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
<p>When an app turns on macOS <em>Secure Event Input</em>, the system stops delivering keystrokes to every background input tool, not only {{AppNameTM}}. It is usually caused by a password field that is still open. {{AppName}} pauses only when macOS reports this mode or when the focused field really is a password field. It does not guess, and it resumes on the very first key after the mode ends.</p>
<p>The {{AppName}} menu names the app that is likely holding it (a best guess that is sometimes wrong):</p>
<ul>
  <li><strong>Terminal</strong>: turn off <em>Secure Keyboard Entry</em> in the Terminal menu.</li>
  <li><strong>iTerm2</strong>: iTerm2 has Secure Keyboard Entry turned on. Turn off <em>iTerm2 &gt; Secure Keyboard Entry</em>, or finish or cancel the password prompt it is waiting for.</li>
  <li><strong>Browsers</strong>: click outside the password field or switch tabs.</li>
  <li><strong>Password managers</strong> and other apps: close their password entry window.</li>
  <li>Unknown app, or the menu points at <code>loginwindow</code>: lock the screen and unlock it (<kbd>Control</kbd> + <kbd>Command</kbd> + <kbd>Q</kbd>), or log out and back in.</li>
</ul>`,
    },
    conflict: {
      id: "conflicts",
      h: "Letters are doubled or missing",
      html: `
<p>Two input methods running at once make letters double or disappear. Quit the other one and stop it from starting at login. {{AppNameTM}} warns you when it detects one, but never quits or changes other apps itself.</p>
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
  <li>Search for the app in <a href="{{repo}}/issues" rel="noopener">GitHub Issues</a>: someone may already have reported it, with a workaround.</li>
  <li>Try typing in {{AppName}}'s practice field (the <em>Test in the practice field</em> button in the report flow) to see whether the problem is specific to that app or happens everywhere.</li>
  <li>In the {{AppName}} menu, the <em>With app name</em> submenu can set <em>Always English</em> or <em>Ignore this app</em> if you need to keep working right now.</li>
  <li>Report it with <em>Report a problem with this app...</em>: the report is pre-filled with the app, its version and the active rule.</li>
</ol>`,
    },
    shortcuts: {
      id: "macos-shortcuts",
      h: "The toggle key clashes with a macOS shortcut",
      html: `
<p>If you pick a combination macOS already uses, {{AppNameTM}} still saves your choice and shows a warning that names the macOS feature using it. To keep the combination for {{AppName}} alone, turn that shortcut off or change it in macOS:</p>
<ol class="steps">
  <li>Open System Settings &gt; Keyboard and click <em>Keyboard Shortcuts...</em>. {{verifyHtml}} The item names on each macOS version.</li>
  <li>Choose the group in the left column (see the list below), then untick the shortcut to turn it off, or double-click its key combination to assign another one.</li>
</ol>
<ul>
  <li><kbd>Command</kbd> + <kbd>Space</kbd>: the <em>Spotlight</em> group, Show Spotlight search.</li>
  <li><kbd>Control</kbd> + <kbd>Space</kbd> and <kbd>Control</kbd> + <kbd>Option</kbd> + <kbd>Space</kbd>: the <em>Input Sources</em> group, select the previous input source and select the next source.</li>
  <li><kbd>Control</kbd> + <kbd>Command</kbd> + <kbd>Space</kbd>: opens the Emoji &amp; Symbols viewer. This shortcut lives in each app's Edit menu, not in the groups above; you can assign another combination to that menu item in the <em>App Shortcuts</em> group. {{verifyHtml}} The menu item and group names on each macOS version.</li>
  <li><kbd>Command</kbd> + <kbd>Tab</kbd> (switching apps), <kbd>Command</kbd> + <kbd>Q</kbd> (quitting apps) and <kbd>Command</kbd> + <kbd>W</kbd> (closing windows): macOS does not let you turn these off. Choose another combination for {{AppName}}.</li>
</ul>
<p>{{AppName}} does not read the macOS shortcut settings, so the warning in Settings stays after you have turned the shortcut off. You can ignore it then.</p>`,
    },
  },
  reportHeading: "How to report a bug",
  reportIntro: "The quickest way is from inside the app: the {{AppName}} menu &gt; <em>Report a problem...</em>.",
  reportSteps: [
    "Pick the app where the problem happened (your last app is preselected).",
    "Pick what happened: missing letters, doubled letters, wrong tone, cannot type Vietnamese, slow or laggy, other.",
    "Type again the example you typed and the result you expected. {{AppNameTM}} never sends what you typed on its own.",
    "Open <em>Preview what will be sent</em> to see the exact report. Then choose <em>Open GitHub</em> (the report is copied to your clipboard for you to paste), <em>Send by email</em>, or <em>Save file...</em>.",
  ],
  reportNoGithub: "You do not need a GitHub account: the email path always works.",
  reportNever: "{{AppNameTM}} will never ask you for verbose logs or for what you typed. Only when really needed will a maintainer invite you to record a short typing trace (60 seconds), which you review yourself before sharing.",
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
  migrateLede: "Guides for moving your macro list from the input method you use now. Today {{AppNameTM}} imports macros from a text file (tab-separated or CSV), from a macOS Text Replacements file and from its own export; it does not read other input methods' export files yet. {{AppName}} imports only a file you choose yourself, and only after you press import. The app never reads another app's data on its own.",
};

export const migrate = {
  title: "Moving from {{Other}} to {{AppName}}",
  // [name in the card list, what moves, name inside a sentence ({{Other}}) when it is not a proper name]
  indexNames: {
    xkey: ["XKey", "Macros, through the plain text template"],
    openkey: ["OpenKey", "Macros, through the plain text template"],
    evkey: ["EVKey", "Macros, through the plain text template"],
    gonhanh: ["Gõ Nhanh", "Macros, through the plain text template"],
    phtv: ["PHTV", "Macros, through the plain text template"],
    macos: ["Built-in macOS Vietnamese", "Text Replacements", "the built-in macOS Vietnamese input"],
    plaintext: ["Plain text or CSV file", "Macros, the common format for any source", "a plain text or CSV file"],
  },
  back: "Back to Support",
  stepsHeading: "Get your macros out of {{Other}}",
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
      intro: "{{AppNameTM}} cannot read {{Other}}'s export files yet. For now, bring your macros over with the <a href=\"{{hrefMigratePlaintext}}\">plain text template</a>, then choose your typing method, tone style and the apps to ignore again in {{AppName}}. Importing {{Other}}'s export files directly (macros and those settings) is planned, once the file format has been checked against a real export.",
      steps: [
        "Open {{Other}}'s settings from its menu bar icon and find the macro list. {{verifyHtml}} The section name.",
        "If {{Other}} can export the macro list, save the file to the Desktop and open it in TextEdit to copy its contents. {{verifyHtml}} Whether there is an export button, and the file format.",
        "Copy each row (shortcut, expansion) into a text file using the <a href=\"{{hrefMigratePlaintext}}\">plain text template</a>, saved as UTF-8.",
        "Note the typing method, tone style and excluded apps you use in {{Other}}. Choose the typing method and tone style again in {{AppName}}'s Settings, Typing; for each app to exclude, use <em>Ignore this app</em> in the {{AppName}} menu.",
      ],
    },
    openkey: {
      intro: "{{AppNameTM}} cannot read {{Other}}'s export files yet. For now, bring your macros over with the <a href=\"{{hrefMigratePlaintext}}\">plain text template</a>. Importing {{Other}}'s export files directly is planned, once the file format has been checked against a real export.",
      steps: [
        "Open the macro list in {{Other}}'s settings. {{verifyHtml}}",
        "If there is an export button, save the file to the Desktop and open it in TextEdit to copy its contents. {{verifyHtml}} The button name and file format.",
        "Copy each row (shortcut, expansion) into a text file using the <a href=\"{{hrefMigratePlaintext}}\">plain text template</a>, saved as UTF-8.",
      ],
    },
    evkey: {
      intro: "{{Other}} (the legacy Mac build or a rewrite) may keep macros only inside the app, and {{AppNameTM}} cannot read {{Other}}'s export files yet. Bring your macros over with the <a href=\"{{hrefMigratePlaintext}}\">plain text template</a>.",
      steps: [
        "Open the macro list in {{Other}}'s settings. {{verifyHtml}}",
        "If there is an export button, save the file to the Desktop and open it in TextEdit to copy its contents. {{verifyHtml}} Whether your build has an export button.",
        "Copy each row (shortcut, expansion) into a text file using the <a href=\"{{hrefMigratePlaintext}}\">plain text template</a>, saved as UTF-8.",
      ],
    },
    gonhanh: {
      intro: "Whether {{Other}} can export data still needs to be checked, and {{AppNameTM}} cannot read {{Other}}'s export files yet. Bring your macros over with the <a href=\"{{hrefMigratePlaintext}}\">plain text template</a>, then set the mode for each app again from the {{AppName}} menu.",
      steps: [
        "Open {{Other}}'s settings and find the macro list, or an export or backup feature. {{verifyHtml}} Whether this feature exists.",
        "Copy each row (shortcut, expansion) into a text file using the <a href=\"{{hrefMigratePlaintext}}\">plain text template</a>, saved as UTF-8.",
      ],
    },
    phtv: {
      intro: "{{AppNameTM}} cannot read {{Other}}'s export files yet. For now, bring your macros over with the <a href=\"{{hrefMigratePlaintext}}\">plain text template</a>. Importing {{Other}}'s export files directly is planned, once the file format has been checked against a real export.",
      steps: [
        "Open the macro list in {{Other}}'s settings. {{verifyHtml}}",
        "If there is an export button, save the file to the Desktop and open it in TextEdit to copy its contents. {{verifyHtml}} The section, button and file format.",
        "Copy each row (shortcut, expansion) into a text file using the <a href=\"{{hrefMigratePlaintext}}\">plain text template</a>, saved as UTF-8.",
      ],
    },
    macos: {
      intro: "The built-in macOS Vietnamese input source has nothing to import. What you can bring along is your Text Replacements list. You can keep or remove the built-in Vietnamese source. While you use {{AppNameTM}}, choose the ABC or U.S. keyboard.",
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
      intro: "This is the general path that works for any source: a text file with one macro per line. {{AppNameTM}} imports both formats below.",
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
<p>In Settings &gt; Support you can export all settings to one JSON file, UTF-8, named like <code>{{slug}}-settings-YYYYMMDD.json</code>. The <code>kind</code> field is always <code>settings-export</code>; <code>schemaVersion</code> (an integer) is the format version; <code>writtenBy</code> is the app version that wrote the file; <code>exportedAt</code> is the export time (ISO 8601, UTC). Then come <code>settings</code>, <code>appModes</code> (per-app modes), <code>ruleOverrides</code> (compatibility rules you set yourself) and <code>macros</code> (shortcut <code>trigger</code>, text <code>expansion</code>, case following <code>adaptCase</code>, on or off <code>enabled</code>). When exporting you can untick macros and per-app modes, because macros may contain private text; an unticked part is left out of the file. When you import a file written by a newer version, {{AppNameTM}} imports the fields it understands and lists the ones it skipped.</p>
<pre><code>{
  "kind": "settings-export",
  "schemaVersion": 1,
  "writtenBy": "0.1.0",
  "exportedAt": "2026-11-13T09:00:00Z",
  "settings": { },
  "appModes": { },
  "ruleOverrides": [ ],
  "macros": [
    { "id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301", "trigger": "vn", "expansion": "Việt Nam", "adaptCase": true, "enabled": true }
  ]
}</code></pre>`,
    },
  },
};
