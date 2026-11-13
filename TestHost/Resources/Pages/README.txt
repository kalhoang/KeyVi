SPDX-License-Identifier: LicenseRef-App-Pending
Local test pages (02-platform.md 13.2, QA-R10, QA-R21). Loaded by the TestHost WKWebView from the app bundle
and by real browsers on the self-hosted runner from file:// (scenario setup values use the {pages}
placeholder). They contain no http(s) references and no network resources; ScenarioFilesTests enforces it.

  fields.html                    input, textarea, contenteditable (the QA-R10 web fields)
  inline-autocomplete.html       browser-style inline autocomplete (4.3)
  edit-mode-transition.html      spreadsheet cell: keys lost while entering edit mode, column autocomplete
  contenteditable-composer.html  chat composer that re-renders on first input and sends on Return
  testhost.js                    mirroring (data-testhost-field) and the completion rules
  testhost.css                   shared style, system fonts only

Every element marked data-testhost-field posts its value to TestHost, which mirrors it into a native field
with that accessibility identifier, so AX readback works for web fields too.
