# 0501. Diagnostics block format v1

- Status: accepted, 2026-11-13
- Requirements: QA-R43, QA-R44, PRD-R45, PRD-R47, PLT-R1202, PLT-R1203

## Context

The in-app report (`Báo lỗi...`, PRD-R47) copies a diagnostics block that the user pastes into the GitHub
issue form. QA-R44 requires the block to be stable and machine-parseable, with a header line that carries
the format version, so a workflow can label issues automatically. The platform track writes the block, the
docs track writes the issue forms, this track parses it (`scripts/parse-diagnostics.py`,
`.github/workflows/diagnostics-labels.yml`). This record is the contract between them.

## Format

````text
```text
{{app-slug}}-diagnostics v1
report.bundleId: com.google.Chrome
report.appVersion: 156.0.8078.80
report.symptom: duplicated
app.version: 0.1.0
app.build: 10001
app.channel: beta
macos.version: 27.1
macos.build: 26B12
hw.arch: arm64
hw.model: Mac15,3
ui.locale: vi_VN
input.method: telex
input.layout: com.apple.keylayout.ABC
input.sourceType: keyboardLayout
permission.accessibility: granted
permission.inputMonitoring: unknown
tap.state: enabled
tap.timeouts24h: 0
tap.lastReenableReason: none
secureInput.active: false
secureInput.holderBundleId:
focus.bundleId: com.google.Chrome
focus.appVersion: 156.0.8078.80
focus.engine: chromium
focus.role: AXTextField
focus.subrole:
focus.identifier:
focus.domClasses:
focus.editable: true
focus.secure: false
rule.id: browser.chromium.addressBar
rule.specificity: 10
rule.strategy: backspaceReplace
rule.params: {"inlineCompletion":"axSelectionThenPlaceholder"}
rule.source: shipped
settings.toneStyle: traditional
settings.autoRestore: true
latency.t1.p99Us: 41
latency.t2.p99Us: 1300
conflicts: none
health.event.01: 2026-11-13T09:12:00Z tapTimeout
```
````

Rules (normative for v1):

1. The block is a fenced code block (three or more backticks or tildes). Its first non-empty line is the
   header `<slug>-diagnostics v<N>`, where `<slug>` is `APP_SLUG` of the build that produced it (read from
   the bundle, never hard-coded) and `<N>` is the format version, here `1`. Parsers accept any slug of the
   shape `[a-z][a-z0-9-]*`, so reports from builds made before a rename still parse.
2. Every following line until the closing fence is `key: value`. Keys match
   `[a-z][A-Za-z0-9]*(\.[A-Za-z0-9]+)*`. Values are a single line, may be empty, and contain no backticks or
   tildes at the start of the line. Blank lines and lines starting with `#` are ignored. The first
   occurrence of a key wins.
3. Content rules from PRD-R45 and PLT-R1203 apply: no typed text, field values, window titles, URLs,
   clipboard data, macro bodies or home-folder paths. Bundle IDs, layout IDs, roles and rule IDs are
   metadata and allowed.
4. Within v1, keys may be added (parsers ignore unknown keys). Removing a key or changing the meaning or
   value set of a key requires `v2` and an update of this record and of the parser.
5. At most 200 lines; the in-app report keeps a fuller JSON form for attachments (PLT-R1202).

Keys the labeler reads (QA-R44):

| Label | Key | Accepted values |
|---|---|---|
| `app:<bundle ID>` | `report.bundleId`, else `focus.bundleId` | reverse-DNS, label at most 50 characters |
| `macos:<major>` | `macos.version` | `<major>[.<minor>[.<patch>]]`, extra text after the number ignored |
| `arch:arm64` / `arch:x86_64` | `hw.arch` | `arm64`, `x86_64` |
| `method:telex` / `method:vni` | `input.method` | `telex`, `vni` (case-insensitive) |

Value sets for the other keys follow PLT-R1202; `report.symptom` uses `missing`, `duplicated`,
`wrongTone`, `cannotType`, `lag`, `other` (the chips of PRD-R47).

## Issue forms

The bug and compatibility forms (QA-R43) declare the diagnostics field as a `textarea` with
`render: text`, so GitHub wraps the pasted text in a fenced block even when the user pastes only the inner
lines. The parser also finds the header inside such a block.

## Consequences

- The labeler only adds labels and never removes them; maintainers can correct labels by hand.
- A label that does not exist yet is created with a neutral color before it is added.
