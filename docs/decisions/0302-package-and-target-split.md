# 0302. Package and target split

- Status: accepted, 2026-11-13
- Requirements: PLT-R102, PLT-R103, PLT-R104, QA-R1 (layer 4), QA-R2
- Context: PLT-R102 suggests targets (names are suggestions, responsibilities are normative) and dependency
  limits: SettingsStore and CompatRules depend on Foundation only, Injection on Diagnostics only, InputHost on
  the engine, rules, injection, diagnostics and settings snapshot types. Parallel workstreams need shared
  vocabulary (bundle keys, modes, strategies, hotkeys) without depending on each other's behaviour, and app
  logic must reach 80 % coverage without launching the app.

## Decision

`Packages/AppCore` (SwiftPM, macOS 15, Swift 6 language mode, `ExistentialAny` and `InternalImportsByDefault`):

| Target | Responsibility | Depends on |
|---|---|---|
| `AppModel` | Shared vocabulary: validated identifiers, enums whose raw values are JSON spellings, hotkey bindings, versions, `JSONValue`, host-state vocabulary, `FileSystem`/`WallClock` protocols and `LocalFileSystem` | Foundation |
| `RealtimeSupport` | Hot-path primitives: `SnapshotCell` + `ReaderEpoch`, `SPSCRing`, `WakeSignal`, `WorkerSignal`, `MonotonicClock`/`MachClock`, `InlineUTF16`, `ThreadConfined`, `RunLoopThread` | Synchronization, Dispatch, Foundation |
| `Diagnostics` | Typed logger, redaction, health log, histograms, tap log ring, reports, capture, signposts | AppModel, RealtimeSupport |
| `SettingsStore` | Documents, migrations, store actor, export/import, macro importers, launch guard | AppModel |
| `CompatRules` | Rule schema, loader, matcher, fingerprinter, matrix, linter | AppModel |
| `Injection` | Job model, queue, worker, strategies, pasteboard preservation, system services | AppModel, RealtimeSupport, Diagnostics |
| `InputHost` | Snapshots, engine bridge, pipeline, tap thread, lifecycle, hotkeys, input source, secure input, focus, memory, permissions, workspace, probes | all of the above + VietnameseEngine, VietnameseEngineData |
| `ShellCore` | UI-free shell logic: brand, localisation lookup, pane-name table, status/menu models, onboarding flow, app location check, bug report, Apps pane model, login item, updater protocol | AppModel, Diagnostics, SettingsStore, CompatRules, InputHost |
| `TestSupport` | Fakes, simulated text field, pipeline harness, ledger, generator, scenarios | all non-UI targets |
| `CompatHarness` (exe `compat-harness`) | Scenario runner for the self-hosted runner | TestSupport |
| `CompatLint` (exe `compat-lint`) | Rules and matrix lint for CI | CompatRules |

The `App` target (XcodeGen) contains only AppKit/SwiftUI views, controllers, the composition root and the
Sparkle wrapper. The PLT-R102 `Updater` and `AppShell` targets live in `App/` so that AppCore has no
third-party dependency at all.

## Rationale for the additions to PLT-R102

- `AppModel` holds vocabulary only (no behaviour, no I/O beyond the file-system abstraction). SettingsStore
  and CompatRules depending on it keeps their "Foundation-level, no platform frameworks" intent while making
  `BundleKey`, `TypingMode`, `InjectionStrategy` and `HotkeyBinding` single definitions.
- `RealtimeSupport` concentrates every lock-free or thread-confinement trick in one small, separately tested
  and sanitizer-checked module, so the audit surface for PLT-R304/PLT-R305 is one directory.
- `ShellCore` makes the shell's logic (state to icon, menu model, onboarding transitions, report assembly,
  localisation lookup) testable with `swift test`, which QA-R2's 80 % app-logic coverage needs.
- Injection does not import CompatRules: InputHost converts a `ResolvedDecision` into an `InjectionPlan` once
  per focus change, so the worker never sees rule JSON and the tap does no conversion.

## Consequences

- Hosted CI runs `swift test` in `Packages/AppCore` without permissions; only `CompatHarness` and the
  TestHost suite need the self-hosted runner.
- The manifest is frozen for wave 1; adding a target is an integrator change.
