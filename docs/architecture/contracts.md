# Platform contracts

Public Swift types, protocols and signatures of every platform module, with their threading and isolation,
the files and directories each one owns, and the platform-service protocols that make the whole layer testable
without permissions. Read [ARCHITECTURE.md](../../ARCHITECTURE.md) first for the big picture.

## 0. How to read this document

- **The code blocks are the compiled skeleton.** Each block is spliced verbatim from
  `Packages/AppCore/Sources/**`, `App/Sources/**`, `TestHost/Sources/**` or `SpikeIMK/**` by
  `python3 -I docs/architecture/tools/sync_contracts.py`, and those sources build with Swift 6.4.2 in Swift 6
  language mode with complete strict concurrency (`swift build` in `Packages/AppCore`; `xcodegen generate`
  then `xcodebuild` for `App`, `TestHost`, `SpikeIMK`). After this commit the sources are authoritative; CI
  can run the tool with `--check` to keep this file in sync.
- **`unimplemented()`** marks a body the owning workstream fills in. Changing a public signature is a
  contract change: update the source, rerun the tool, and tell every consumer (workstreams.md lists them).
- **Already implemented in the skeleton** (with tests): `RealtimeSupport` (snapshot cell, SPSC ring, signals,
  clock, `TimerScheduler`/`DispatchTimerScheduler`, `AtomicUInt64Array`, `InlineUTF16`, threads), `AppModel`
  (identifiers, vocabulary, hotkey JSON, versions, `JSONValue`, `LocalFileSystem`), the tap/worker seam in
  Injection (`JobQueue`, `EchoTracker`, `WorkerFeedback`, `EventMarker`, `CurrentFocusGeneration`), the
  hot-path diagnostics sinks (`Log2Histogram`, `AtomicCounter`, `PlatformMetrics`, `PerBundleHistograms`,
  `HealthEventLog`, `TapLogRing`), `CallbackWatchdog`, `Brand.from`, and the fakes listed in section 13.
  Wave-1 workstreams need these at the same time, so they are not left to one of them
  ([0313](../decisions/0313-testability-seams.md)); the owning workstream may optimise them and keeps their
  `*SeamTests.swift` green.
- **Isolation legend** used in the tables: `tap` / `inject` / `ax` = confined to that dedicated thread;
  `main` = `@MainActor`; `utility` = the utility serial queue (the `SettingsStore` actor's executor);
  `any` = `Sendable`, safe from every thread; `tap-safe` = may be called inside the tap callback
  (no locks, no allocation, no syscalls that block).
- Conventions: SPDX header `GPL-3.0-or-later` on every file outside the MPL-2.0 engine packages and `data/` (ADR 0006); requirement IDs in comments
  where they drive non-obvious behaviour; no bundle-ID literals in code (PLT-R501; reverse-DNS constants that
  are not bundle IDs go in a file named `ReverseDNSConstants.swift` and are allowed by a pattern in
  `scripts/lint-bundle-ids.allow` or an inline `lint:allow-bundle-id <reason>` marker); no string
  interpolation in log calls (PLT-R902).

## 1. Module dependencies and isolation summary

| Module | Depends on | Main isolation | Notes |
|---|---|---|---|
| AppModel | Foundation | any | Values only |
| RealtimeSupport | CRealtimeSupport (C11 atomic builtins), Dispatch, Foundation | any / tap-safe | The only place with `@unchecked Sendable` lock-free code; `Atomic`, `Mutex`, `TimeSpan` replace `Synchronization` and `Duration` (ADR 0315) |
| Diagnostics | AppModel, RealtimeSupport | any; `TapLogRing.push`, histogram `record`, `CaptureController.isRecording` are tap-safe | |
| SettingsStore | AppModel, RealtimeSupport | utility (actor on `QueueExecutor`) | |
| CompatRules | AppModel | any (pure values); resolution called on ax | |
| Injection | AppModel, RealtimeSupport, Diagnostics | inject (worker), tap-safe producer API on `JobQueue` | Never imports CompatRules |
| InputHost | all of the above, VietnameseEngine(Data) | tap (pipeline), ax (focus), main (controller, input sources), utility (monitors) | |
| ShellCore | AppModel, Diagnostics, SettingsStore, CompatRules, InputHost | any values, main (`InterfaceLanguageModel`, `UpdaterControlling`) | No AppKit/SwiftUI |
| App | all, Sparkle | main | Views, controllers, composition root |
| TestSupport | all non-UI | tests | Never linked into the app |

## 2. Ownership of files and directories at runtime

| Path | Owner (only writer) | Contents | Permissions |
|---|---|---|---|
| `~/Library/Application Support/<folder>/settings.json`, `app-modes.json`, `rule-overrides.json`, `macros.json` | `SettingsStore` | Section 7 | dir 0700, files 0600 |
| `…/Application Support/<folder>/backups/` | `SettingsStore` | `<file>.v<N>.<timestamp>.json`, newest 5 per file | 0700 / 0600 |
| `~/Library/Logs/<folder>/*.jsonl` | `DiagnosticsLogger` | JSON lines, 5 x 1 MB, 14 days | 0700 / 0600 |
| `~/Library/Logs/<folder>/captures/` | `CaptureController` | Typing traces, 24 h | 0700 / 0600, excluded from backup |
| User defaults of the bundle ID | `LaunchGuard`, redaction salt, `PermissionMonitor` (last granted digest), window frames, Sparkle | Non-exported state | system |
| App bundle `Contents/Resources/compat-rules.json`, `compat-matrix.json`, `SystemPanes.json`, `*.lproj` | build | Read-only data | as installed |

`<folder>` is `Brand.storageFolderName` (display name if ASCII, else slug; frozen at the first public
release, [0307](../decisions/0307-settings-file-layout.md)).

## 3. Platform-service protocols

Every interaction with macOS goes through one of these protocols, so app logic, the pipeline and the worker
run in `swift test` with fakes (QA-R1 layer 4). Production implementations need permissions and are exercised
only on the self-hosted runner or by Pa.

| Protocol (module) | Production implementation and Apple APIs | Thread | Fake (TestSupport) |
|---|---|---|---|
| `EventTapFactory`, `EventTapHandle` (InputHost) | `CGEventTapFactory`: `CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: TapEventMask.standard.cgMask, callback:, userInfo:)`, wrapped in a handle: `install(on:)` = `CFMachPortCreateRunLoopSource` + `CFRunLoopAddSource`, `setEnabled` = `CGEvent.tapEnable(tap:enable:)`, `isEnabled` = `CGEvent.tapIsEnabled(tap:)`, `invalidate` = `CFRunLoopRemoveSource` + `CFMachPortInvalidate` | tap (create, install, run), any (enable) | `FakeEventTapFactory`, `FakeEventTapHandle` (pure Swift) |
| `EventPoster` (Injection) | `CGEventPoster`: `CGEventSource(stateID: .privateState)`, `localEventsSuppressionInterval = 0`, `CGEvent(keyboardEventSource:virtualKey:keyDown:)`, explicit `flags`, `keyboardSetUnicodeString` (`CGEventKeyboardSetUnicodeString`), `setIntegerValueField(.eventSourceUserData, …)` (`kCGEventSourceUserData`), `setIntegerValueField(.keyboardEventAutorepeat / .keyboardEventKeyboardType, …)`, `post(tap: .cgSessionEventTap)`. No per-post `CGPreflightPostEventAccess` (checked off-thread after an echo miss, ADR 0311) | inject | `FakeEventPoster` (`.delivering`, `.silentlyDropping`, `.failingCreation`) |
| `FocusedFieldAccess` (Injection) | `AXFocusedFieldAccess`: `AXUIElementSetMessagingTimeout`, `AXUIElementCopyAttributeValue(kAXSelectedTextRangeAttribute)`, `AXUIElementCopyParameterizedAttributeValue(kAXStringForRangeParameterizedAttribute)` (at most 64 units), `AXUIElementSetAttributeValue(kAXSelectedTextRangeAttribute / kAXSelectedTextAttribute)` | inject | `FakeFocusedFieldAccess` over `SimulatedTextField` |
| `PasteboardAccess` (Injection) | `NSPasteboardAccess`: `NSPasteboard.general` (tests: `NSPasteboard(name:)`), `pasteboardItems` snapshot of every type's `data(forType:)`, `changeCount`, `clearContents`, one item with `public.utf8-plain-text` + `org.nspasteboard.TransientType` / `ConcealedType` / `AutoGeneratedType` | inject (VERIFY thread safety, PLT-R462) | `FakePasteboard` |
| `AXProvider` (InputHost) | `SystemAXProvider`: `AXUIElementCreateSystemWide`, `AXUIElementCreateApplication`, `AXUIElementSetMessagingTimeout(…, 0.1)`, `kAXFocusedApplicationAttribute`, `kAXFocusedUIElementAttribute`, role/subrole/`kAXIdentifierAttribute`/`AXDOMClassList`/`kAXParentAttribute`/document URL/window title, `AXObserverCreate`, `AXObserverAddNotification` (`kAXFocusedUIElementChangedNotification`, `kAXFocusedWindowChangedNotification`, `kAXApplicationActivatedNotification`, `kAXTitleChangedNotification`), `AXObserverGetRunLoopSource`; `AXManualAccessibility` only on rule request; never `AXEnhancedUserInterface` | ax | `FakeAXProvider` |
| `ProcessIdentityProvider` (InputHost) | `NSRunningApplication(processIdentifier:)`, `proc_pidpath`, `proc_name`, `Bundle(url:)` (`CFBundleShortVersionString`, `CFBundleVersion`, `LSApplicationCategoryType`), SHA-256 of the executable path for bundle-less processes, `kill(pid, 0)` | ax, utility | `FakeProcessIdentityProvider` |
| `BundleInspector` (CompatRules) | FileManager listing of `Contents/Frameworks`, helper apps and bounded file search (fingerprinting, PLT-R510) | ax | `FakeBundleInspector` |
| `InputSourceProvider` (InputHost) | `TISCopyCurrentKeyboardInputSource`, `TISCopyCurrentKeyboardLayoutInputSource`, `TISGetInputSourceProperty` (`kTISPropertyInputSourceID`, `kTISPropertyInputSourceType`, `kTISPropertyInputSourceIsASCIICapable`, `kTISPropertyInputSourceLanguages`, `kTISPropertyLocalizedName`, `kTISPropertyUnicodeKeyLayoutData`), `TISCreateInputSourceList`, `LMGetKbdType`, `DistributedNotificationCenter` for `kTISNotifySelectedKeyboardInputSourceChanged` and `kTISNotifyEnabledKeyboardInputSourcesChanged`. Read-only | main | `FakeInputSourceProvider` |
| `LayoutTableBuilding` (InputHost) | `UCKeyTranslateLayoutBuilder`: `UCKeyTranslate(layout, keyCode, kUCKeyActionDown, modifierKeyState, keyboardType, 0, &deadKeyState, 4, &length, &chars)` for none, Shift, Caps Lock, Shift+Caps Lock; dead key = no output and non-zero dead-key state | main (any off the tap) | real builder over system layouts read by ID (read-only) |
| `SecureInputProbe` (InputHost) | `SystemSecureInputProbe`: `IsSecureEventInputEnabled()`; `IORegistryEntryCreateCFProperty(IORegistryGetRootEntry(kIOMainPortDefault), "IOConsoleUsers", …)` then `kCGSSessionSecureInputPID` of the console session entry | utility | `FakeSecureInputProbe` |
| `PermissionProbe` (InputHost) | `AXIsProcessTrusted`, `AXIsProcessTrustedWithOptions` (`kAXTrustedCheckOptionPrompt`), `CGPreflightPostEventAccess`, `CGPreflightListenEventAccess`, `CGRequestPostEventAccess`, `CGRequestListenEventAccess`; `SecCodeCopySelf` + `SecCodeCopyDesignatedRequirement` for the identity digest | utility, main | `FakePermissionProbe` |
| `PermissionResetting` (InputHost) | `/usr/bin/tccutil reset Accessibility <own bundle ID>` via `Process`, user-initiated only (PLT-R740) | main | test double |
| `WorkspaceEvents` (InputHost) | `NSWorkspace.shared.notificationCenter`: `didActivateApplicationNotification`, `willSleepNotification`, `didWakeNotification`, `sessionDidResignActiveNotification`, `sessionDidBecomeActiveNotification`; screen lock/unlock distributed notifications | main | `FakeWorkspaceEvents` |
| `MonotonicClock` (RealtimeSupport) | `MachClock`: `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)`, `mach_wait_until` with `mach_timebase_info` | any (`sleep` on inject only) | `ManualClock` |
| `TimerScheduler` (RealtimeSupport) | `DispatchTimerScheduler`: `DispatchSource.makeTimerSource(queue:)` on the utility queue, `schedule(deadline:repeating:leeway:)` | utility | `ManualScheduler` (virtual time over `ManualClock`) |
| `WallClock` (AppModel) | `SystemWallClock` (`Date()`) | any | `FixedWallClock` |
| `FileSystem` (AppModel) | `LocalFileSystem`: FileManager + POSIX `open(O_EXCL)`, `write`, `fsync`, `rename`, `chmod`; `URLResourceValues.isExcludedFromBackup` | utility | `InMemoryFileSystem` |
| `KeyValueStore` (SettingsStore) | `UserDefaults` of the bundle ID | utility | `InMemoryKeyValueStore` |
| `LoginItemService` (ShellCore) | `SMAppServiceLoginItem`: `SMAppService.mainApp.status`, `register()`, `unregister()`, `SMAppService.openSystemSettingsLoginItems()` | main | test double |
| `UpdaterControlling` (ShellCore) | `UpdaterController` (App) over `SPUUpdater` with an `SPUStandardUserDriver` subclass (ADR 0304) | main | test double |
| `KeyboardDriver`, `ScenarioReadback` (TestSupport) | `compat-harness`: its own `CGEventSource` posting physical-like events with timing profiles; readback through AX, `safaridriver`/`chromedriver`, terminal capture or a human prompt | self-hosted runner | n/a |

## 4. AppModel: shared vocabulary

Owned files: `Packages/AppCore/Sources/AppModel/**` (frozen in wave 1; changes through the integrator).
Isolation: any. Raw values of the enums are JSON spellings in settings and rules files, so renaming one needs a
migration.

<!-- include: Packages/AppCore/Sources/AppModel/Identifiers.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Validated metadata identifiers. They are the only string-like values the typed logger accepts without
// redaction (PLT-R902): their character set and length make it impossible to carry typed content in them.

/// Bundle identifier of a focus owner, or the SHA-256 of the executable path for processes without a bundle
/// identifier (PLT-R393). Never constructed from a string literal in application code (PLT-R501).
public struct BundleKey: RawRepresentable, Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    /// Key for a process without a bundle identifier: `sha256:<64 lowercase hex>` (PLT-R393).
    public static func executable(sha256Hex: String) -> BundleKey? {
        let hex = sha256Hex.lowercased()
        guard hex.utf8.count == 64, hex.utf8.allSatisfy(Self.isHexDigit) else { return nil }
        return BundleKey(rawValue: "sha256:" + hex)
    }

    public var isExecutableHash: Bool { rawValue.hasPrefix("sha256:") }
    public var description: String { rawValue }
    public static func < (lhs: BundleKey, rhs: BundleKey) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let key = BundleKey(rawValue: raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "invalid bundle key"))
        }
        self = key
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func isValid(_ raw: String) -> Bool {
        if raw.hasPrefix("sha256:") {
            let hex = raw.utf8.dropFirst(7)
            return hex.count == 64 && hex.allSatisfy(isHexDigit)
        }
        guard (1...255).contains(raw.utf8.count) else { return false }
        return raw.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2E || byte == 0x2D || byte == 0x5F
        }
    }

    static func isHexDigit(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66)
    }
}

/// Stable dotted rule identifier (02-platform.md 5.4 `id`), for example `terminal.default` or `user.ignore.3`.
public struct RuleID: RawRepresentable, Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard (1...128).contains(rawValue.utf8.count) else { return nil }
        let segments = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        let valid = segments.allSatisfy { segment in
            !segment.isEmpty
                && segment.utf8.allSatisfy { byte in
                    (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
                        || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2D || byte == 0x5F
                }
        }
        guard valid else { return nil }
        self.rawValue = rawValue
    }

    public var isUserOverride: Bool { rawValue.hasPrefix("user.") }
    public var description: String { rawValue }
    public static func < (lhs: RuleID, rhs: RuleID) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let id = RuleID(rawValue: raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "invalid rule id"))
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Text Input Source identifier of a keyboard layout or input method (PLT-R362), for example the ABC layout.
public struct InputSourceID: RawRepresentable, Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard BundleKey.isValid(rawValue), !rawValue.hasPrefix("sha256:") else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// Virtual key code (`CGKeyCode`). Layout-independent position of a physical key.
public struct KeyCode: RawRepresentable, Sendable, Hashable, Codable, Comparable, BitwiseCopyable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static func < (lhs: KeyCode, rhs: KeyCode) -> Bool { lhs.rawValue < rhs.rawValue }

    // Layout-independent keys used by the platform (Carbon kVK_* values; positions, not characters).
    public static let returnKey = KeyCode(rawValue: 0x24)
    public static let tab = KeyCode(rawValue: 0x30)
    public static let space = KeyCode(rawValue: 0x31)
    public static let delete = KeyCode(rawValue: 0x33)  // backspace (PLT-R407)
    public static let escape = KeyCode(rawValue: 0x35)
    public static let rightCommand = KeyCode(rawValue: 0x36)
    public static let command = KeyCode(rawValue: 0x37)
    public static let shift = KeyCode(rawValue: 0x38)
    public static let capsLock = KeyCode(rawValue: 0x39)
    public static let option = KeyCode(rawValue: 0x3A)
    public static let control = KeyCode(rawValue: 0x3B)
    public static let rightShift = KeyCode(rawValue: 0x3C)
    public static let rightOption = KeyCode(rawValue: 0x3D)
    public static let rightControl = KeyCode(rawValue: 0x3E)
    public static let function = KeyCode(rawValue: 0x3F)
    public static let forwardDelete = KeyCode(rawValue: 0x75)
    public static let home = KeyCode(rawValue: 0x73)
    public static let end = KeyCode(rawValue: 0x77)
    public static let pageUp = KeyCode(rawValue: 0x74)
    public static let pageDown = KeyCode(rawValue: 0x79)
    public static let leftArrow = KeyCode(rawValue: 0x7B)
    public static let rightArrow = KeyCode(rawValue: 0x7C)
    public static let downArrow = KeyCode(rawValue: 0x7D)
    public static let upArrow = KeyCode(rawValue: 0x7E)
    public static let keypadEnter = KeyCode(rawValue: 0x4C)
}

/// Monotonic counter of focus contexts (PLT-R316, PLT-R383). Every job records the generation it was built for.
public struct FocusGeneration: RawRepresentable, Sendable, Hashable, Comparable, Codable, BitwiseCopyable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public static let initial = FocusGeneration(rawValue: 0)
    public var next: FocusGeneration { FocusGeneration(rawValue: rawValue &+ 1) }
    public static func < (lhs: FocusGeneration, rhs: FocusGeneration) -> Bool { lhs.rawValue < rhs.rawValue }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/AppModel/Vocabulary.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Shared enumerations. Raw values are the JSON spellings used in settings files and in compat/rules.json
// (02-platform.md 5.4), so they MUST NOT change without a schema migration (PLT-R1005).

/// VI/EN mode of the input host (03-product.md D11-D13).
public enum TypingMode: String, Sendable, Hashable, Codable, CaseIterable {
    case vietnamese = "vi"
    case english = "en"

    public var toggled: TypingMode { self == .vietnamese ? .english : .vietnamese }
}

/// D1.
public enum TypingMethod: String, Sendable, Hashable, Codable, CaseIterable { case telex, vni }

/// D2.
public enum TonePlacement: String, Sendable, Hashable, Codable, CaseIterable { case traditional, modern }

/// D18. Selected interface language, independent of the macOS language (PRD-R63).
public enum InterfaceLanguage: String, Sendable, Hashable, Codable, CaseIterable {
    case vietnamese = "vi"
    case english = "en"
}

/// D21.
public enum UpdateChannel: String, Sendable, Hashable, Codable, CaseIterable { case stable, beta }

/// D13 and the rule field `defaultMode` (02-platform.md 5.4).
public enum FirstSeenMode: String, Sendable, Hashable, Codable, CaseIterable {
    case inherit, vi, en
}

/// Explicit per-app rule chosen by the user (PRD-R21). Precedence: ignore > alwaysEnglish > alwaysVietnamese
/// > remembered > first-seen default.
public enum PerAppRule: String, Sendable, Hashable, Codable, CaseIterable {
    case remember, alwaysEnglish, alwaysVietnamese, ignore
}

/// Engine fingerprint of the focused app's UI technology (PLT-R510).
public enum EngineFingerprint: String, Sendable, Hashable, Codable, CaseIterable {
    case electron, chromium, cef, gecko, jvm, qt, catalyst, ios, webkitBrowser, native
}

/// Generic injection strategies (02-platform.md section 4). Shared by CompatRules (as data) and Injection
/// (as behaviour) so the two never drift.
public enum InjectionStrategy: String, Sendable, Hashable, Codable, CaseIterable {
    case backspaceReplace, selectReplace, axReplace, paste, passThrough
}

/// Inline-completion handling (PLT-R420-R422).
public enum InlineCompletionMode: String, Sendable, Hashable, Codable, CaseIterable {
    case none, axSelection, placeholder, axSelectionThenPlaceholder
}

/// Text-context gating (PLT-R386). `byEngine` is resolved to a concrete value before it reaches the tap.
public enum RequireTextFocus: String, Sendable, Hashable, Codable, CaseIterable {
    case never, whenKnown, always, byEngine
}

/// Re-entry verification (PLT-R342).
public enum VerifyReentry: String, Sendable, Hashable, Codable, CaseIterable { case never, whenReadable }

/// `action.engineContext` (ENG-R850).
public enum EngineContextKind: String, Sendable, Hashable, Codable, CaseIterable { case general, code }

/// `action.axEnable` (PLT-R385).
public enum AXEnableMode: String, Sendable, Hashable, Codable, CaseIterable { case none, manual }

/// Availability of Accessibility data for the focused app (PLT-R383).
public enum AXAvailability: String, Sendable, Hashable, Codable { case available, unavailable, timedOut }

/// Where a resolved decision came from (PLT-R383).
public enum DecisionSource: String, Sendable, Hashable, Codable { case shipped, user, `default` }

/// Permission states (PLT-R720).
public enum PermissionState: String, Sendable, Hashable, Codable { case granted, denied, unknown }

/// Permissions the app may need (PLT-R701, PLT-R702).
public enum PermissionKind: String, Sendable, Hashable, Codable, CaseIterable {
    case accessibility, postEvent, listenEvent
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/AppModel/Hotkeys.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Hotkey bindings (03-product.md PRD-R14 to PRD-R18). Stored in settings.json; recognised by InputHost.

/// Modifier keys, with side-specific bits for the right-side-only taps (PRD-R15).
public struct ModifierKeys: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let control = ModifierKeys(rawValue: 1 << 0)
    public static let option = ModifierKeys(rawValue: 1 << 1)
    public static let shift = ModifierKeys(rawValue: 1 << 2)
    public static let command = ModifierKeys(rawValue: 1 << 3)
    public static let function = ModifierKeys(rawValue: 1 << 4)
    /// Set together with `.command` when the right Command key is the one held.
    public static let rightCommand = ModifierKeys(rawValue: 1 << 5)
    /// Set together with `.option` when the right Option key is the one held.
    public static let rightOption = ModifierKeys(rawValue: 1 << 6)
}

/// Modifier-only taps the recorder accepts (PRD-R15).
public enum ModifierTapChord: String, Sendable, Hashable, Codable, CaseIterable {
    case controlShift, commandShift, optionShift, controlOption, rightCommand, rightOption

    /// The modifier set that must be held (and then fully released) for the tap to fire.
    public var modifiers: ModifierKeys {
        switch self {
        case .controlShift: [.control, .shift]
        case .commandShift: [.command, .shift]
        case .optionShift: [.option, .shift]
        case .controlOption: [.control, .option]
        case .rightCommand: [.command, .rightCommand]
        case .rightOption: [.option, .rightOption]
        }
    }
}

/// What a hotkey is for. Only two configurable global hotkeys exist in v1 (PRD-R18).
public enum HotkeyRole: String, Sendable, Hashable, Codable, CaseIterable { case toggleMode, restoreLastWord }

/// A recorded hotkey. JSON shape (settings.json, schema v1):
/// `{"type":"modifierTap","chord":"controlShift"}`, `{"type":"keyCombo","modifiers":9,"keyCode":49}`,
/// `{"type":"key","keyCode":53}`.
public enum HotkeyBinding: Sendable, Hashable, Codable {
    /// Press and release modifiers only, nothing else in between, within 500 ms (D11, PRD-R14).
    case modifierTap(ModifierTapChord)
    /// At least one modifier plus one key (PRD-R15).
    case keyCombo(modifiers: ModifierKeys, keyCode: KeyCode)
    /// A single key without modifiers. Allowed only for `.restoreLastWord` (Escape is the suggestion, D8).
    case key(KeyCode)

    /// D11 default.
    public static let defaultToggle = HotkeyBinding.modifierTap(.controlShift)

    public func isAllowed(for role: HotkeyRole) -> Bool {
        switch (self, role) {
        case (.key, .toggleMode): false
        case (.keyCombo(let modifiers, _), _): !modifiers.isEmpty
        default: true
        }
    }

    private enum CodingKeys: String, CodingKey { case type, chord, modifiers, keyCode }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "modifierTap":
            self = .modifierTap(try container.decode(ModifierTapChord.self, forKey: .chord))
        case "keyCombo":
            self = .keyCombo(
                modifiers: try container.decode(ModifierKeys.self, forKey: .modifiers),
                keyCode: try container.decode(KeyCode.self, forKey: .keyCode))
        case "key":
            self = .key(try container.decode(KeyCode.self, forKey: .keyCode))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "unknown hotkey type")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .modifierTap(let chord):
            try container.encode("modifierTap", forKey: .type)
            try container.encode(chord, forKey: .chord)
        case .keyCombo(let modifiers, let keyCode):
            try container.encode("keyCombo", forKey: .type)
            try container.encode(modifiers, forKey: .modifiers)
            try container.encode(keyCode, forKey: .keyCode)
        case .key(let keyCode):
            try container.encode("key", forKey: .type)
            try container.encode(keyCode, forKey: .keyCode)
        }
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/AppModel/HostState.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Input host state machine vocabulary (02-platform.md 2.1). InputHost drives it; ShellCore renders it
// (PRD-R10, PRD-R11, PRD-R43); Diagnostics logs its content-free code.

public enum HostState: Sendable, Hashable {
    case noPermission
    case starting
    case ready(TypingMode)
    case paused(PauseReason)
    case failOpen(FailOpenReason)

    /// True when keys may be transformed (still subject to EN mode and passThrough rules).
    public var isTransforming: Bool {
        if case .ready = self { return true }
        return false
    }

    public var code: HostStateCode {
        switch self {
        case .noPermission: .noPermission
        case .starting: .starting
        case .ready(.vietnamese): .readyVietnamese
        case .ready(.english): .readyEnglish
        case .paused(let reason): .paused(reason.code)
        case .failOpen(let reason): .failOpen(reason)
        }
    }
}

public enum PauseReason: Sendable, Hashable {
    case secureInput(SecureInputHolder?)
    /// `name` is the localized input-source name shown in the menu (PRD-R43); never logged.
    case nonLatinInputSource(name: String)
    case builtInVietnameseSource
    case passThroughRule(RuleID)
    case secureField
    case sessionInactive
    case userDisabled
    case noTextFocus
    /// The guided test of "This app misbehaves" types with its own strategy (PLT-R1205 steps 3-5): every key
    /// passes unchanged, hotkeys are suspended and nothing reaches the engine or per-app memory.
    case diagnosticsTest

    public var code: PauseCode {
        switch self {
        case .secureInput: .secureInput
        case .nonLatinInputSource: .nonLatinInputSource
        case .builtInVietnameseSource: .builtInVietnameseSource
        case .passThroughRule: .passThroughRule
        case .secureField: .secureField
        case .sessionInactive: .sessionInactive
        case .userDisabled: .userDisabled
        case .noTextFocus: .noTextFocus
        case .diagnosticsTest: .diagnosticsTest
        }
    }
}

public enum FailOpenReason: String, Sendable, Hashable, Codable {
    case permissionRevoked, postingBroken, tapUnavailable, watchdog
    /// The watchdog tripped and the stuck callback never returned: no second tap is created while the old
    /// tap thread may still be inside a callback (ADR 0309). The status line suggests reopening the app.
    case callbackStuck
}

public enum PauseCode: String, Sendable, Hashable, Codable {
    case secureInput, nonLatinInputSource, builtInVietnameseSource, passThroughRule, secureField,
        sessionInactive, userDisabled, noTextFocus, diagnosticsTest
}

/// Content-free state code for logs and reports.
public enum HostStateCode: Sendable, Hashable, Codable {
    case noPermission, starting, readyVietnamese, readyEnglish
    case paused(PauseCode)
    case failOpen(FailOpenReason)
}

/// "Likely holder" of Secure Event Input (PLT-R396). The value is a hint, not a fact.
public struct SecureInputHolder: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, Codable {
        /// A running app with a bundle identifier.
        case application
        /// `loginwindow`: advise locking and unlocking the screen (PLT-R396).
        case loginWindow
        /// The PID no longer exists: advise lock/unlock or log out (PLT-R396).
        case exitedProcess
        /// A running process without a bundle identifier.
        case process
    }

    public var pid: Int32
    public var kind: Kind
    public var bundle: BundleKey?
    /// Localized app name for the menu (PRD-R11). Never logged.
    public var displayName: String?
    /// Key into `secureInputHints` of compat-rules.json (PLT-R397, PLT-R398C), for example
    /// `terminal.secureKeyboardEntry`.
    public var hintKey: String?

    public init(pid: Int32, kind: Kind, bundle: BundleKey?, displayName: String?, hintKey: String?) {
        self.pid = pid
        self.kind = kind
        self.bundle = bundle
        self.displayName = displayName
        self.hintKey = hintKey
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/AppModel/Versions.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later

/// Semver-ish version for `match.appVersion` / `match.macOS` (02-platform.md 5.4) and diagnostics.
/// Parses leading dot-separated integers ("27.1", "155.0.7000.12", "1.0.0-beta.2" -> [1, 0, 0]) and compares
/// component-wise, missing components counting as zero.
public struct LooseVersion: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public let components: [Int]
    public let original: String

    public init?(_ string: String) {
        var parts: [Int] = []
        for piece in string.split(separator: ".", omittingEmptySubsequences: false) {
            let digits = piece.prefix { $0.isASCII && $0.isNumber }
            guard let value = Int(digits) else { break }
            parts.append(value)
            if digits.count != piece.count { break }
        }
        guard !parts.isEmpty else { return nil }
        components = parts
        original = string
    }

    public var description: String { original }

    public static func < (lhs: LooseVersion, rhs: LooseVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: LooseVersion, rhs: LooseVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
    public func hash(into hasher: inout Hasher) {
        var trimmed = components
        while trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let version = LooseVersion(raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad version"))
        }
        self = version
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(original)
    }
}

/// Inclusive version range (`{min, max}` in 02-platform.md 5.4). Either bound may be absent.
public struct VersionRange: Sendable, Hashable, Codable {
    public var min: LooseVersion?
    public var max: LooseVersion?
    public init(min: LooseVersion? = nil, max: LooseVersion? = nil) {
        self.min = min
        self.max = max
    }

    public func contains(_ version: LooseVersion) -> Bool {
        if let min, version < min { return false }
        if let max, max < version { return false }
        return true
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/AppModel/JSONValue.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later

/// Untyped JSON tree. Settings documents keep their raw object so unknown keys survive a rewrite
/// (PLT-R1002) and migrations are pure functions over JSON (PLT-R1005).
public enum JSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let object) = self { return object }
        return nil
    }

    public var intValue: Int? {
        if case .number(let number) = self, number == number.rounded(), abs(number) < 9.0e15 {
            return Int(number)
        }
        return nil
    }

    public var stringValue: String? {
        if case .string(let string) = self { return string }
        return nil
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
```
<!-- /include -->

`LocalFileSystem` (the production implementation) follows `FileSystem` in the same source file.

<!-- include: Packages/AppCore/Sources/AppModel/FileSystem.swift until="/// Production file system" -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later

public import Foundation

/// POSIX permission bits. Every directory the app creates is 0700 and every file 0600 (PLT-R903, PLT-R1001).
public struct FilePermissions: RawRepresentable, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let ownerOnlyDirectory = FilePermissions(rawValue: 0o700)
    public static let ownerOnlyFile = FilePermissions(rawValue: 0o600)
}

public struct FileAttributes: Sendable, Hashable {
    public var size: Int
    public var modificationDate: Date
    public var creationDate: Date
    public var permissions: FilePermissions
    public init(size: Int, modificationDate: Date, creationDate: Date, permissions: FilePermissions) {
        self.size = size
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.permissions = permissions
    }
}

public enum FileSystemError: Error, Sendable, Hashable {
    case notFound(path: String)
    case tooLarge(path: String, limit: Int)
    case ioFailure(path: String, errno: Int32)
}

/// File-system service used by SettingsStore and Diagnostics. The production implementation is
/// `LocalFileSystem`; tests use `InMemoryFileSystem` from TestSupport. Utility queue only: never called from
/// the tap, inject or ax threads (PLT-R203, PLT-R305).
public protocol FileSystem: Sendable {
    func fileExists(at url: URL) -> Bool
    /// Reads at most `maxBytes`; larger files throw `.tooLarge` (PLT-R912 caps imports at 5 MB).
    func readData(at url: URL, maxBytes: Int) throws -> Data
    /// Temporary file in the same directory, `fsync`, then `rename` (PLT-R1003).
    func writeAtomically(_ data: Data, to url: URL, permissions: FilePermissions) throws
    /// Appends to a log file, creating it with `permissions` if needed (PLT-R903 JSON lines).
    func append(_ data: Data, to url: URL, permissions: FilePermissions) throws
    func createDirectory(at url: URL, permissions: FilePermissions) throws
    func moveItem(at source: URL, to destination: URL) throws
    func copyItem(at source: URL, to destination: URL) throws
    func removeItem(at url: URL) throws
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func attributes(at url: URL) throws -> FileAttributes
    /// `URLResourceValues.isExcludedFromBackup` (PLT-R905 captures).
    func setExcludedFromBackup(_ excluded: Bool, at url: URL) throws
}

/// Wall-clock time for timestamps in files and reports. Monotonic time for the hot path lives in
/// RealtimeSupport (`MonotonicClock`).
public protocol WallClock: Sendable {
    func now() -> Date
}

public struct SystemWallClock: WallClock {
    public init() {}
    public func now() -> Date { Date() }
}
```
<!-- /include -->

## 5. RealtimeSupport: hot-path primitives

Owned files: `Packages/AppCore/Sources/RealtimeSupport/**` and `Packages/AppCore/Sources/CRealtimeSupport/**`
(workstream W1-A hardens and benchmarks; the skeleton implementation is complete and passes Thread Sanitizer).
Why the snapshot cell is shaped this way: [0303](../decisions/0303-snapshot-publication.md). The atomics, the
mutex and the time span replace the macOS 15 `Synchronization` module and the macOS 13 `Duration` for the
macOS 12 floor: [0315](../decisions/0315-minimum-macos-12.md).

<!-- include: Packages/AppCore/Sources/RealtimeSupport/Atomic.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Lock-free atomics with explicit memory orderings (PLT-R304, PLT-R388) for macOS 12 and later
// (docs/decisions/0315-minimum-macos-12.md). The API mirrors the `Synchronization` module's `Atomic`, which
// needs macOS 15, so call sites read the same: `Atomic<Int>(0)`, `load(ordering: .acquiring)`,
// `wrappingAdd(1, ordering: .relaxed)`, `compareExchange(expected:desired:ordering:)`.
//
// Differences from `Synchronization.Atomic`, all deliberate:
// - `Atomic` is a copyable handle to one word allocated at `init` (copies share the word); after `init` no
//   operation allocates, locks or blocks.
// - `UnsafeAtomic` applies the same operations to a word someone else owns (a raw buffer, a C global).
// - Only the operations the code base uses exist; add more here rather than reaching for another module.

public import CRealtimeSupport

#if !(arch(arm64) || arch(x86_64))
#error("RealtimeSupport atomics assume a 64-bit Apple platform (PLT-R105: arm64 and x86_64)")
#endif

// MARK: - Orderings

/// Memory ordering of an atomic load.
public struct AtomicLoadOrdering: Sendable, Hashable {
    @usableFromInline let rawValue: CInt

    @inlinable init(rawValue: CInt) { self.rawValue = rawValue }

    /// No ordering constraint beyond atomicity.
    @inlinable public static var relaxed: Self { Self(rawValue: 0) }
    /// Later reads and writes stay after this load; pairs with a releasing store.
    @inlinable public static var acquiring: Self { Self(rawValue: 2) }
    /// Acquiring, and part of the single total order of sequentially consistent operations.
    @inlinable public static var sequentiallyConsistent: Self { Self(rawValue: 5) }
}

/// Memory ordering of an atomic store.
public struct AtomicStoreOrdering: Sendable, Hashable {
    @usableFromInline let rawValue: CInt

    @inlinable init(rawValue: CInt) { self.rawValue = rawValue }

    /// No ordering constraint beyond atomicity.
    @inlinable public static var relaxed: Self { Self(rawValue: 0) }
    /// Earlier reads and writes stay before this store; pairs with an acquiring load.
    @inlinable public static var releasing: Self { Self(rawValue: 3) }
    /// Releasing, and part of the single total order of sequentially consistent operations.
    @inlinable public static var sequentiallyConsistent: Self { Self(rawValue: 5) }
}

/// Memory ordering of an atomic read-modify-write operation.
public struct AtomicUpdateOrdering: Sendable, Hashable {
    @usableFromInline let rawValue: CInt

    @inlinable init(rawValue: CInt) { self.rawValue = rawValue }

    /// No ordering constraint beyond atomicity.
    @inlinable public static var relaxed: Self { Self(rawValue: 0) }
    /// The read half acquires.
    @inlinable public static var acquiring: Self { Self(rawValue: 2) }
    /// The write half releases.
    @inlinable public static var releasing: Self { Self(rawValue: 3) }
    /// Both halves: acquiring read, releasing write.
    @inlinable public static var acquiringAndReleasing: Self { Self(rawValue: 4) }
    /// Acquiring and releasing, and part of the single total order of sequentially consistent operations.
    @inlinable public static var sequentiallyConsistent: Self { Self(rawValue: 5) }
}

// MARK: - Storage words

/// An unsigned word the C layer operates on atomically (8, 32 or 64 bits).
public protocol AtomicStorageWord: FixedWidthInteger, UnsignedInteger, Sendable {
    static func atomicLoad(_ address: UnsafeMutablePointer<Self>, ordering: CInt) -> Self
    static func atomicStore(_ value: Self, to address: UnsafeMutablePointer<Self>, ordering: CInt)
    static func atomicExchange(_ value: Self, at address: UnsafeMutablePointer<Self>, ordering: CInt) -> Self
    /// Returns whether the exchange happened and the value found (equal to `expected` when it happened).
    static func atomicCompareExchange(
        expected: Self, desired: Self, at address: UnsafeMutablePointer<Self>, ordering: CInt
    ) -> (exchanged: Bool, original: Self)
    /// Wrapping add; returns the previous value.
    static func atomicFetchAdd(_ value: Self, at address: UnsafeMutablePointer<Self>, ordering: CInt) -> Self
    /// Wrapping subtract; returns the previous value.
    static func atomicFetchSubtract(_ value: Self, at address: UnsafeMutablePointer<Self>, ordering: CInt) -> Self
}

extension UInt8: AtomicStorageWord {
    @inlinable public static func atomicLoad(_ address: UnsafeMutablePointer<Self>, ordering: CInt) -> Self {
        crt_load_u8(address, ordering)
    }
    @inlinable public static func atomicStore(_ value: Self, to address: UnsafeMutablePointer<Self>, ordering: CInt) {
        crt_store_u8(address, value, ordering)
    }
    @inlinable
    public static func atomicExchange(_ value: Self, at address: UnsafeMutablePointer<Self>, ordering: CInt) -> Self {
        crt_exchange_u8(address, value, ordering)
    }
    @inlinable
    public static func atomicCompareExchange(
        expected: Self, desired: Self, at address: UnsafeMutablePointer<Self>, ordering: CInt
    ) -> (exchanged: Bool, original: Self) {
        var found = expected
        let exchanged = crt_compare_exchange_u8(address, &found, desired, ordering)
        return (exchanged, found)
    }
    @inlinable
    public static func atomicFetchAdd(_ value: Self, at address: UnsafeMutablePointer<Self>, ordering: CInt) -> Self {
        crt_fetch_add_u8(address, value, ordering)
    }
    @inlinable
    public static func atomicFetchSubtract(_ value: Self, at address: UnsafeMutablePointer<Self>, ordering: CInt)
        -> Self
    {
        crt_fetch_sub_u8(address, value, ordering)
    }
}

extension UInt32: AtomicStorageWord {
    @inlinable public static func atomicLoad(_ address: UnsafeMutablePointer<Self>, ordering: CInt) -> Self {
        crt_load_u32(address, ordering)
    }
    @inlinable public static func atomicStore(_ value: Self, to address: UnsafeMutablePointer<Self>, ordering: CInt) {
        crt_store_u32(address, value, ordering)
    }
    @inlinable
    public static func atomicExchange(_ value: Self, at address: UnsafeMutablePointer<Self>, ordering: CInt) -> Self {
        crt_exchange_u32(address, value, ordering)
    }
    @inlinable
    public static func atomicCompareExchange(
        expected: Self, desired: Self, at address: UnsafeMutablePointer<Self>, ordering: CInt
    ) -> (exchanged: Bool, original: Self) {
        var found = expected
        let exchanged = crt_compare_exchange_u32(address, &found, desired, ordering)
        return (exchanged, found)
    }
    @inlinable
    public static func atomicFetchAdd(_ value: Self, at address: UnsafeMutablePointer<Self>, ordering: CInt) -> Self {
        crt_fetch_add_u32(address, value, ordering)
    }
    @inlinable
    public static func atomicFetchSubtract(_ value: Self, at address: UnsafeMutablePointer<Self>, ordering: CInt)
        -> Self
    {
        crt_fetch_sub_u32(address, value, ordering)
    }
}

extension UInt64: AtomicStorageWord {
    @inlinable public static func atomicLoad(_ address: UnsafeMutablePointer<Self>, ordering: CInt) -> Self {
        crt_load_u64(address, ordering)
    }
    @inlinable public static func atomicStore(_ value: Self, to address: UnsafeMutablePointer<Self>, ordering: CInt) {
        crt_store_u64(address, value, ordering)
    }
    @inlinable
    public static func atomicExchange(_ value: Self, at address: UnsafeMutablePointer<Self>, ordering: CInt) -> Self {
        crt_exchange_u64(address, value, ordering)
    }
    @inlinable
    public static func atomicCompareExchange(
        expected: Self, desired: Self, at address: UnsafeMutablePointer<Self>, ordering: CInt
    ) -> (exchanged: Bool, original: Self) {
        var found = expected
        let exchanged = crt_compare_exchange_u64(address, &found, desired, ordering)
        return (exchanged, found)
    }
    @inlinable
    public static func atomicFetchAdd(_ value: Self, at address: UnsafeMutablePointer<Self>, ordering: CInt) -> Self {
        crt_fetch_add_u64(address, value, ordering)
    }
    @inlinable
    public static func atomicFetchSubtract(_ value: Self, at address: UnsafeMutablePointer<Self>, ordering: CInt)
        -> Self
    {
        crt_fetch_sub_u64(address, value, ordering)
    }
}

// MARK: - Representable values

/// A value that round-trips through one atomic storage word.
public protocol AtomicRepresentable {
    associatedtype AtomicRepresentation: AtomicStorageWord
    static func encodeAtomicRepresentation(_ value: Self) -> AtomicRepresentation
    static func decodeAtomicRepresentation(_ representation: AtomicRepresentation) -> Self
}

/// An integer stored as its own bit pattern in a word of the same width, so wrapping arithmetic on the word is
/// wrapping arithmetic on the value.
public protocol AtomicInteger: AtomicRepresentable, FixedWidthInteger {}

extension AtomicInteger {
    @inlinable public static func encodeAtomicRepresentation(_ value: Self) -> AtomicRepresentation {
        AtomicRepresentation(truncatingIfNeeded: value)
    }
    @inlinable public static func decodeAtomicRepresentation(_ representation: AtomicRepresentation) -> Self {
        Self(truncatingIfNeeded: representation)
    }
}

extension UInt8: AtomicInteger { public typealias AtomicRepresentation = UInt8 }
extension Int8: AtomicInteger { public typealias AtomicRepresentation = UInt8 }
extension UInt32: AtomicInteger { public typealias AtomicRepresentation = UInt32 }
extension Int32: AtomicInteger { public typealias AtomicRepresentation = UInt32 }
extension UInt64: AtomicInteger { public typealias AtomicRepresentation = UInt64 }
extension Int64: AtomicInteger { public typealias AtomicRepresentation = UInt64 }
extension UInt: AtomicInteger { public typealias AtomicRepresentation = UInt64 }
extension Int: AtomicInteger { public typealias AtomicRepresentation = UInt64 }

extension Bool: AtomicRepresentable {
    public typealias AtomicRepresentation = UInt8
    @inlinable public static func encodeAtomicRepresentation(_ value: Bool) -> UInt8 { value ? 1 : 0 }
    @inlinable public static func decodeAtomicRepresentation(_ representation: UInt8) -> Bool { representation != 0 }
}

extension Unmanaged: AtomicRepresentable {
    public typealias AtomicRepresentation = UInt64
    @inlinable public static func encodeAtomicRepresentation(_ value: Unmanaged<Instance>) -> UInt64 {
        UInt64(UInt(bitPattern: value.toOpaque()))
    }
    @inlinable public static func decodeAtomicRepresentation(_ representation: UInt64) -> Unmanaged<Instance> {
        // Only ever decodes words written by `encodeAtomicRepresentation`, which are never null.
        Unmanaged.fromOpaque(UnsafeRawPointer(bitPattern: UInt(representation))!)
    }
}

// MARK: - Operations on a word

/// Atomic operations on a word owned elsewhere (raw buffers, C globals). The caller keeps the memory alive,
/// aligned and accessed only atomically for as long as any `UnsafeAtomic` refers to it.
public struct UnsafeAtomic<Value: AtomicRepresentable>: @unchecked Sendable {
    // @unchecked: a plain address; atomicity of every access is the point of the type.
    public let address: UnsafeMutablePointer<Value.AtomicRepresentation>

    @inlinable public init(at address: UnsafeMutablePointer<Value.AtomicRepresentation>) { self.address = address }

    @inlinable
    public func load(ordering: AtomicLoadOrdering) -> Value {
        Value.decodeAtomicRepresentation(.atomicLoad(address, ordering: ordering.rawValue))
    }

    @inlinable
    public func store(_ desired: Value, ordering: AtomicStoreOrdering) {
        Value.AtomicRepresentation.atomicStore(
            Value.encodeAtomicRepresentation(desired), to: address, ordering: ordering.rawValue)
    }

    /// Stores `desired` and returns the previous value.
    @inlinable @discardableResult
    public func exchange(_ desired: Value, ordering: AtomicUpdateOrdering) -> Value {
        Value.decodeAtomicRepresentation(
            .atomicExchange(Value.encodeAtomicRepresentation(desired), at: address, ordering: ordering.rawValue))
    }

    /// Stores `desired` if the current value is `expected` (strong: no spurious failure). The failure ordering
    /// is the success ordering without its releasing half.
    @inlinable
    public func compareExchange(expected: Value, desired: Value, ordering: AtomicUpdateOrdering)
        -> (exchanged: Bool, original: Value)
    {
        let result = Value.AtomicRepresentation.atomicCompareExchange(
            expected: Value.encodeAtomicRepresentation(expected), desired: Value.encodeAtomicRepresentation(desired),
            at: address, ordering: ordering.rawValue)
        return (result.exchanged, Value.decodeAtomicRepresentation(result.original))
    }
}

extension UnsafeAtomic where Value: AtomicInteger {
    @inlinable @discardableResult
    public func wrappingAdd(_ operand: Value, ordering: AtomicUpdateOrdering) -> (oldValue: Value, newValue: Value) {
        let old = Value.decodeAtomicRepresentation(
            .atomicFetchAdd(Value.encodeAtomicRepresentation(operand), at: address, ordering: ordering.rawValue))
        return (old, old &+ operand)
    }

    @inlinable @discardableResult
    public func wrappingSubtract(_ operand: Value, ordering: AtomicUpdateOrdering)
        -> (oldValue: Value, newValue: Value)
    {
        let old = Value.decodeAtomicRepresentation(
            .atomicFetchSubtract(Value.encodeAtomicRepresentation(operand), at: address, ordering: ordering.rawValue))
        return (old, old &- operand)
    }

    /// Adds `operand` and traps if the result overflowed (the word keeps the wrapped value).
    @inlinable @discardableResult
    public func add(_ operand: Value, ordering: AtomicUpdateOrdering) -> (oldValue: Value, newValue: Value) {
        let result = wrappingAdd(operand, ordering: ordering)
        precondition(!result.oldValue.addingReportingOverflow(operand).overflow, "atomic add overflowed")
        return result
    }

    /// Subtracts `operand` and traps if the result overflowed (the word keeps the wrapped value).
    @inlinable @discardableResult
    public func subtract(_ operand: Value, ordering: AtomicUpdateOrdering) -> (oldValue: Value, newValue: Value) {
        let result = wrappingSubtract(operand, ordering: ordering)
        precondition(!result.oldValue.subtractingReportingOverflow(operand).overflow, "atomic subtract overflowed")
        return result
    }

    /// Stores the larger of the current value and `operand` (a compare-exchange loop: lock-free, not wait-free).
    @inlinable @discardableResult
    public func max(_ operand: Value, ordering: AtomicUpdateOrdering) -> (oldValue: Value, newValue: Value) {
        var current = load(ordering: .relaxed)
        while true {
            let desired = Swift.max(current, operand)
            let result = compareExchange(expected: current, desired: desired, ordering: ordering)
            if result.exchanged { return (current, desired) }
            current = result.original
        }
    }

    /// Stores the smaller of the current value and `operand` (a compare-exchange loop: lock-free, not wait-free).
    @inlinable @discardableResult
    public func min(_ operand: Value, ordering: AtomicUpdateOrdering) -> (oldValue: Value, newValue: Value) {
        var current = load(ordering: .relaxed)
        while true {
            let desired = Swift.min(current, operand)
            let result = compareExchange(expected: current, desired: desired, ordering: ordering)
            if result.exchanged { return (current, desired) }
            current = result.original
        }
    }
}

// MARK: - Owned atomic

/// One atomic word, allocated at `init` and freed with the last copy. Copies share the word.
public struct Atomic<Value: AtomicRepresentable>: @unchecked Sendable {
    // @unchecked: the buffer is written at init only; its single element is accessed only atomically.
    @usableFromInline let storage: ManagedBuffer<Void, Value.AtomicRepresentation>

    public init(_ initialValue: Value) {
        storage = .create(minimumCapacity: 1) { _ in }
        storage.withUnsafeMutablePointerToElements { word in
            word.initialize(to: Value.encodeAtomicRepresentation(initialValue))
        }
    }

    /// The operations on the owned word. Its address is stable: a `ManagedBuffer` never moves its elements.
    @inlinable var word: UnsafeAtomic<Value> {
        UnsafeAtomic(at: storage.withUnsafeMutablePointerToElements { $0 })
    }

    @inlinable
    public func load(ordering: AtomicLoadOrdering) -> Value {
        defer { withExtendedLifetime(storage) {} }
        return word.load(ordering: ordering)
    }

    @inlinable
    public func store(_ desired: Value, ordering: AtomicStoreOrdering) {
        defer { withExtendedLifetime(storage) {} }
        word.store(desired, ordering: ordering)
    }

    /// Stores `desired` and returns the previous value.
    @inlinable @discardableResult
    public func exchange(_ desired: Value, ordering: AtomicUpdateOrdering) -> Value {
        defer { withExtendedLifetime(storage) {} }
        return word.exchange(desired, ordering: ordering)
    }

    /// Stores `desired` if the current value is `expected` (strong: no spurious failure).
    @inlinable
    public func compareExchange(expected: Value, desired: Value, ordering: AtomicUpdateOrdering)
        -> (exchanged: Bool, original: Value)
    {
        defer { withExtendedLifetime(storage) {} }
        return word.compareExchange(expected: expected, desired: desired, ordering: ordering)
    }
}

extension Atomic where Value: AtomicInteger {
    @inlinable @discardableResult
    public func wrappingAdd(_ operand: Value, ordering: AtomicUpdateOrdering) -> (oldValue: Value, newValue: Value) {
        defer { withExtendedLifetime(storage) {} }
        return word.wrappingAdd(operand, ordering: ordering)
    }

    @inlinable @discardableResult
    public func wrappingSubtract(_ operand: Value, ordering: AtomicUpdateOrdering)
        -> (oldValue: Value, newValue: Value)
    {
        defer { withExtendedLifetime(storage) {} }
        return word.wrappingSubtract(operand, ordering: ordering)
    }

    /// Adds `operand` and traps on overflow.
    @inlinable @discardableResult
    public func add(_ operand: Value, ordering: AtomicUpdateOrdering) -> (oldValue: Value, newValue: Value) {
        defer { withExtendedLifetime(storage) {} }
        return word.add(operand, ordering: ordering)
    }

    /// Subtracts `operand` and traps on overflow.
    @inlinable @discardableResult
    public func subtract(_ operand: Value, ordering: AtomicUpdateOrdering) -> (oldValue: Value, newValue: Value) {
        defer { withExtendedLifetime(storage) {} }
        return word.subtract(operand, ordering: ordering)
    }

    /// Stores the larger of the current value and `operand`.
    @inlinable @discardableResult
    public func max(_ operand: Value, ordering: AtomicUpdateOrdering) -> (oldValue: Value, newValue: Value) {
        defer { withExtendedLifetime(storage) {} }
        return word.max(operand, ordering: ordering)
    }

    /// Stores the smaller of the current value and `operand`.
    @inlinable @discardableResult
    public func min(_ operand: Value, ordering: AtomicUpdateOrdering) -> (oldValue: Value, newValue: Value) {
        defer { withExtendedLifetime(storage) {} }
        return word.min(operand, ordering: ordering)
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/RealtimeSupport/Mutex.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Mutual exclusion for macOS 12 and later (docs/decisions/0315-minimum-macos-12.md). The API mirrors the
// `Synchronization` module's `Mutex` (macOS 15): `Mutex(initialValue)` and `withLock { value in ... }`.
//
// Built on `os_unfair_lock`, like `Synchronization.Mutex` on Darwin: no allocation after `init`, waiters sleep
// in the kernel with priority donation, recursion and unlocking from another thread trap. It blocks, so the
// tap thread never takes one (PLT-R304, PLT-R305); the tap reads published snapshots and lock-free atomics.

public import Darwin

/// A value protected by an unfair lock. Copies are handles to the same lock and value.
public struct Mutex<Value>: @unchecked Sendable {
    // @unchecked: the value is reachable only inside `withLock`, while the lock is held.
    @usableFromInline let storage: ManagedBuffer<Value, os_unfair_lock>

    public init(_ initialValue: sending Value) {
        storage = .create(minimumCapacity: 1) { _ in initialValue }
        storage.withUnsafeMutablePointerToElements { lock in lock.initialize(to: os_unfair_lock()) }
    }

    /// Runs `body` with exclusive access to the value. Never call on the tap thread; never nest on one mutex.
    @inlinable
    public func withLock<Result, E: Error>(_ body: (inout sending Value) throws(E) -> sending Result) throws(E)
        -> sending Result
    {
        // The header and element addresses of a `ManagedBuffer` are stable for its whole life.
        let (value, lock) = storage.withUnsafeMutablePointers { ($0, $1) }
        os_unfair_lock_lock(lock)
        defer {
            os_unfair_lock_unlock(lock)
            withExtendedLifetime(storage) {}
        }
        return try body(&value.pointee)
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/RealtimeSupport/TimeSpan.swift until="    // MARK: Arithmetic" -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Length of time for timeouts, intervals, backoffs and deadlines (docs/decisions/0315-minimum-macos-12.md).
// Replaces `Swift.Duration`, which needs macOS 13 (PLT-R106: the floor is macOS 12). Call sites keep the
// `Duration` spelling of values: `.milliseconds(150)`, `.seconds(2)`, `.zero`, comparisons and arithmetic.
//
// Signed nanoseconds in 64 bits (about 292 years either way). Factories and arithmetic saturate at the bounds
// instead of trapping, so a configuration value can never crash the input method.

public import Dispatch

public struct TimeSpan: Sendable, Hashable, Comparable, BitwiseCopyable, CustomStringConvertible {
    /// Signed length in nanoseconds.
    public var nanoseconds: Int64

    @inlinable public init(nanoseconds: Int64) { self.nanoseconds = nanoseconds }

    public static let zero = TimeSpan(nanoseconds: 0)

    // MARK: Factories

    @inlinable public static func nanoseconds(_ value: some BinaryInteger) -> TimeSpan {
        TimeSpan(nanoseconds: Int64(clamping: value))
    }

    @inlinable public static func microseconds(_ value: some BinaryInteger) -> TimeSpan {
        scaled(value, by: 1_000)
    }

    @inlinable public static func milliseconds(_ value: some BinaryInteger) -> TimeSpan {
        scaled(value, by: 1_000_000)
    }

    @inlinable public static func seconds(_ value: some BinaryInteger) -> TimeSpan {
        scaled(value, by: 1_000_000_000)
    }

    /// Fractional seconds, rounded to the nearest nanosecond; NaN is zero.
    @inlinable public static func seconds(_ value: Double) -> TimeSpan {
        fromNanoseconds(value * 1e9)
    }

    /// Fractional milliseconds, rounded to the nearest nanosecond; NaN is zero.
    @inlinable public static func milliseconds(_ value: Double) -> TimeSpan {
        fromNanoseconds(value * 1e6)
    }

    @inlinable static func scaled(_ value: some BinaryInteger, by factor: Int64) -> TimeSpan {
        let clamped = Int64(clamping: value)
        let (product, overflow) = clamped.multipliedReportingOverflow(by: factor)
        guard !overflow else { return TimeSpan(nanoseconds: (clamped < 0) != (factor < 0) ? .min : .max) }
        return TimeSpan(nanoseconds: product)
    }

    @inlinable static func fromNanoseconds(_ value: Double) -> TimeSpan {
        guard !value.isNaN else { return .zero }
        guard value < 9.223_372_036_854_775e18 else { return TimeSpan(nanoseconds: .max) }
        guard value > -9.223_372_036_854_775e18 else { return TimeSpan(nanoseconds: .min) }
        return TimeSpan(nanoseconds: Int64(value.rounded()))
    }

    // MARK: Conversions

    /// Length in seconds as a floating-point value (for Foundation's `TimeInterval` APIs and display).
    @inlinable public var inSeconds: Double { Double(nanoseconds) / 1e9 }

    /// Nanoseconds clamped to zero and above, for APIs that take an unsigned count (`Task.sleep(nanoseconds:)`,
    /// `DispatchTime(uptimeNanoseconds:)`).
    @inlinable public var unsignedNanoseconds: UInt64 { UInt64(clamping: nanoseconds) }

    /// Nanosecond-precision interval for Dispatch APIs; negative lengths become zero.
    @inlinable public var dispatchInterval: DispatchTimeInterval {
        .nanoseconds(Int(clamping: Swift.max(0, nanoseconds)))
    }

    public var description: String { "\(inSeconds) seconds" }
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/RealtimeSupport/SnapshotCell.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Snapshot publication (PLT-R304, PLT-R388, docs/decisions/0303-snapshot-publication.md).
//
// Writers (main, ax, utility) publish immutable values; the tap thread reads the current value with ONE
// atomic load and no retain, lock or allocation. Memory safety for the tap reader comes from quiescent-state
// based reclamation (QSBR) with a single reader: the tap brackets every callback with `ReaderEpoch.enter()`
// and `exit()`, and a writer frees a replaced box only after the epoch shows that the tap has left any read
// section that could have loaded it. Boxes are therefore always released on a writer thread, never on the tap.
//
// Readers other than the tap use `load()`, which takes a short writer-side lock and returns a strong copy.

/// Read-section counter for the single tap reader. Even = outside a callback, odd = inside.
public final class ReaderEpoch: Sendable {
    private let counter = Atomic<UInt64>(0)

    public init() {}

    /// First statement of the tap callback (an "atomic counter update", allowed by PLT-R304).
    @inline(__always)
    public func enter() { counter.wrappingAdd(1, ordering: .sequentiallyConsistent) }

    /// Last statement of the tap callback, on every return path.
    @inline(__always)
    public func exit() { counter.wrappingAdd(1, ordering: .sequentiallyConsistent) }

    var value: UInt64 { counter.load(ordering: .sequentiallyConsistent) }
}

/// Immutable value published through one atomic reference (Appendix B "Snapshot").
public final class SnapshotCell<Value: Sendable>: Sendable {
    private final class Box: Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    private struct WriterState: @unchecked Sendable {
        // Unmanaged boxes retired by `publish`, with the reader epoch observed right after the exchange.
        var retired: [(box: Unmanaged<Box>, epoch: UInt64)] = []
        var latest: Value
    }

    private let current: Atomic<Unmanaged<Box>>
    private let writer: Mutex<WriterState>
    private let epoch: ReaderEpoch

    public init(_ initial: Value, epoch: ReaderEpoch) {
        self.epoch = epoch
        current = Atomic(Unmanaged.passRetained(Box(initial)))
        writer = Mutex(WriterState(latest: initial))
    }

    deinit {
        current.load(ordering: .sequentiallyConsistent).release()
        writer.withLock { state in
            for entry in state.retired { entry.box.release() }
            state.retired.removeAll()
        }
    }

    /// Tap thread only, between `ReaderEpoch.enter()` and `exit()`. One atomic load; the value is borrowed
    /// for the duration of `body` and MUST NOT escape it.
    @inline(__always)
    public func read<R>(_ body: (Value) -> R) -> R {
        current.load(ordering: .sequentiallyConsistent)._withUnsafeGuaranteedRef { body($0.value) }
    }

    /// Any thread except the tap. Returns a strong copy; may wait for a concurrent `publish` (O(1) work).
    public func load() -> Value {
        writer.withLock { $0.latest }
    }

    /// Main, ax or utility thread. Never called on the tap thread.
    public func publish(_ value: Value) {
        let fresh = Unmanaged.passRetained(Box(value))
        writer.withLock { state in
            let old = current.exchange(fresh, ordering: .sequentiallyConsistent)
            state.retired.append((old, epoch.value))
            state.latest = value
            reclaim(&state)
        }
    }

    /// Frees boxes the tap can no longer reference. Called by `publish` and by the utility watchdog.
    public func reclaim() {
        writer.withLock { reclaim(&$0) }
    }

    /// Boxes retired but not yet freed (tests and the watchdog's bound check).
    var retiredCount: Int { writer.withLock { $0.retired.count } }

    private func reclaim(_ state: inout WriterState) {
        let now = epoch.value
        state.retired.removeAll { entry in
            // Even epoch at retire time: the tap was outside a callback, later callbacks load the new box.
            // Odd epoch: the callback that may hold the old box has ended once the counter moved on.
            let safe = entry.epoch & 1 == 0 || now != entry.epoch
            if safe { entry.box.release() }
            return safe
        }
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/RealtimeSupport/SPSCRing.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later

/// Bounded lock-free single-producer single-consumer queue (PLT-R304 "pushing onto a lock-free
/// single-producer queue"). Storage is allocated once; push and pop never allocate or block.
///
/// Discipline (checked in debug builds by the owners, not by this type): exactly one producer thread calls
/// `push`, exactly one consumer thread calls `pop`. Elements are destroyed on the consumer thread.
public final class SPSCRing<Element: Sendable>: @unchecked Sendable {
    public let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Element?>
    private let head = Atomic<Int>(0)  // next slot to pop, written by the consumer
    private let tail = Atomic<Int>(0)  // next slot to push, written by the producer

    /// `capacity` MUST be a power of two.
    public init(capacity: Int) {
        precondition(capacity > 0 && capacity & (capacity - 1) == 0, "capacity must be a power of two")
        self.capacity = capacity
        mask = capacity - 1
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: nil, count: capacity)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    /// Producer only. Returns false when full (the caller treats that as a liveness flush, PLT-R314).
    @inline(__always)
    public func push(_ element: consuming Element) -> Bool {
        let currentTail = tail.load(ordering: .relaxed)
        let currentHead = head.load(ordering: .acquiring)
        guard currentTail &- currentHead < capacity else { return false }
        (storage + (currentTail & mask)).pointee = element
        tail.store(currentTail &+ 1, ordering: .releasing)
        return true
    }

    /// Consumer only.
    @inline(__always)
    public func pop() -> Element? {
        let currentHead = head.load(ordering: .relaxed)
        let currentTail = tail.load(ordering: .acquiring)
        guard currentHead != currentTail else { return nil }
        let slot = storage + (currentHead & mask)
        let element = slot.move()
        slot.initialize(to: nil)
        head.store(currentHead &+ 1, ordering: .releasing)
        return element
    }

    /// Approximate from any thread; exact from the producer or the consumer.
    public var count: Int { tail.load(ordering: .acquiring) &- head.load(ordering: .acquiring) }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/RealtimeSupport/Signals.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later

public import Dispatch

/// Wake-up from the tap thread to a dispatch queue without blocking, locking or allocating: a
/// `DispatchSourceUserDataAdd` merge coalesces signals and runs `handler` once on `queue`. Used for tap ->
/// main (outbox), tap -> utility (watchdog arming) and tap -> ax (revalidation, via a hop) notifications.
public final class WakeSignal: Sendable {
    private let source: any DispatchSourceUserDataAdd

    public init(queue: DispatchQueue, handler: @escaping @Sendable () -> Void) {
        source = DispatchSource.makeUserDataAddSource(queue: queue)
        source.setEventHandler(handler: handler)
        source.activate()
    }

    /// Safe on the tap thread.
    @inline(__always)
    public func signal() { source.add(data: 1) }

    public func cancel() { source.cancel() }
}

/// Wake-up for the `inject` thread's condition-driven loop (PLT-R203). `signal()` never blocks the caller;
/// only the worker waits, with an absolute deadline (PLT-R409).
public final class WorkerSignal: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    public init() {}

    /// Safe on the tap thread.
    @inline(__always)
    public func signal() { semaphore.signal() }

    /// Worker only. Returns false when the deadline passed without a signal.
    public func wait(until deadline: MonotonicInstant?) -> Bool {
        guard let deadline else {
            semaphore.wait()
            return true
        }
        return semaphore.wait(timeout: DispatchTime(uptimeNanoseconds: deadline.nanoseconds)) == .success
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/RealtimeSupport/MonotonicClock.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later

internal import Darwin

/// Point on the uptime clock (`CLOCK_UPTIME_RAW`, the mach absolute time base) in nanoseconds.
public struct MonotonicInstant: Sendable, Hashable, Comparable, BitwiseCopyable {
    public var nanoseconds: UInt64
    public init(nanoseconds: UInt64) { self.nanoseconds = nanoseconds }
    public static let zero = MonotonicInstant(nanoseconds: 0)

    public static func < (lhs: MonotonicInstant, rhs: MonotonicInstant) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }

    public func advanced(byMicroseconds microseconds: UInt64) -> MonotonicInstant {
        MonotonicInstant(nanoseconds: nanoseconds &+ microseconds &* 1_000)
    }

    /// Saturating difference in nanoseconds.
    public func nanoseconds(since earlier: MonotonicInstant) -> UInt64 {
        nanoseconds >= earlier.nanoseconds ? nanoseconds - earlier.nanoseconds : 0
    }

    /// Saturating difference as a span (zero when `earlier` is later).
    public func duration(since earlier: MonotonicInstant) -> TimeSpan {
        .nanoseconds(nanoseconds(since: earlier))
    }
}

/// Monotonic clock for timestamps, deadlines and pacing. `sleep(until:)` is allowed only on the `inject`
/// thread (PLT-R409) and in tests; never on the tap thread (PLT-R305).
public protocol MonotonicClock: Sendable {
    func now() -> MonotonicInstant
    func sleep(until deadline: MonotonicInstant)
}

/// Production clock. `now()` is a vDSO-style read with no syscall on Apple silicon.
public struct MachClock: MonotonicClock {
    private let numerator: UInt64
    private let denominator: UInt64

    public init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        numerator = UInt64(info.numer)
        denominator = UInt64(info.denom)
    }

    @inline(__always)
    public func now() -> MonotonicInstant {
        MonotonicInstant(nanoseconds: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
    }

    public func sleep(until deadline: MonotonicInstant) {
        // The kernel reads a deadline of 0 as "no deadline" and would block forever, so a deadline that has
        // already passed returns at once instead of reaching mach_wait_until.
        guard deadline > now() else { return }
        // Absolute deadline in mach ticks (PLT-R409).
        let ticks = deadline.nanoseconds.multipliedFullWidth(by: denominator)
        let (quotient, _) = numerator.dividingFullWidth(ticks)
        mach_wait_until(max(quotient, 1))
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/RealtimeSupport/InlineUTF16.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later

/// Fixed-capacity UTF-16 buffer (at most 20 code units, the practical limit of
/// `CGEventKeyboardSetUnicodeString`, PLT-R404). Bitwise-copyable so events can be held, queued and
/// replayed on the hot path without heap allocation.
public struct InlineUTF16: Sendable, Hashable, BitwiseCopyable {
    public static let capacity = 20

    public private(set) var count: UInt8
    private var units:
        (
            UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16,
            UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16
        )

    public static let empty = InlineUTF16()

    public init() {
        count = 0
        units = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    /// Copies at most `capacity` units from a buffer (tap thread: buffer filled by
    /// `CGEventKeyboardGetUnicodeString`). Returns nil if the source is longer than the capacity.
    public init?(_ buffer: UnsafeBufferPointer<UInt16>) {
        guard buffer.count <= Self.capacity else { return nil }
        self.init()
        withUnsafeMutableBytes(of: &units) { raw in
            let target = raw.bindMemory(to: UInt16.self)
            // A `while` loop: an unoptimised `for ... in` over a range allocates an iterator box per iteration, and
            // Debug builds (the dev recorder's, PLT-R904A) run this on the tap (PLT-R305).
            var index = 0
            while index < buffer.count {
                target[index] = buffer[index]
                index += 1
            }
        }
        count = UInt8(buffer.count)
    }

    /// Non-tap threads only (allocates when reading the string's UTF-16 view of a large string).
    public init?(_ string: some StringProtocol) {
        let utf16 = Array(string.utf16)
        let built = utf16.withUnsafeBufferPointer { InlineUTF16($0) }
        guard let built else { return nil }
        self = built
    }

    /// Calls `body` with the stored units, without allocating.
    public func withUnits<Result>(_ body: (UnsafeBufferPointer<UInt16>) throws -> Result) rethrows -> Result {
        try withUnsafeBytes(of: units) { raw in
            try body(UnsafeBufferPointer(start: raw.bindMemory(to: UInt16.self).baseAddress, count: Int(count)))
        }
    }

    /// Allocates; never call on the tap thread.
    public var string: String { withUnits { String(decoding: $0, as: UTF16.self) } }

    public static func == (lhs: InlineUTF16, rhs: InlineUTF16) -> Bool {
        lhs.withUnits { left in rhs.withUnits { right in left.elementsEqual(right) } }
    }

    public func hash(into hasher: inout Hasher) { withUnits { hasher.combine(bytes: UnsafeRawBufferPointer($0)) } }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/RealtimeSupport/Threads.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Dedicated threads (PLT-R203). Swift concurrency cannot express "this state belongs to the ax run-loop
// thread", so confinement is enforced by construction plus debug assertions, in exactly two audited types.

public import Foundation

/// State owned by exactly one dedicated thread (tap, inject or ax). The first `withValue` call binds the
/// owner; later calls from another thread trap in debug builds.
public final class ThreadConfined<Value>: @unchecked Sendable {
    private var value: Value
    private let owner = Atomic<UInt>(0)

    public init(_ value: Value) { self.value = value }

    @inline(__always)
    public func withValue<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        #if DEBUG
        let current = UInt(bitPattern: pthread_self())
        let (exchanged, original) = owner.compareExchange(
            expected: 0, desired: current, ordering: .relaxed)
        assert(exchanged || original == current, "ThreadConfined accessed from a second thread")
        #endif
        return try body(&value)
    }
}

/// A `Thread` with its own CFRunLoop that stays alive until `stop()`. Used for the `ax` thread (AXObserver
/// sources). The `tap` thread does NOT use this type because its run loop must contain only the tap source
/// (PLT-R303); see InputHost `TapThread`.
public final class RunLoopThread: Sendable {
    private struct State: @unchecked Sendable {
        var runLoop: CFRunLoop?
        var thread: Thread?
        var threadID: UInt = 0
    }

    public let name: String
    public let qualityOfService: QualityOfService
    private let state = Mutex(State())
    private let ready = DispatchSemaphore(value: 0)

    public init(name: String, qualityOfService: QualityOfService) {
        self.name = name
        self.qualityOfService = qualityOfService
    }

    /// Starts the thread and returns once its run loop is ready. Calling it again while the thread runs does
    /// nothing, so a second thread can never share this object's state.
    public func start() {
        let thread = Thread { [self] in
            let runLoop = CFRunLoopGetCurrent()!
            var context = CFRunLoopSourceContext()
            let keepAlive = CFRunLoopSourceCreate(nil, 0, &context)
            CFRunLoopAddSource(runLoop, keepAlive, .defaultMode)
            state.withLock {
                $0.runLoop = runLoop
                $0.threadID = UInt(bitPattern: pthread_self())
            }
            ready.signal()
            CFRunLoopRun()
            // Stopped: later `perform` and `addSource` calls become no-ops instead of targeting a dead loop.
            state.withLock { $0 = State() }
        }
        thread.name = name
        thread.qualityOfService = qualityOfService
        let alreadyStarted = state.withLock { state in
            guard state.thread == nil else { return true }
            state.thread = thread
            return false
        }
        guard !alreadyStarted else { return }
        thread.start()
        ready.wait()
    }

    /// Runs `block` on this thread's run loop (CFRunLoopPerformBlock + wake-up). Not for the tap thread.
    public func perform(_ block: @escaping @Sendable () -> Void) {
        guard let runLoop = state.withLock({ $0.runLoop }) else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    /// Adds a run-loop source (for example `AXObserverGetRunLoopSource`) from any thread.
    public func addSource(_ source: CFRunLoopSource) {
        guard let runLoop = state.withLock({ $0.runLoop }) else { return }
        CFRunLoopAddSource(runLoop, source, .defaultMode)
    }

    public func removeSource(_ source: CFRunLoopSource) {
        guard let runLoop = state.withLock({ $0.runLoop }) else { return }
        CFRunLoopRemoveSource(runLoop, source, .defaultMode)
    }

    public var isCurrentThread: Bool {
        state.withLock { $0.threadID } == UInt(bitPattern: pthread_self())
    }

    public func stop() {
        guard let runLoop = state.withLock({ $0.runLoop }) else { return }
        CFRunLoopStop(runLoop)
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/RealtimeSupport/TimerScheduler.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Timers for host services (docs/decisions/0313-testability-seams.md). Every periodic or delayed action of the
// permission monitor, secure-input monitor, tap watchdog and lifecycle backoff goes through `TimerScheduler`,
// so tests drive them deterministically with `ManualScheduler` (TestSupport) instead of sleeping.
// Never used on the tap thread (PLT-R305).

public import Dispatch

/// A scheduled one-shot or repeating timer. `cancel()` is idempotent and callable from any thread. A one-shot
/// timer stays alive until it fires or is cancelled; a repeating timer is cancelled when its last reference
/// goes away, so owners keep it in a property.
public protocol ScheduledTimer: Sendable {
    func cancel()
}

/// Schedules handlers on the scheduler's own queue (production: the utility queue, PLT-R203).
public protocol TimerScheduler: Sendable {
    /// Runs `handler` once after `delay`. `leeway` lets the OS coalesce wakeups (PLT-R803).
    func schedule(after delay: TimeSpan, leeway: TimeSpan, _ handler: @escaping @Sendable () -> Void)
        -> any ScheduledTimer
    /// Runs `handler` every `interval`, first after one interval.
    func scheduleRepeating(every interval: TimeSpan, leeway: TimeSpan, _ handler: @escaping @Sendable () -> Void)
        -> any ScheduledTimer
}

/// Production scheduler backed by `DispatchSourceTimer` on one serial queue.
public final class DispatchTimerScheduler: TimerScheduler {
    public let queue: DispatchQueue

    public init(queue: DispatchQueue) { self.queue = queue }

    public func schedule(after delay: TimeSpan, leeway: TimeSpan, _ handler: @escaping @Sendable () -> Void)
        -> any ScheduledTimer
    {
        let timer = DispatchTimer(queue: queue)
        timer.start(deadline: .now() + delay.dispatchInterval, repeating: nil, leeway: leeway) {
            timer.cancel()
            handler()
        }
        return timer
    }

    public func scheduleRepeating(
        every interval: TimeSpan, leeway: TimeSpan, _ handler: @escaping @Sendable () -> Void
    ) -> any ScheduledTimer {
        // A zero or negative interval would make the source fire continuously (PLT-R803 "no busy waiting").
        let period = max(interval, Self.minimumRepeatInterval)
        let timer = DispatchTimer(queue: queue)
        timer.start(deadline: .now() + period.dispatchInterval, repeating: period, leeway: leeway, handler)
        return timer
    }

    /// Floor for repeating intervals; callers' own periods are at least 2 s at rest (PLT-R803).
    static let minimumRepeatInterval: TimeSpan = .milliseconds(1)
}

private final class DispatchTimer: ScheduledTimer {
    private let source: any DispatchSourceTimer
    private let cancelled = Atomic<Bool>(false)

    init(queue: DispatchQueue) {
        source = DispatchSource.makeTimerSource(queue: queue)
    }

    deinit { cancel() }

    func start(
        deadline: DispatchTime, repeating: TimeSpan?, leeway: TimeSpan, _ handler: @escaping @Sendable () -> Void
    ) {
        source.schedule(
            deadline: deadline, repeating: repeating?.dispatchInterval ?? .never, leeway: leeway.dispatchInterval)
        source.setEventHandler(handler: handler)
        source.activate()
    }

    func cancel() {
        guard !cancelled.exchange(true, ordering: .sequentiallyConsistent) else { return }
        source.cancel()
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/RealtimeSupport/AtomicArray.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Fixed-size array of atomic UInt64 slots (histogram buckets, the worker outcome board). The words are allocated
// once and never resized, and every slot is accessed through `UnsafeAtomic`, so every operation after `init` is
// lock-free and allocation-free (PLT-R304).

public final class AtomicUInt64Array: @unchecked Sendable {
    // @unchecked: the pointer is written only at init and deinit; every slot is accessed atomically.
    public let count: Int
    private let words: UnsafeMutablePointer<UInt64>

    public init(count: Int, initialValue: UInt64 = 0) {
        precondition(count > 0)
        self.count = count
        words = .allocate(capacity: count)
        words.initialize(repeating: initialValue, count: count)
    }

    deinit {
        words.deinitialize(count: count)
        words.deallocate()
    }

    @inline(__always)
    private func slot(_ index: Int) -> UnsafeAtomic<UInt64> {
        precondition(index >= 0 && index < count)
        return UnsafeAtomic(at: words + index)
    }

    @inline(__always)
    public func load(_ index: Int) -> UInt64 {
        slot(index).load(ordering: .sequentiallyConsistent)
    }

    @inline(__always)
    public func store(_ value: UInt64, at index: Int) {
        slot(index).store(value, ordering: .sequentiallyConsistent)
    }

    @inline(__always)
    public func increment(_ index: Int, by amount: UInt64 = 1) {
        slot(index).wrappingAdd(amount, ordering: .relaxed)
    }

    /// Copies every slot (not atomic as a whole; each slot is read atomically).
    public func snapshot() -> [UInt64] { (0..<count).map(load) }
}
```
<!-- /include -->

## 6. Diagnostics

Owned files: `Packages/AppCore/Sources/Diagnostics/**`, `Tests/DiagnosticsTests/**`,
`Sources/TestSupport/Fakes/Diagnostics/**` (workstream W1-A). Isolation: any; the tap uses only
`TapLogRing.push`, `Log2Histogram.record`, `AtomicCounter.increment` and `CaptureController.isRecording`.

Rules: the logger accepts only `LogEvent` values (typed metadata, `StaticString`, `Redacted`); the tap never
logs, it writes `TapLogRecord`s; the report type has no field that can hold content (no `JSONValue`: the
reported app's user override is the typed `ReportedOverride` projection without summary, URL prefixes or title
patterns, [0312](../decisions/0312-report-override-projection.md)); the typing trace is the only artefact with
characters. `Log2Histogram`, `AtomicCounter`, `PlatformMetrics`, `PerBundleHistograms`, `HealthEventLog`
(memory part) and `TapLogRing` are implemented in the skeleton.

Draining the tap log: Diagnostics provides `TapLogRing` and the record format, not the drainer. The drainer is
InputHost's `TapLogDrainer` (`InputHost/Integration/TapLogDrainer.swift`, W2-A). `InputHostController` creates
it with the tap's clock and the injected `WallClock`, runs `drain()` every 30 s on the utility queue through the
injected `TimerScheduler` (`tapLogDrainInterval`), and once more when the host stops. Each drain calls
`TapLogRing.drain`, turns each `TapLogRecord` (a code and two integers, never characters) into a `HealthEvent`
or a fixed `LogEvent` note, and dates `TapLogRecord.at`, a `MonotonicInstant`, with `MonotonicToWallClock`,
anchored on both clocks at the moment of the drain (uptime stops during sleep, the wall clock does not). A
growing `droppedCount` (records lost while the ring was full) is reported as a log note with the number in
`TapLogDrainResult.newlyDropped`. The tap thread only calls `push` (PLT-R304).

### 6.1 The issue block (QA-R44)

`DiagnosticsRenderer.issueBlock` produces the block defined by
[ADR 0501](../decisions/0501-diagnostics-block-format.md), which is the contract with the issue forms and
`scripts/parse-diagnostics.py`. It is a fenced block (info string `text`); the first line inside is the header
`<slug>-diagnostics v1` with the slug read from the bundle; then one `key: value` per line, ASCII keys, values
without newlines, lists comma-separated, at most 200 lines. The labeller reads `report.bundleId` (else
`focus.bundleId`) -> `app:<bundle>`, the major of `macos.version` -> `macos:<major>`, `hw.arch` ->
`arch:arm64|x86_64`, `input.method` -> `method:telex|vni`. Keys in `DiagnosticsBlockKey` never change within a
format version; new keys may be added; a breaking change bumps the version. The full key list and an example
are in ADR 0501, including the keys added in wave 1 (`report.symptomDetail`, `ui.locale`, `permission.*`,
`tap.*`, `focus.*`, `rule.*`, `settings.*`, `appMode.*`, `latency.*`, `counters.*`, `probe.*`, `conflicts`,
`health.*`). `report.symptom` keeps the six PRD-R47 chip values: `lettersOutOfOrder` maps to `other` and
`nothingTyped` to `cannotType`, and `report.symptomDetail` carries the exact `DiagnosticsReport.Symptom`.

<!-- include: Packages/AppCore/Sources/Diagnostics/Identity.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later

public import AppModel

/// Build metadata read from the bundle by the App's `Brand` helper and injected into AppCore. Bundle metadata
/// is not user content, so it is an allowed metadata type for logs and reports (PLT-R901, PLT-R902).
public struct AppIdentity: Sendable, Hashable, Codable {
    public var displayName: String
    public var slug: String
    public var bundleIdentifier: String
    public var version: String
    public var build: String
    public var channel: UpdateChannel

    public init(
        displayName: String, slug: String, bundleIdentifier: String, version: String, build: String,
        channel: UpdateChannel
    ) {
        self.displayName = displayName
        self.slug = slug
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.build = build
        self.channel = channel
    }
}

/// Host metadata for reports (PLT-R1202).
public struct SystemInfo: Sendable, Hashable, Codable {
    public var macOSVersion: String  // "27.1"
    public var macOSBuild: String  // "26B123"
    public var architecture: String  // "arm64" or "x86_64"
    public var modelIdentifier: String  // sysctl hw.model
    public var uiLanguage: InterfaceLanguage
    public var systemLanguage: String  // BCP 47 tag of the macOS primary language

    public init(
        macOSVersion: String, macOSBuild: String, architecture: String, modelIdentifier: String,
        uiLanguage: InterfaceLanguage, systemLanguage: String
    ) {
        self.macOSVersion = macOSVersion
        self.macOSBuild = macOSBuild
        self.architecture = architecture
        self.modelIdentifier = modelIdentifier
        self.uiLanguage = uiLanguage
        self.systemLanguage = systemLanguage
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/Diagnostics/Redaction.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later

internal import AppModel
internal import CryptoKit
internal import Security

/// Per-install random salt (32 bytes) for hashed redaction (PLT-R902). Stored in the app's user defaults
/// domain (not in the settings folder) so exports never carry it.
public struct RedactionSalt: Sendable, Hashable {
    public let bytes: [UInt8]
    public init(bytes: [UInt8]) {
        precondition(bytes.count == 32, "salt must be 32 bytes")
        self.bytes = bytes
    }

    /// CSPRNG (`SecRandomCopyBytes`). Falls back to the system generator (`arc4random_buf`, also a CSPRNG) in
    /// the practically impossible case that Security reports an error.
    public static func random() -> RedactionSalt {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        if status != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            bytes = bytes.map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        return RedactionSalt(bytes: bytes)
    }
}

/// The only way a dynamic string enters a log record (PLT-R902). Either a salted, truncated SHA-256
/// (`h:3fa9c1d2e4b5a697`) or a fixed marker. There is no initializer that keeps the original text.
public struct Redacted: Sendable, Hashable, Codable, CustomStringConvertible {
    public let description: String
    private init(description: String) { self.description = description }

    /// HMAC-SHA-256 keyed with the install salt (the salted SHA-256 construction that is not open to length
    /// extension), truncated to 8 bytes and written as `h:` plus 16 lowercase hex digits. The same value hashes
    /// to the same marker within one install, so logs can correlate events without revealing the value.
    public static func hashed(_ value: some StringProtocol, salt: RedactionSalt) -> Redacted {
        let code = HMAC<SHA256>.authenticationCode(for: Array(value.utf8), using: SymmetricKey(data: salt.bytes))
        return Redacted(description: "h:" + HexEncoding.lowercase(code.prefix(8)))
    }

    public static let dropped = Redacted(description: "<dropped>")
}

enum HexEncoding {
    static func lowercase(_ bytes: some Sequence<UInt8>) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var output: [UInt8] = []
        for byte in bytes {
            output.append(digits[Int(byte >> 4)])
            output.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: output, as: UTF8.self)
    }
}

/// Sanitising of the few free `String` fields that typed metadata still carries (bundle metadata, AX roles,
/// version strings). Logs accept only token-shaped values (PLT-R902); reports keep metadata but never let a
/// value break the line format (ADR 0501 rule 2).
enum MetadataText {
    /// The value if it is a metadata token (ASCII letters, digits and `. _ - + :`, at most `maxLength`
    /// characters), else nil. Spaces, non-ASCII letters and punctuation are rejected, so prose cannot pass.
    static func token(_ value: String, maxLength: Int = 64) -> String? {
        guard !value.isEmpty, value.utf8.count <= maxLength else { return nil }
        let allowed = value.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2E || byte == 0x5F || byte == 0x2D || byte == 0x2B || byte == 0x3A
        }
        return allowed ? value : nil
    }

    /// `token` or the fixed drop marker, for log fields.
    static func logToken(_ value: String) -> String {
        token(value) ?? Redacted.dropped.description
    }

    /// One line of at most `maxLength` characters: control characters and line or paragraph separators
    /// (everything Python's `splitlines` breaks on) become spaces, surrounding whitespace is trimmed and
    /// leading backticks or tildes are removed so a value can never close a fenced block.
    static func singleLine(_ value: String, maxLength: Int = 200) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: scalars.append(" ")
            default: scalars.append(scalar)
            }
        }
        var line = Substring(String(scalars).prefix(maxLength))
        while let first = line.first, first == "`" || first == "~" || first.isWhitespace { line = line.dropFirst() }
        while let last = line.last, last.isWhitespace { line = line.dropLast() }
        return String(line)
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/Diagnostics/LogEvent.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Typed logging API (PLT-R902). Every payload is an enumerated metadata type. Strings appear only as
// `StaticString` literals or `Redacted`. A lint (scripts/lint.sh, CI track) rejects string interpolation in
// any call to `log(...)`.

public import AppModel

public enum LogLevel: UInt8, Sendable, Hashable, Codable, Comparable {
    case debug, info, notice, error, fault
    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum LogCategory: String, Sendable, Hashable, Codable, CaseIterable {
    case lifecycle, tap, pipeline, injection, focus, rules, settings, permissions, secureInput, updates,
        diagnostics, ui
}

public enum LogEvent: Sendable {
    case lifecycle(LifecycleEvent)
    case health(HealthEvent)
    case hostState(from: HostStateCode, to: HostStateCode)
    case permission(PermissionKind, PermissionState)
    case settings(SettingsEvent)
    case rules(RulesEvent)
    case update(UpdateEvent)
    /// A fixed message. `StaticString` guarantees a compile-time literal.
    case note(StaticString, category: LogCategory)
    /// A fixed message plus one redacted dynamic value.
    case redacted(StaticString, Redacted, category: LogCategory)

    public enum LifecycleEvent: Sendable, Hashable {
        case launched(AppIdentity)
        case safeModeEntered(recentCrashes: Int)
        case terminating
        case tapCreated
        case tapRemoved
    }

    public enum SettingsEvent: Sendable, Hashable {
        case loaded(schemaVersion: Int, migratedFrom: Int?)
        case recoveredFromBackup(file: SettingsFileCode)
        case corruptFileQuarantined(file: SettingsFileCode)
        case newerSchemaReadOnly(file: SettingsFileCode, schemaVersion: Int)
        case writeFailed(file: SettingsFileCode, errno: Int32)
        case imported(macros: Int, appEntries: Int, overrides: Int)
        case exported
    }

    public enum RulesEvent: Sendable, Hashable {
        case loaded(rules: Int, overrides: Int)
        case invalidShippedFileUsingEmbeddedDefaults
        case tie(winner: RuleID, loser: RuleID)
        case resolved(bundle: BundleKey, rule: RuleID?, strategy: InjectionStrategy, source: DecisionSource)
    }

    public enum UpdateEvent: Sendable, Hashable {
        case checkStarted(manual: Bool)
        case updateFound(build: String)
        case installScheduledOnQuit
        /// The keyboard was idle and secure input off: the update installs and relaunches now (PLT-R1105).
        case installingNow
        case failed(code: Int)
    }
}

/// Settings file identifiers for logs (no paths).
public enum SettingsFileCode: String, Sendable, Hashable, Codable {
    case settings, appModes, ruleOverrides, macros
}

/// Logging entry point for main, ax, inject and utility threads. Never blocks: the record is handed to the
/// utility queue. The tap thread does not use this API; it writes `TapLogRecord`s (PLT-R304).
public protocol DiagnosticsLogging: Sendable {
    func log(_ event: LogEvent, level: LogLevel)
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/Diagnostics/Health.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later

public import AppModel
public import Foundation
internal import RealtimeSupport

/// Metadata-only health event (PLT-R1206).
public struct HealthEvent: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        case tapTimeout, tapDisabledByUserInput, tapReenabled, watchdogTrip, flush, fallbackActivated,
            axCircuitBreakerTrip, echoLoss, postingBroken, permissionTransition, secureInputEpisode,
            ruleLoadError, ruleTie, placeholderResidue, pasteRestoreSkipped, generationDiscard,
            settingsRecovered, settingsNewerSchema, safeModeEntered,
            /// PLT-R397B: short secure-input episodes keep ending while the user types (`.count`).
            secureInputBursts
    }

    public enum Detail: Sendable, Hashable, Codable {
        case count(Int)
        case durationMicroseconds(UInt64)
        case permission(PermissionKind, from: PermissionState, to: PermissionState)
        case fallback(from: InjectionStrategy, to: InjectionStrategy)
        case secureInput(holder: BundleKey?, holderKind: SecureInputHolder.Kind?, durationMilliseconds: UInt64)
        case failOpen(FailOpenReason)
    }

    public var kind: Kind
    public var at: Date
    public var bundle: BundleKey?
    public var rule: RuleID?
    public var detail: Detail?

    public init(kind: Kind, at: Date, bundle: BundleKey? = nil, rule: RuleID? = nil, detail: Detail? = nil) {
        self.kind = kind
        self.at = at
        self.bundle = bundle
        self.rule = rule
        self.detail = detail
    }
}

/// PLT-R397B thresholds. An episode shorter than `shortEpisode` that key evidence ended (PLT-R398B) happened while the
/// user was typing: the 2 s poll (PLT-R395) saw it start less than a second before the next key reached the tap. A
/// password typed into a secure field lasts longer, and an episode a poll ends lasts about a poll interval. In the
/// product owner's trace of 14/11/2026 a background process produced three such episodes within 40 s. `threshold`
/// of them ending within `window` record one `secureInputBursts` event; the next can follow one `window` later.
public enum SecureInputBursts {
    public static let shortEpisode: TimeInterval = 1
    public static let threshold = 3
    public static let window: TimeInterval = 600
}

/// In-memory ring of recent health events (the report shows the last 50, PLT-R1202), mirrored to the log
/// file so events from before a crash remain explainable (PRD-R46). Not used on the tap thread.
/// Implemented in the skeleton (docs/decisions/0313-testability-seams.md); W1-A adds the log-file mirror.
public final class HealthEventLog: Sendable {
    /// The report lists the last 50 health events (PLT-R1202).
    public static let reportedEventCount = 50
    /// Events kept in memory, and read back from earlier sessions' logs, for the report's 24-hour counters.
    public static let defaultCapacity = 256

    private struct Ring {
        var events: [HealthEvent] = []
        var next = 0
    }

    /// The secure-input episode in progress (PLT-R1206).
    private struct Episode {
        var holder: BundleKey?
        var holderKind: SecureInputHolder.Kind?
        var start: Date
        /// Key evidence ended it (PLT-R398B): the user was typing.
        var endedByKey = false
    }

    /// Ends of short episodes that typing ended, and the last burst event (PLT-R397B).
    private struct Bursts {
        var ends: [Date] = []
        var reportedAt: Date?
    }

    private let capacity: Int
    private let ring = Mutex(Ring())
    private let episode = Mutex<Episode?>(nil)
    private let bursts = Mutex(Bursts())
    private let mirror: (any DiagnosticsLogging)?

    /// `mirror` (production: the `DiagnosticsLogger`) receives every recorded event as `.health`, at error
    /// level for events that lose or risk losing keys and notice level otherwise (PRD-R46, PLT-R1206).
    public init(capacity: Int = HealthEventLog.defaultCapacity, mirror: (any DiagnosticsLogging)? = nil) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.mirror = mirror
    }

    public func record(_ event: HealthEvent) {
        ring.withLock { ring in
            if ring.events.count < capacity {
                ring.events.append(event)
            } else {
                ring.events[ring.next] = event
            }
            ring.next = (ring.next + 1) % capacity
        }
        mirror?.log(.health(event), level: event.kind.logLevel)
    }

    /// Secure-input episodes (PLT-R1206): `active` with the likely holder starts an episode; the end of it, or a
    /// different holder, records one `secureInputEpisode` event with the holder's bundle ID and kind and the
    /// duration in milliseconds (never negative when the wall clock was set back). The holder's name is never
    /// recorded (PLT-R901).
    public func noteSecureInput(_ holder: SecureInputHolder?, active: Bool, at now: Date) {
        let ended: Episode? = episode.withLock { current in
            let next = active ? Episode(holder: holder?.bundle, holderKind: holder?.kind, start: now) : nil
            if let running = current, let next, running.holder == next.holder, running.holderKind == next.holderKind {
                return nil
            }
            let previous = current
            current = next
            return previous
        }
        guard let ended else { return }
        let seconds = max(0, now.timeIntervalSince(ended.start))
        record(
            HealthEvent(
                kind: .secureInputEpisode, at: now,
                detail: .secureInput(
                    holder: ended.holder, holderKind: ended.holderKind,
                    durationMilliseconds: UInt64((seconds * 1_000).rounded()))))
        if ended.endedByKey && seconds < SecureInputBursts.shortEpisode { noteShortEpisode(endedAt: now) }
    }

    /// PLT-R398B: the tap processed a key while paused for secure input; the episode in progress ended while the
    /// user typed. Called before the host state change that ends it.
    public func noteSecureInputEndedByKey() {
        episode.withLock { $0?.endedByKey = true }
    }

    /// PLT-R397B: `SecureInputBursts.threshold` short episodes that typing ended, within `window`, record one
    /// content-free `secureInputBursts` event (no holder: PLT-R396 names whatever app was frontmost).
    private func noteShortEpisode(endedAt now: Date) {
        let count: Int? = bursts.withLock { state in
            state.ends.removeAll { now.timeIntervalSince($0) > SecureInputBursts.window }
            state.ends.append(now)
            if let last = state.reportedAt, now.timeIntervalSince(last) < SecureInputBursts.window { return nil }
            guard state.ends.count >= SecureInputBursts.threshold else { return nil }
            state.reportedAt = now
            let count = state.ends.count
            state.ends.removeAll()
            return count
        }
        if let count { record(HealthEvent(kind: .secureInputBursts, at: now, detail: .count(count))) }
    }

    /// Newest last, at most `limit` events.
    public func recent(limit: Int) -> [HealthEvent] {
        ring.withLock { ring in
            let ordered =
                ring.events.count < capacity
                ? ring.events : Array(ring.events[ring.next...] + ring.events[..<ring.next])
            return Array(ordered.suffix(max(0, limit)))
        }
    }

    /// The events a report is assembled from (PLT-R1202, PRD-R46): the earlier sessions' events (`earlier`, asked
    /// for at most this ring's capacity) then this session's, newest last. The report lists the last 50 of them;
    /// its 24-hour tap counters see all of them, so many later events do not hide a recent tap timeout.
    public func reportSource(earlier: (Int) -> [HealthEvent]) -> [HealthEvent] {
        HealthEvent.reportList(earlier: earlier(capacity), current: recent(limit: capacity), limit: 2 * capacity)
    }

    /// Count of events of `kind` within `window` before `now` (PLT-R330 "more than 3 within 10 minutes").
    public func count(of kind: HealthEvent.Kind, within window: TimeInterval, now: Date) -> Int {
        let start = now.addingTimeInterval(-window)
        return ring.withLock { ring in
            ring.events.reduce(0) { $0 + ($1.kind == kind && $1.at >= start && $1.at <= now ? 1 : 0) }
        }
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/Diagnostics/HealthEventRestore.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Health events of earlier sessions (PRD-R46): the log keeps every event as a `health.<kind>` record with the
// metadata fields of `HealthEvent.logFields`, so a crash or a tap timeout from before this launch can be read
// back and listed in the report's last 50 events (PLT-R1202). Metadata only (PLT-R1206).

internal import AppModel
internal import Foundation

extension HealthEvent {
    static let recordCodePrefix = "health."

    /// The event a `health.<kind>` log record was written from, or nil for other records, unknown kinds and
    /// records without a readable time. A detail field that does not parse leaves the detail empty.
    public init?(record: LogRecord) {
        guard record.code.hasPrefix(Self.recordCodePrefix),
            let kind = Kind(rawValue: String(record.code.dropFirst(Self.recordCodePrefix.count)))
        else { return nil }
        let fields = record.fields.compactMapValues(\.stringValue)
        guard let at = fields["eventAt"].flatMap({ try? Date($0, strategy: .iso8601) }) else { return nil }
        self.init(
            kind: kind, at: at, bundle: fields["bundle"].flatMap(BundleKey.init(rawValue:)),
            rule: fields["rule"].flatMap(RuleID.init(rawValue:)), detail: Self.detail(fields))
    }

    /// The inverse of the detail part of `detailPairs`.
    private static func detail(_ fields: [String: String]) -> Detail? {
        if let count = fields["count"] { return Int(count).map(Detail.count) }
        if let duration = fields["durationUs"] { return UInt64(duration).map(Detail.durationMicroseconds) }
        if let permission = fields["permission"] {
            guard let kind = PermissionKind(rawValue: permission),
                let from = fields["from"].flatMap(PermissionState.init(rawValue:)),
                let to = fields["to"].flatMap(PermissionState.init(rawValue:))
            else { return nil }
            return .permission(kind, from: from, to: to)
        }
        if let from = fields["fromStrategy"] {
            guard let from = InjectionStrategy(rawValue: from),
                let to = fields["toStrategy"].flatMap(InjectionStrategy.init(rawValue:))
            else { return nil }
            return .fallback(from: from, to: to)
        }
        if let duration = fields["durationMs"] {
            guard let milliseconds = UInt64(duration) else { return nil }
            return .secureInput(
                holder: fields["holder"].flatMap(BundleKey.init(rawValue:)),
                holderKind: fields["holderKind"].flatMap(SecureInputHolder.Kind.init(rawValue:)),
                durationMilliseconds: milliseconds)
        }
        return fields["failOpen"].flatMap(FailOpenReason.init(rawValue:)).map(Detail.failOpen)
    }

    /// The report's health events (PLT-R1202 "last 50 health events", PRD-R46): earlier sessions' events read
    /// from the log, then this session's from memory, newest last, at most `limit`. An earlier event that is
    /// also among the current ones (the wall clock was set back) is listed once.
    public static func reportList(earlier: [HealthEvent], current: [HealthEvent], limit: Int) -> [HealthEvent] {
        let currentLines = Set(current.map(\.summaryLine))
        let previous = earlier.filter { !currentLines.contains($0.summaryLine) }
        return Array((previous + current).suffix(max(0, limit)))
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/Diagnostics/Metrics.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Always-on, content-free, lock-free histograms (PLT-R801): fixed memory, log2 buckets, safe on the tap.
// Implemented in the skeleton because the pipeline and the worker record into them on every event
// (docs/decisions/0313-testability-seams.md); workstream W1-A owns, benchmarks and may optimise them. W3-A added
// the gate-aligned sub-buckets of the decide-to-posted histograms and `PlatformMetrics.reset()` for the
// integration hooks (ADR 0502).

public import AppModel
internal import RealtimeSupport

/// 64 log2 buckets of nanoseconds (bucket i counts values in [2^i, 2^(i+1)); bucket 0 also counts 0), one
/// `Atomic<UInt64>` each. A histogram created with `subBuckets: true` also counts every value up to
/// `LatencySubBuckets.upperNanoseconds` in the fixed linear buckets of `LatencySubBuckets`, so a percentile
/// decision against the 8.1 gates is exact (a log2 bucket from 2.1 to 4.2 ms straddles the 3 ms T2 gate).
public final class Log2Histogram: Sendable {
    public static let bucketCount = 64
    private let buckets = AtomicUInt64Array(count: Log2Histogram.bucketCount)
    private let subBuckets: AtomicUInt64Array?

    public init(subBuckets: Bool = false) {
        self.subBuckets = subBuckets ? AtomicUInt64Array(count: LatencySubBuckets.count) : nil
    }

    /// Lock-free, allocation-free; allowed on the tap thread (PLT-R304). Two relaxed increments at most.
    @inline(__always)
    public func record(nanoseconds: UInt64) {
        let index = nanoseconds == 0 ? 0 : (UInt64.bitWidth - 1 - nanoseconds.leadingZeroBitCount)
        buckets.increment(index)
        if let subBuckets, let fine = LatencySubBuckets.index(nanoseconds: nanoseconds) { subBuckets.increment(fine) }
    }

    /// Zeroes every bucket with atomic stores. Safe while other threads record: an increment that races with
    /// the store lands before it (and is cleared) or after it (and is kept); nothing tears.
    public func reset() {
        for index in 0..<Self.bucketCount { buckets.store(0, at: index) }
        guard let subBuckets else { return }
        for index in 0..<LatencySubBuckets.count { subBuckets.store(0, at: index) }
    }

    public func snapshot() -> HistogramSnapshot {
        HistogramSnapshot(
            buckets: buckets.snapshot(),
            subBuckets: subBuckets.map {
                SubBucketSnapshot(segments: LatencySubBuckets.segments, counts: $0.snapshot())
            }
        )
    }
}

/// Linear sub-buckets of the decide-to-posted histograms (T2, T3; 02-platform.md 8.1). Bucket i of a segment
/// counts values in (start + i * width, start + (i + 1) * width], upper end included, so "p99 <= gate" is decided
/// exactly whenever the gate is a bucket edge. Every 8.1 value up to 25 ms is one: the T2 target 0.5 and 2 ms and
/// gate 3 ms, the T3 target 2 and 8 ms and gate 15 ms, the T4 gate 10 ms, and the Intel values (1.5 times) 4.5
/// and 22.5 ms. Resolution: 10 us to 1 ms, 50 us to 5 ms, 250 us to 25 ms (260 buckets, 2 KiB per histogram).
public enum LatencySubBuckets {
    public struct Segment: Sendable, Hashable, Codable {
        /// Inclusive upper end; the segment starts just above the previous segment's end (0 for the first).
        public var upToNanoseconds: UInt64
        public var widthNanoseconds: UInt64

        public init(upToNanoseconds: UInt64, widthNanoseconds: UInt64) {
            self.upToNanoseconds = upToNanoseconds
            self.widthNanoseconds = widthNanoseconds
        }
    }

    public static let segments: [Segment] = [
        Segment(upToNanoseconds: 1_000_000, widthNanoseconds: 10_000),
        Segment(upToNanoseconds: 5_000_000, widthNanoseconds: 50_000),
        Segment(upToNanoseconds: 25_000_000, widthNanoseconds: 250_000),
    ]
    public static let count = 260
    public static let upperNanoseconds: UInt64 = 25_000_000

    /// The bucket of `nanoseconds` (0 counts in the first bucket), nil above `upperNanoseconds`. Constants only:
    /// no array access, no allocation, safe on the tap thread. `LatencySubBucketTests` pins it to `segments`.
    @inline(__always)
    static func index(nanoseconds: UInt64) -> Int? {
        if nanoseconds <= 1_000_000 { return nanoseconds == 0 ? 0 : Int((nanoseconds - 1) / 10_000) }
        if nanoseconds <= 5_000_000 { return 100 + Int((nanoseconds - 1_000_001) / 50_000) }
        if nanoseconds <= 25_000_000 { return 180 + Int((nanoseconds - 5_000_001) / 250_000) }
        return nil
    }
}

/// Counts of a histogram's linear sub-buckets with their layout, so a reader needs no knowledge of
/// `LatencySubBuckets` (and reads a future layout too).
public struct SubBucketSnapshot: Sendable, Hashable, Codable {
    /// A reader refuses layouts with more buckets than this (the JSON may come from another process).
    static let maximumBucketCount = 100_000

    public var segments: [LatencySubBuckets.Segment]
    public var counts: [UInt64]

    public init(segments: [LatencySubBuckets.Segment], counts: [UInt64]) {
        self.segments = segments
        self.counts = counts
    }

    /// Where the rank-th smallest sample lies: the bucket's bounds (lower excluded, upper included), the samples
    /// in earlier buckets and the samples in this one. Nil when the sub-buckets hold fewer than `rank` samples or
    /// the layout does not match the counts.
    public struct Position: Sendable, Hashable {
        public var lower: UInt64
        public var upper: UInt64
        public var before: UInt64
        public var count: UInt64
    }

    public func position(ofRank rank: UInt64) -> Position? {
        guard rank > 0, isConsistent else { return nil }
        var index = 0
        var start: UInt64 = 0
        var before: UInt64 = 0
        for segment in segments {
            var lower = start
            while lower < segment.upToNanoseconds {
                let count = counts[index]
                if count > 0 && before + count >= rank {
                    return Position(
                        lower: lower, upper: lower + segment.widthNanoseconds, before: before, count: count)
                }
                before += count
                lower += segment.widthNanoseconds
                index += 1
            }
            start = segment.upToNanoseconds
        }
        return nil
    }

    /// Inclusive upper end of the last segment; 0 without segments.
    public var upperNanoseconds: UInt64 { segments.last?.upToNanoseconds ?? 0 }

    /// Segments ascend, every width divides its segment, and the bucket count matches `counts`.
    public var isConsistent: Bool {
        var start: UInt64 = 0
        var total = 0
        for segment in segments {
            guard segment.widthNanoseconds > 0, segment.upToNanoseconds > start,
                (segment.upToNanoseconds - start) % segment.widthNanoseconds == 0
            else { return false }
            let buckets = (segment.upToNanoseconds - start) / segment.widthNanoseconds
            guard buckets <= UInt64(Self.maximumBucketCount - total) else { return false }
            total += Int(buckets)
            start = segment.upToNanoseconds
        }
        return !segments.isEmpty && total == counts.count
    }
}

public struct HistogramSnapshot: Sendable, Hashable, Codable {
    public var buckets: [UInt64]
    /// Linear sub-buckets (decide-to-posted histograms only). Nil for the other histograms and in JSON written
    /// before W3-A, which still decodes; a nil value is left out of the JSON.
    public var subBuckets: SubBucketSnapshot?

    public init(buckets: [UInt64], subBuckets: SubBucketSnapshot? = nil) {
        self.buckets = buckets
        self.subBuckets = subBuckets
    }

    public static let empty = HistogramSnapshot(buckets: Array(repeating: 0, count: Log2Histogram.bucketCount))
    public var count: UInt64 { buckets.reduce(0, +) }

    /// Upper bound (ns) of the log2 bucket containing the given fraction (0.5 = p50, 0.99 = p99). Nil when empty
    /// or when `fraction` is outside 0...1. Ignores the sub-buckets (the issue block keeps its log2 values);
    /// `precisePercentile` uses them.
    public func percentile(_ fraction: Double) -> UInt64? {
        guard let rank = rank(fraction) else { return nil }
        var seen: UInt64 = 0
        for (index, value) in buckets.enumerated() {
            seen += value
            if seen >= rank { return index >= 63 ? UInt64.max : (UInt64(1) << UInt64(index + 1)) - 1 }
        }
        return UInt64.max
    }

    /// Upper bound (ns) of the finest bucket containing the given fraction: the sub-bucket when the value lies in
    /// their range, so the answer is at most one sub-bucket width above the true value and never on the wrong side
    /// of an 8.1 gate; otherwise the log2 bucket (`percentile`).
    public func precisePercentile(_ fraction: Double) -> UInt64? {
        guard let rank = rank(fraction) else { return nil }
        if let position = subBuckets?.position(ofRank: rank) { return position.upper }
        return percentile(fraction)
    }

    /// Nearest rank of a fraction among the recorded samples (1-based); nil when empty or outside 0...1.
    public func rank(_ fraction: Double) -> UInt64? {
        let total = count
        guard total > 0, (0.0...1.0).contains(fraction) else { return nil }
        return max(1, UInt64((Double(total) * fraction).rounded(.up)))
    }
}

/// Monotonic counter safe on every thread.
public final class AtomicCounter: Sendable {
    private let storage = Atomic<UInt64>(0)
    public init() {}
    @inline(__always)
    public func increment(by amount: UInt64 = 1) { storage.wrappingAdd(amount, ordering: .relaxed) }
    public var value: UInt64 { storage.load(ordering: .relaxed) }
    /// Atomic store of zero; an increment racing with it is kept or cleared, never torn.
    public func reset() { storage.store(0, ordering: .relaxed) }
}

/// Platform budget metrics of 02-platform.md 8.1. Probe-tagged events (PLT-R810) go to `probe*` only, so user
/// metrics exclude them.
public final class PlatformMetrics: Sendable {
    public let callbackDuration = Log2Histogram()  // T1
    public let decideToPosted = Log2Histogram(subBuckets: true)  // T2
    public let decideToPostedWithAX = Log2Histogram(subBuckets: true)  // T3
    public let echoRoundTrip = Log2Histogram()
    public let heldWait = Log2Histogram()  // T5
    public let focusRefresh = Log2Histogram()  // T6
    public let probeDecideToPosted = Log2Histogram(subBuckets: true)  // T2 for latency-probe events only
    public let flushes = AtomicCounter()
    public let tapTimeouts = AtomicCounter()
    public let fallbackActivations = AtomicCounter()
    public let echoLosses = AtomicCounter()
    public let watchdogTrips = AtomicCounter()
    /// Events that could not be delivered after posting broke (ADR 0311): counted, never silent.
    public let lostWhilePostingBroken = AtomicCounter()
    /// AX call durations aggregated per bundle (PLT-R801); recorded on the ax and inject threads.
    public let axCallDurations = PerBundleHistograms()

    public init() {}

    /// Zeroes every histogram and counter (the integration hooks' `resetMetrics`, so a measured workload starts
    /// clean, ADR 0502). Atomic stores only, safe while the tap and the worker record: an event recorded during
    /// the reset is either cleared or kept, never half-counted. The per-bundle AX histograms are emptied too.
    public func reset() {
        for histogram in histograms { histogram.reset() }
        for counter in counters { counter.reset() }
        axCallDurations.reset()
    }

    private var histograms: [Log2Histogram] {
        [
            callbackDuration, decideToPosted, decideToPostedWithAX, echoRoundTrip, heldWait, focusRefresh,
            probeDecideToPosted,
        ]
    }

    private var counters: [AtomicCounter] {
        [flushes, tapTimeouts, fallbackActivations, echoLosses, watchdogTrips, lostWhilePostingBroken]
    }

    public func snapshot() -> MetricsSnapshot {
        MetricsSnapshot(
            callbackDuration: callbackDuration.snapshot(), decideToPosted: decideToPosted.snapshot(),
            decideToPostedWithAX: decideToPostedWithAX.snapshot(), echoRoundTrip: echoRoundTrip.snapshot(),
            heldWait: heldWait.snapshot(), focusRefresh: focusRefresh.snapshot(), flushes: flushes.value,
            tapTimeouts: tapTimeouts.value, fallbackActivations: fallbackActivations.value,
            echoLosses: echoLosses.value, watchdogTrips: watchdogTrips.value,
            lostWhilePostingBroken: lostWhilePostingBroken.value)
    }
}

/// Bounded map of bundle -> histogram (at most `capacity` bundles, least recently used evicted). Uses a lock;
/// never touched by the tap thread.
public final class PerBundleHistograms: Sendable {
    private struct State {
        var histograms: [BundleKey: Log2Histogram] = [:]
        var order: [BundleKey] = []  // least recently used first
    }

    private let capacity: Int
    private let state = Mutex(State())

    public init(capacity: Int = 64) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public func record(_ bundle: BundleKey, nanoseconds: UInt64) {
        let histogram: Log2Histogram = state.withLock { state in
            if let existing = state.histograms[bundle] {
                state.order.removeAll { $0 == bundle }
                state.order.append(bundle)
                return existing
            }
            if state.order.count >= capacity {
                let evicted = state.order.removeFirst()
                state.histograms[evicted] = nil
            }
            let created = Log2Histogram()
            state.histograms[bundle] = created
            state.order.append(bundle)
            return created
        }
        histogram.record(nanoseconds: nanoseconds)
    }

    public func snapshot() -> [BundleKey: HistogramSnapshot] {
        state.withLock { $0.histograms.mapValues { $0.snapshot() } }
    }

    /// Forgets every bundle (`PlatformMetrics.reset()`).
    public func reset() {
        state.withLock { state in
            state.histograms = [:]
            state.order = []
        }
    }
}

public struct MetricsSnapshot: Sendable, Hashable, Codable {
    public var callbackDuration: HistogramSnapshot
    public var decideToPosted: HistogramSnapshot
    public var decideToPostedWithAX: HistogramSnapshot
    public var echoRoundTrip: HistogramSnapshot
    public var heldWait: HistogramSnapshot
    public var focusRefresh: HistogramSnapshot
    public var flushes: UInt64
    public var tapTimeouts: UInt64
    public var fallbackActivations: UInt64
    public var echoLosses: UInt64
    public var watchdogTrips: UInt64
    public var lostWhilePostingBroken: UInt64

    public init(
        callbackDuration: HistogramSnapshot, decideToPosted: HistogramSnapshot,
        decideToPostedWithAX: HistogramSnapshot, echoRoundTrip: HistogramSnapshot, heldWait: HistogramSnapshot,
        focusRefresh: HistogramSnapshot, flushes: UInt64, tapTimeouts: UInt64, fallbackActivations: UInt64,
        echoLosses: UInt64, watchdogTrips: UInt64, lostWhilePostingBroken: UInt64
    ) {
        self.callbackDuration = callbackDuration
        self.decideToPosted = decideToPosted
        self.decideToPostedWithAX = decideToPostedWithAX
        self.echoRoundTrip = echoRoundTrip
        self.heldWait = heldWait
        self.focusRefresh = focusRefresh
        self.flushes = flushes
        self.tapTimeouts = tapTimeouts
        self.fallbackActivations = fallbackActivations
        self.echoLosses = echoLosses
        self.watchdogTrips = watchdogTrips
        self.lostWhilePostingBroken = lostWhilePostingBroken
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/Diagnostics/TapLog.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Fixed-size records the tap thread writes into a lock-free ring (PLT-R304 "writing fixed-size records into a
// lock-free log ring buffer"). The utility queue drains them into health events and the log file.

internal import AppModel
public import RealtimeSupport

public enum TapLogCode: UInt16, Sendable, Hashable, Codable, BitwiseCopyable {
    case tapDisabledByTimeout = 1
    case tapDisabledByUserInput
    case tapReenabled
    case jobQueueFull
    case flushRequested
    case echoMissing
    case secureInputResumedByKey  // PLT-R398B
    case layoutMismatch  // debug cross-check, keycode + layout only (PLT-R363)
    case unknownEventType
    case callbackOverBudget
    /// PLT-R397A: a keyUp whose keyDown the tap never saw (`a` = key code); the composition was reset.
    case unseenKeyUp
}

public struct TapLogRecord: Sendable, Hashable, BitwiseCopyable {
    public var code: TapLogCode
    public var at: MonotonicInstant
    /// Code-specific integers (keycode, counts, durations). Never characters.
    public var a: UInt64
    public var b: UInt64

    public init(code: TapLogCode, at: MonotonicInstant, a: UInt64 = 0, b: UInt64 = 0) {
        self.code = code
        self.at = at
        self.a = a
        self.b = b
    }
}

/// Single producer (tap), single consumer (utility drain). Implemented in the skeleton
/// (docs/decisions/0313-testability-seams.md).
public final class TapLogRing: Sendable {
    private let ring: SPSCRing<TapLogRecord>
    private let dropped = Atomic<UInt64>(0)

    /// `capacity` is rounded up to a power of two.
    public init(capacity: Int = 1024) {
        var size = 1
        while size < max(1, capacity) { size <<= 1 }
        ring = SPSCRing(capacity: size)
    }

    /// Tap thread. Drops the record (and counts the drop) when full.
    @inline(__always)
    public func push(_ record: TapLogRecord) {
        if !ring.push(record) { dropped.wrappingAdd(1, ordering: .relaxed) }
    }

    /// Utility queue.
    public func drain(_ body: (TapLogRecord) -> Void) {
        while let record = ring.pop() { body(record) }
    }

    public var droppedCount: UInt64 { dropped.load(ordering: .relaxed) }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/Diagnostics/LogStore.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later

public import AppModel
public import Foundation
internal import RealtimeSupport

/// PLT-R903: `~/Library/Logs/<folder>/`, dir 0700, files 0600, JSON lines, 5 files of 1 MB, 14 days.
public struct LogStorePolicy: Sendable, Hashable {
    public var directory: URL
    public var maxFileBytes: Int
    public var maxFiles: Int
    public var retention: TimeInterval

    public init(directory: URL, maxFileBytes: Int = 1_000_000, maxFiles: Int = 5, retention: TimeInterval = 14 * 86_400)
    {
        self.directory = directory
        self.maxFileBytes = maxFileBytes
        self.maxFiles = maxFiles
        self.retention = retention
    }
}

/// One JSON line in the log file.
public struct LogRecord: Sendable, Codable {
    public var at: Date
    public var level: LogLevel
    public var category: LogCategory
    /// Stable machine code of the event, for example `health.flush` or `settings.recoveredFromBackup`.
    public var code: String
    /// Typed metadata fields rendered from the event (bundle keys, rule IDs, counts, durations).
    public var fields: [String: JSONValue]

    public init(at: Date, level: LogLevel, category: LogCategory, code: String, fields: [String: JSONValue]) {
        self.at = at
        self.level = level
        self.category = category
        self.code = code
        self.fields = fields
    }

    /// Renders a typed event (PLT-R902). The only way application code produces a record.
    public init(event: LogEvent, level: LogLevel, at: Date) {
        let rendered = event.rendered
        self.init(at: at, level: level, category: rendered.category, code: rendered.code, fields: rendered.fields)
    }
}

/// Production logger: renders `LogEvent` to `LogRecord`, writes JSON lines on the utility queue, mirrors to
/// the unified log through `os.Logger` with default private redaction for dynamic values (PLT-R902).
public final class DiagnosticsLogger: DiagnosticsLogging {
    private let files: LogFileStore
    private let clock: any WallClock
    private let mirror: UnifiedLogMirror
    private let queue: DispatchQueue
    /// When this logger was created, the start of this session's records.
    public let sessionStart: Date
    private let earlierHealth = Mutex<[HealthEvent]?>(nil)

    public init(policy: LogStorePolicy, fileSystem: any FileSystem, clock: any WallClock, subsystem: String) {
        files = LogFileStore(policy: policy, fileSystem: fileSystem)
        self.clock = clock
        mirror = UnifiedLogMirror(subsystem: subsystem)
        queue = DispatchQueue(label: subsystem + ".diagnostics-log", qos: .utility)
        sessionStart = clock.now()
    }

    /// Health events of earlier sessions from the log files, newest last, at most `limit` (PRD-R46): a crash or
    /// a tap timeout from before this launch still reaches the next report. The files are read once, on the
    /// logger's queue after the records logged so far are written (ahead of time by `maintain()`, or on the
    /// first call); later calls return the same events. Waits for the queue: never call it on the tap thread or
    /// from inside a logging call.
    public func earlierSessionHealthEvents(limit: Int) -> [HealthEvent] {
        let events = earlierHealth.withLock { $0 } ?? queue.sync { loadEarlierHealth() }
        return Array(events.suffix(max(0, limit)))
    }

    /// Runs on `queue` only, which serialises the single read; the mutex is never held while waiting for it.
    private func loadEarlierHealth() -> [HealthEvent] {
        if let cached = earlierHealth.withLock({ $0 }) { return cached }
        let read = files.healthEvents(before: sessionStart, limit: HealthEventLog.defaultCapacity)
        earlierHealth.withLock { $0 = read }
        return read
    }

    /// Never blocks: the timestamp is taken here, rendering and writing happen on the logger's serial
    /// utility queue. Not called on the tap thread (PLT-R304); the tap writes `TapLogRecord`s instead.
    public func log(_ event: LogEvent, level: LogLevel) {
        let at = clock.now()
        queue.async { [files, mirror] in
            let record = LogRecord(event: event, level: level, at: at)
            mirror.write(record)
            files.append(record)
        }
    }

    /// Rotation and 14-day retention; scheduled by the utility queue at launch and every 6 hours. The first pass
    /// also reads the earlier sessions' health events, so the first report does not wait for the files.
    public func maintain() {
        let now = clock.now()
        queue.async { [self] in
            files.maintain(now: now)
            _ = loadEarlierHealth()
        }
    }

    /// Waits until every record logged before this call is written. For shutdown and tests; never call it on
    /// the tap thread or from inside a logging call.
    public func flush() {
        queue.sync {}
    }

    /// Writes that failed since launch (disk full, permissions). Logging never throws to its callers.
    public var failedWrites: Int { files.failedWrites }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/Diagnostics/Report.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Environment report (PLT-R1202) and the machine-parseable issue block (QA-R44).
//
// Privacy is structural: the report type has no field that could hold typed text, field values, window
// titles, URLs, clipboard data, macro bodies or other apps' memory entries (PLT-R1203, PRD-R45). Adding such a
// field is a security review item (QA-R59).

public import AppModel
public import Foundation

public struct DiagnosticsReport: Sendable, Hashable, Codable {
    /// Bumped on any breaking change to the issue block keys (QA-R44).
    public static let formatVersion = 1

    public var formatVersion: Int
    public var generatedAt: Date
    public var app: AppIdentity
    public var system: SystemInfo
    public var hostState: HostStateCode
    public var keyboard: KeyboardSection
    public var permissions: PermissionsSection
    public var tap: TapSection
    public var secureInput: SecureInputSection
    public var focus: FocusSection?
    public var rule: RuleSection?
    public var settings: SettingsSection
    /// Per-app memory entry of the reported app only (PLT-R913).
    public var reportedAppMode: AppModeSection?
    public var latency: LatencySection
    /// Last 50 (PLT-R1202).
    public var healthEvents: [HealthEvent]
    public var conflictingInputApps: [BundleKey]
    public var userReport: UserReportSection?

    public init(
        formatVersion: Int = DiagnosticsReport.formatVersion, generatedAt: Date, app: AppIdentity, system: SystemInfo,
        hostState: HostStateCode, keyboard: KeyboardSection, permissions: PermissionsSection, tap: TapSection,
        secureInput: SecureInputSection, focus: FocusSection?, rule: RuleSection?, settings: SettingsSection,
        reportedAppMode: AppModeSection?, latency: LatencySection, healthEvents: [HealthEvent],
        conflictingInputApps: [BundleKey], userReport: UserReportSection?
    ) {
        self.formatVersion = formatVersion
        self.generatedAt = generatedAt
        self.app = app
        self.system = system
        self.hostState = hostState
        self.keyboard = keyboard
        self.permissions = permissions
        self.tap = tap
        self.secureInput = secureInput
        self.focus = focus
        self.rule = rule
        self.settings = settings
        self.reportedAppMode = reportedAppMode
        self.latency = latency
        self.healthEvents = healthEvents
        self.conflictingInputApps = conflictingInputApps
        self.userReport = userReport
    }

    public struct KeyboardSection: Sendable, Hashable, Codable {
        public var layout: InputSourceID?
        public var sourceKind: InputSourceKindCode
        public var enabledSources: [InputSourceID]

        public init(layout: InputSourceID?, sourceKind: InputSourceKindCode, enabledSources: [InputSourceID]) {
            self.layout = layout
            self.sourceKind = sourceKind
            self.enabledSources = enabledSources
        }
    }

    public enum InputSourceKindCode: String, Sendable, Hashable, Codable {
        case asciiLayout, nonLatinLayout, inputMethod, builtInVietnamese, unknown
    }

    public struct PermissionsSection: Sendable, Hashable, Codable {
        public var accessibility: PermissionState
        public var postEvent: PermissionState
        public var listenEvent: PermissionState
        public var health: PermissionHealthCode

        public init(
            accessibility: PermissionState, postEvent: PermissionState, listenEvent: PermissionState,
            health: PermissionHealthCode
        ) {
            self.accessibility = accessibility
            self.postEvent = postEvent
            self.listenEvent = listenEvent
            self.health = health
        }
    }

    public enum PermissionHealthCode: String, Sendable, Hashable, Codable {
        case ready, noPermission, stale, secureInput, paused
    }

    public struct TapSection: Sendable, Hashable, Codable {
        public var enabled: Bool
        public var location: String  // always "session" (PLT-R301)
        public var timeoutsLast24Hours: Int
        public var userInputDisablesLast24Hours: Int
        public var lastReenableReason: HealthEvent.Kind?

        public init(
            enabled: Bool, location: String = "session", timeoutsLast24Hours: Int, userInputDisablesLast24Hours: Int,
            lastReenableReason: HealthEvent.Kind?
        ) {
            self.enabled = enabled
            self.location = location
            self.timeoutsLast24Hours = timeoutsLast24Hours
            self.userInputDisablesLast24Hours = userInputDisablesLast24Hours
            self.lastReenableReason = lastReenableReason
        }
    }

    public struct SecureInputSection: Sendable, Hashable, Codable {
        public var enabled: Bool
        public var likelyHolder: BundleKey?
        public var holderKind: SecureInputHolder.Kind?

        public init(enabled: Bool, likelyHolder: BundleKey?, holderKind: SecureInputHolder.Kind?) {
            self.enabled = enabled
            self.likelyHolder = likelyHolder
            self.holderKind = holderKind
        }
    }

    public struct FocusSection: Sendable, Hashable, Codable {
        public var bundle: BundleKey
        public var appVersion: String?
        public var engine: EngineFingerprint
        public var axAvailability: AXAvailability
        public var role: String?
        public var subrole: String?
        public var identifier: String?
        public var domClasses: [String]
        public var editable: Bool?
        public var secure: Bool

        public init(
            bundle: BundleKey, appVersion: String?, engine: EngineFingerprint, axAvailability: AXAvailability,
            role: String?, subrole: String?, identifier: String?, domClasses: [String], editable: Bool?, secure: Bool
        ) {
            self.bundle = bundle
            self.appVersion = appVersion
            self.engine = engine
            self.axAvailability = axAvailability
            self.role = role
            self.subrole = subrole
            self.identifier = identifier
            self.domClasses = domClasses
            self.editable = editable
            self.secure = secure
        }
    }

    public struct RuleSection: Sendable, Hashable, Codable {
        public var rule: RuleID?
        public var source: DecisionSource
        public var specificity: Int
        public var strategy: InjectionStrategy
        /// Effective parameters after caps (every field set).
        public var parameters: ReportedParameters
        /// PLT-R1202 "override flag".
        public var isUserOverride: Bool
        /// The user override for the reported app, so maintainers can promote it (PLT-R541). A typed projection
        /// of the override rule: no free text, no URL, no title pattern (PLT-R1203, docs/decisions/0312).
        public var userOverride: ReportedOverride?

        public init(
            rule: RuleID?, source: DecisionSource, specificity: Int, strategy: InjectionStrategy,
            parameters: ReportedParameters, isUserOverride: Bool, userOverride: ReportedOverride?
        ) {
            self.rule = rule
            self.source = source
            self.specificity = specificity
            self.strategy = strategy
            self.parameters = parameters
            self.isUserOverride = isUserOverride
            self.userOverride = userOverride
        }
    }

    /// Strategy parameters as typed values (`StrategyParams` of the rules schema without its JSON form). In the
    /// effective `parameters` every field is set; in a `ReportedOverride` only the fields the override sets.
    public struct ReportedParameters: Sendable, Hashable, Codable {
        public var unicodeChunk: Int?
        public var interEventDelayUs: Int?
        public var postDeleteSettleUs: Int?
        public var firstEditDelayUs: Int?
        public var inlineCompletion: InlineCompletionMode?
        public var allowMultiCharEvents: Bool?
        public var allowSplit: Bool?
        public var longTextThreshold: Int?
        public var restoreDelayMs: Int?
        public var verifyAfterEdit: Bool?

        public init(
            unicodeChunk: Int? = nil, interEventDelayUs: Int? = nil, postDeleteSettleUs: Int? = nil,
            firstEditDelayUs: Int? = nil, inlineCompletion: InlineCompletionMode? = nil,
            allowMultiCharEvents: Bool? = nil, allowSplit: Bool? = nil, longTextThreshold: Int? = nil,
            restoreDelayMs: Int? = nil, verifyAfterEdit: Bool? = nil
        ) {
            self.unicodeChunk = unicodeChunk
            self.interEventDelayUs = interEventDelayUs
            self.postDeleteSettleUs = postDeleteSettleUs
            self.firstEditDelayUs = firstEditDelayUs
            self.inlineCompletion = inlineCompletion
            self.allowMultiCharEvents = allowMultiCharEvents
            self.allowSplit = allowSplit
            self.longTextThreshold = longTextThreshold
            self.restoreDelayMs = restoreDelayMs
            self.verifyAfterEdit = verifyAfterEdit
        }
    }

    /// Typed projection of a user override rule (docs/decisions/0312-report-override-projection.md). Built by
    /// ShellCore's `ReportAssembler.reportedOverride(from:)`. Rendered as rule JSON in the report so a
    /// maintainer can paste it into `compat/rules.json` after adding provenance.
    public struct ReportedOverride: Sendable, Hashable, Codable {
        public var id: RuleID
        public var match: ReportedMatch
        public var strategy: InjectionStrategy
        public var parameters: ReportedParameters?
        public var fallback: [InjectionStrategy]?
        public var requireTextFocus: RequireTextFocus?
        public var verifyReentry: VerifyReentry?
        public var engineContext: EngineContextKind?
        /// Match fields present in the override but never reported because they can hold content
        /// (`web.urlPrefixes`, `titlePattern`): names only, never values (PLT-R1203).
        public var omittedMatchFields: [OmittedMatchField]

        public init(
            id: RuleID, match: ReportedMatch, strategy: InjectionStrategy, parameters: ReportedParameters?,
            fallback: [InjectionStrategy]?, requireTextFocus: RequireTextFocus?, verifyReentry: VerifyReentry?,
            engineContext: EngineContextKind?, omittedMatchFields: [OmittedMatchField]
        ) {
            self.id = id
            self.match = match
            self.strategy = strategy
            self.parameters = parameters
            self.fallback = fallback
            self.requireTextFocus = requireTextFocus
            self.verifyReentry = verifyReentry
            self.engineContext = engineContext
            self.omittedMatchFields = omittedMatchFields
        }
    }

    /// Match fields that are metadata (PLT-R1202 lists bundle ID, role, subrole, identifier, DOM classes; app
    /// categories, version ranges, engines and ancestor roles are metadata of the same kind).
    public struct ReportedMatch: Sendable, Hashable, Codable {
        public var bundleIds: [BundleKey]?
        public var bundleGroup: String?
        public var engines: [EngineFingerprint]?
        public var appCategories: [String]?
        public var appVersion: VersionRange?
        public var macOS: VersionRange?
        public var axRoles: [String]?
        public var axSubroles: [String]?
        public var axIdentifiers: [String]?
        public var axDomClasses: [String]?
        public var axAncestorRoles: [String]?
        public var axEditable: Bool?

        public init(
            bundleIds: [BundleKey]? = nil, bundleGroup: String? = nil, engines: [EngineFingerprint]? = nil,
            appCategories: [String]? = nil, appVersion: VersionRange? = nil, macOS: VersionRange? = nil,
            axRoles: [String]? = nil, axSubroles: [String]? = nil, axIdentifiers: [String]? = nil,
            axDomClasses: [String]? = nil, axAncestorRoles: [String]? = nil, axEditable: Bool? = nil
        ) {
            self.bundleIds = bundleIds
            self.bundleGroup = bundleGroup
            self.engines = engines
            self.appCategories = appCategories
            self.appVersion = appVersion
            self.macOS = macOS
            self.axRoles = axRoles
            self.axSubroles = axSubroles
            self.axIdentifiers = axIdentifiers
            self.axDomClasses = axDomClasses
            self.axAncestorRoles = axAncestorRoles
            self.axEditable = axEditable
        }
    }

    /// The two rule fields that can carry content (page addresses, window titles) and are therefore never
    /// copied into a report.
    public enum OmittedMatchField: String, Sendable, Hashable, Codable, CaseIterable {
        case webURLPrefixes = "web.urlPrefixes"
        case titlePattern
    }

    public struct SettingsSection: Sendable, Hashable, Codable {
        public var typingMethod: TypingMethod
        public var tonePlacement: TonePlacement
        public var englishRestore: Bool
        public var standaloneW: Bool
        public var bracketKeys: Bool
        public var macrosEnabled: Bool
        public var macroCount: Int  // count only (PRD-R33)
        public var macrosInEnglishMode: Bool
        public var rememberPerApp: Bool
        public var toggleHotkey: HotkeyBinding
        public var restoreHotkeySet: Bool
        public var interfaceLanguage: InterfaceLanguage
        public var updateChannel: UpdateChannel
        public var explicitlySetKeys: [String]  // names of keys the user changed (PRD-R6), no values

        public init(
            typingMethod: TypingMethod, tonePlacement: TonePlacement, englishRestore: Bool, standaloneW: Bool,
            bracketKeys: Bool, macrosEnabled: Bool, macroCount: Int, macrosInEnglishMode: Bool, rememberPerApp: Bool,
            toggleHotkey: HotkeyBinding, restoreHotkeySet: Bool, interfaceLanguage: InterfaceLanguage,
            updateChannel: UpdateChannel, explicitlySetKeys: [String]
        ) {
            self.typingMethod = typingMethod
            self.tonePlacement = tonePlacement
            self.englishRestore = englishRestore
            self.standaloneW = standaloneW
            self.bracketKeys = bracketKeys
            self.macrosEnabled = macrosEnabled
            self.macroCount = macroCount
            self.macrosInEnglishMode = macrosInEnglishMode
            self.rememberPerApp = rememberPerApp
            self.toggleHotkey = toggleHotkey
            self.restoreHotkeySet = restoreHotkeySet
            self.interfaceLanguage = interfaceLanguage
            self.updateChannel = updateChannel
            self.explicitlySetKeys = explicitlySetKeys
        }
    }

    public struct AppModeSection: Sendable, Hashable, Codable {
        public var bundle: BundleKey
        public var rule: PerAppRule?
        public var rememberedMode: TypingMode?

        public init(bundle: BundleKey, rule: PerAppRule?, rememberedMode: TypingMode?) {
            self.bundle = bundle
            self.rule = rule
            self.rememberedMode = rememberedMode
        }
    }

    public struct LatencySection: Sendable, Hashable, Codable {
        public var metrics: MetricsSnapshot
        public var probe: LatencyProbeResult?

        public init(metrics: MetricsSnapshot, probe: LatencyProbeResult?) {
            self.metrics = metrics
            self.probe = probe
        }
    }

    public struct UserReportSection: Sendable, Hashable, Codable {
        public var symptom: Symptom
        public var reportedApp: BundleKey?
        public var reproducesInPracticeField: Bool?

        public init(symptom: Symptom, reportedApp: BundleKey?, reproducesInPracticeField: Bool?) {
            self.symptom = symptom
            self.reportedApp = reportedApp
            self.reproducesInPracticeField = reproducesInPracticeField
        }
    }

    /// PRD-R47 chips and PLT-R1205 symptoms.
    public enum Symptom: String, Sendable, Hashable, Codable, CaseIterable {
        case lostLetters, duplicatedLetters, lettersOutOfOrder, wrongTone, cannotTypeVietnamese, nothingTyped,
            lag, other
    }
}

/// Result of the built-in latency probe (PLT-R810).
public struct LatencyProbeResult: Sendable, Hashable, Codable {
    public enum Profile: String, Sendable, Hashable, Codable, CaseIterable {
        case normal  // 120 ms between keys
        case fast  // 40 ms
        case burst  // 5 ms
    }

    public struct ProfileResult: Sendable, Hashable, Codable {
        public var profile: Profile
        public var decideToPostedP50Microseconds: UInt64
        public var decideToPostedP99Microseconds: UInt64
        public var endToEndDeltaP50Microseconds: UInt64
        public var endToEndDeltaP99Microseconds: UInt64
        public var samples: Int

        public init(
            profile: Profile, decideToPostedP50Microseconds: UInt64, decideToPostedP99Microseconds: UInt64,
            endToEndDeltaP50Microseconds: UInt64, endToEndDeltaP99Microseconds: UInt64, samples: Int
        ) {
            self.profile = profile
            self.decideToPostedP50Microseconds = decideToPostedP50Microseconds
            self.decideToPostedP99Microseconds = decideToPostedP99Microseconds
            self.endToEndDeltaP50Microseconds = endToEndDeltaP50Microseconds
            self.endToEndDeltaP99Microseconds = endToEndDeltaP99Microseconds
            self.samples = samples
        }
    }

    public var ranAt: Date
    public var results: [ProfileResult]

    public init(ranAt: Date, results: [ProfileResult]) {
        self.ranAt = ranAt
        self.results = results
    }
}

/// Renders a report for the three outputs of PLT-R1204/PRD-R47.
public enum DiagnosticsRenderer {
    /// Human-readable text in the interface language, shown verbatim before copying (PLT-R1204).
    public static func plainText(_ report: DiagnosticsReport, language: InterfaceLanguage) -> String {
        PlainTextReport(report: report, labels: ReportLabels.labels(for: language)).render()
    }

    /// QA-R44 block, parsed by the issue labeller (`scripts/parse-diagnostics.py`). The format is fixed by
    /// ADR 0501 (`docs/decisions/0501-diagnostics-block-format.md`). Exact shape:
    ///
    ///     ```text
    ///     <slug>-diagnostics v1
    ///     report.bundleId: com.example.App
    ///     app.version: 0.1.0
    ///     app.build: 12
    ///     app.channel: beta
    ///     macos.version: 27.1
    ///     macos.build: 26B123
    ///     hw.arch: arm64
    ///     input.method: telex
    ///     focus.bundleId: com.example.App
    ///     ...one `key: value` per line, keys from `DiagnosticsBlockKey` plus any ADR 0501 key...
    ///     ```
    ///
    /// `<slug>` is `report.app.slug` (read from the bundle, never hard-coded). Values never contain newlines;
    /// lists are comma-separated. Keys match `[a-z][A-Za-z0-9]*(\.[A-Za-z0-9]+)*`. At most 200 lines.
    public static func issueBlock(_ report: DiagnosticsReport) -> String { IssueBlock.render(report) }

    /// Inverse of `issueBlock` for tests and for the labeller contract: `nil` when no block or an unknown
    /// format version is found. Accepts any slug of the shape `[a-z][a-z0-9-]*` (ADR 0501 rule 1).
    public static func parseIssueBlock(_ text: String) -> [String: String]? { IssueBlock.parse(text) }

    /// JSON file attached by "Gửi qua email" / "Lưu tệp..." (PRD-R47): pretty-printed, sorted keys, ISO 8601
    /// dates. Decodes back into an equal `DiagnosticsReport`.
    public static func json(_ report: DiagnosticsReport) throws -> Data { try ReportJSON.encode(report) }

    /// The reported app's user override as rule JSON in the `compat/rules.json` shape (PLT-R541, ADR 0312), so
    /// a maintainer can paste it after adding `summary` and provenance. Content-bearing match fields are never
    /// part of `ReportedOverride`, so they cannot appear here.
    public static func ruleJSON(_ override: DiagnosticsReport.ReportedOverride, pretty: Bool) -> String {
        ReportJSON.rule(override, pretty: pretty)
    }
}

/// Keys of the issue block (ADR 0501). The labeller relies on `report.bundleId` / `focus.bundleId`,
/// `macos.version`, `hw.arch` and `input.method` (QA-R44 labels `app:<bundle>`, `macos:<major>`, `arch:...`,
/// `method:...`). Keys may be added within format v1; none of these may change or be removed.
public enum DiagnosticsBlockKey: String, Sendable, CaseIterable {
    case reportBundle = "report.bundleId"
    case reportAppVersion = "report.appVersion"
    case reportSymptom = "report.symptom"
    case appVersion = "app.version"  // lint:allow-bundle-id ADR 0501 block key
    case appBuild = "app.build"  // lint:allow-bundle-id ADR 0501 block key
    case appChannel = "app.channel"  // lint:allow-bundle-id ADR 0501 block key
    case macOSVersion = "macos.version"
    case macOSBuild = "macos.build"
    case architecture = "hw.arch"
    case model = "hw.model"
    case method = "input.method"
    case layout = "input.layout"
    case focusBundle = "focus.bundleId"
    case focusAppVersion = "focus.appVersion"
    case focusEngine = "focus.engine"
    case rule = "rule.id"
    case strategy = "rule.strategy"
    case secureInput = "secureInput.active"
    case hostState = "host.state"
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/Diagnostics/Capture.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Time-boxed typing trace (PLT-R905, PRD-R46, D26): the only artefact that ever contains typed characters.

public import AppModel
public import Foundation
public import RealtimeSupport

public enum CaptureLimits {
    public static let defaultDuration: TimeSpan = .seconds(60)
    public static let maximumDuration: TimeSpan = .seconds(180)
    public static let retention: TimeInterval = 24 * 3_600
}

public struct CaptureSessionID: RawRepresentable, Sendable, Hashable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// What the tap records while a capture is active. Characters come from the layout table (what the user's
/// layout produced), never from field contents.
public struct KeyCaptureRecord: Sendable, BitwiseCopyable {
    public enum Kind: UInt8, Sendable, BitwiseCopyable { case keyDown, keyUp, flagsChanged, mouseDown }
    public enum Outcome: UInt8, Sendable, BitwiseCopyable {
        case passed, held, consumedForEdit, consumedAsHotkey, consumedPairedKeyUp
    }
    public var kind: Kind
    public var keyCode: UInt16
    public var flags: UInt64
    public var character: InlineUTF16
    public var outcome: Outcome
    public var at: MonotonicInstant
    public init(
        kind: Kind, keyCode: UInt16, flags: UInt64, character: InlineUTF16, outcome: Outcome,
        at: MonotonicInstant
    ) {
        self.kind = kind
        self.keyCode = keyCode
        self.flags = flags
        self.character = character
        self.outcome = outcome
        self.at = at
    }
}

public enum CaptureRecord: Sendable {
    case key(KeyCaptureRecord)
    /// Engine decision for the last key: delete count and inserted text (content, capture only).
    case engine(deleteCount: Int, insert: String, at: MonotonicInstant)
    case job(sequence: UInt64, strategy: InjectionStrategy, durationMicroseconds: UInt64, outcome: StaticString)
    /// Roles and bundle IDs only, never titles or URLs (PLT-R905).
    case focus(bundle: BundleKey?, role: String?, subrole: String?, at: MonotonicInstant)
    /// Nothing is recorded while secure input is on or a secure field is focused; the gap is marked.
    case gap(reason: PauseCode, from: MonotonicInstant, to: MonotonicInstant)
}

public struct CaptureSessionInfo: Sendable, Hashable, Codable {
    public var id: CaptureSessionID
    public var startedAt: Date
    public var endsAt: Date
    public var file: URL
}

/// Why a capture could not start or a session could not be read (PLT-R905).
public enum CaptureError: Error, Sendable, Hashable {
    /// Zero, negative or longer than `CaptureLimits.maximumDuration`.
    case invalidDuration
    case alreadyRecording
    /// No capture file with this ID exists (expired, exported, discarded or never created).
    case unknownSession
    case storage(FileSystemError)
}

/// Owns capture state. `isRecording` is an atomic flag the tap reads once per callback; records flow through
/// SPSC rings (tap, inject, ax producers) drained by the utility queue into
/// `~/Library/Logs/<folder>/captures/<id>.jsonl` (0600, excluded from backup).
///
/// The session stops by itself when its duration is over (a one-shot timer on `scheduler`); while it runs a
/// repeating 2 s timer drains the rings (PLT-R803). `beginGap`/`endGap` bracket secure input and secure fields:
/// `isRecording` is false in between, records stamped inside the gap are dropped and a gap line is written.
public final class CaptureController: Sendable {
    public let tapRecords = SPSCRing<CaptureRecord>(capacity: 8_192)
    public let injectRecords = SPSCRing<CaptureRecord>(capacity: 2_048)
    public let focusRecords = SPSCRing<CaptureRecord>(capacity: 512)

    let directory: URL
    let fileSystem: any FileSystem
    let wallClock: any WallClock
    let clock: any MonotonicClock
    private let scheduler: any TimerScheduler
    private let recording = Atomic<Bool>(false)
    private let session = Mutex<CaptureSession?>(nil)
    private let writeFailures = Atomic<Int>(0)
    #if DEV_RECORDER
    /// PLT-R904A: the dev builds' continuous recorder shares the rings, the drain and the secure gaps.
    public let dev: DevRecorder
    #endif

    public init(
        directory: URL, fileSystem: any FileSystem, wallClock: any WallClock, clock: any MonotonicClock,
        scheduler: any TimerScheduler
    ) {
        self.directory = directory
        self.fileSystem = fileSystem
        self.wallClock = wallClock
        self.clock = clock
        self.scheduler = scheduler
        #if DEV_RECORDER
        dev = DevRecorder(
            directory: Self.devDirectory(besides: directory), fileSystem: fileSystem, wallClock: wallClock,
            clock: clock, scheduler: scheduler)
        dev.attach { [weak self] in self?.drainNow() }
        #endif
    }

    #if DEV_RECORDER
    /// The running app's wiring: the recorder's attention requests (marker, readback) run on `attentionQueue`.
    public init(
        directory: URL, fileSystem: any FileSystem, wallClock: any WallClock, clock: any MonotonicClock,
        scheduler: any TimerScheduler, devAttentionQueue: DispatchQueue
    ) {
        self.directory = directory
        self.fileSystem = fileSystem
        self.wallClock = wallClock
        self.clock = clock
        self.scheduler = scheduler
        dev = DevRecorder(
            directory: Self.devDirectory(besides: directory), fileSystem: fileSystem, wallClock: wallClock,
            clock: clock, scheduler: scheduler, attentionQueue: devAttentionQueue)
        dev.attach { [weak self] in self?.drainNow() }
    }

    /// `<logs folder>/dev-traces`, next to `captures`.
    static func devDirectory(besides captures: URL) -> URL {
        captures.deletingLastPathComponent().appendingPathComponent(DevTraceFiles.folderName, isDirectory: true)
    }
    #endif

    /// Tap-safe (one atomic load; two in dev builds).
    public var isRecording: Bool {
        #if DEV_RECORDER
        return recording.load(ordering: .acquiring) || dev.isActive
        #else
        recording.load(ordering: .acquiring)
        #endif
    }

    /// Appends that failed while a session ran (timer-driven drains cannot throw).
    public var failedWrites: Int { writeFailures.load(ordering: .relaxed) }

    /// Explicit user action only, after a confirmation that explains what is recorded (PLT-R905).
    public func start(duration: TimeSpan) throws -> CaptureSessionInfo {
        guard duration > .zero, duration <= CaptureLimits.maximumDuration else { throw CaptureError.invalidDuration }
        return try session.withLock { (active: inout CaptureSession?) throws -> CaptureSessionInfo in
            guard active == nil else { throw CaptureError.alreadyRecording }
            #if DEV_RECORDER
            // The continuous recorder keeps what is queued; the new session still starts with nothing old.
            if dev.isStarted { drainContinuousOnly() } else { discardPendingRecords() }
            #else
            discardPendingRecords()
            #endif
            let startedAt = wallClock.now()
            let id = CaptureFiles.makeID(at: startedAt)
            let info = CaptureSessionInfo(
                id: id, startedAt: startedAt, endsAt: startedAt.addingTimeInterval(duration.inSeconds),
                file: CaptureFiles.url(for: id, in: directory))
            try storage { try prepareFile(for: info) }
            let stopTimer = scheduler.schedule(after: duration, leeway: .milliseconds(100)) { [weak self] in
                self?.finish(reason: .timeLimit)
            }
            let drainTimer = scheduler.scheduleRepeating(every: CaptureFiles.drainInterval, leeway: .milliseconds(200))
            {
                [weak self] in self?.drainNow()
            }
            active = CaptureSession(info: info, start: clock.now(), timers: [stopTimer, drainTimer])
            recording.store(true, ordering: .releasing)
            return info
        }
    }

    public func stop() -> CaptureSessionInfo? { finish(reason: .stopped) }

    public func remaining(now: Date) -> TimeSpan? {
        session.withLock { active in
            active.map { .seconds(max(0, $0.info.endsAt.timeIntervalSince(now))) }
        }
    }

    /// Secure input turned on or a secure field got focus: record nothing until `endGap` (PLT-R905).
    /// `holder`: the likely holder of secure input (PLT-R396), for the dev recorder's gap line only.
    public func beginGap(_ reason: PauseCode, holder: SecureInputHolder? = nil) {
        #if DEV_RECORDER
        dev.beginGap(reason, holder: holder, at: clock.now())
        #endif
        session.withLock { active in
            guard active != nil, active?.openGap == nil else { return }
            recording.store(false, ordering: .releasing)
            active?.openGap = CaptureSession.OpenGap(reason: reason, from: clock.now())
        }
    }

    public func endGap() {
        #if DEV_RECORDER
        dev.endGap(at: clock.now())
        #endif
        session.withLock { active in
            guard active?.openGap != nil else { return }
            active?.closeGap(at: clock.now())
            recording.store(true, ordering: .releasing)
        }
    }

    /// Readable rendering the user reviews before export (PLT-R905).
    public func render(_ id: CaptureSessionID, language: InterfaceLanguage) throws -> String {
        let url = try existingFile(for: id)
        drainNow()
        let data = try storage { try fileSystem.readData(at: url, maxBytes: CaptureFiles.maximumFileBytes) }
        return CaptureRendering.render(data, language: language)
    }

    /// Writes the export and deletes the capture immediately afterwards.
    public func export(_ id: CaptureSessionID, to destination: URL) throws {
        let url = try existingFile(for: id)
        finishIfActive(id)
        let data = try storage { try fileSystem.readData(at: url, maxBytes: CaptureFiles.maximumFileBytes) }
        try storage { try fileSystem.writeAtomically(data, to: destination, permissions: .ownerOnlyFile) }
        try storage { try fileSystem.removeItem(at: url) }
    }

    public func discard(_ id: CaptureSessionID) {
        guard let url = try? existingFile(for: id) else { return }
        finishIfActive(id)
        try? fileSystem.removeItem(at: url)
    }

    /// Deletes captures older than 24 hours; run at launch and hourly on the utility queue.
    public func purgeExpired(now: Date) {
        // Compared by name: directory listings may spell the folder differently (symlinks, trailing slash).
        let activeName = session.withLock { $0?.info.file.lastPathComponent }
        guard let entries = try? fileSystem.contentsOfDirectory(at: directory) else { return }
        for url in entries where url.pathExtension == CaptureFiles.fileExtension && url.lastPathComponent != activeName
        {
            guard let created = try? fileSystem.attributes(at: url).creationDate else { continue }
            if now.timeIntervalSince(created) >= CaptureLimits.retention { try? fileSystem.removeItem(at: url) }
        }
    }

    // MARK: Session internals

    @discardableResult
    private func finish(reason: CaptureFiles.EndReason) -> CaptureSessionInfo? {
        session.withLock { active in
            recording.store(false, ordering: .releasing)
            guard var current = active else { return nil }
            for timer in current.timers { timer.cancel() }
            let now = clock.now()
            current.closeGap(at: now)
            #if DEV_RECORDER
            dev.stage()
            #endif
            var lines = drainedLines(&current, now: now)
            lines.append(CaptureLine(type: .end, t: now.microseconds(since: current.start), reason: reason.rawValue))
            append(lines, to: current.info.file)
            active = nil
            #if DEV_RECORDER
            dev.flush()
            #endif
            return current.info
        }
    }

    private func finishIfActive(_ id: CaptureSessionID) {
        if session.withLock({ $0?.info.id == id }) { finish(reason: .stopped) }
    }

    private func drainNow() {
        #if DEV_RECORDER
        drainNow(betweenRings: {})
        #else
        session.withLock { active in
            guard var current = active else { return }
            append(drainedLines(&current, now: clock.now()), to: current.info.file)
            active = current
        }
        #endif
    }

    #if DEV_RECORDER
    /// PLT-R904A trace order: the tap pushes a key into the shared ring before the dev records of the same key
    /// (engine steps, boundaries), so the dev rings are popped first. A key that arrives between the two pops is
    /// then written with or before its dev records, never after them. `betweenRings` runs between the two pops
    /// (tests: a producer racing the drain).
    func drainNow(betweenRings: () -> Void) {
        session.withLock { active in
            guard var current = active else {
                drainContinuousOnly(betweenRings: betweenRings)
                return
            }
            dev.stage()
            betweenRings()
            append(drainedLines(&current, now: clock.now()), to: current.info.file)
            active = current
            dev.flush()
        }
    }

    /// No time-boxed session: every queued record goes to the dev recorder only. Called with the session lock held,
    /// so the rings keep exactly one consumer at a time.
    private func drainContinuousOnly(betweenRings: () -> Void = {}) {
        dev.stage()
        betweenRings()
        for ring in [tapRecords, injectRecords, focusRecords] {
            while let record = ring.pop() { dev.collect(record) }
        }
        dev.flush()
    }
    #endif

    /// Pops every ring and returns the lines to write, oldest first. Records stamped before the session or
    /// inside a gap are dropped (PLT-R905 "nothing is recorded while secure input is on").
    private func drainedLines(_ session: inout CaptureSession, now: MonotonicInstant) -> [CaptureLine] {
        var timed: [(at: MonotonicInstant, line: CaptureLine)] = session.takeUnwrittenGaps()
        for ring in [tapRecords, injectRecords, focusRecords] {
            while let record = ring.pop() {
                #if DEV_RECORDER
                dev.collect(record)
                #endif
                let at = record.timestamp ?? now
                guard session.accepts(at) else { continue }
                timed.append((at, CaptureLine(record, start: session.start)))
            }
        }
        return timed.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(\.element.line)
    }

    private func discardPendingRecords() {
        for ring in [tapRecords, injectRecords, focusRecords] { while ring.pop() != nil {} }
    }

    private func append(_ lines: [CaptureLine], to file: URL) {
        guard !lines.isEmpty else { return }
        do {
            try fileSystem.append(CaptureFiles.encode(lines), to: file, permissions: .ownerOnlyFile)
        } catch {
            writeFailures.wrappingAdd(1, ordering: .relaxed)
        }
    }

    /// Directory 0700, file 0600 with the session header, both excluded from backups (PLT-R905).
    private func prepareFile(for info: CaptureSessionInfo) throws {
        try fileSystem.createDirectory(at: directory, permissions: .ownerOnlyDirectory)
        try fileSystem.setExcludedFromBackup(true, at: directory)
        let header = CaptureLine(
            type: .session, id: info.id.rawValue, startedAt: info.startedAt, endsAt: info.endsAt,
            formatVersion: CaptureFiles.formatVersion)
        try fileSystem.append(CaptureFiles.encode([header]), to: info.file, permissions: .ownerOnlyFile)
        try fileSystem.setExcludedFromBackup(true, at: info.file)
    }

    private func existingFile(for id: CaptureSessionID) throws -> URL {
        guard CaptureFiles.isValid(id) else { throw CaptureError.unknownSession }
        let url = CaptureFiles.url(for: id, in: directory)
        guard fileSystem.fileExists(at: url) else { throw CaptureError.unknownSession }
        return url
    }

    private func storage<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as FileSystemError {
            throw CaptureError.storage(error)
        }
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/Diagnostics/Signposts.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later

internal import AppModel
internal import os

/// `os_signpost` intervals around the callback, job execution and AX calls in all builds (PLT-R802); zero cost
/// when not recording. Interval names are static strings.
///
/// Tap-safe: when no tool records signposts `begin` and `end` are one flag check. While recording they use the
/// format-less `os_signpost` call and a generated ID, neither of which allocates (checked by the W1-A
/// allocation test). Signposts carry no metadata at all, only the interval name.
public struct PlatformSignposts: Sendable {
    public enum Interval: Sendable { case tapCallback, injectionJob, axCall }
    public struct Token: Sendable { let raw: UInt64 }

    private let log: OSLog

    public init(subsystem: String) {
        log = OSLog(subsystem: subsystem, category: .pointsOfInterest)
    }

    /// A token for `end`. Its value is 0 when signposts are not being recorded.
    @inline(__always)
    public func begin(_ interval: Interval) -> Token {
        guard log.signpostsEnabled else { return Token(raw: 0) }
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: interval.name, signpostID: id)
        return Token(raw: id.rawValue)
    }

    @inline(__always)
    public func end(_ interval: Interval, _ token: Token) {
        guard token.raw != 0, log.signpostsEnabled else { return }
        os_signpost(.end, log: log, name: interval.name, signpostID: OSSignpostID(token.raw))
    }
}

extension PlatformSignposts.Interval {
    var name: StaticString {
        switch self {
        case .tapCallback: "tapCallback"
        case .injectionJob: "injectionJob"
        case .axCall: "axCall"
        }
    }
}
```
<!-- /include -->

## 7. SettingsStore

Owned files: `Packages/AppCore/Sources/SettingsStore/**`, `Tests/SettingsStoreTests/**` (including fixtures
for every released schema version), `Sources/TestSupport/Fakes/Settings/**` (workstream W1-B). Isolation:
`SettingsStore` is an `actor` whose executor is the utility serial queue; the value types are `Sendable`.

### 7.1 "Unset" versus "set" (PRD-R6, PLT-R1004)

Every user-facing setting is a `Setting<Value>`: `.unset` (absent key in JSON, follows `DefaultSettings.v1`,
so a future default change reaches the user) or `.set(value)` (explicit choice, kept forever even if equal to
today's default). For optional values `.set(nil)` is a JSON `null`, "the user chose none", which is different
from absence (for example the restore hotkey, D8). Reset to default writes `.unset`. Example
`settings.json` after the user picked VNI and explicitly cleared the restore hotkey:

```json
{
  "schemaVersion": 1,
  "writtenBy": "0.1.0",
  "settings": { "typingMethod": "vni", "restoreHotkey": null },
  "englishRestoreLists": {
    "keepAsTyped": ["tex"], "keepVietnamese": [],
    "learnedWords": [{ "list": "keepAsTyped", "raw": "cos", "app": "com.example.Editor" }]
  },
  "optedInRules": [],
  "onboarding": { "completedVersion": "0.1.0" },
  "futureKeyFromNewerBuild": { "kept": true }
}
```

`keepAsTyped` and `keepVietnamese` are the global entries (typed in Settings, or saved before per-app learning);
`learnedWords` are the words learned from toggles, each applying only in its `app` (ENG-R862,
[ADR 0320](../decisions/0320-per-app-learned-words.md)). An item without `app` is a global entry.

### 7.2 Per-app memory store (`app-modes.json`)

```json
{
  "schemaVersion": 1,
  "writtenBy": "0.1.0",
  "globalMode": "vi",
  "apps": [
    { "bundle": "com.example.Terminal", "mode": "en" },
    { "bundle": "com.example.Chat", "rule": "alwaysVietnamese" },
    { "bundle": "com.example.Editor", "rule": "ignore" },
    { "bundle": "sha256:4f1c…", "mode": "en" }
  ]
}
```

Most recently used first; at most 1,000 entries with only a remembered mode (least recently used evicted);
entries with an explicit rule are never evicted (PLT-R392). Writes are debounced 5 s. The ax thread owns the
live copy (`AppModeMemory`, section 10) and sends documents to `recordAppModes`.

### 7.3 Macro import formats (PRD-R32)

| Format | Detection | Shape | Notes |
|---|---|---|---|
| App export / `macros.json` | JSON object with `kind: settings-export` or `macros` array | `{trigger, expansion, adaptCase, enabled}` | `id` regenerated on conflict |
| TAB-separated text | UTF-8, tabs present | `shortcut<TAB>expansion` per line | `\n`, `\t`, `\\` escapes; blank and `#` lines ignored |
| CSV | commas, RFC 4180 quoting | two columns | Header row skipped when it matches a known header |
| Text Replacements plist | `bplist00` or XML plist array | dictionaries with `shortcut`, `phrase` | The drag-out file from System Settings > Keyboard > Text Replacements (VERIFY on macOS 27) |

All rows go through `MacroValidator` (1-32 printable ASCII without whitespace or Vietnamese letters, expansion
up to 4,000 characters, no shortcut equal to another plus trailing punctuation or a trailing main-row digit,
ENG-R1103). The preview counts new,
duplicate and invalid rows; duplicates resolve with "keep mine" or "use imported" (PRD-R70). Importers for
competitor export files (XKey, OpenKey, EVKey, Gõ Nhanh, PHTV, PRD-R69) are added only after their formats are
observed from real exports, never from their source code (CLR-R1, CLR-R5); until then those users use the TSV
or CSV path.

<!-- include: Packages/AppCore/Sources/SettingsStore/Setting.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later

/// A user setting that is either untouched (`unset`, follows future default changes) or an explicit choice
/// (`set`, preserved forever, even when equal to today's default). PRD-R6, PLT-R1004.
///
/// JSON: `unset` is an absent key; `set(v)` is the key with `v`. For optional values, `set(nil)` is an
/// explicit JSON `null` ("the user chose none"), distinct from absence.
public enum Setting<Value: Sendable & Hashable & Codable>: Sendable, Hashable {
    case unset
    case set(Value)

    public func resolved(default defaultValue: Value) -> Value {
        if case .set(let value) = self { return value }
        return defaultValue
    }

    public var isSet: Bool {
        if case .set = self { return true }
        return false
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/SettingsStore/UserSettings.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// settings.json payload (PLT-R1001). Only explicit user choices are persisted; defaults live in code
// (`DefaultSettings`) and rules (PLT-R1004). Keys are the JSON names below and MUST NOT be renamed without a
// migration (PLT-R1005).

public import AppModel

/// Explicit choices (`settings` object of settings.json). D-numbers refer to 03-product.md section 4.
public struct UserSettings: Sendable, Hashable {
    public var typingMethod: Setting<TypingMethod> = .unset  // D1 "typingMethod"
    public var tonePlacement: Setting<TonePlacement> = .unset  // D2 "tonePlacement"
    public var englishRestore: Setting<Bool> = .unset  // D4 "englishRestore"
    public var telexStandaloneW: Setting<Bool> = .unset  // D5 "telexStandaloneW"
    public var telexBracketKeys: Setting<Bool> = .unset  // D6 "telexBracketKeys"
    public var restoreHotkey: Setting<HotkeyBinding?> = .unset  // D8 "restoreHotkey" (null = none)
    public var macrosEnabled: Setting<Bool> = .unset  // D9 "macrosEnabled"
    public var macrosInEnglishMode: Setting<Bool> = .unset  // D10 "macrosInEnglishMode"
    public var toggleHotkey: Setting<HotkeyBinding> = .unset  // D11 "toggleHotkey"
    public var rememberPerApp: Setting<Bool> = .unset  // D12 "rememberPerApp"
    public var firstSeenAppMode: Setting<FirstSeenMode> = .unset  // D13 "firstSeenAppMode" (no UI in v1)
    public var showSwitchIndicator: Setting<Bool> = .unset  // D14 "showSwitchIndicator"
    public var soundOnSwitch: Setting<Bool> = .unset  // D15 "soundOnSwitch"
    public var clickIconToToggle: Setting<Bool> = .unset  // D16 "clickIconToToggle"
    public var interfaceLanguage: Setting<InterfaceLanguage> = .unset  // D18 "interfaceLanguage"
    public var automaticallyCheckForUpdates: Setting<Bool> = .unset  // D19
    public var automaticallyInstallUpdates: Setting<Bool> = .unset  // D20
    public var updateChannel: Setting<UpdateChannel> = .unset  // D21
    public var layoutBinding: Setting<LayoutModeBinding> = .unset  // PLT-R373 "layoutBinding"

    /// ENG-R860 user lists, keyed by lowercased raw keys ("englishRestoreLists" object). User-authored
    /// settings, allowed on disk (PLT-R901 a).
    public var keepAsTyped: Set<String> = []
    public var keepVietnamese: Set<String> = []
    /// ENG-R862: words learned from the user's toggles, each applying only in its app (`englishRestoreLists`
    /// `learnedWords`). `keepAsTyped` and `keepVietnamese` above are the global entries.
    public var learnedWords: Set<LearnedWord> = []
    /// Shipped rules with `requiresUserOptIn: true` that the user enabled (PLT-R460) ("optedInRules").
    public var optedInRules: Set<RuleID> = []
    /// "onboarding" object (PRD-R42).
    public var onboarding = OnboardingState()

    public init() {}

    /// Names of keys that are explicitly set, for the content-free diagnostics report: the JSON names of set
    /// `Setting` values in declaration order, then `keepAsTyped`, `keepVietnamese`, `learnedWords`, `optedInRules`
    /// when non-empty. Names only, never values or apps (PLT-R901, PRD-R6, ADR 0314).
    public var explicitlySetKeys: [String] {
        let settings = SettingFields.all.filter { $0.isSet(self) }.map(\.key)
        let lists = [
            (SettingListKey.keepAsTyped, keepAsTyped.isEmpty), (SettingListKey.keepVietnamese, keepVietnamese.isEmpty),
            (SettingListKey.learnedWords, learnedWords.isEmpty), (SettingListKey.optedInRules, optedInRules.isEmpty),
        ]
        return settings + lists.filter { !$0.1 }.map(\.0)
    }
}

/// D17 (open at login) is deliberately absent: `SMAppService.mainApp` status is the source of truth.

/// PLT-R373: ASCII-capable layouts designated as VI or EN; when enabled the selected source decides the mode.
public struct LayoutModeBinding: Sendable, Hashable, Codable {
    public var enabled: Bool
    public var vietnamese: [InputSourceID]
    public var english: [InputSourceID]
    public init(enabled: Bool = false, vietnamese: [InputSourceID] = [], english: [InputSourceID] = []) {
        self.enabled = enabled
        self.vietnamese = vietnamese
        self.english = english
    }
}

public struct OnboardingState: Sendable, Hashable, Codable {
    /// App version that completed onboarding; nil = never completed (PRD-R40, PRD-R42).
    public var completedVersion: String?
    public init(completedVersion: String? = nil) { self.completedVersion = completedVersion }
}

/// Resolved values the rest of the app consumes. Never persisted.
public struct EffectiveSettings: Sendable, Hashable {
    public var typingMethod: TypingMethod
    public var tonePlacement: TonePlacement
    public var englishRestore: Bool
    public var telexStandaloneW: Bool
    public var telexBracketKeys: Bool
    public var restoreHotkey: HotkeyBinding?
    public var macrosEnabled: Bool
    public var macrosInEnglishMode: Bool
    public var toggleHotkey: HotkeyBinding
    public var rememberPerApp: Bool
    public var firstSeenAppMode: FirstSeenMode
    public var showSwitchIndicator: Bool
    public var soundOnSwitch: Bool
    public var clickIconToToggle: Bool
    public var interfaceLanguage: InterfaceLanguage
    public var automaticallyCheckForUpdates: Bool
    public var automaticallyInstallUpdates: Bool
    public var updateChannel: UpdateChannel
    public var layoutBinding: LayoutModeBinding
    public var keepAsTyped: Set<String>
    public var keepVietnamese: Set<String>
    public var optedInRules: Set<RuleID>
}

/// The shipped defaults (PRD-R5). Changing one after 1.0 needs a decision record and a release note.
public enum DefaultSettings {
    public static let v1 = EffectiveSettings(
        typingMethod: .telex,  // D1
        tonePlacement: .traditional,  // D2
        englishRestore: true,  // D4
        telexStandaloneW: true,  // D5
        telexBracketKeys: false,  // D6
        restoreHotkey: .key(.escape),  // D8 Escape; an explicit null (the off switch) stays none (Q14, 13/11/2026)
        macrosEnabled: true,  // D9
        macrosInEnglishMode: false,  // D10
        toggleHotkey: .defaultToggle,  // D11 tap Control+Shift
        rememberPerApp: true,  // D12
        firstSeenAppMode: .inherit,  // D13
        showSwitchIndicator: true,  // D14
        soundOnSwitch: false,  // D15
        clickIconToToggle: false,  // D16
        interfaceLanguage: .vietnamese,  // D18
        automaticallyCheckForUpdates: true,  // D19
        automaticallyInstallUpdates: true,  // D20
        updateChannel: .stable,  // D21
        layoutBinding: LayoutModeBinding(),
        keepAsTyped: [],
        keepVietnamese: [],
        optedInRules: []
    )
}

extension UserSettings {
    public func resolved(over defaults: EffectiveSettings = DefaultSettings.v1) -> EffectiveSettings {
        EffectiveSettings(
            typingMethod: typingMethod.resolved(default: defaults.typingMethod),
            tonePlacement: tonePlacement.resolved(default: defaults.tonePlacement),
            englishRestore: englishRestore.resolved(default: defaults.englishRestore),
            telexStandaloneW: telexStandaloneW.resolved(default: defaults.telexStandaloneW),
            telexBracketKeys: telexBracketKeys.resolved(default: defaults.telexBracketKeys),
            restoreHotkey: restoreHotkey.resolved(default: defaults.restoreHotkey),
            macrosEnabled: macrosEnabled.resolved(default: defaults.macrosEnabled),
            macrosInEnglishMode: macrosInEnglishMode.resolved(default: defaults.macrosInEnglishMode),
            toggleHotkey: toggleHotkey.resolved(default: defaults.toggleHotkey),
            rememberPerApp: rememberPerApp.resolved(default: defaults.rememberPerApp),
            firstSeenAppMode: firstSeenAppMode.resolved(default: defaults.firstSeenAppMode),
            showSwitchIndicator: showSwitchIndicator.resolved(default: defaults.showSwitchIndicator),
            soundOnSwitch: soundOnSwitch.resolved(default: defaults.soundOnSwitch),
            clickIconToToggle: clickIconToToggle.resolved(default: defaults.clickIconToToggle),
            interfaceLanguage: interfaceLanguage.resolved(default: defaults.interfaceLanguage),
            automaticallyCheckForUpdates: automaticallyCheckForUpdates.resolved(
                default: defaults.automaticallyCheckForUpdates),
            automaticallyInstallUpdates: automaticallyInstallUpdates.resolved(
                default: defaults.automaticallyInstallUpdates),
            updateChannel: updateChannel.resolved(default: defaults.updateChannel),
            layoutBinding: layoutBinding.resolved(default: defaults.layoutBinding),
            keepAsTyped: keepAsTyped,
            keepVietnamese: keepVietnamese,
            optedInRules: optedInRules
        )
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/SettingsStore/Documents.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The four files of PLT-R1001. Each is `{ "schemaVersion": Int, "writtenBy": String, ...payload }`; unknown
// keys are preserved on rewrite (PLT-R1002) because every document keeps its raw JSON object and overlays
// known keys on encode.

public import AppModel
public import Foundation

public enum SettingsFile: String, Sendable, Hashable, CaseIterable {
    case settings = "settings.json"
    case appModes = "app-modes.json"
    case ruleOverrides = "rule-overrides.json"
    case macros = "macros.json"

    /// Current schema version written by this build. CI keeps a fixture per released version (PLT-R1005).
    public var currentSchemaVersion: Int { 1 }
}

/// Common envelope. `raw` is the full object as read (or as last written), so keys this build does not know
/// survive (PLT-R1002) and a newer-schema file can be used read-only for known fields (PLT-R1007).
public struct DocumentEnvelope<Payload: Sendable & Hashable>: Sendable, Hashable {
    public var schemaVersion: Int
    public var writtenBy: String
    public var payload: Payload
    public var raw: [String: JSONValue]

    public init(schemaVersion: Int, writtenBy: String, payload: Payload, raw: [String: JSONValue] = [:]) {
        self.schemaVersion = schemaVersion
        self.writtenBy = writtenBy
        self.payload = payload
        self.raw = raw
    }
}

/// app-modes.json: global mode, explicit per-app rules and remembered modes, most recently used first
/// (PLT-R390-R393, PRD-R21-R23). At most 1,000 remembered entries; entries with an explicit rule are never
/// evicted.
public struct AppModesDocument: Sendable, Hashable {
    public var globalMode: TypingMode
    public var apps: [AppModeEntry]
    public init(globalMode: TypingMode = .vietnamese, apps: [AppModeEntry] = []) {
        self.globalMode = globalMode
        self.apps = apps
    }

    public static let rememberedCapacity = 1_000
}

public struct AppModeEntry: Sendable, Hashable, Codable {
    public var bundle: BundleKey
    /// Explicit user rule (`nil` and `.remember` both mean "use memory").
    public var rule: PerAppRule?
    public var mode: TypingMode?
    public init(bundle: BundleKey, rule: PerAppRule? = nil, mode: TypingMode? = nil) {
        self.bundle = bundle
        self.rule = rule
        self.mode = mode
    }
}

/// rule-overrides.json entry (PLT-R541). `rule` is raw rule JSON in the 02-platform.md 5.4 schema with
/// `id` prefixed `user.`; CompatRules decodes and validates it. Kept raw so unknown rule keys survive.
public struct StoredRuleOverride: Sendable, Hashable {
    public var createdAt: Date  // "set by you on <date>"
    public var rule: JSONValue
    public init(createdAt: Date, rule: JSONValue) {
        self.createdAt = createdAt
        self.rule = rule
    }
}

/// macros.json entry (PRD-R29-R31). Content: never logged, never in diagnostics (PRD-R33).
public struct StoredMacro: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var trigger: String
    public var expansion: String
    public var adaptCase: Bool
    public var enabled: Bool
    public init(id: UUID = UUID(), trigger: String, expansion: String, adaptCase: Bool = true, enabled: Bool = true) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
        self.adaptCase = adaptCase
        self.enabled = enabled
    }
}

/// Where the files live (PLT-R1001, Appendix A). Built by the App from the `Brand` helper: the folder is the
/// display name when it is ASCII, otherwise the slug (PLT-R903), and is frozen at the first public release
/// (docs/decisions/0307-settings-file-layout.md).
public struct StorageLocation: Sendable, Hashable {
    public var directory: URL  // ~/Library/Application Support/<folder>/
    public var backupsDirectory: URL { directory.appendingPathComponent("backups", isDirectory: true) }
    public func url(for file: SettingsFile) -> URL { directory.appendingPathComponent(file.rawValue) }
    public init(directory: URL) { self.directory = directory }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/SettingsStore/Migrations.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later

public import AppModel

/// Pure function from schema version N to N+1 over the raw JSON object (PLT-R1005). Migrations never drop
/// unknown keys.
public protocol DocumentMigration: Sendable {
    var file: SettingsFile { get }
    var fromVersion: Int { get }
    func migrate(_ object: [String: JSONValue]) throws -> [String: JSONValue]
}

public enum MigrationError: Error, Sendable, Hashable {
    case missingStep(file: SettingsFile, from: Int)
    case invalidDocument(file: SettingsFile, reason: String)
}

/// Chains registered migrations. Before migrating, the store copies the original to
/// `backups/<file>.v<N>.<timestamp>.json` and keeps the newest five per file (PLT-R1005).
public struct MigrationChain: Sendable {
    private let steps: [SettingsFile: [Int: any DocumentMigration]]

    /// When two migrations claim the same file and version, the later one in the array wins.
    public init(_ migrations: [any DocumentMigration]) {
        var steps: [SettingsFile: [Int: any DocumentMigration]] = [:]
        for migration in migrations { steps[migration.file, default: [:]][migration.fromVersion] = migration }
        self.steps = steps
    }

    /// Applies each step from `from` up to `to` in order and stamps `schemaVersion` after each one, so a step
    /// only has to transform its payload. `from == to` returns the object unchanged; going down is an error.
    public func migrate(_ object: [String: JSONValue], file: SettingsFile, from: Int, to: Int) throws
        -> [String: JSONValue]
    {
        guard from <= to else {
            throw MigrationError.invalidDocument(file: file, reason: "cannot migrate to an older schema")
        }
        var current = object
        for version in from..<to {
            guard let step = steps[file]?[version] else { throw MigrationError.missingStep(file: file, from: version) }
            current = try step.migrate(current)
            current["schemaVersion"] = .number(Double(version + 1))
        }
        return current
    }

    /// All migrations shipped by this build (empty while every file is at version 1).
    ///
    /// settings.json stays at version 1 for per-app learning (ENG-R862, ADR 0320): `englishRestoreLists` gains the
    /// optional `learnedWords` array, which builds without it keep unread (PLT-R1002). No step is needed for the
    /// files written before it: their `keepAsTyped` and `keepVietnamese` entries carry no app, so they are read as
    /// global entries, and so is a `learnedWords` item without an app (`LearnedWordsCodec`).
    public static let shipped = MigrationChain([])
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/SettingsStore/SettingsStore.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Settings persistence (PLT-R10xx). An actor whose executor is the utility serial queue, so all reads,
// migrations and debounced atomic writes are serialized there (PLT-R1003, PLT-R203 "utility queue"). The
// executor is `QueueExecutor` (ADR 0315: `DispatchSerialQueue` is an executor only from macOS 14).
// Loading lives in SettingsStore+Load.swift, writing in SettingsStore+Persistence.swift, reset and import in
// SettingsStore+Transfer.swift.

public import AppModel
public import Dispatch
public import Foundation

/// Everything the rest of the app needs, published after every change (PLT-R1008: live, no restart).
public struct SettingsState: Sendable, Hashable {
    public var generation: UInt64
    public var user: UserSettings
    public var effective: EffectiveSettings
    public var appModes: AppModesDocument
    public var ruleOverrides: [StoredRuleOverride]
    public var macros: [StoredMacro]
    /// A file was written by a newer schema: known fields are used, nothing is written (PLT-R1007).
    public var readOnlyFiles: Set<SettingsFile>
    /// Crash-loop safe mode: defaults in memory, files untouched (PLT-R1009).
    public var safeMode: Bool
    public var notices: [StoreNotice]

    /// `effective` is derived from `user` over `DefaultSettings.v1`. For consumers' tests and previews.
    public init(
        generation: UInt64 = 0, user: UserSettings = UserSettings(), appModes: AppModesDocument = AppModesDocument(),
        ruleOverrides: [StoredRuleOverride] = [], macros: [StoredMacro] = [], readOnlyFiles: Set<SettingsFile> = [],
        safeMode: Bool = false, notices: [StoreNotice] = []
    ) {
        self.generation = generation
        self.user = user
        self.effective = user.resolved()
        self.appModes = appModes
        self.ruleOverrides = ruleOverrides
        self.macros = macros
        self.readOnlyFiles = readOnlyFiles
        self.safeMode = safeMode
        self.notices = notices
    }
}

/// User-visible notices (PLT-R1006, PLT-R1007, PLT-R1009), rendered by ShellCore.
public enum StoreNotice: Sendable, Hashable {
    case recoveredFromBackup(SettingsFile, backupDate: Date)
    case corruptFileUsingDefaults(SettingsFile)  // nothing overwritten until the user confirms
    case newerSchemaReadOnly(SettingsFile, schemaVersion: Int)
    case safeMode(recentCrashes: Int)
    /// `errno` is the POSIX code of the failed write, logged by the composition root (PLT-R1202); `noErrno` when
    /// the failure carried none. At most one per file: a later failure replaces it, a successful write clears it.
    case writeFailed(SettingsFile, errno: Int32)
}

extension StoreNotice {
    /// The `errno` of a `writeFailed` whose error had no POSIX code (for example a serialisation failure).
    public static let noErrno: Int32 = 0

    /// The POSIX code behind a failed file operation (`FileSystemError`), `noErrno` for any other error.
    static func errno(of error: any Error) -> Int32 {
        switch error as? FileSystemError {
        case .ioFailure(_, let code)?: code
        case .notFound?: ENOENT
        case .tooLarge?: EFBIG
        case nil: noErrno
        }
    }
}

public enum ResetScope: Sendable, Hashable {
    case all(includeMacros: Bool)  // PRD-R26: macros only with the separate checkbox
    case general, typing, apps  // per pane
    /// Macros pane (PRD-R26): D9 and D10 back to "unset" (PRD-R6); the list is emptied only when `includeList`
    /// (the separate checkbox). Each rewritten file is backed up first, like every reset (PLT-R1006).
    case macros(includeList: Bool)
}

public actor SettingsStore {
    /// Serial queue the store's jobs run on.
    let queue: DispatchQueue
    let executor: QueueExecutor
    let storage: DocumentStorage
    let writtenBy: String
    let migrations: MigrationChain
    let launchGuard: LaunchGuard
    let scheduler: any DebounceScheduler
    let onChange: @Sendable (SettingsState) -> Void

    var user = UserSettings()
    var appModes = AppModesDocument()
    var ruleOverrides: [StoredRuleOverride] = []
    var macros: [StoredMacro] = []
    var files: [SettingsFile: FileStatus] = [:]
    var notices: [StoreNotice] = []
    var safeMode = false
    /// Nothing is written before the first `load()`: an early write would replace files not read yet.
    var loaded = false
    var generation: UInt64 = 0
    var nextTimerToken: UInt64 = 0

    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    /// - Parameters:
    ///   - queue: the utility serial queue (QoS utility); must be serial.
    ///   - writtenBy: app version recorded in every file (PLT-R1002).
    ///   - scheduler: debounce timers; nil = `DispatchDebounceScheduler` on `queue`. Tests pass a manual one.
    ///   - onChange: called on `queue` after each change; InputHost publishes snapshots from it, ShellCore
    ///     hops to the main actor.
    public init(
        location: StorageLocation,
        fileSystem: any FileSystem,
        wallClock: any WallClock,
        writtenBy: String,
        queue: DispatchQueue,
        migrations: MigrationChain = .shipped,
        launchGuard: LaunchGuard,
        scheduler: (any DebounceScheduler)? = nil,
        onChange: @escaping @Sendable (SettingsState) -> Void
    ) {
        self.queue = queue
        self.executor = QueueExecutor(queue: queue)
        self.storage = DocumentStorage(location: location, fileSystem: fileSystem, wallClock: wallClock)
        self.writtenBy = writtenBy
        self.migrations = migrations
        self.launchGuard = launchGuard
        self.scheduler = scheduler ?? DispatchDebounceScheduler(queue: queue)
        self.onChange = onChange
    }

    /// Loads all four files: migrate (with backups), recover from corruption (PLT-R1006), detect newer
    /// schema (PLT-R1007), honour safe mode (PLT-R1009).
    public func load() -> SettingsState {
        performLoad()
        return state
    }

    public var state: SettingsState {
        SettingsState(
            generation: generation, user: user, appModes: appModes, ruleOverrides: ruleOverrides, macros: macros,
            readOnlyFiles: Set(files.filter { $0.value.readOnly }.keys), safeMode: safeMode, notices: notices)
    }

    /// Applies an explicit change (debounced write, 1 s).
    public func updateSettings(_ change: @Sendable (inout UserSettings) -> Void) {
        var next = user
        change(&next)
        guard next != user else { return }
        user = next
        changed(.settings, after: WriteDelay.standard)
    }

    /// Per-app explicit rule from the menu or the Apps pane (PRD-R21). `nil` clears it.
    public func setAppRule(_ rule: PerAppRule?, for bundle: BundleKey) {
        let next = appModes.settingRule(rule, for: bundle)
        guard next != appModes else { return }
        appModes = next
        changed(.appModes, after: WriteDelay.standard)
    }

    /// Remembered modes and global mode from InputHost's memory; written with a 5 s debounce (PLT-R392).
    /// Explicit rules stay as set through `setAppRule`, so a copy that left the ax thread before a rule change
    /// can never revert that rule.
    public func recordAppModes(_ document: AppModesDocument) {
        let next = appModes.recordingMemory(from: document)
        guard next != appModes else { return }
        appModes = next
        changed(.appModes, after: WriteDelay.appModes)
    }

    /// Adds or replaces (same `user.` rule id) an override. A rule without a valid `user.` id is ignored; the
    /// date is kept to the second so it reads back unchanged (PLT-R541 "set by you on <date>").
    public func addRuleOverride(_ override: StoredRuleOverride) {
        guard let id = override.ruleID else { return }
        let stored = StoredRuleOverride(
            createdAt: StorageTimestamp.wholeSeconds(override.createdAt), rule: override.rule)
        var next = ruleOverrides
        if let index = next.firstIndex(where: { $0.ruleID == id }) { next[index] = stored } else { next.append(stored) }
        guard next != ruleOverrides else { return }
        ruleOverrides = next
        changed(.ruleOverrides, after: WriteDelay.standard)
    }

    public func removeRuleOverride(id: RuleID) {
        let next = ruleOverrides.filter { $0.ruleID != id }
        guard next != ruleOverrides else { return }
        ruleOverrides = next
        changed(.ruleOverrides, after: WriteDelay.standard)
    }

    /// The editor validates entries (`MacroValidator`); the store keeps them as given.
    public func replaceMacros(_ macros: [StoredMacro]) {
        guard macros != self.macros else { return }
        self.macros = macros
        changed(.macros, after: WriteDelay.standard)
    }

    /// PRD-R26. The caller offers an export first.
    public func reset(_ scope: ResetScope) { performReset(scope) }

    /// User confirmed using defaults after a corrupt file without backup (PLT-R1006): writes the in-memory state
    /// of that file, including changes made meanwhile. For a state recovered from a backup (already written at
    /// load) it only dismisses the notice.
    public func confirmDefaults(for file: SettingsFile) {
        guard status(file).awaitingConfirmation else {
            // A recovered backup is already saved: confirming only dismisses the notice.
            if notices.contains(where: { $0.isRecovery(of: file) }) {
                notices.removeAll { $0.isRecovery(of: file) }
                publish()
            }
            return
        }
        updateStatus(file) {
            $0.awaitingConfirmation = false
            $0.dirty = true
        }
        notices.removeAll { $0.isRecovery(of: file) }
        writeNow(file)
        publish()
    }

    /// Leaves safe mode and resets the launch guard.
    public func exitSafeMode() {
        launchGuard.reset()
        guard safeMode else { return }
        performLoad()
    }

    /// Writes pending changes immediately (quit, update install).
    public func flush() {
        var noticesChanged = false
        for file in SettingsFile.allCases {
            cancelPendingWrite(file)
            noticesChanged = writeNow(file) || noticesChanged
        }
        if noticesChanged { publish() }
    }

    // MARK: Export and import (PLT-R1010, PRD-R72)

    public func export(_ options: ExportOptions, now: Date) throws -> Data { try exportData(options, now: now) }
    /// Validates untrusted data (5 MB cap, schema, no evaluation, PLT-R912) and builds a preview.
    public func previewImport(_ data: Data) throws -> ImportPreview {
        try SettingsImporter(migrations: migrations).preview(data, baseline: ImportBaseline(user: user, macros: macros))
    }
    /// Backs up current files, applies, migrates older schemas, lists skipped fields of newer schemas.
    public func applyImport(_ preview: ImportPreview, choices: ImportChoices) throws {
        try performImport(preview, choices: choices)
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/SettingsStore/ExportImport.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Own export format (PLT-R1010, PRD-R72), brand-neutral so renaming the app never breaks old exports:
//
//     {
//       "kind": "settings-export",
//       "schemaVersion": 1,
//       "writtenBy": "0.1.0",
//       "exportedAt": "2026-11-13T09:00:00Z",
//       "settings": { ...settings.json without envelope... },
//       "appModes": { ...app-modes.json without envelope... },   // optional (unticked = absent)
//       "ruleOverrides": [ ...stored overrides... ],
//       "macros": [ ...stored macros... ]                         // optional (unticked = absent)
//     }
//
// File name: `<slug>-settings-YYYYMMDD.json` (slug injected by the App).

public import AppModel
public import Foundation

public struct ExportOptions: Sendable, Hashable {
    public var includeMacros: Bool  // the sheet notes that macros may contain private text
    public var includeAppModes: Bool
    public init(includeMacros: Bool = true, includeAppModes: Bool = true) {
        self.includeMacros = includeMacros
        self.includeAppModes = includeAppModes
    }

    /// `<slug>-settings-YYYYMMDD.json`, dated in the user's time zone.
    public static func fileName(slug: String, date: Date) -> String {
        fileName(slug: slug, date: date, timeZone: .current)
    }

    static func fileName(slug: String, date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let day = String(format: "%04d%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        return "\(slug)-settings-\(day).json"
    }
}

public struct ImportPreview: Sendable, Hashable {
    public var schemaVersion: Int
    public var changedSettingKeys: [String]
    public var appEntries: Int
    public var ruleOverrides: Int
    public var macros: MacroImportPreview?
    /// Keys from a newer schema that this build will skip (PLT-R1010).
    public var skippedFields: [String]
    /// Opaque validated content applied by `applyImport`.
    public var content: JSONValue
}

public struct ImportChoices: Sendable, Hashable {
    public var applySettings: Bool
    public var applyAppModes: Bool
    public var applyRuleOverrides: Bool
    /// Off = the macros in the file are ignored (the preview still lists them).
    public var applyMacros: Bool
    public var macroDuplicates: MacroDuplicateResolution
    public init(
        applySettings: Bool = true, applyAppModes: Bool = true, applyRuleOverrides: Bool = true,
        applyMacros: Bool = true, macroDuplicates: MacroDuplicateResolution = .keepMine
    ) {
        self.applySettings = applySettings
        self.applyAppModes = applyAppModes
        self.applyRuleOverrides = applyRuleOverrides
        self.applyMacros = applyMacros
        self.macroDuplicates = macroDuplicates
    }
}

/// Why an import file was refused (PLT-R912). Each case is a reason the import sheet can explain (PRD-R43).
public enum SettingsImportError: Error, Sendable, Hashable {
    case tooLarge(limit: Int)
    case tooDeeplyNested(limit: Int)
    case notJSON
    case notAnObject
    /// Valid JSON, but not this app's settings export (`kind` is not `settings-export`).
    case notASettingsExport
    case invalidSchemaVersion
    /// A section has the wrong JSON type (`settings` and `appModes` must be objects, the others arrays).
    case invalidSection(String)
    /// An older export this build cannot migrate.
    case migrationFailed(fromVersion: Int)
    /// Crash-loop safe mode touches no files (PLT-R1009); leave safe mode first.
    case unavailableInSafeMode
}

/// The export format. The schema version and the import cap are public so the Settings window's import sheet
/// reads them from here instead of keeping copies (PLT-R912, PRD-R72).
public enum SettingsExportFormat {
    static let kind = "settings-export"
    /// The export schema this build writes; a file above it is "from a newer version" (PLT-R1010).
    public static let schemaVersion = 1
    /// PLT-R912: larger files are refused before parsing (`SettingsImportError.tooLarge`).
    public static let maxImportBytes = 5 * 1024 * 1024
    static let headerKeys: Set<String> = ["kind", "schemaVersion", "writtenBy", "exportedAt"]
    static let settings = "settings", appModes = "appModes", ruleOverrides = "ruleOverrides", macros = "macros"
    static let sectionKeys: Set<String> = [settings, appModes, ruleOverrides, macros]
}

/// The store's documents as an import is previewed against them.
struct ImportBaseline: Sendable {
    var user: UserSettings
    var macros: [StoredMacro]
}

/// Validates an untrusted export (5 MB cap, bounded nesting, schema checks, no evaluation of content) and builds
/// the preview (PLT-R912, PLT-R1010). Older exports are migrated section by section; content of a newer schema
/// is read for known fields and everything else is listed in `skippedFields`.
struct SettingsImporter {
    let migrations: MigrationChain

    func preview(_ data: Data, baseline: ImportBaseline) throws(SettingsImportError) -> ImportPreview {
        let root = try parseRoot(data)
        guard let version = root[EnvelopeKey.schemaVersion]?.intValue, version >= 0 else {
            throw .invalidSchemaVersion
        }
        var skipped = root.keys.filter {
            !SettingsExportFormat.headerKeys.contains($0) && !SettingsExportFormat.sectionKeys.contains($0)
        }.sorted()
        var content: [String: JSONValue] = [:]
        var preview = ImportPreview(
            schemaVersion: version, changedSettingKeys: [], appEntries: 0, ruleOverrides: 0, macros: nil,
            skippedFields: [], content: .null)

        if let section = try objectSection(root, SettingsExportFormat.settings) {
            let object = try migrated(section, file: .settings, from: version)
            let user = SettingsCodec.decode(object)
            skipped += SettingsCodec.skippedPaths(in: object).map { "settings." + $0 }
            preview.changedSettingKeys = Self.changedKeys(from: baseline.user, to: user)
            content[SettingsExportFormat.settings] = .object(SettingsCodec.encode(user, over: [:]))
        }
        if let section = try objectSection(root, SettingsExportFormat.appModes) {
            let object = try migrated(section, file: .appModes, from: version)
            let document = AppModesCodec.decode(object)
            skipped += AppModesCodec.skippedPaths(in: object).map { "appModes." + $0 }
            preview.appEntries = document.apps.count
            content[SettingsExportFormat.appModes] = .object(AppModesCodec.encode(document, over: [:]))
        }
        if let items = try arraySection(root, SettingsExportFormat.ruleOverrides) {
            let object = try migrated(["overrides": .array(items)], file: .ruleOverrides, from: version)
            let overrides = RuleOverridesCodec.decode(object)
            skipped += RuleOverridesCodec.skippedPaths(in: object).map { "ruleOverrides." + $0 }
            preview.ruleOverrides = overrides.count
            content[SettingsExportFormat.ruleOverrides] = .array(RuleOverridesCodec.encodeList(overrides, over: []))
        }
        if let items = try arraySection(root, SettingsExportFormat.macros) {
            let object = try migrated(["macros": .array(items)], file: .macros, from: version)
            let rows = MacroJSONParser.rows(fromItems: arrayItems(object["macros"]))
            preview.macros = MacroImporter.preview(rows, existing: baseline.macros)
        }
        preview.skippedFields = skipped
        preview.content = .object(content)
        return preview
    }

    private func parseRoot(_ data: Data) throws(SettingsImportError) -> [String: JSONValue] {
        guard data.count <= SettingsExportFormat.maxImportBytes else {
            throw .tooLarge(limit: SettingsExportFormat.maxImportBytes)
        }
        let root: [String: JSONValue]
        do {
            root = try JSONSupport.parseObject(data)
        } catch {
            switch error {
            case .tooDeeplyNested(let limit): throw .tooDeeplyNested(limit: limit)
            case .notAnObject: throw .notAnObject
            case .empty, .invalidJSON: throw .notJSON
            }
        }
        guard root["kind"]?.stringValue == SettingsExportFormat.kind else { throw .notASettingsExport }
        return root
    }

    private func objectSection(_ root: [String: JSONValue], _ key: String) throws(SettingsImportError)
        -> [String: JSONValue]?
    {
        guard let value = root[key] else { return nil }
        guard case .object(let object) = value else { throw .invalidSection(key) }
        return object
    }

    private func arraySection(_ root: [String: JSONValue], _ key: String) throws(SettingsImportError) -> [JSONValue]? {
        guard let value = root[key] else { return nil }
        guard case .array(let items) = value else { throw .invalidSection(key) }
        return items
    }

    /// A section of an older export goes through the same migrations as the file it belongs to.
    private func migrated(_ payload: [String: JSONValue], file: SettingsFile, from version: Int)
        throws(SettingsImportError) -> [String: JSONValue]
    {
        guard version < file.currentSchemaVersion else { return payload }
        var object = payload
        object[EnvelopeKey.schemaVersion] = .number(Double(version))
        do {
            object = try migrations.migrate(object, file: file, from: version, to: file.currentSchemaVersion)
        } catch {
            throw .migrationFailed(fromVersion: version)
        }
        for key in EnvelopeKey.all { object.removeValue(forKey: key) }
        return object
    }

    /// Setting keys whose value would change; onboarding is machine state and never imported.
    static func changedKeys(from current: UserSettings, to imported: UserSettings) -> [String] {
        var keys = SettingFields.all.filter { !$0.isEqual(current, imported) }.map(\.key)
        if current.keepAsTyped != imported.keepAsTyped { keys.append(SettingListKey.keepAsTyped) }
        if current.keepVietnamese != imported.keepVietnamese { keys.append(SettingListKey.keepVietnamese) }
        if current.learnedWords != imported.learnedWords { keys.append(SettingListKey.learnedWords) }
        if current.optedInRules != imported.optedInRules { keys.append(SettingListKey.optedInRules) }
        return keys
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/SettingsStore/MacroImport.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Macro import (PRD-R32, PRD-R69, PRD-R70). Tolerant: invalid rows are skipped with a reason, one bad row
// never aborts the import, duplicates never overwrite without the user's choice.
//
// Accepted formats:
// - appExport: this app's settings export (`macros` array) or a bare macros.json.
// - tabSeparated: UTF-8 text, one `shortcut<TAB>expansion` per line; `\n`, `\t` and `\\` escapes in the
//   expansion decode to newline, tab and backslash; blank lines and lines starting with `#` are ignored.
// - csv: RFC 4180, two columns (shortcut, expansion), quoted fields may contain newlines; a first row equal to
//   a known header (`shortcut,expansion`, `trigger,expansion`, `phím tắt,nội dung`) is skipped.
// - textReplacementsPlist: property list array of dictionaries with `shortcut` and `phrase` keys, the file
//   produced by dragging entries out of System Settings > Keyboard > Text Replacements (VERIFY on macOS 27).

internal import AppModel
public import Foundation

public enum MacroImportFormat: String, Sendable, Hashable, CaseIterable {
    case appExport, tabSeparated, csv, textReplacementsPlist
}

/// Why a row was rejected (shown in the preview, PRD-R43 "Dòng 12: thiếu phần nội dung gõ tắt").
public enum MacroRowIssue: Sendable, Hashable {
    case emptyShortcut
    case emptyExpansion
    case shortcutTooLong  // > 32
    case shortcutHasWhitespace
    case shortcutNotPrintableASCII  // includes Vietnamese letters (PRD-R29)
    case expansionTooLong  // > 4,000
    case shadowedBy(shorter: String)  // shortcut = other shortcut + trailing punctuation (PRD-R29)
    /// The other shortcut equals this one plus trailing punctuation, so this one would make it unreachable
    /// (engine `shadowedByShorterTrigger`, seen from the shorter side).
    case shadows(longer: String)
    /// Same shortcut, compared case-insensitively, as another entry (engine `duplicateTrigger`).
    case duplicate(of: String)
    case malformedLine
}

public struct MacroImportRow: Sendable, Hashable {
    /// 1-based line of a text file, or 1-based entry number in a JSON array or property list.
    public var line: Int
    public var shortcut: String
    public var expansion: String
    public var issue: MacroRowIssue?
    /// From this app's own export only; kept when it does not clash (contracts.md 7.3 "id regenerated on
    /// conflict"), so export then import reproduces the same macros.
    public var id: UUID?
    public var adaptCase: Bool
    public var enabled: Bool

    public init(
        line: Int, shortcut: String, expansion: String, issue: MacroRowIssue? = nil, id: UUID? = nil,
        adaptCase: Bool = true, enabled: Bool = true
    ) {
        self.line = line
        self.shortcut = shortcut
        self.expansion = expansion
        self.issue = issue
        self.id = id
        self.adaptCase = adaptCase
        self.enabled = enabled
    }
}

public enum MacroDuplicateResolution: String, Sendable, Hashable { case keepMine, useImported }

public struct MacroImportPreview: Sendable, Hashable {
    public var new: [StoredMacro]
    public var duplicates: [(existing: StoredMacro, imported: StoredMacro)]
    public var invalid: [MacroImportRow]

    public init(
        new: [StoredMacro] = [], duplicates: [(existing: StoredMacro, imported: StoredMacro)] = [],
        invalid: [MacroImportRow] = []
    ) {
        self.new = new
        self.duplicates = duplicates
        self.invalid = invalid
    }

    public static func == (lhs: MacroImportPreview, rhs: MacroImportPreview) -> Bool {
        lhs.new == rhs.new && lhs.invalid == rhs.invalid
            && lhs.duplicates.map(\.existing) == rhs.duplicates.map(\.existing)
            && lhs.duplicates.map(\.imported) == rhs.duplicates.map(\.imported)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(new)
        hasher.combine(invalid)
        hasher.combine(duplicates.map(\.imported))
    }
}

public enum MacroImporter {
    /// Files larger than this are refused before parsing (same cap as settings import, PLT-R912).
    public static let maxFileBytes = 5 * 1024 * 1024

    /// Sniffs content first (plist header, JSON object, tabs vs commas), then the extension.
    public static func detectFormat(_ data: Data, fileExtension: String?) -> MacroImportFormat? {
        MacroFormatSniffer.detect(data, fileExtension: fileExtension?.lowercased())
    }

    /// Rows in file order. Structural problems and per-row rules (PRD-R29) are filled in `issue`; duplicates
    /// and shadowing need the other rows and the user's macros, so `preview` decides those. A file that cannot
    /// be read at all yields one `malformedLine` row at line 1; an empty file yields no rows.
    public static func parse(_ data: Data, format: MacroImportFormat) -> [MacroImportRow] {
        guard data.count <= maxFileBytes else {
            return [MacroImportRow(line: 1, shortcut: "", expansion: "", issue: .malformedLine)]
        }
        let rows: [MacroImportRow]
        switch format {
        case .appExport: rows = MacroJSONParser.parse(data)
        case .tabSeparated: rows = MacroTextParser.parseTabSeparated(data)
        case .csv: rows = MacroTextParser.parseCSV(data)
        case .textReplacementsPlist: rows = MacroPlistParser.parse(data)
        }
        return rows.map(validated)
    }

    /// Duplicates are by case-insensitive shortcut (matching is case-insensitive, ENG-R1101).
    ///
    /// A valid row whose shortcut matches one of `existing` is a duplicate (resolved later by the user's
    /// choice); a repeat inside the file is invalid. Shadowing (PRD-R29) is checked against the user's macros in
    /// both directions and among the imported rows so that the longer shortcut is the one rejected, whatever
    /// the row order. Imported rows never displace an existing macro.
    public static func preview(_ rows: [MacroImportRow], existing: [StoredMacro]) -> MacroImportPreview {
        var existingByKey: [String: StoredMacro] = [:]
        for macro in existing where existingByKey[MacroValidator.key(macro.trigger)] == nil {
            existingByKey[MacroValidator.key(macro.trigger)] = macro
        }
        var preview = MacroImportPreview()
        var seen = Set<String>()
        var candidates: [MacroImportRow] = []
        for row in rows.map(validated) {
            let key = MacroValidator.key(row.shortcut)
            if row.issue != nil {
                preview.invalid.append(row)
            } else if !seen.insert(key).inserted {
                preview.invalid.append(rejected(row, .duplicate(of: row.shortcut)))
            } else if let mine = existingByKey[key] {
                preview.duplicates.append((mine, storedMacro(from: row, id: mine.id)))
            } else {
                candidates.append(row)
            }
        }
        addNew(candidates, existing: existing, to: &preview)
        preview.invalid.sort { $0.line < $1.line }
        return preview
    }

    /// Rows that conflict with the user's macros are rejected first; among the rest only the longer shortcut
    /// of a shadowing pair is rejected.
    private static func addNew(
        _ candidates: [MacroImportRow], existing: [StoredMacro], to preview: inout MacroImportPreview
    ) {
        let existingTriggers = existing.map(\.trigger)
        var accepted: [MacroImportRow] = []
        for row in candidates {
            if let issue = MacroValidator.shadowing(row.shortcut, against: existingTriggers) {
                preview.invalid.append(rejected(row, issue))
            } else {
                accepted.append(row)
            }
        }
        let acceptedShortcuts = accepted.map(\.shortcut)
        var usedIDs = Set(existing.map(\.id))
        for row in accepted {
            if let issue = MacroValidator.shadowedBy(row.shortcut, among: acceptedShortcuts) {
                preview.invalid.append(rejected(row, issue))
                continue
            }
            let id = row.id.flatMap { usedIDs.contains($0) ? nil : $0 } ?? UUID()
            usedIDs.insert(id)
            preview.new.append(storedMacro(from: row, id: id))
        }
    }

    /// `useImported` replaces each duplicate in place (keeping its id); `keepMine` leaves it. New macros are
    /// appended; an id that is taken by then gets a fresh one, and a shortcut that is taken by then is skipped.
    public static func merge(
        _ preview: MacroImportPreview, into existing: [StoredMacro],
        resolution: MacroDuplicateResolution
    ) -> [StoredMacro] {
        var result = existing
        if resolution == .useImported {
            for (mine, imported) in preview.duplicates {
                guard let index = result.firstIndex(where: { $0.id == mine.id }) else { continue }
                result[index] = StoredMacro(
                    id: mine.id, trigger: imported.trigger, expansion: imported.expansion,
                    adaptCase: imported.adaptCase, enabled: imported.enabled)
            }
        }
        var ids = Set(result.map(\.id))
        var keys = Set(result.map { MacroValidator.key($0.trigger) })
        for macro in preview.new where keys.insert(MacroValidator.key(macro.trigger)).inserted {
            var macro = macro
            if !ids.insert(macro.id).inserted {
                macro.id = UUID()
                ids.insert(macro.id)
            }
            result.append(macro)
        }
        return result
    }

    private static func validated(_ row: MacroImportRow) -> MacroImportRow {
        guard row.issue == nil else { return row }
        var row = row
        row.issue = MacroValidator.issue(shortcut: row.shortcut, expansion: row.expansion, others: [])
        return row
    }

    private static func rejected(_ row: MacroImportRow, _ issue: MacroRowIssue) -> MacroImportRow {
        var row = row
        row.issue = issue
        return row
    }

    private static func storedMacro(from row: MacroImportRow, id: UUID) -> StoredMacro {
        StoredMacro(
            id: id, trigger: row.shortcut, expansion: row.expansion, adaptCase: row.adaptCase, enabled: row.enabled)
    }
}

/// Editor-side validation (PRD-R29). The engine's `MacroTable.init` stays authoritative when the table is
/// built: `MacroEngineAgreementTests` builds a `MacroTable` from seeded random tables this validator accepts
/// (typed or imported and merged) and checks pairwise agreement in both directions.
///
/// Agreement with `MacroTable.ValidationError` (ENG-R1101, ENG-R1103): `emptyTrigger` = `emptyShortcut`;
/// `triggerTooLong` = `shortcutTooLong` (more than 32); `invalidTriggerCharacter` = `shortcutHasWhitespace` or
/// `shortcutNotPrintableASCII` (only U+0021...U+007E are allowed); `expansionTooLong` = `expansionTooLong` (more
/// than 4,000 characters, counted as `String.count`); `duplicateTrigger` = `duplicate(of:)`;
/// `shadowedByShorterTrigger` = `shadowedBy(shorter:)` / `shadows(longer:)` (punctuation or a main-row digit after
/// the shorter trigger, ENG-R1103). The editor is stricter in one place:
/// an empty expansion is rejected (`emptyExpansion`, PRD-R43 example).
public enum MacroValidator {
    public static let maxShortcutLength = 32
    public static let maxExpansionLength = 4_000

    /// First problem of `shortcut -> expansion` among `others` (pass every macro except the one being edited;
    /// disabled macros count, because enabling one later must not produce a table the engine rejects).
    public static func issue(shortcut: String, expansion: String, others: [StoredMacro]) -> MacroRowIssue? {
        if let issue = shortcutIssue(shortcut) { return issue }
        if expansion.isEmpty { return .emptyExpansion }
        if expansion.count > maxExpansionLength { return .expansionTooLong }
        let key = key(shortcut)
        if let same = others.first(where: { Self.key($0.trigger) == key }) { return .duplicate(of: same.trigger) }
        return shadowing(shortcut, against: others.map(\.trigger))
    }

    static func shortcutIssue(_ shortcut: String) -> MacroRowIssue? {
        if shortcut.isEmpty { return .emptyShortcut }
        if shortcut.unicodeScalars.contains(where: { $0.properties.isWhitespace }) { return .shortcutHasWhitespace }
        if !shortcut.unicodeScalars.allSatisfy(isPrintableASCII) { return .shortcutNotPrintableASCII }
        if shortcut.unicodeScalars.count > maxShortcutLength { return .shortcutTooLong }
        return nil
    }

    /// Shadowing in both directions against existing shortcuts (ENG-R1103).
    static func shadowing(_ shortcut: String, against triggers: [String]) -> MacroRowIssue? {
        let key = key(shortcut)
        if let shorter = triggers.first(where: { isShadowed(key, by: Self.key($0)) }) {
            return .shadowedBy(shorter: shorter)
        }
        if let longer = triggers.first(where: { isShadowed(Self.key($0), by: key) }) { return .shadows(longer: longer) }
        return nil
    }

    /// Only the longer side of a pair is rejected among imported rows.
    static func shadowedBy(_ shortcut: String, among shortcuts: [String]) -> MacroRowIssue? {
        let key = key(shortcut)
        return shortcuts.first { isShadowed(key, by: Self.key($0)) }.map { .shadowedBy(shorter: $0) }
    }

    /// `longer` starts with `shorter` followed by an ASCII punctuation character or a main-row digit: that key is a
    /// boundary at which the span equals `shorter`, so `shorter` expands there and `longer` can never fire,
    /// whatever comes after it (PRD-R29, ENG-R1103, 01-engine.md section 9.2: `vn` shadows `vn.` and `vn.x`). A
    /// digit is a boundary in Telex, so `k` shadows `k1`; the check does not depend on the typing method, exactly
    /// like the engine's (decision of the product owner, 13/11/2026).
    static func isShadowed(_ longer: String, by shorter: String) -> Bool {
        let shorterScalars = shorter.unicodeScalars
        guard !shorterScalars.isEmpty, longer.unicodeScalars.count > shorterScalars.count, longer.hasPrefix(shorter),
            let next = longer.unicodeScalars.dropFirst(shorterScalars.count).first
        else { return false }
        return endsShorterShortcut(next)
    }

    /// Punctuation or a main-row digit: typed right after a complete shortcut, it fires that shortcut (ENG-R1103).
    static func endsShorterShortcut(_ scalar: Unicode.Scalar) -> Bool {
        isASCIIPunctuation(scalar) || ("0"..."9").contains(scalar)
    }

    /// Matching key: ASCII-lowercased shortcut (ENG-R1101 case-insensitive matching).
    static func key(_ shortcut: String) -> String { shortcut.lowercased() }

    static func isPrintableASCII(_ scalar: Unicode.Scalar) -> Bool { (0x21...0x7E).contains(scalar.value) }

    static func isASCIIPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        isPrintableASCII(scalar) && !(scalar.properties.isAlphabetic || ("0"..."9").contains(scalar))
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/SettingsStore/LaunchGuard.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later

internal import AppModel
internal import RealtimeSupport

//
// Crash-loop safe mode (PLT-R1009): three launches that did not survive 60 s within a short window start the
// app with defaults in memory, without touching files.

/// Small key-value persistence for the guard (the app's user defaults domain in production, so the settings
/// folder holds only the four documented files).
public protocol KeyValueStore: Sendable {
    func integer(forKey key: String) -> Int
    func set(_ value: Int, forKey key: String)
    func double(forKey key: String) -> Double
    func set(_ value: Double, forKey key: String)
}

public final class LaunchGuard: Sendable {
    public static let crashThreshold = 3
    public static let survivalSeconds: Double = 60
    /// The crashed launches of one streak all started within this many seconds of the first (the "short
    /// window"). A launch that crashes once a day at login is not a crash loop; three tries in a row are.
    public static let crashWindowSeconds: Double = 600

    enum Key {
        static let inProgressSince = "launchGuard.inProgressSince"
        static let recentCrashes = "launchGuard.recentCrashes"
        static let firstCrashAt = "launchGuard.firstCrashAt"
        static let appVersion = "launchGuard.appVersion"
    }

    private let store: any KeyValueStore
    private let safeModeFlag = Atomic<Bool>(false)

    public init(store: any KeyValueStore) { self.store = store }

    /// Called first thing at launch; returns true when safe mode must be entered.
    ///
    /// `now` is wall-clock seconds since 1970 (monotonic time restarts at boot). A launch that is still marked
    /// in progress never reached `markSurvived()`, so it crashed or was killed within 60 s of starting.
    /// `appVersion` (the bundle version) clears the streak when it differs from the version recorded by the
    /// previous launch: installing an update is the usual way out of a crash loop, and a fixed build must not
    /// start in safe mode because of the old build's crashes. Nil keeps the recorded version.
    public func beginLaunch(now: Double, appVersion: String? = nil) -> Bool {
        let previousStart = store.double(forKey: Key.inProgressSince)
        if adoptVersion(appVersion) {
            clearStreak()
        } else if previousStart > 0 {
            recordCrash(launchedAt: previousStart)
        }
        store.set(now, forKey: Key.inProgressSince)
        let enter = recentCrashes >= Self.crashThreshold
        safeModeFlag.store(enter, ordering: .sequentiallyConsistent)
        return enter
    }

    /// Called 60 s after launch and on clean quit. In safe mode the crash count is kept, so the next launch is
    /// safe again until the user resets or leaves safe mode (`reset()`).
    public func markSurvived() {
        store.set(0.0, forKey: Key.inProgressSince)
        guard !isSafeModeActive else { return }
        clearStreak()
    }

    public var recentCrashes: Int { store.integer(forKey: Key.recentCrashes) }

    /// True after `beginLaunch` decided on safe mode, until `reset()`. `SettingsStore.load` reads it.
    public var isSafeModeActive: Bool { safeModeFlag.load(ordering: .sequentiallyConsistent) }

    /// Leaves safe mode and forgets the streak (`SettingsStore.exitSafeMode`, reset from the safe-mode notice).
    /// The current launch stays in progress until it survives.
    public func reset() {
        clearStreak()
        safeModeFlag.store(false, ordering: .sequentiallyConsistent)
    }

    /// Records `version`; true when it replaces a different recorded version.
    private func adoptVersion(_ version: String?) -> Bool {
        guard let version else { return false }
        let fingerprint = Self.versionFingerprint(version)
        let recorded = store.integer(forKey: Key.appVersion)
        guard recorded != fingerprint else { return false }
        store.set(fingerprint, forKey: Key.appVersion)
        return recorded != 0
    }

    /// Stable, non-zero 32-bit FNV-1a hash of the version string. The key-value store holds numbers only, and
    /// 32 bits stay exact even in a store that keeps every number as a `Double`; zero means "nothing recorded".
    static func versionFingerprint(_ version: String) -> Int {
        var hash: UInt32 = 0x811c_9dc5
        for byte in version.utf8 {
            hash ^= UInt32(byte)
            hash &*= 0x0100_0193
        }
        return hash == 0 ? 1 : Int(hash)
    }

    private func recordCrash(launchedAt start: Double) {
        let crashes = recentCrashes
        let first = store.double(forKey: Key.firstCrashAt)
        let continuesStreak = crashes > 0 && start >= first && start - first <= Self.crashWindowSeconds
        if continuesStreak {
            store.set(crashes + 1, forKey: Key.recentCrashes)
        } else {
            store.set(1, forKey: Key.recentCrashes)
            store.set(start, forKey: Key.firstCrashAt)
        }
    }

    private func clearStreak() {
        store.set(0, forKey: Key.recentCrashes)
        store.set(0.0, forKey: Key.firstCrashAt)
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/SettingsStore/LegacyStorage.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// One-time move of the storage folders after a product rename (ADR 0307, review finding on the temporary
// name). Runs at launch before `SettingsStore.load`, on the utility queue. Workstream W1-B.

public import AppModel
public import Foundation

public enum LegacyStorageMigration: Sendable, Hashable {
    /// The current folder exists, or no legacy folder exists: nothing to do.
    case notNeeded
    /// `from` (a legacy folder name) was moved to the current name.
    case moved(from: String)
    /// Both the current and a legacy folder exist: the current one wins, the legacy one is left untouched.
    case skippedBothExist(legacy: String)
    case failed(FileSystemError)
}

public enum LegacyStorageMigrator {
    /// For each base (`~/Library/Application Support`, `~/Library/Logs`): if `<base>/<current>` does not exist
    /// and `<base>/<legacy>` exists for the first name in `legacyNames` (newest first), renames it to
    /// `<base>/<current>` keeping permissions (0700). Never merges, never deletes.
    ///
    /// Returns one result per base, in order. Names come from Info.plist (`AppLegacyStorageFolderNames`); a name
    /// that is empty, equal to `current`, or not a single path component (`/`, `.`, `..`) is ignored so a bad
    /// build setting can never move a folder outside its base.
    public static func migrate(
        current: String, legacyNames: [String], bases: [URL], fileSystem: any FileSystem
    ) -> [LegacyStorageMigration] {
        guard isSinglePathComponent(current) else { return bases.map { _ in .notNeeded } }
        let candidates = legacyNames.filter { $0 != current && isSinglePathComponent($0) }
        return bases.map { base in
            migrate(base: base, current: current, candidates: candidates, fileSystem: fileSystem)
        }
    }

    private static func migrate(
        base: URL, current: String, candidates: [String], fileSystem: any FileSystem
    ) -> LegacyStorageMigration {
        let currentURL = base.appendingPathComponent(current, isDirectory: true)
        let existingLegacy = candidates.first { name in
            fileSystem.fileExists(at: base.appendingPathComponent(name, isDirectory: true))
        }
        guard let legacy = existingLegacy else { return .notNeeded }
        guard !fileSystem.fileExists(at: currentURL) else { return .skippedBothExist(legacy: legacy) }
        let legacyURL = base.appendingPathComponent(legacy, isDirectory: true)
        do {
            // rename(2) keeps the inode and therefore its 0700 mode and contents.
            try fileSystem.moveItem(at: legacyURL, to: currentURL)
            return .moved(from: legacy)
        } catch let error as FileSystemError {
            return .failed(error)
        } catch {
            return .failed(.ioFailure(path: legacyURL.path, errno: EIO))
        }
    }

    static func isSinglePathComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
}
```
<!-- /include -->

## 8. CompatRules

Owned files: `Packages/AppCore/Sources/CompatRules/**`, `Sources/CompatLint/**`,
`Tests/CompatRulesTests/**`, `Sources/TestSupport/Fakes/Rules/**`, `compat/rules.json`, `compat/matrix.json`,
`compat/schema/**` (workstream W1-C). Isolation: pure values (any); `RuleSet.resolve` runs on the ax thread on
focus change only (PLT-R523).

Schema mapping to 02-platform.md 5.4: every field of the spec's table is a property with the same name and
optionality (`match.*`, `action.*`, `provenance.*`, `test.*`); enums use the spec's spellings
(`InjectionStrategy`, `EngineFingerprint`, `FirstSeenMode` for `defaultMode`, `RequireTextFocus`,
`AXEnableMode`, `EngineContextKind`). Two additions, both required elsewhere in the spec: `action.verifyReentry`
(PLT-R342 speaks of "the rule's verifyReentry"; the defaults block already has it) and the user-suggestion
provenance shape of PLT-R1205. The JSON Schema twin is `compat/schema/rules.schema.json`; it accepts the
spec's 5.4 and 5.6 examples unchanged (checked 2026-11-13).

### 8.1 MatchContext: what the focus tracker fills in

The focus tracker (W1-E, `InputHost/Focus/`) builds one `MatchContext` per focus change on the ax thread and
passes it to `RuleSet.resolve` (02-platform.md 5.2, 5.5). `documentURL` is "the document URL of the focused web
area" (5.5): the `AXURL` of the nearest `AXWebArea` ancestor of the focused element, read only for the browser
engines (`chromium`, `webkitBrowser`, `gecko`). It is therefore set only while the focused element is inside
the web area, and it is `nil` whenever browser chrome has focus (the omnibox or address bar, the find bar, the
tab strip), even when the visible tab shows a page that a web rule matches. Chrome rules match on `ax` fields
and web-app rules on `web.urlPrefixes`; if the host filled `documentURL` for the omnibox, the seeded Sheets
rules (engines + web, score 10) would tie with the address-bar rules (engines + ax, score 10).
`Tests/CompatRulesTests/SeededDataTests.swift` pins the omnibox-over-Sheets context to
`browser.chromium.addressBar` with no tie. `documentURL` and `windowTitle` are used in memory for matching only
and never stored (PLT-R383).

### 8.2 Compatibility matrix and the Apps pane

`compat/matrix.json` (shipped as `compat-matrix.json`, decoded by `MatrixLoader`) has one `MatrixEntry` per
row. `MatrixEntry.scope` (`MatrixScope`) is absent or `app` for the row that stands for the whole app, `webApp`
for a web app used in that browser, and `inApp` for a tool or mode inside the app. A bundle ID has at most one
app-level row and any number of scoped rows: `compat-lint` reports a second app-level row as `schemaInvalid`,
and `scripts/check-matrix.py` also rejects two scoped rows with the same bundle ID, scope and display name.

Selection rule for the Apps pane (PRD-R34, PRD-R35): `MatrixDocument.appEntry(for:)` returns the app-level row
(the first one if a hand-edited file has more), and its `MatrixStatusResolver.displayStatus` (not verified
after 120 days, QA-R19) is the one status the pane shows for that app. `MatrixDocument.scopedEntries(for:)`
returns the `webApp` and `inApp` rows in file order for a detail view; they never decide the app's status. A
missing or invalid file shows every app as not verified.

<!-- include: Packages/AppCore/Sources/CompatRules/Schema.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// compat-rules.json schema, version 1 (02-platform.md 5.4). Field names, optionality and enum spellings match
// the spec table exactly; compat/schema/rules.schema.json is the JSON Schema twin (CI validates both ways).

public import AppModel

public struct RulesDocument: Sendable, Hashable, Codable {
    public var schemaVersion: Int
    public var rulesetVersion: String  // "2026.11.0"
    public var defaults: RuleDefaults
    /// Named bundle groups. Reserved: `terminals` (5.4 example), `webkitBrowsers` (PLT-R510 fingerprint).
    public var bundleGroups: [String: [BundleKey]]
    /// Other Vietnamese input apps to warn about (PLT-R399).
    public var conflictingInputApps: [BundleKey]
    public var secureInputHints: [SecureInputHint]
    public var rules: [Rule]

    public init(
        schemaVersion: Int, rulesetVersion: String, defaults: RuleDefaults, bundleGroups: [String: [BundleKey]],
        conflictingInputApps: [BundleKey], secureInputHints: [SecureInputHint], rules: [Rule]
    ) {
        self.schemaVersion = schemaVersion
        self.rulesetVersion = rulesetVersion
        self.defaults = defaults
        self.bundleGroups = bundleGroups
        self.conflictingInputApps = conflictingInputApps
        self.secureInputHints = secureInputHints
        self.rules = rules
    }
}

public struct RuleDefaults: Sendable, Hashable, Codable {
    public var strategy: InjectionStrategy
    public var params: StrategyParams
    public var fallback: [InjectionStrategy]
    public var defaultMode: FirstSeenMode
    public var requireTextFocus: RequireTextFocus
    public var verifyReentry: VerifyReentry

    public init(
        strategy: InjectionStrategy, params: StrategyParams, fallback: [InjectionStrategy],
        defaultMode: FirstSeenMode, requireTextFocus: RequireTextFocus, verifyReentry: VerifyReentry
    ) {
        self.strategy = strategy
        self.params = params
        self.fallback = fallback
        self.defaultMode = defaultMode
        self.requireTextFocus = requireTextFocus
        self.verifyReentry = verifyReentry
    }
}

public struct SecureInputHint: Sendable, Hashable, Codable {
    public var bundleId: BundleKey
    /// String Catalog key suffix, for example `terminal.secureKeyboardEntry` (PLT-R397, PLT-R398C).
    public var hintKey: String

    public init(
        bundleId: BundleKey, hintKey: String
    ) {
        self.bundleId = bundleId
        self.hintKey = hintKey
    }
}

public struct Rule: Sendable, Hashable, Codable {
    public var id: RuleID
    public var summary: String
    public var match: RuleMatch
    public var action: RuleAction
    /// Required for shipped rules (PLT-R505); user overrides carry `userSuggestion` provenance (PLT-R1205).
    public var provenance: RuleProvenance?
    /// Required for shipped rules (PLT-R505).
    public var test: RuleTest?

    public init(
        id: RuleID, summary: String, match: RuleMatch, action: RuleAction, provenance: RuleProvenance? = nil,
        test: RuleTest? = nil
    ) {
        self.id = id
        self.summary = summary
        self.match = match
        self.action = action
        self.provenance = provenance
        self.test = test
    }
}

public struct RuleMatch: Sendable, Hashable, Codable {
    public var bundleIds: [BundleKey]?
    public var bundleGroup: String?
    public var engines: [EngineFingerprint]?
    public var appCategories: [String]?
    public var appVersion: VersionRange?
    public var macOS: VersionRange?
    public var ax: AXMatch?
    public var web: WebMatch?
    /// Shipped rules only, only with `bundleIds`, at most 200 characters, compiled at load (PLT-R502).
    public var titlePattern: String?

    public init(
        bundleIds: [BundleKey]? = nil, bundleGroup: String? = nil, engines: [EngineFingerprint]? = nil,
        appCategories: [String]? = nil, appVersion: VersionRange? = nil, macOS: VersionRange? = nil,
        ax: AXMatch? = nil, web: WebMatch? = nil, titlePattern: String? = nil
    ) {
        self.bundleIds = bundleIds
        self.bundleGroup = bundleGroup
        self.engines = engines
        self.appCategories = appCategories
        self.appVersion = appVersion
        self.macOS = macOS
        self.ax = ax
        self.web = web
        self.titlePattern = titlePattern
    }
}

/// Any-of within a field, all-of across fields.
public struct AXMatch: Sendable, Hashable, Codable {
    public var roles: [String]?
    public var subroles: [String]?
    public var identifiers: [String]?
    public var domClasses: [String]?
    public var ancestorRoles: [String]?
    public var editable: Bool?

    public init(
        roles: [String]? = nil, subroles: [String]? = nil, identifiers: [String]? = nil,
        domClasses: [String]? = nil, ancestorRoles: [String]? = nil, editable: Bool? = nil
    ) {
        self.roles = roles
        self.subroles = subroles
        self.identifiers = identifiers
        self.domClasses = domClasses
        self.ancestorRoles = ancestorRoles
        self.editable = editable
    }
}

public struct WebMatch: Sendable, Hashable, Codable {
    /// Requires the AX document URL; evaluated in memory, never logged.
    public var urlPrefixes: [String]?

    public init(
        urlPrefixes: [String]? = nil
    ) {
        self.urlPrefixes = urlPrefixes
    }
}

public struct RuleAction: Sendable, Hashable, Codable {
    public var strategy: InjectionStrategy
    public var params: StrategyParams?
    /// Used only when the primary fails detectably (AX error, readback mismatch).
    public var fallback: [InjectionStrategy]?
    public var defaultMode: FirstSeenMode?
    public var requireTextFocus: RequireTextFocus?
    /// Not in the 5.4 field table but required by PLT-R342 ("the rule's verifyReentry"); defaults block has it.
    public var verifyReentry: VerifyReentry?
    public var axEnable: AXEnableMode?
    public var overlay: Bool?
    public var requiresUserOptIn: Bool?
    public var engineContext: EngineContextKind?
    public var features: RuleFeatures?

    public init(
        strategy: InjectionStrategy, params: StrategyParams? = nil, fallback: [InjectionStrategy]? = nil,
        defaultMode: FirstSeenMode? = nil, requireTextFocus: RequireTextFocus? = nil,
        verifyReentry: VerifyReentry? = nil, axEnable: AXEnableMode? = nil, overlay: Bool? = nil,
        requiresUserOptIn: Bool? = nil, engineContext: EngineContextKind? = nil, features: RuleFeatures? = nil
    ) {
        self.strategy = strategy
        self.params = params
        self.fallback = fallback
        self.defaultMode = defaultMode
        self.requireTextFocus = requireTextFocus
        self.verifyReentry = verifyReentry
        self.axEnable = axEnable
        self.overlay = overlay
        self.requiresUserOptIn = requiresUserOptIn
        self.engineContext = engineContext
        self.features = features
    }
}

/// Keys from 02-platform.md section 4 plus the extra keys listed in 5.4 `action.params`.
public struct StrategyParams: Sendable, Hashable, Codable {
    public var unicodeChunk: Int?  // 1...20 (PLT-R404)
    public var interEventDelayUs: Int?  // 0...50,000 (PLT-R408)
    public var postDeleteSettleUs: Int?  // 0...50,000
    public var firstEditDelayUs: Int?  // 0...50,000
    public var inlineCompletion: InlineCompletionMode?
    public var allowMultiCharEvents: Bool?  // PLT-R480
    public var allowSplit: Bool?  // PLT-R408
    public var longTextThreshold: Int?  // graphemes, default 64 (PLT-R480)
    public var restoreDelayMs: Int?  // default 400 (PLT-R461)
    public var verifyAfterEdit: Bool?  // PLT-R410

    public init(
        unicodeChunk: Int? = nil, interEventDelayUs: Int? = nil, postDeleteSettleUs: Int? = nil,
        firstEditDelayUs: Int? = nil, inlineCompletion: InlineCompletionMode? = nil,
        allowMultiCharEvents: Bool? = nil, allowSplit: Bool? = nil, longTextThreshold: Int? = nil,
        restoreDelayMs: Int? = nil, verifyAfterEdit: Bool? = nil
    ) {
        self.unicodeChunk = unicodeChunk
        self.interEventDelayUs = interEventDelayUs
        self.postDeleteSettleUs = postDeleteSettleUs
        self.firstEditDelayUs = firstEditDelayUs
        self.inlineCompletion = inlineCompletion
        self.allowMultiCharEvents = allowMultiCharEvents
        self.allowSplit = allowSplit
        self.longTextThreshold = longTextThreshold
        self.restoreDelayMs = restoreDelayMs
        self.verifyAfterEdit = verifyAfterEdit
    }
}

/// `action.features` (all default true except `autoCapitalize`, a later feature).
public struct RuleFeatures: Sendable, Hashable, Codable {
    public var autoCapitalize: Bool?
    public var macros: Bool?
    public var englishRestore: Bool?
    public var restoreHotkey: Bool?

    public init(
        autoCapitalize: Bool? = nil, macros: Bool? = nil, englishRestore: Bool? = nil, restoreHotkey: Bool? = nil
    ) {
        self.autoCapitalize = autoCapitalize
        self.macros = macros
        self.englishRestore = englishRestore
        self.restoreHotkey = restoreHotkey
    }
}

/// Shipped rules use the 5.4 provenance; user overrides use the PLT-R1205 suggestion shape. Decoded by the
/// presence of `source`.
public enum RuleProvenance: Sendable, Hashable, Codable {
    case shipped(Provenance)
    case userSuggestion(UserProvenance)

    public init(from decoder: any Decoder) throws { self = try Self.decodeTagged(from: decoder) }
    public func encode(to encoder: any Encoder) throws { try encodeTagged(to: encoder) }
}

public struct Provenance: Sendable, Hashable, Codable {
    public var reason: String
    public var evidence: [Evidence]
    public var tested: [TestedEntry]
    public var notes: String?
    public var addedIn: String
    public var reviewBy: String  // ISO date "YYYY-MM-DD"

    public init(
        reason: String, evidence: [Evidence], tested: [TestedEntry], notes: String? = nil, addedIn: String,
        reviewBy: String
    ) {
        self.reason = reason
        self.evidence = evidence
        self.tested = tested
        self.notes = notes
        self.addedIn = addedIn
        self.reviewBy = reviewBy
    }
}

public struct UserProvenance: Sendable, Hashable, Codable {
    public var source: String  // "user-suggestion"
    public var appVersion: String?
    public var macOS: String?
    public var date: String

    public init(
        source: String, appVersion: String? = nil, macOS: String? = nil, date: String
    ) {
        self.source = source
        self.appVersion = appVersion
        self.macOS = macOS
        self.date = date
    }
}

public struct Evidence: Sendable, Hashable, Codable {
    public var type: String  // "scenario", "issue", "report"
    public var ref: String

    public init(
        type: String, ref: String
    ) {
        self.type = type
        self.ref = ref
    }
}

public struct TestedEntry: Sendable, Hashable, Codable {
    public enum Result: String, Sendable, Hashable, Codable { case pass, fail }
    public var app: String
    public var appVersion: String
    public var macOS: String
    public var date: String
    public var result: Result

    public init(
        app: String, appVersion: String, macOS: String, date: String, result: Result
    ) {
        self.app = app
        self.appVersion = appVersion
        self.macOS = macOS
        self.date = date
        self.result = result
    }
}

public struct RuleTest: Sendable, Hashable, Codable {
    public enum Automation: String, Sendable, Hashable, Codable { case automated, manual }
    /// Scenario ID (PLT-R530): `compat/scenarios/<scenario>.json` must exist.
    public var scenario: String
    public var automation: Automation

    public init(
        scenario: String, automation: Automation
    ) {
        self.scenario = scenario
        self.automation = automation
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/CompatRules/Resolution.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Rule resolution (02-platform.md 5.5). Runs on the ax thread on focus change, never per keystroke (PLT-R523).

public import AppModel

/// Matcher input built by the focus tracker (5.2). `documentURL` and `windowTitle` are transient: used in
/// memory for matching and never stored in snapshots, logs or reports (PLT-R383).
public struct MatchContext: Sendable, Hashable {
    public var bundle: BundleKey?
    public var appVersion: LooseVersion?
    public var macOS: LooseVersion
    public var engine: EngineFingerprint
    public var appCategory: String?
    public var role: String?
    public var subrole: String?
    public var identifier: String?
    public var domClasses: [String]
    public var ancestorRoles: [String]  // up to 6 levels
    public var editable: Bool?
    public var documentURL: String?
    public var windowTitle: String?

    public init(
        bundle: BundleKey?, appVersion: LooseVersion?, macOS: LooseVersion, engine: EngineFingerprint,
        appCategory: String? = nil, role: String? = nil, subrole: String? = nil, identifier: String? = nil,
        domClasses: [String] = [], ancestorRoles: [String] = [], editable: Bool? = nil,
        documentURL: String? = nil, windowTitle: String? = nil
    ) {
        self.bundle = bundle
        self.appVersion = appVersion
        self.macOS = macOS
        self.engine = engine
        self.appCategory = appCategory
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.domClasses = domClasses
        self.ancestorRoles = ancestorRoles
        self.editable = editable
        self.documentURL = documentURL
        self.windowTitle = windowTitle
    }
}

/// Fully resolved parameters with caps applied (PLT-R404, PLT-R408, PLT-R480, PLT-R461).
public struct ResolvedParams: Sendable, Hashable, Codable {
    public var unicodeChunk: Int
    public var interEventDelayUs: Int
    public var postDeleteSettleUs: Int
    public var firstEditDelayUs: Int
    public var inlineCompletion: InlineCompletionMode
    public var allowMultiCharEvents: Bool
    public var allowSplit: Bool
    public var longTextThreshold: Int
    public var restoreDelayMs: Int
    public var verifyAfterEdit: Bool

    public static let maximumDelayUs = 50_000
    public static let maximumUnicodeChunk = 20

    /// The 5.4 `defaults.params` plus the section 4 defaults for keys the defaults block omits.
    public static let defaults = ResolvedParams(
        unicodeChunk: 1, interEventDelayUs: 0, postDeleteSettleUs: 0, firstEditDelayUs: 0, inlineCompletion: .none,
        allowMultiCharEvents: false, allowSplit: false, longTextThreshold: 64, restoreDelayMs: 400,
        verifyAfterEdit: false)

    public init(
        unicodeChunk: Int, interEventDelayUs: Int, postDeleteSettleUs: Int, firstEditDelayUs: Int,
        inlineCompletion: InlineCompletionMode, allowMultiCharEvents: Bool, allowSplit: Bool, longTextThreshold: Int,
        restoreDelayMs: Int, verifyAfterEdit: Bool
    ) {
        self.unicodeChunk = unicodeChunk
        self.interEventDelayUs = interEventDelayUs
        self.postDeleteSettleUs = postDeleteSettleUs
        self.firstEditDelayUs = firstEditDelayUs
        self.inlineCompletion = inlineCompletion
        self.allowMultiCharEvents = allowMultiCharEvents
        self.allowSplit = allowSplit
        self.longTextThreshold = longTextThreshold
        self.restoreDelayMs = restoreDelayMs
        self.verifyAfterEdit = verifyAfterEdit
    }
}

public struct ResolvedFeatures: Sendable, Hashable, Codable {
    public var autoCapitalize: Bool
    public var macros: Bool
    public var englishRestore: Bool
    public var restoreHotkey: Bool

    /// 5.4: all true except `autoCapitalize`.
    public static let defaults = ResolvedFeatures(
        autoCapitalize: false, macros: true, englishRestore: true, restoreHotkey: true)

    public init(autoCapitalize: Bool, macros: Bool, englishRestore: Bool, restoreHotkey: Bool) {
        self.autoCapitalize = autoCapitalize
        self.macros = macros
        self.englishRestore = englishRestore
        self.restoreHotkey = restoreHotkey
    }
}

/// The "compatibility profile" of 03-product.md: winning rule's action applied over `defaults`.
public struct ResolvedDecision: Sendable, Hashable {
    public var rule: RuleID?
    public var source: DecisionSource
    public var specificity: Int
    public var strategy: InjectionStrategy
    public var params: ResolvedParams
    public var fallback: [InjectionStrategy]
    public var defaultMode: FirstSeenMode
    /// Never `.byEngine`: resolved with PLT-R386 (`whenKnown` for native/catalyst, else `never`).
    public var requireTextFocus: RequireTextFocus
    public var verifyReentry: VerifyReentry
    public var axEnable: AXEnableMode
    public var overlay: Bool
    public var requiresUserOptIn: Bool
    public var engineContext: EngineContextKind
    public var features: ResolvedFeatures
    /// Per-rule booleans for the snapshot (PLT-R383); the strings themselves are not kept.
    public var matchedTitle: Bool
    public var matchedURL: Bool
    /// Set when two rules tied at runtime (PLT-R521); the caller records a health event.
    public var tieLoser: RuleID?
    /// The winning user override, when `source == .user`. The diagnostics report never embeds it raw: ShellCore
    /// projects it to the typed `DiagnosticsReport.ReportedOverride` (PLT-R541, PLT-R1203, ADR 0312).
    public var userOverride: Rule?

    public init(
        rule: RuleID?, source: DecisionSource, specificity: Int, strategy: InjectionStrategy, params: ResolvedParams,
        fallback: [InjectionStrategy], defaultMode: FirstSeenMode, requireTextFocus: RequireTextFocus,
        verifyReentry: VerifyReentry, axEnable: AXEnableMode, overlay: Bool, requiresUserOptIn: Bool,
        engineContext: EngineContextKind, features: ResolvedFeatures, matchedTitle: Bool = false,
        matchedURL: Bool = false, tieLoser: RuleID? = nil, userOverride: Rule? = nil
    ) {
        self.rule = rule
        self.source = source
        self.specificity = specificity
        self.strategy = strategy
        self.params = params
        self.fallback = fallback
        self.defaultMode = defaultMode
        self.requireTextFocus = requireTextFocus
        self.verifyReentry = verifyReentry
        self.axEnable = axEnable
        self.overlay = overlay
        self.requiresUserOptIn = requiresUserOptIn
        self.engineContext = engineContext
        self.features = features
        self.matchedTitle = matchedTitle
        self.matchedURL = matchedURL
        self.tieLoser = tieLoser
        self.userOverride = userOverride
    }
}

/// Compiled, immutable rule set: shipped document plus user overrides plus opted-in IDs.
public struct RuleSet: Sendable {
    public init(document: RulesDocument, overrides: [Rule], optedIn: Set<RuleID>) throws(RulesValidationError) {
        self.document = document
        compiled = try CompiledRuleSet(document: document, overrides: overrides, optedIn: optedIn)
    }

    public let document: RulesDocument
    let compiled: CompiledRuleSet

    /// Specificity per PLT-R520; user overrides outrank shipped rules (PLT-R522); ties resolve to the
    /// lexicographically smaller id (PLT-R521).
    public func resolve(_ context: MatchContext) -> ResolvedDecision {
        compiled.resolve(context, defaults: document.defaults)
    }

    /// Bundles whose AX focus is observed even when not frontmost (`overlay: true`, PLT-R380).
    public var overlayBundles: Set<BundleKey> { compiled.overlayBundles }
    /// Bundles with a `titlePattern` rule: only these get title-change observers (PLT-R380).
    public var titlePatternBundles: Set<BundleKey> { compiled.titlePatternBundles }
    public var conflictingInputApps: Set<BundleKey> { compiled.conflictingInputApps }
    public func secureInputHintKey(for bundle: BundleKey) -> String? { compiled.hintKey(for: bundle) }
    /// `bundleGroups["webkitBrowsers"]`, consumed by the fingerprinter (PLT-R510).
    public var webkitBrowsers: Set<BundleKey> { compiled.webkitBrowsers }
    /// Match signature used for duplicate detection (PLT-R521).
    public static func signature(of match: RuleMatch) -> String { MatchSignature.canonical(match) }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/CompatRules/Loading.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later

public import AppModel
public import Foundation

public enum RulesValidationError: Error, Sendable, Hashable {
    case decoding(path: String, reason: String)
    case unsupportedSchemaVersion(Int)
    case duplicateRuleID(RuleID)
    case unknownBundleGroup(rule: RuleID, group: String)
    case titlePatternWithoutBundleIDs(RuleID)
    case titlePatternTooLong(RuleID)
    case invalidTitlePattern(RuleID)
    case titlePatternInUserOverride(RuleID)  // PLT-R502
    case parameterOutOfRange(rule: RuleID?, key: String)
    case placeholderInBroadRule(RuleID)  // PLT-R422: not global, not title-only
    case userOverrideIDNotPrefixed(RuleID)
}

public struct RulesLoadResult: Sendable {
    public var document: RulesDocument
    /// True when the shipped file was invalid and `EmbeddedRules.minimal` is in use (PLT-R503).
    public var usedEmbeddedDefaults: Bool
    public var error: RulesValidationError?
}

public struct RejectedOverride: Sendable, Hashable {
    public var index: Int
    public var error: RulesValidationError
}

public enum RulesLoader {
    /// Never throws and never crashes on bad input: falls back to the embedded ruleset (PLT-R503).
    public static func load(contentsOf url: URL) -> RulesLoadResult { RulesDecoding.load(contentsOf: url) }
    public static func decode(_ data: Data) throws(RulesValidationError) -> RulesDocument {
        try RulesDecoding.decode(data)
    }
    /// Decodes rule-overrides.json entries; invalid entries are rejected individually.
    public static func decodeOverrides(_ raw: [JSONValue]) -> (rules: [Rule], rejected: [RejectedOverride]) {
        RulesDecoding.decodeOverrides(raw)
    }
}

/// Compiled-in known-good ruleset (PLT-R503): the `defaults` block and engine-only rules. It contains no
/// bundle identifiers, so the bundle-ID literal lint (PLT-R501) stays clean.
public enum EmbeddedRules {
    public static var minimal: RulesDocument { EmbeddedRuleset.document }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/CompatRules/Fingerprint.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Engine fingerprinting (PLT-R510). Pure logic over a `BundleInspector`; the ax thread caches results per
// (bundle path, CFBundleVersion). Every heuristic is VERIFY against current builds.

public import AppModel
public import Foundation

/// Read-only view of an app bundle. Production implementation in InputHost (FileManager); fake in TestSupport.
public protocol BundleInspector: Sendable {
    /// Names inside `Contents/Frameworks` (for example `Electron Framework.framework`).
    func frameworkNames(in bundle: URL) -> [String]
    /// Names of nested helper apps (for example `Google Chrome Helper (Renderer).app`).
    func helperAppNames(in bundle: URL) -> [String]
    /// True if a file with this name is at most `maxDepth` levels below `directory` (1 = directly inside), for
    /// example `libjvm.dylib` under `<bundle>/Contents/jbr`. `directory` is a folder inside the bundle chosen by
    /// the caller; a missing folder yields false. The fingerprinter only passes known library folders and
    /// depths up to 6, so implementations walk a bounded subtree on the ax thread (PLT-R510, PLT-R384).
    func containsFile(named name: String, in directory: URL, maxDepth: Int) -> Bool
    func infoDictionary(of bundle: URL) -> [String: JSONValue]?
}

public struct EngineFingerprinter: Sendable {
    public init(inspector: any BundleInspector, webkitBrowsers: Set<BundleKey>) {
        self.inspector = inspector
        self.webkitBrowsers = webkitBrowsers
    }

    let inspector: any BundleInspector
    let webkitBrowsers: Set<BundleKey>

    /// Order: webkitBrowser (rules group) > electron > cef > chromium > gecko > jvm > qt > ios > catalyst >
    /// native.
    public func fingerprint(bundleURL: URL, bundle: BundleKey?) -> EngineFingerprint {
        if let bundle, webkitBrowsers.contains(bundle) { return .webkitBrowser }
        return EngineHeuristics(inspector: inspector, bundleURL: bundleURL).classify()
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/CompatRules/Matrix.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// compat/matrix.json: verification status (02-platform.md 13.3, QA-R17), a separate file and schema from the
// behaviour rules. Single source for the Apps pane and the website matrix (PRD-R35, PRD-R38).

public import AppModel
public import Foundation

public struct MatrixDocument: Sendable, Hashable, Codable {
    public var schemaVersion: Int
    public var entries: [MatrixEntry]

    public init(schemaVersion: Int, entries: [MatrixEntry]) {
        self.schemaVersion = schemaVersion
        self.entries = entries
    }
}

public struct MatrixEntry: Sendable, Hashable, Codable {
    public var bundleId: BundleKey
    public var displayName: String
    public var category: String
    public var tier: Int?  // 1 or 2 (PRD-R39)
    public var ruleId: RuleID?
    public var status: MatrixStatus
    public var note: LocalizedNote?
    public var lastVerified: String?  // ISO date
    public var appVersion: String?
    public var macOS: String?
    public var verifier: String?
    public var issues: [Int]
    public var checks: MatrixChecks?
    /// Absent or `app` for the row that stands for the whole app (one per bundle ID, the Apps pane status);
    /// `webApp` or `inApp` for a row about a web app or a tool inside the host app (same bundle ID).
    public var scope: MatrixScope?

    public init(
        bundleId: BundleKey, displayName: String, category: String, tier: Int? = nil, ruleId: RuleID? = nil,
        status: MatrixStatus, note: LocalizedNote? = nil, lastVerified: String? = nil, appVersion: String? = nil,
        macOS: String? = nil, verifier: String? = nil, issues: [Int] = [], checks: MatrixChecks? = nil,
        scope: MatrixScope? = nil
    ) {
        self.bundleId = bundleId
        self.displayName = displayName
        self.category = category
        self.tier = tier
        self.ruleId = ruleId
        self.status = status
        self.note = note
        self.lastVerified = lastVerified
        self.appVersion = appVersion
        self.macOS = macOS
        self.verifier = verifier
        self.issues = issues
        self.checks = checks
        self.scope = scope
    }
}

/// What a matrix row is about (PRD-R34, PRD-R35): the app itself, a web app inside a browser, or a tool inside
/// the host app (tmux in a terminal, an editor's integrated terminal).
public enum MatrixScope: String, Sendable, Hashable, Codable, CaseIterable {
    case app, webApp, inApp
}

/// User-facing values (PRD-R35).
public enum MatrixStatus: String, Sendable, Hashable, Codable, CaseIterable {
    case works, worksWithNotes, notVerified, knownLimitation
}

public struct LocalizedNote: Sendable, Hashable, Codable {
    public var vi: String
    public var en: String

    public init(vi: String, en: String) {
        self.vi = vi
        self.en = en
    }
}

/// Columns of 13.3.
public struct MatrixChecks: Sendable, Hashable, Codable {
    public var telexBasic: MatrixCell?
    public var vniBasic: MatrixCell?
    public var inlineCompletion: MatrixCell?
    public var burstTyping: MatrixCell?
    public var backspaceReentry: MatrixCell?
    public var restoreHotkey: MatrixCell?
    public var perAppMemory: MatrixCell?
    public var macroExpansion: MatrixCell?

    public init(
        telexBasic: MatrixCell? = nil, vniBasic: MatrixCell? = nil, inlineCompletion: MatrixCell? = nil,
        burstTyping: MatrixCell? = nil, backspaceReentry: MatrixCell? = nil, restoreHotkey: MatrixCell? = nil,
        perAppMemory: MatrixCell? = nil, macroExpansion: MatrixCell? = nil
    ) {
        self.telexBasic = telexBasic
        self.vniBasic = vniBasic
        self.inlineCompletion = inlineCompletion
        self.burstTyping = burstTyping
        self.backspaceReentry = backspaceReentry
        self.restoreHotkey = restoreHotkey
        self.perAppMemory = perAppMemory
        self.macroExpansion = macroExpansion
    }
}

public struct MatrixCell: Sendable, Hashable, Codable {
    public enum Result: String, Sendable, Hashable, Codable {
        case pass, fail
        case notApplicable = "n/a"
    }

    public var result: Result
    public var date: String
    public var tester: String

    public init(result: Result, date: String, tester: String) {
        self.result = result
        self.date = date
        self.tester = tester
    }
}

public enum MatrixStatusResolver {
    /// Entries not verified for 120 days display as `notVerified` (QA-R19).
    public static func displayStatus(_ entry: MatrixEntry, today: Date) -> MatrixStatus {
        MatrixFreshness.displayStatus(entry, today: today)
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/CompatRules/Lint.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// CI checks over compat/rules.json and compat/matrix.json (13.1 "Rules"), run by `compat-lint`.

public import AppModel
public import Foundation

public struct LintFinding: Sendable, Hashable {
    public enum Severity: String, Sendable, Hashable { case error, warning }
    public var severity: Severity
    public var code: LintCode
    public var rule: RuleID?
    public var bundle: BundleKey?
    /// Human-readable specifics (a decoding path, the other rule of a duplicate); never typed content.
    public var detail: String?

    public init(
        severity: Severity, code: LintCode, rule: RuleID? = nil, bundle: BundleKey? = nil, detail: String? = nil
    ) {
        self.severity = severity
        self.code = code
        self.rule = rule
        self.bundle = bundle
        self.detail = detail
    }
}

public enum LintCode: String, Sendable, Hashable, CaseIterable {
    case schemaInvalid
    case missingProvenance  // PLT-R505
    case missingTest  // PLT-R505
    case noPassingTestedEntry  // 5.4 `tested`: at least one passing entry
    case unverifiedTestedEntry  // a `tested` entry without an ISO date (VERIFY); release blocker
    case unknownScenario  // test.scenario has no compat/scenarios file
    case reviewByPassed  // PLT-R506 warning
    case reviewByPassedOver30Days  // PLT-R506 release blocker
    case reviewByMoreThan12Months  // PLT-R506
    case identicalMatchSignature  // PLT-R521
    case placeholderWithoutGateTest  // PLT-R422
    case manualTestWithoutMatrixRow  // PLT-R531
    case manualMatrixRowUnverified  // PLT-R531: row lacks date, app version, macOS or tester; release blocker
    case tier1MatrixRowOlderThan90Days  // PLT-R531, 13.3 (release mode)
    case matrixRuleUnknown
    case pasteWithoutOptIn  // PLT-R460
}

public struct RulesLinter: Sendable {
    /// `placeholderGateScenarioIDs`: the scenarios whose file declares the PLT-R422 gate (`PlaceholderGate`).
    public init(
        rules: RulesDocument, matrix: MatrixDocument?, scenarioIDs: Set<String>,
        placeholderGateScenarioIDs: Set<String> = [], today: Date, releaseMode: Bool
    ) {
        context = LintContext(
            rules: rules, matrix: matrix, scenarioIDs: scenarioIDs,
            placeholderGateScenarioIDs: placeholderGateScenarioIDs,
            today: ISODay(today), releaseMode: releaseMode)
    }

    let context: LintContext

    public func run() -> [LintFinding] { LintEngine(context: context).run() }
}
```
<!-- /include -->

## 9. Injection

Owned files: `Packages/AppCore/Sources/Injection/**`, `Tests/InjectionTests/**`,
`Sources/TestSupport/Fakes/Injection/**` (workstream W1-D). Isolation: the worker runs on the dedicated
`inject` thread; `JobQueue.push`, `inFlight`, `nextSequence`, `WorkerFeedback` reads, `EchoTracker` (entirely
tap-confined) and `EventMarker.classify` are tap-safe; everything else is worker-only. `JobQueue`,
`WorkerFeedback`, `EchoTracker`, `EventMarker`, `CurrentFocusGeneration` and the injection fakes are implemented
in the skeleton ([0313](../decisions/0313-testability-seams.md)).

Job lifecycle: the tap builds a job (sequence, focus generation, `InjectionPlan` from the focus snapshot,
field handle, counts, insertion, keycodes, trigger copy) and pushes it; the worker pops in FIFO order, discards
stale generations (replaying triggers), checks liveness, minimises the edit, runs the strategy executor in an
`InjectionEnvironment`, posts events with fresh marker sequences, records the outcome on the 64-entry board and
calls `finished(_:expectation:)`: with an `EchoExpectation` (final event sequence and time) when it posted, with
`nil` when it posted nothing. The job stays in flight until the tap's `EchoTracker` sees that echo or 200 ms
pass ([0311](../decisions/0311-in-flight-until-echo.md)); with `InFlightPolicy.untilPosted` (fallback if echoes
are not delivered) it settles at `finished`. While posting is broken the worker posts nothing and counts losses.
Strategy fallbacks apply only to detectable failures (PLT-R410, 4.5).

Re-entry verification (PLT-R342, decided in wave 2a): `EditJob.verifyBeforeApply` is honoured for every
`EditKind`. The pipeline sets it for every edit of a word re-opened by Backspace when the rule's
`verifyReentry` is not `.never`: `.reentry` edits, and `.macro` and `.restore` edits on such a word, which keep
their kind. A flagged job whose expected text (`replacedText`, bounded AX read) does not match is passed
through: its trigger is replayed unchanged, and a restore (no trigger) delivers nothing. `backspaceRecompose`
edits never ask for verification.

<!-- include: Packages/AppCore/Sources/Injection/Jobs.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Job model (PLT-R311, PLT-R401). Jobs are built on the tap thread and executed strictly FIFO on `inject`.

public import AppModel
public import RealtimeSupport

/// Injection parameters, converted once per focus change from the resolved rule decision (InputHost), so the
/// tap does no conversion and Injection never depends on the rule schema (PLT-R102).
public struct InjectionParameters: Sendable, Hashable {
    public var unicodeChunk: Int  // graphemes per event when 1; UTF-16 units cap when > 1 (PLT-R404)
    public var interEventDelayUs: Int
    public var postDeleteSettleUs: Int
    public var firstEditDelayUs: Int
    public var inlineCompletion: InlineCompletionMode
    public var allowMultiCharEvents: Bool
    public var allowSplit: Bool
    public var longTextThreshold: Int
    public var restoreDelayMs: Int
    public var verifyAfterEdit: Bool
    /// The user opted into `paste` for this app (PLT-R460, PLT-R480).
    public var pasteOptedIn: Bool

    public static let defaults = InjectionParameters(
        unicodeChunk: 1, interEventDelayUs: 0, postDeleteSettleUs: 0, firstEditDelayUs: 0,
        inlineCompletion: .none, allowMultiCharEvents: false, allowSplit: false, longTextThreshold: 64,
        restoreDelayMs: 400, verifyAfterEdit: false, pasteOptedIn: false)

    public init(
        unicodeChunk: Int, interEventDelayUs: Int, postDeleteSettleUs: Int, firstEditDelayUs: Int,
        inlineCompletion: InlineCompletionMode, allowMultiCharEvents: Bool, allowSplit: Bool,
        longTextThreshold: Int, restoreDelayMs: Int, verifyAfterEdit: Bool, pasteOptedIn: Bool
    ) {
        self.unicodeChunk = unicodeChunk
        self.interEventDelayUs = interEventDelayUs
        self.postDeleteSettleUs = postDeleteSettleUs
        self.firstEditDelayUs = firstEditDelayUs
        self.inlineCompletion = inlineCompletion
        self.allowMultiCharEvents = allowMultiCharEvents
        self.allowSplit = allowSplit
        self.longTextThreshold = longTextThreshold
        self.restoreDelayMs = restoreDelayMs
        self.verifyAfterEdit = verifyAfterEdit
        self.pasteOptedIn = pasteOptedIn
    }
}

public struct InjectionPlan: Sendable, Hashable {
    public var strategy: InjectionStrategy
    public var parameters: InjectionParameters
    public var fallback: [InjectionStrategy]

    public init(strategy: InjectionStrategy, parameters: InjectionParameters, fallback: [InjectionStrategy]) {
        self.strategy = strategy
        self.parameters = parameters
        self.fallback = fallback
    }

    public static let `default` = InjectionPlan(
        strategy: .backspaceReplace, parameters: .defaults, fallback: [.passThrough])
}

/// Accessibility element of the focused field, captured in the focus snapshot by the ax thread and carried by
/// jobs so the worker never reads snapshots. `element` is nil in tests.
public struct FieldHandle: Sendable, Hashable {
    public var pid: Int32
    /// Identity within one focus generation (fakes compare by token).
    public var token: UInt64
    public var element: AXElementReference?

    public init(pid: Int32, token: UInt64, element: AXElementReference?) {
        self.pid = pid
        self.token = token
        self.element = element
    }
}

/// Monotonic job sequence (also the low bits of the marker of the job's last synthetic event, PLT-R323).
public struct JobSequence: RawRepresentable, Sendable, Hashable, Comparable, BitwiseCopyable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public static func < (lhs: JobSequence, rhs: JobSequence) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Copy of a held physical keyboard event (PLT-R324): keycode, flags, autorepeat, keyboard type and Unicode
/// string preserved; the replay adds the app's marker. Bitwise-copyable, so holding never allocates.
public struct KeyEventRecord: Sendable, Hashable, BitwiseCopyable {
    public enum Kind: UInt8, Sendable, Hashable, BitwiseCopyable { case keyDown, keyUp, flagsChanged }

    public var kind: Kind
    public var keyCode: KeyCode
    public var flags: UInt64  // CGEventFlags raw value
    public var autorepeat: Bool
    public var keyboardType: UInt32
    public var unicode: InlineUTF16
    /// Time the tap received the original (T5 held-wait metric, PLT-R314 liveness).
    public var receivedAt: MonotonicInstant
    /// Latency-probe event (PLT-R810). Replayed with the ordinary echo marker (a probe-kind marker would make the
    /// tap treat the replay as a new physical probe and hold it again); the worker routes metrics by this flag.
    public var isProbe: Bool

    public init(
        kind: Kind, keyCode: KeyCode, flags: UInt64, autorepeat: Bool, keyboardType: UInt32, unicode: InlineUTF16,
        receivedAt: MonotonicInstant, isProbe: Bool
    ) {
        self.kind = kind
        self.keyCode = keyCode
        self.flags = flags
        self.autorepeat = autorepeat
        self.keyboardType = keyboardType
        self.unicode = unicode
        self.receivedAt = receivedAt
        self.isProbe = isProbe
    }
}

public enum EditKind: UInt8, Sendable, Hashable {
    case compose, backspaceRecompose, restore, macro, reentry
}

/// Key codes resolved on the tap from the current layout table (PLT-R405, PLT-R461 step 3).
public struct JobKeyCodes: Sendable, Hashable {
    /// Keycode of the physical key that triggered the edit.
    public var trigger: KeyCode
    /// For restores, macros and an edit an action key triggered (`isActionKey`: Backspace, PLT-R352; Return, Tab or
    /// Space at a commit; Escape as the restore hotkey; PLT-R405): keycode of the first character of the insertion,
    /// or else of the replaced text, that the current layout types on a key without an action, so the insertion
    /// never rides on an action key's keycode.
    public var firstCharacter: KeyCode?
    /// Keycode producing "v" in the current layout (Command+V for `paste`).
    public var paste: KeyCode?

    public init(trigger: KeyCode, firstCharacter: KeyCode? = nil, paste: KeyCode? = nil) {
        self.trigger = trigger
        self.firstCharacter = firstCharacter
        self.paste = paste
    }

    /// PLT-R405: a key that can trigger an edit and whose keycode carries an action of its own in a text editor:
    /// Backspace, Return and keypad Enter, Tab, Space and Escape. (The other deletion key never triggers an edit,
    /// PLT-R340, and is never posted, PLT-R407.) Chromium (and so Electron) and WebKit derive the DOM `code` of a key
    /// event, and for a non-ASCII character also the legacy `keyCode`, from the virtual keycode, so a Unicode event
    /// posted on one of these keys reaches an editor that acts on `code` or `keyCode` as that key: it deletes, sends,
    /// moves the focus or cancels instead of typing. No Unicode event rides on these keycodes. Tap-safe.
    @inline(__always)
    public static func isActionKey(_ keyCode: KeyCode) -> Bool {
        switch keyCode {
        case .delete, .returnKey, .keypadEnter, .tab, .space, .escape: true
        default: false
        }
    }
}

/// PLT-R401. Content (insertion, replacedText) lives only in memory and is never logged.
public struct EditJob: Sendable {
    public var sequence: JobSequence
    public var generation: FocusGeneration
    public var plan: InjectionPlan
    public var field: FieldHandle?
    public var kind: EditKind
    /// Grapheme clusters the engine emitted (PLT-R403, ENG-R630).
    public var deleteCount: Int
    public var deleteUTF16Count: Int
    /// The text expected before the caret that the edit replaces, when the pipeline knows it. Used for prefix
    /// trimming (PLT-R402) and bounded re-entry verification (PLT-R342).
    public var replacedText: String?
    /// NFC (PLT-R403).
    public var insertion: String
    public var keyCodes: JobKeyCodes
    /// The physical key that triggered the edit. If the job is abandoned (liveness flush or generation
    /// discard) the worker replays it, so the conservation invariant still holds (PLT-R312). Nil when the
    /// original key is already queued as a replay (`thenPassThrough`).
    public var trigger: KeyEventRecord?
    /// Re-entry into a committed word: verify before applying when the rule allows (PLT-R342). The pipeline sets it
    /// for every edit of a word re-opened by Backspace when `verifyReentry != .never` (`.reentry`, and also
    /// `.macro` and `.restore`, which keep their kind); the worker honours it for every kind.
    public var verifyBeforeApply: Bool
    /// The word began within 300 ms of a focus change or click (`firstEditDelayUs`, PLT-R408).
    public var wordStartedNearFocusChange: Bool
    public var createdAt: MonotonicInstant
    public var isProbe: Bool
    /// PLT-R340 amendment (2026-11-14): the first job after a focus change the tap discovered late, when it kept
    /// the composition. The worker applies it only if `field` is readable and its text before the caret (before the
    /// selection, when an inline completion is selected) ends with `replacedText`; otherwise the trigger passes
    /// through and the composition is reset. Strict, unlike `verifyBeforeApply`: an unreadable field fails.
    public var verifyLateFocus: Bool

    public init(
        sequence: JobSequence, generation: FocusGeneration, plan: InjectionPlan, field: FieldHandle?,
        kind: EditKind, deleteCount: Int, deleteUTF16Count: Int, replacedText: String?, insertion: String,
        keyCodes: JobKeyCodes, trigger: KeyEventRecord?, verifyBeforeApply: Bool,
        wordStartedNearFocusChange: Bool, createdAt: MonotonicInstant, isProbe: Bool, verifyLateFocus: Bool = false
    ) {
        self.sequence = sequence
        self.generation = generation
        self.plan = plan
        self.field = field
        self.kind = kind
        self.deleteCount = deleteCount
        self.deleteUTF16Count = deleteUTF16Count
        self.replacedText = replacedText
        self.insertion = insertion
        self.keyCodes = keyCodes
        self.trigger = trigger
        self.verifyBeforeApply = verifyBeforeApply
        self.wordStartedNearFocusChange = wordStartedNearFocusChange
        self.createdAt = createdAt
        self.isProbe = isProbe
        self.verifyLateFocus = verifyLateFocus
    }
}

public enum BoundaryReason: UInt8, Sendable, Hashable {
    case mouseDown, focusChanged, navigation, commandChord, returnOrTab, escape, modeToggled, inputSourceChanged,
        secureInputChanged, tapReenabled, settingsChanged, ruleChanged, sessionChanged
    /// PLT-R397A: a keyUp whose keyDown the tap never saw: the app received input the engine did not see.
    case unseenInput
}

/// Marks a hard boundary in FIFO order (PLT-R340). The worker resets first-edit timing (PLT-R408); paste
/// coalescing (PLT-R461 step 6) is bounded by `restoreDelayMs` and the `changeCount` guard, not by boundaries.
public struct BoundaryJob: Sendable, Hashable {
    public var sequence: JobSequence
    public var reason: BoundaryReason
    public var generation: FocusGeneration
    public init(sequence: JobSequence, reason: BoundaryReason, generation: FocusGeneration) {
        self.sequence = sequence
        self.reason = reason
        self.generation = generation
    }
}

public enum InjectionJob: Sendable {
    case edit(EditJob)
    case replay(JobSequence, KeyEventRecord)
    /// keyUp of a keyDown consumed for `job`: dropped if the job executed, replayed if it was abandoned
    /// (PLT-R313 with conservation).
    case pairedKeyUp(JobSequence, KeyEventRecord, forJob: JobSequence)
    case boundary(BoundaryJob)
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/Injection/Marker.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Self-generated event marker (PLT-R321). Layout of `kCGEventSourceUserData` (Int64):
//   bits 63...24  per-launch random tag (40 bits, CSPRNG, never zero)
//   bit  23       kind: 0 = injected or replayed by the worker, 1 = latency probe / guided test input
//   bits 22...0   event sequence number, incremented by the worker for every posted event (wraps)
// Physical events are never modified (PLT-R321). Implemented in the skeleton (ADR 0313); W1-D owns it.

internal import AppModel

public struct EventMarker: Sendable, Hashable {
    public static let tagMask: UInt64 = 0xFF_FFFF_FFFF
    public static let sequenceMask: UInt32 = 0x7F_FFFF
    private static let probeBit: UInt64 = 1 << 23

    public let tag: UInt64

    /// `tag` is masked to 40 bits and must not be zero (physical events usually carry user data 0).
    public init(tag: UInt64) {
        precondition(tag & Self.tagMask != 0, "marker tag must be non-zero")
        self.tag = tag & Self.tagMask
    }

    /// 40 bits from `SystemRandomNumberGenerator` (a CSPRNG on Darwin: `arc4random_buf`), retried if zero.
    public static func random() -> EventMarker {
        var generator = SystemRandomNumberGenerator()
        var tag: UInt64 = 0
        while tag == 0 { tag = generator.next() & tagMask }
        return EventMarker(tag: tag)
    }

    public func userData(sequence: UInt32, probe: Bool) -> Int64 {
        let bits = (tag << 24) | (probe ? Self.probeBit : 0) | UInt64(sequence & Self.sequenceMask)
        return Int64(bitPattern: bits)
    }

    /// Tap-safe: integer arithmetic only.
    @inline(__always)
    public func classify(_ userData: Int64) -> MarkerMatch {
        let bits = UInt64(bitPattern: userData)
        guard bits >> 24 == tag else { return .foreign }
        let sequence = UInt32(truncatingIfNeeded: bits) & Self.sequenceMask
        return bits & Self.probeBit == 0 ? .echo(sequence: sequence) : .probe(sequence: sequence)
    }
}

public enum MarkerMatch: Sendable, Hashable {
    /// An event the worker posted: record the echo and pass it unchanged (PLT-R310 step 2).
    case echo(sequence: UInt32)
    /// A probe or guided-test event: process as physical, route metrics to probe histograms (PLT-R810).
    case probe(sequence: UInt32)
    /// Physical (or another tool's) event.
    case foreign
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/Injection/ReverseDNSConstants.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Reverse-DNS strings that are NOT bundle identifiers (pasteboard types). They live only in files named
// `ReverseDNSConstants.swift`; each is allowed by scripts/lint-bundle-ids.allow (PLT-R501, ARCHITECTURE.md 7).

/// Pasteboard type names used by the `paste` strategy (PLT-R461 step 2) and by the fakes.
public enum PasteboardTypeName {
    public static let plainText = "public.utf8-plain-text"
    /// nspasteboard.org markers: clipboard managers skip or hide items carrying them.
    public static let transient = "org.nspasteboard.TransientType"
    public static let concealed = "org.nspasteboard.ConcealedType"
    public static let autoGenerated = "org.nspasteboard.AutoGeneratedType"
    /// Marker types written with every transient item.
    public static let markers = [transient, concealed, autoGenerated]
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/Injection/Services.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Platform services used by the inject thread. Production implementations live in Injection/System;
// TestSupport provides fakes so every strategy is testable without permissions (QA-R1 layer 4).

public import AppModel
public import ApplicationServices
public import Foundation
public import RealtimeSupport

/// One synthetic key event. Flags are always explicit (PLT-R320, PLT-R406); backspace carries no Unicode
/// string (PLT-R407).
public struct SyntheticKeyEvent: Sendable, Hashable, BitwiseCopyable {
    public var keyCode: KeyCode
    public var isKeyDown: Bool
    public var flags: UInt64
    public var unicode: InlineUTF16

    public init(keyCode: KeyCode, isKeyDown: Bool, flags: UInt64, unicode: InlineUTF16) {
        self.keyCode = keyCode
        self.isKeyDown = isKeyDown
        self.flags = flags
        self.unicode = unicode
    }
}

/// `CGEventPost` returns nothing: a revoked permission makes posts vanish silently, so the only reliable
/// signal is echo loss (PLT-R323, ADR 0311). The poster reports only what it can see.
public enum PostError: Error, Sendable, Hashable {
    /// `CGEvent(keyboardEventSource:virtualKey:keyDown:)` returned nil.
    case eventCreationFailed
}

/// Production: `CGEventSource(stateID: .privateState)` with `localEventsSuppressionInterval = 0` (PLT-R320),
/// `CGEvent(keyboardEventSource:virtualKey:keyDown:)`, explicit `flags`, `keyboardSetUnicodeString`,
/// `setIntegerValueField(.eventSourceUserData, value:)`, then `post(tap: .cgSessionEventTap)` (PLT-R322).
/// It never calls `CGPreflightPostEventAccess()` per post; that check runs off the inject thread only after an
/// echo miss (ADR 0311).
public protocol EventPoster: Sendable {
    func post(_ event: SyntheticKeyEvent, userData: Int64) throws(PostError)
    /// Recreates a held physical event with all PLT-R324 fields and the marker.
    func replay(_ record: KeyEventRecord, userData: Int64) throws(PostError)
}

/// UTF-16 range, `CFRange` semantics (`AXValue` of type `.cfRange`).
public struct TextRange: Sendable, Hashable {
    public var location: Int
    public var length: Int
    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

public enum AXCallResult<Value: Sendable>: Sendable {
    case success(Value)
    case timedOut
    case unavailable
    case failed(code: Int32)  // AXError raw value
}

/// Bounded AX access for injection (PLT-R342, PLT-R343, PLT-R420, 4.5). Never reads a full `AXValue`.
/// Production: `AXUIElementCopyAttributeValue(kAXSelectedTextRangeAttribute)`,
/// `AXUIElementCopyParameterizedAttributeValue(kAXStringForRangeParameterizedAttribute)`,
/// `AXUIElementSetAttributeValue(kAXSelectedTextRangeAttribute / kAXSelectedTextAttribute)`, each after
/// `AXUIElementSetMessagingTimeout` with the requested timeout.
public protocol FocusedFieldAccess: Sendable {
    func selectedRange(_ field: FieldHandle, timeout: TimeSpan) -> AXCallResult<TextRange>
    /// At most 64 UTF-16 units (PLT-R343); longer ranges are clamped by the implementation.
    func text(_ field: FieldHandle, in range: TextRange, timeout: TimeSpan) -> AXCallResult<String>
    func setSelectedRange(_ field: FieldHandle, to range: TextRange, timeout: TimeSpan) -> AXCallResult<Void>
    func setSelectedText(_ field: FieldHandle, to text: String, timeout: TimeSpan) -> AXCallResult<Void>
}

/// `AXUIElement` wrapper. AX references are immutable CF objects that may be used from any thread.
public final class AXElementReference: @unchecked Sendable, Hashable {
    public let element: AXUIElement
    public init(_ element: AXUIElement) { self.element = element }
    public static func == (lhs: AXElementReference, rhs: AXElementReference) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }
    public func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}

/// One pasteboard item: every type with its data (PLT-R461 step 1).
public struct PasteboardItemData: Sendable, Hashable {
    public var types: [String]
    public var data: [String: Data]
    public init(types: [String], data: [String: Data]) {
        self.types = types
        self.data = data
    }
}

public struct PasteboardSnapshot: Sendable, Hashable {
    public var changeCount: Int
    public var items: [PasteboardItemData]
    public var totalBytes: Int
    public init(changeCount: Int, items: [PasteboardItemData], totalBytes: Int) {
        self.changeCount = changeCount
        self.items = items
        self.totalBytes = totalBytes
    }
}

public struct PasteboardLimits: Sendable, Hashable {
    public var readTimeout: TimeSpan = .milliseconds(100)
    public var maxTotalBytes: Int = 10 * 1_024 * 1_024
    public init() {}
}

public enum PasteboardError: Error, Sendable, Hashable {
    case unreadableItem, filePromise, lazyDataUnavailable, tooLarge, timedOut, writeFailed
}

/// Production: `NSPasteboard.general` (tests: `NSPasteboard(name:)` with a unique name, 13.1).
/// `writeTransient` writes one item with `public.utf8-plain-text` plus `org.nspasteboard.TransientType`,
/// `org.nspasteboard.ConcealedType` and `org.nspasteboard.AutoGeneratedType` (PLT-R461 step 2).
/// Thread: called on `inject`; VERIFY thread safety, else the implementation hops to main asynchronously and
/// the worker waits on its own condition with a timeout (PLT-R462).
public protocol PasteboardAccess: Sendable {
    var changeCount: Int { get }
    func snapshot(limits: PasteboardLimits) throws(PasteboardError) -> PasteboardSnapshot
    /// Returns the new `changeCount`.
    func writeTransient(_ text: String) throws(PasteboardError) -> Int
    func restore(_ snapshot: PasteboardSnapshot) throws(PasteboardError)
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/Injection/Queue.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Shared state between the tap (producer) and the worker (consumer). Everything the tap touches here is a
// lock-free push or pop or an atomic load/store (PLT-R304). Implemented in the skeleton because it is the seam
// between the pipeline (W1-F1) and the worker (W1-D) (docs/decisions/0313-testability-seams.md); W1-D owns it.
//
// "In flight" follows docs/decisions/0311-in-flight-until-echo.md: a job stays in flight until the tap sees
// the echo of the job's final synthetic event, or the echo timeout passes, or the worker reports that the job
// posted nothing. Reading PLT-R311 by its rationale: a physical key that reached the WindowServer before the
// job's events were posted reaches the tap before their echo, so it is held instead of overtaking them.

public import AppModel
public import Diagnostics
public import RealtimeSupport

/// When a job stops counting as in flight (ADR 0311).
public enum InFlightPolicy: UInt8, Sendable, Hashable {
    /// Until the tap sees the echo of the job's final event, or `EchoTracker.timeout` passes (default).
    case untilEcho
    /// Until the worker has posted the job's final event. Fallback if PLT-R301 VERIFY (a) shows that echoes are
    /// not delivered to the app's own tap (PLT-R323 "fall back to permission polling only").
    case untilPosted
}

/// The worker's note that a job's final event was posted (PLT-R323).
public struct EchoExpectation: Sendable, Hashable, BitwiseCopyable {
    public var job: JobSequence
    /// Marker sequence (23 bits, `EventMarker`) of the job's last posted event.
    public var finalEventSequence: UInt32
    public var postedAt: MonotonicInstant

    public init(job: JobSequence, finalEventSequence: UInt32, postedAt: MonotonicInstant) {
        self.job = job
        self.finalEventSequence = finalEventSequence
        self.postedAt = postedAt
    }
}

/// FIFO of jobs plus the in-flight count of PLT-R311.
public final class JobQueue: Sendable {
    public let policy: InFlightPolicy
    public let capacity: Int
    private let jobs: SPSCRing<InjectionJob>
    /// Worker -> tap: expectations of jobs that posted events (drained by `EchoTracker` on the tap).
    let expectations: SPSCRing<EchoExpectation>
    private let signal: WorkerSignal
    private let pushed = Atomic<UInt64>(0)  // written by the tap only
    private let settledByTap = Atomic<UInt64>(0)  // written by the tap only (echo seen or timed out)
    private let settledByWorker = Atomic<UInt64>(0)  // written by the worker only (nothing posted, or policy)
    private let sequence = Atomic<UInt64>(0)  // written by the tap only

    /// Capacity above the 256-job liveness ceiling (PLT-R314) so a full ring is never the first symptom.
    /// Rounded up to a power of two.
    public init(capacity: Int = 512, signal: WorkerSignal, policy: InFlightPolicy = .untilEcho) {
        var size = 1
        while size < max(2, capacity) { size <<= 1 }
        self.capacity = size
        self.policy = policy
        self.signal = signal
        jobs = SPSCRing(capacity: size)
        expectations = SPSCRing(capacity: size)
    }

    /// Tap: pushes, counts the job as in flight, signals the worker. False when full: the caller passes the
    /// event through and requests a flush.
    @inline(__always)
    public func push(_ job: InjectionJob) -> Bool {
        guard jobs.push(job) else { return false }
        pushed.wrappingAdd(1, ordering: .sequentiallyConsistent)
        signal.signal()
        return true
    }

    /// Tap: jobs pushed and not yet settled (two atomic loads and one subtraction).
    @inline(__always)
    public var inFlight: Int {
        let total = pushed.load(ordering: .sequentiallyConsistent)
        let settled =
            settledByTap.load(ordering: .sequentiallyConsistent)
            &+ settledByWorker.load(ordering: .sequentiallyConsistent)
        return Int(truncatingIfNeeded: total &- settled)
    }

    /// Tap: next job sequence (single producer).
    @inline(__always)
    public func nextSequence() -> JobSequence {
        JobSequence(rawValue: sequence.wrappingAdd(1, ordering: .relaxed).newValue)
    }

    /// Worker.
    public func pop() -> InjectionJob? { jobs.pop() }

    /// Worker: the job ended. `expectation` is nil when the job posted nothing (a `BoundaryJob`, a dropped
    /// `pairedKeyUp`, an edit that turned out empty): it settles immediately. Otherwise, with `.untilEcho`, the
    /// job stays in flight until the tap settles it (`EchoTracker`); with `.untilPosted` it settles now.
    public func finished(_ sequence: JobSequence, expectation: EchoExpectation?) {
        guard let expectation, policy == .untilEcho else {
            settledByWorker.wrappingAdd(1, ordering: .sequentiallyConsistent)
            return
        }
        if !expectations.push(expectation) {
            // Cannot happen while at most `capacity` jobs are in flight; settle rather than block the keyboard.
            settledByWorker.wrappingAdd(1, ordering: .sequentiallyConsistent)
        }
    }

    /// Jobs pushed and not yet popped (approximate from other threads).
    public var queuedCount: Int { jobs.count }

    /// Tap (EchoTracker): `count` jobs settled by echo or timeout.
    @inline(__always)
    func settleByTap(_ count: Int) {
        settledByTap.wrappingAdd(UInt64(count), ordering: .sequentiallyConsistent)
    }
}

public enum JobOutcome: UInt8, Sendable, Hashable {
    case executed, executedWithFallback, abandoned, discardedForGeneration, passedThroughByFallback
}

/// Worker -> tap feedback through atomics.
public final class WorkerFeedback: Sendable {
    public static let boardSize = 64
    private let resetCount = Atomic<UInt64>(0)
    private let postingBroken = Atomic<Bool>(false)
    /// Slot i holds `(sequence << 8) | (outcome + 1)` for the most recent job with `sequence % 64 == i`.
    private let board = AtomicUInt64Array(count: WorkerFeedback.boardSize)

    public init() {}

    /// Worker increments after a flush or discard; the tap resets the engine when it sees a new value
    /// (PLT-R314 "reset the composition").
    public func requestCompositionReset() { resetCount.wrappingAdd(1, ordering: .sequentiallyConsistent) }
    public var compositionResetCount: UInt64 { resetCount.load(ordering: .sequentiallyConsistent) }

    /// Outcome of recent jobs (64-entry board indexed by sequence) so the tap can decide what to do with the
    /// keyUp of a consumed keyDown whose job already finished (PLT-R313). Nil = unknown or too old.
    public func record(_ outcome: JobOutcome, for sequence: JobSequence) {
        let slot = Int(sequence.rawValue % UInt64(Self.boardSize))
        board.store((sequence.rawValue << 8) | UInt64(outcome.rawValue + 1), at: slot)
    }

    public func outcome(of sequence: JobSequence) -> JobOutcome? {
        let value = board.load(Int(sequence.rawValue % UInt64(Self.boardSize)))
        guard value != 0, value >> 8 == sequence.rawValue & (UInt64.max >> 8) else { return nil }
        return JobOutcome(rawValue: UInt8(truncatingIfNeeded: value & 0xFF) &- 1)
    }

    /// Set by the tap after three consecutive echo misses (ADR 0311) or by the utility queue when
    /// `CGPreflightPostEventAccess()` turns false after a miss; read by the tap at callback entry to fail open
    /// within the same callback (PLT-R730). Cleared by the lifecycle owner when posting works again.
    public func markPostingBroken() { postingBroken.store(true, ordering: .sequentiallyConsistent) }
    public func clearPostingBroken() { postingBroken.store(false, ordering: .sequentiallyConsistent) }
    public var isPostingBroken: Bool { postingBroken.load(ordering: .sequentiallyConsistent) }
}

/// Result of the tap's per-callback echo bookkeeping.
public enum EchoHealth: Sendable, Hashable {
    case healthy
    /// `missesForBroken` consecutive jobs saw no echo within the timeout (PLT-R323): fail open (PLT-R730).
    case postingBroken
}

/// Echo liveness and in-flight settlement (PLT-R323, ADR 0311). TAP THREAD ONLY except `consecutiveMisses`.
/// The worker publishes `EchoExpectation`s through `JobQueue.finished`; the tap drains them at callback entry,
/// settles jobs whose final event echoed or whose echo timed out, and counts consecutive misses. The pending
/// list is allocated once (capacity = queue capacity), so the tap path never allocates.
public final class EchoTracker: @unchecked Sendable {
    public let timeout: TimeSpan
    public let missesForBroken: Int
    private let queue: JobQueue
    /// PLT-R801 echo round trip (`PlatformMetrics.echoRoundTrip`); atomic increments only.
    private let roundTrip: Log2Histogram?
    private let pending: UnsafeMutablePointer<EchoExpectation>
    private let pendingCapacity: Int
    // Tap-thread state.
    private var head = 0
    private var count = 0
    private var highestEcho: UInt32 = 0
    /// When the echo that raised `highestEcho` arrived: the round trip of a job ends no later than that.
    private var highestEchoAt = MonotonicInstant.zero
    private var hasSeenEcho = false
    private var misses = 0
    private let missesMirror = Atomic<Int>(0)
    /// One past the latest instant (monotonic nanoseconds) up to which unechoed expectations were lost while the
    /// tap was disabled (0: none). Written by the tap or the lifecycle owner, read by the tap at settlement.
    private let forgivenBound = Atomic<UInt64>(0)

    public init(
        queue: JobQueue, timeout: TimeSpan = .milliseconds(200), missesForBroken: Int = 3,
        roundTrip: Log2Histogram? = nil
    ) {
        self.queue = queue
        self.timeout = timeout
        self.missesForBroken = missesForBroken
        self.roundTrip = roundTrip
        pendingCapacity = queue.capacity
        pending = .allocate(capacity: queue.capacity)
    }

    deinit { pending.deallocate() }

    /// Tap, at callback entry (after PLT-R310 step 1): pulls new expectations, settles those whose echo was
    /// already seen and those older than `timeout` (each timeout is a miss and settles its job).
    public func settle(now: MonotonicInstant) -> EchoHealth {
        while count < pendingCapacity, let expectation = queue.expectations.pop() {
            pending[(head + count) % pendingCapacity] = expectation
            count += 1
        }
        var settled = 0
        let timeoutNanoseconds = timeout.unsignedNanoseconds
        let forgiven = forgivenBound.load(ordering: .sequentiallyConsistent)
        while count > 0 {
            let front = pending[head]
            if hasSeenEcho && Self.isAtOrBefore(front.finalEventSequence, highestEcho) {
                misses = 0
                roundTrip?.record(nanoseconds: highestEchoAt.nanoseconds(since: front.postedAt))
            } else if now.nanoseconds(since: front.postedAt) > timeoutNanoseconds {
                // A miss, unless it was posted before the tap was re-enabled (PLT-R330, PLT-R306): its echo
                // bypassed the disabled tap and never comes, which says nothing about posting. Either way it
                // settles only at the timeout, so keys stay held behind it as before (PLT-R311, ADR 0311).
                if front.postedAt.nanoseconds >= forgiven { misses += 1 }
            } else {
                break
            }
            head = (head + 1) % pendingCapacity
            count -= 1
            settled += 1
        }
        if settled > 0 { queue.settleByTap(settled) }
        missesMirror.store(misses, ordering: .relaxed)
        return misses >= missesForBroken ? .postingBroken : .healthy
    }

    /// Tap, on a marked echo (PLT-R310 step 2): records the watermark and settles every pending expectation at
    /// or before it. Echoes arrive in posting order, and one that arrives before its expectation was drained is
    /// matched by the watermark when the expectation shows up.
    public func observed(_ sequence: UInt32, at now: MonotonicInstant) {
        if !hasSeenEcho || Self.isAtOrBefore(highestEcho, sequence) {
            highestEcho = sequence
            highestEchoAt = now
        }
        hasSeenEcho = true
        _ = settle(now: now)
    }

    /// Any thread: the tap was disabled (a tap-disabled event, a watchdog trip) and is being re-enabled.
    /// Synthetic events posted while it was disabled, or queued behind a stuck callback and released by the
    /// disable, never pass through it, so their echoes never arrive. An expectation posted at or before `instant`
    /// whose echo times out does not count as a miss (PLT-R330, PLT-R306, PLT-R323: only a run of misses on an
    /// enabled tap means posting is broken). One atomic max; the bound never moves backwards.
    public func forgiveLostEchoes(postedAtOrBefore instant: MonotonicInstant) {
        let bound = instant.nanoseconds == .max ? UInt64.max : instant.nanoseconds + 1
        forgivenBound.max(bound, ordering: .sequentiallyConsistent)
    }

    /// Any thread (diagnostics).
    public var consecutiveMisses: Int { missesMirror.load(ordering: .relaxed) }

    /// Wrapping comparison over the 23-bit marker sequence space.
    @inline(__always)
    static func isAtOrBefore(_ lhs: UInt32, _ rhs: UInt32) -> Bool {
        ((rhs &- lhs) & EventMarker.sequenceMask) < (EventMarker.sequenceMask >> 1)
    }
}

/// Current focus generation, written by the ax thread on every publication, read by the worker to discard
/// stale edits (PLT-R316).
public final class CurrentFocusGeneration: Sendable {
    private let value = Atomic<UInt64>(0)
    public init() {}
    public func store(_ generation: FocusGeneration) {
        value.store(generation.rawValue, ordering: .sequentiallyConsistent)
    }
    public func load() -> FocusGeneration { FocusGeneration(rawValue: value.load(ordering: .sequentiallyConsistent)) }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/Injection/Worker.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The serial injection worker on the dedicated `inject` thread (PLT-R203, PLT-R311-R317, section 4).

internal import AppModel
public import Diagnostics
public import RealtimeSupport

public struct WorkerConfiguration: Sendable, Hashable {
    /// Oldest held event may wait this long before a flush (PLT-R314, VERIFY tuning).
    public var livenessCeiling: TimeSpan = .milliseconds(150)
    /// Ceiling while a macro job runs (PLT-R480).
    public var macroLivenessCeiling: TimeSpan = .seconds(1)
    /// Queue length that forces a flush (PLT-R314).
    public var maxQueuedJobs: Int = 256
    /// Jobs longer than this are split (if `allowSplit`) or use the fallback (PLT-R408).
    public var maxJobDuration: TimeSpan = .milliseconds(150)
    /// Long text: chunked Unicode up to 2,000 graphemes, paste above if opted in; hard cap 4,000 (PLT-R480).
    public var pasteThresholdGraphemes: Int = 2_000
    public var maximumExpansionGraphemes: Int = 4_000
    public init() {}
}

public struct InjectionServices: Sendable {
    public var poster: any EventPoster
    public var fieldAccess: any FocusedFieldAccess
    public var pasteboard: any PasteboardAccess
    public var clock: any MonotonicClock
    public var metrics: PlatformMetrics
    public var health: HealthEventLog
    public var logger: any DiagnosticsLogging
    public var capture: CaptureController?
    /// PLT-R802: intervals around each job and each AX call (nil: none, as in most tests).
    public var signposts: PlatformSignposts?

    public init(
        poster: any EventPoster, fieldAccess: any FocusedFieldAccess, pasteboard: any PasteboardAccess,
        clock: any MonotonicClock, metrics: PlatformMetrics, health: HealthEventLog,
        logger: any DiagnosticsLogging, capture: CaptureController?, signposts: PlatformSignposts? = nil
    ) {
        self.poster = poster
        self.fieldAccess = fieldAccess
        self.pasteboard = pasteboard
        self.clock = clock
        self.metrics = metrics
        self.health = health
        self.logger = logger
        self.capture = capture
        self.signposts = signposts
    }
}

/// Reasons the host asks the worker to flush outside the normal liveness check.
public enum FlushReason: UInt8, Sendable, Hashable {
    case tapDisabled  // PLT-R330 step 3
    case failOpen  // PLT-R730
    case queueFull
}

/// The serial worker. It owns the marker event sequence: every posted event (edit, replay, probe) gets the
/// next 23-bit sequence, and after a job's final event it calls `JobQueue.finished(_:expectation:)` with that
/// sequence so the tap can settle the job on its echo (ADR 0311). Jobs that post nothing finish with `nil`.
/// While `WorkerFeedback.isPostingBroken` is set it posts nothing: held events and triggers that cannot be
/// delivered are counted in `PlatformMetrics.lostWhilePostingBroken` and one `postingBroken` health event
/// with `.count(n)` (ADR 0308, ADR 0311); conservation (PLT-R312) is guaranteed only while posting works.
public final class InjectionWorker: Sendable {
    private let core: Mutex<WorkerCore>
    private let control: WorkerControl

    public init(
        queue: JobQueue, signal: WorkerSignal, feedback: WorkerFeedback, marker: EventMarker,
        focusGeneration: CurrentFocusGeneration, services: InjectionServices,
        configuration: WorkerConfiguration = WorkerConfiguration()
    ) {
        let control = WorkerControl(signal: signal)
        self.control = control
        core = Mutex(
            WorkerCore(
                queue: queue, feedback: feedback, marker: marker, focusGeneration: focusGeneration,
                services: services, configuration: configuration, control: control))
    }

    /// Spawns the `inject` thread (QoS user-interactive). The loop drains jobs, executes them FIFO, sleeps
    /// only on its own signal with absolute deadlines (pacing, liveness), and never waits on the main or tap
    /// thread (PLT-R315).
    public func start() { control.start { [self] in runThreadLoop() } }
    public func stop() { control.stop() }

    /// Asynchronous request (atomic flag + signal): abandon unstarted edit jobs (replaying their triggers),
    /// replay every held event in order, request a composition reset, record a `flush` health event.
    public func requestFlush(_ reason: FlushReason) { control.requestFlush(reason) }

    /// Deterministic mode for tests and the pipeline harness: runs the loop body on the caller's thread until
    /// the queue is empty and no deadline is pending, using the injected (fake) clock.
    public func runUntilIdle() { core.withLock { $0.runUntilIdle() } }

    /// Body of the `inject` thread: process, then wait on the worker signal until the next deadline.
    private func runThreadLoop() {
        while !control.isStopRequested {
            let idle = core.withLock { $0.runAvailable() }
            guard !control.isStopRequested else { return }
            if idle.isIdle { _ = control.signal.wait(until: idle.deadline) }
        }
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/Injection/Strategies.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Strategy catalogue (02-platform.md section 4) and the pure helpers every strategy shares.

public import AppModel
public import RealtimeSupport

public enum StrategyOutcome: Sendable, Hashable {
    /// Final synthetic event posted; its sequence goes to the echo tracker.
    case completed(lastEventSequence: UInt32)
    /// Detectable failure before anything was posted (AX error, pasteboard unreadable): try `fallback`.
    case failedBeforePosting(FallbackReason)
    /// Failure after partial output (readback mismatch for `axReplace`): fallback for the rest of the focus
    /// session, health event (4.5).
    case failedAfterPosting(FallbackReason)
}

/// Why a strategy did not deliver the edit. `historyMismatch`: the field's caret is closer to the start than the
/// composition the engine wants to replace (the history is out of sync with the field); a per-job condition.
public enum FallbackReason: UInt8, Sendable, Hashable {
    case axUnavailable, axTimedOut, axWriteFailed, readbackMismatch, pasteboardUnsafe, postingFailed, jobTooLong,
        historyMismatch
}

/// The inject-thread environment a strategy runs in. Implemented by the worker; faked in strategy tests.
public protocol InjectionEnvironment: AnyObject {
    var now: MonotonicInstant { get }
    /// Absolute-deadline pacing on the inject thread (PLT-R409).
    func sleep(until deadline: MonotonicInstant)
    /// Posts one event with a fresh marker sequence and returns that sequence.
    func post(_ event: SyntheticKeyEvent) throws(PostError) -> UInt32
    /// Replays every held event queued behind the current job (paste step 4, PLT-R461).
    func releaseHeldEvents()
    var fieldAccess: any FocusedFieldAccess { get }
    var pasteboard: any PasteboardAccess { get }
}

public protocol StrategyExecutor: Sendable {
    var strategy: InjectionStrategy { get }
    func execute(_ job: EditJob, in environment: any InjectionEnvironment) -> StrategyOutcome
}

/// `backspaceReplace` (4.2, with 4.3 inline completion), `selectReplace` (4.4), `axReplace` (4.5),
/// `paste` (4.6 with `PasteboardPreserver`). `passThrough` jobs are never built.
public enum StrategyCatalog {
    public static func executor(for strategy: InjectionStrategy) -> any StrategyExecutor {
        BuiltInExecutors.executor(for: strategy, limits: StrategyLimits())
    }
}

/// PLT-R402: trims the common grapheme prefix of the replaced text and the insertion. With unknown replaced
/// text, the edit is returned unchanged (the engine's edits are already minimal, ENG-R611).
public enum EditMinimizer {
    public static func minimize(deleteCount: Int, replaced: String?, insertion: String)
        -> (deleteCount: Int, insertion: String)
    {
        let edit = MinimalEdit(deleteCount: deleteCount, deleteUTF16Count: 0, replaced: replaced, insertion: insertion)
        return (edit.deleteCount, edit.insertion)
    }
}

/// PLT-R404/PLT-R480: one grapheme per event by default; up to `maxUTF16` units per event when allowed;
/// never splits a grapheme cluster.
public enum UnicodeChunker {
    public static func chunks(of text: String, maxUTF16: Int, oneGraphemePerEvent: Bool) -> [InlineUTF16] {
        GraphemeChunking.chunks(of: text, maxUTF16: maxUTF16, oneGraphemePerEvent: oneGraphemePerEvent)
    }
}

/// Full clipboard preservation for `paste` (PLT-R461): snapshot every item and type (abort on file promises,
/// unmaterialisable lazy data, > 10 MB or > 100 ms), write the transient item, paste, restore after
/// `restoreDelayMs` only if `changeCount` is unchanged, coalesce consecutive pastes within the window.
/// Inject thread only. The restore window starts at the first `restoreIfDue` call after `beginPaste` (the worker
/// arms it right after Command+V); a further `beginPaste` inside the window keeps the first snapshot.
public final class PasteboardPreserver {
    var session: PasteSession

    public init(pasteboard: any PasteboardAccess, limits: PasteboardLimits = PasteboardLimits()) {
        session = PasteSession(pasteboard: pasteboard, limits: limits)
    }

    /// Step 1-2. Throws when the clipboard cannot be fully preserved: never destroy what cannot be restored.
    public func beginPaste(_ text: String) throws(PasteboardError) { try session.begin(text) }

    /// Steps 4-6, driven by the worker's deadlines.
    public func restoreIfDue(now: MonotonicInstant, restoreDelay: TimeSpan) -> RestoreResult {
        session.restoreIfDue(now: now, restoreDelay: restoreDelay)
    }

    public enum RestoreResult: Sendable, Hashable { case notDue, restored, skippedUserCopied, nothingPending }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/Injection/System/SystemInjectionServices.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Production implementations of the injection services. They need granted permissions and are exercised by
// the self-hosted integration suite (13.2), never by hosted CI or on the maintainer's everyday Mac.
// Each is a thin wrapper: the logic lives in `CGEventFactory`, `AXFieldCalls` and `PasteboardIO`, which are
// unit-tested without posting, AX trust or the general pasteboard.

internal import AppModel
internal import ApplicationServices
public import RealtimeSupport

/// CoreGraphics poster (PLT-R320-R322, PLT-R324).
public final class CGEventPoster: EventPoster {
    private let factory: CGEventFactory

    public init() { factory = CGEventFactory() }

    public func post(_ event: SyntheticKeyEvent, userData: Int64) throws(PostError) {
        try factory.makeEvent(event, userData: userData).post(tap: .cgSessionEventTap)
    }

    public func replay(_ record: KeyEventRecord, userData: Int64) throws(PostError) {
        try factory.makeReplay(record, userData: userData).post(tap: .cgSessionEventTap)
    }
}

/// Bounded AX field access (PLT-R343).
public final class AXFocusedFieldAccess: FocusedFieldAccess {
    public init() {}
    public func selectedRange(_ field: FieldHandle, timeout: TimeSpan) -> AXCallResult<TextRange> {
        AXFieldCalls.selectedRange(field.element?.element, timeout: timeout)
    }
    public func text(_ field: FieldHandle, in range: TextRange, timeout: TimeSpan) -> AXCallResult<String> {
        AXFieldCalls.text(field.element?.element, in: range, timeout: timeout)
    }
    public func setSelectedRange(_ field: FieldHandle, to range: TextRange, timeout: TimeSpan) -> AXCallResult<Void> {
        AXFieldCalls.setSelectedRange(field.element?.element, to: range, timeout: timeout)
    }
    public func setSelectedText(_ field: FieldHandle, to text: String, timeout: TimeSpan) -> AXCallResult<Void> {
        AXFieldCalls.setSelectedText(field.element?.element, to: text, timeout: timeout)
    }
}

/// AppKit pasteboard (PLT-R461). `pasteboardName` nil = general pasteboard.
public final class NSPasteboardAccess: PasteboardAccess {
    private let io: PasteboardIO

    public init(pasteboardName: String?) { io = PasteboardIO(name: pasteboardName) }
    public var changeCount: Int { io.changeCount }
    public func snapshot(limits: PasteboardLimits) throws(PasteboardError) -> PasteboardSnapshot {
        try io.snapshot(limits: limits)
    }
    public func writeTransient(_ text: String) throws(PasteboardError) -> Int { try io.writeTransient(text) }
    public func restore(_ snapshot: PasteboardSnapshot) throws(PasteboardError) { try io.restore(snapshot) }
}
```
<!-- /include -->

## 10. InputHost

Owned files (three wave-1 workstreams, disjoint paths):

| Path under `Sources/InputHost/` | Owner | Tests |
|---|---|---|
| `Snapshots/`, `Engine/`, `Pipeline/` | W1-F1 (pipeline) | `Tests/InputHostTests/Pipeline/`, `Sources/TestSupport/Pipeline/` |
| `Tap/`, `Lifecycle/HostLifecycle.swift` | W1-F2 (tap, watchdogs, lifecycle state machine) | `Tests/InputHostTests/Tap/`, `Tests/InputHostTests/Lifecycle/`, `Sources/TestSupport/Fakes/Tap/` |
| `Hotkeys/`, `InputSource/`, `SecureInput/`, `Focus/`, `Memory/`, `Permissions/`, `Workspace/` | W1-E (host services) | `Tests/InputHostTests/Services/`, `Sources/TestSupport/Fakes/Host/` |
| `Lifecycle/InputHostController.swift`, `Integration/` | W2-A (composition) | `Tests/InputHostTests/Integration/` |
| `Probes/` | W2-C (diagnostics UI) | `Tests/InputHostTests/Probes/` |

`Snapshots/` is a frozen contract between W1-E (producers) and W1-F1 (consumer). Every service that has
periodic or delayed work takes `any TimerScheduler`, and every service clock is `any MonotonicClock`
([0313](../decisions/0313-testability-seams.md)); only the tap pipeline is generic over its clock.

### 10.1 Pipeline and per-key state (tap thread)

`KeyPipeline<Factory, Clock>` holds, confined to the tap thread: the current `CompositionEngine`, the engine
variant and settings generation it was built for, the `HotkeyRecognizer`, a fixed-size table of consumed
keyDowns awaiting their keyUp (keycode -> job sequence), the last seen worker reset counter, the tap's own
toggle override (sequence, bundle, mode), the secure-input "resumed" generation and the idle timestamp for
PLT-R382. Steps of PLT-R310 are in ARCHITECTURE.md section 4.

Engine catalog revision (PRD-R27, PLT-R340): the settings publisher (W2-A, utility queue) builds the
`EngineCatalog` with `EngineBridge.catalog(settings:resources:revision:)` and sets `EngineCatalog.revision`. It
gives a new value when an input of the catalog changes (anything `EngineBridge.configuration` or
`EngineBridge.resources` reads, the user word lists and the macro table) and passes the previous value
unchanged when a settings change leaves the engines alone (hotkeys, interface language, update channel). On a
new `TapSettingsSnapshot.generation` the pipeline compares the revision with the one its engine was built for:
a different or `nil` revision builds a fresh engine and is a boundary (`configurationChanged`); the same
revision only rebuilds the hotkey recogniser and keeps the word being typed. `nil` means unknown, so a publisher
that never sets a revision gets the safe behaviour (every generation rebuilds).

Re-entry (PLT-R342): every edit of a word re-opened by Backspace carries `verifyBeforeApply` when the rule's
`verifyReentry` is not `.never`, whatever its kind (`.reentry`, `.macro`, `.restore`); the worker honours the
flag for every kind (section 9).

Diagnostics pass-through (PLT-R1205 steps 3-5): while `LifecycleSnapshot.diagnosticsPassThrough` is true the
host state is `paused(diagnosticsTest)` (after the phase checks, before `userDisabled`). Every keyboard event
then passes unchanged (held only while earlier jobs are in flight, PLT-R311) without feeding the engine, and
hotkeys are suspended like during recording, so no VI/EN toggle reaches per-app memory and the manual mode is
unchanged. The flag is read from the snapshot at callback entry like every other per-key input: no lock and no
allocation (PLT-R304, PLT-R305). The guided test's own events carry this launch's marker (probe kind), so they
stay out of the user's metrics (PLT-R810).

### 10.2 Hotkey recogniser (PRD-R14, PRD-R15)

`HotkeyRecognizer` is a value-type state machine fed with `HotkeyInput` built from tap events:

- **Modifier tap** (default: tap Control+Shift). `idle` -> `arming` when a `flagsChanged` makes the held set a
  superset-in-progress of the chord (any press order); any keyDown, pointer down or scroll -> `cancelled`;
  holding longer than 500 ms -> `cancelled`; autorepeat ignored; when the last modifier is released and the
  maximum held set equals the chord exactly -> `.toggleTap` and back to `idle`. Modifier events are always
  passed through (they were never swallowed), so other apps' shortcuts keep working; a chord used with another
  key never toggles.
- **Key combo**. keyDown with exactly the bound modifiers -> `.toggleCombo`; the pipeline consumes that keyDown
  and its keyUp (outcome "consumed as hotkey").
- **Restore binding** (unset by default). keyDown matching the binding -> `.restoreCandidate`; the pipeline sends
  `.restoreToggle` to the engine and consumes the key only if the engine answers with an edit; otherwise the key
  passes, and Escape is a hard boundary (PLT-R353). Rules can disable it (`features.restoreHotkey`).
- Right-side-only taps use the keycode of the `flagsChanged` event (`kVK_RightCommand`, `kVK_RightOption`).
- While the app's own recorder is active (`LifecycleSnapshot.recorderActive`), hotkeys are suspended.
- `HotkeyRecorder` accumulates the held modifier set and the last non-modifier key in any press order and
  finishes when everything is released; modifier-only results must be one of the PRD-R15 chords; combos that
  macOS uses are accepted with a `SystemShortcutConflict` warning (PRD-R16). Globe/fn is not offered until the
  PRD-R17 VERIFY item is resolved.

### 10.3 Tap thread confinement, watchdog and lifecycle

- `TapThread<Handler: TapEventHandler>` calls its `@Sendable` handler factory inside the thread entry, so the
  `KeyPipeline` (deliberately not `Sendable`) is created on the tap thread and reached only from the C
  callback's `userInfo`. No `ThreadConfined` check runs per callback. The factory returns
  `any EventTapHandle`, so tests use `FakeEventTapHandle` and never message the WindowServer.
- `TapEventMask.standard` includes `scrollWheel` (PRD-R14 cancels the toggle tap on scroll; PLT-R301 allows the
  bit only for that). The pipeline feeds a scroll to `HotkeyRecognizer.handle(.scroll)` and passes it.
- `TapWatchdog` (utility, through `TimerScheduler`): 250 ms check armed by the tap's activity signal and
  disarmed after 2 s idle; 5 s enabled check plus `TapSnapshots.reclaimAll()`; after a trip, recovery only if
  `CallbackWatchdog.isInsideCallback` is false 2 s later, otherwise `TapTrip.callbackStuck` ->
  `failOpen(callbackStuck)`, never a second tap ([0309](../decisions/0309-callback-watchdog-gating.md)).
- `HostLifecycle` is the 2.1 state machine as a value: `handle(_ input:) -> [LifecycleEffect]`. Inputs are
  permission changes, tap created or failed, retry timer fired, watchdog trips, callback exited, posting broken,
  system disables, session and user-disable changes and the diagnostics pass-through; effects are publish,
  publish flags (same phase, a flag changed), create/remove/disable/re-enable tap, flush, reset composition,
  schedule/cancel retry (1, 2, 5, 10 s after a failed tap creation, PLT-R332; the posting-broken backoff below),
  health records and the instability notice. `InputHostController` (W2-A) performs the effects with real
  services.
- Diagnostics pass-through (PLT-R1205 steps 3-5): `InputHostController.setDiagnosticsPassThrough(_:)` feeds
  `.diagnosticsPassThrough(Bool)`. Calls nest (a depth count); only the first start and the matching last end
  change `HostLifecycle.diagnosticsPassThrough`, and an end without a start is ignored. Entering returns
  `[.publishFlags, .resetComposition]` (the tap stops transforming in its next callback, then the word is
  dropped); leaving returns `[.resetComposition, .publishFlags]` (PLT-R210: never a transform with a stale
  composition). Before launch the flag is only recorded; the first publish carries it. It is never a phase.
- Posting broken (PLT-R323, PLT-R730, [0311](../decisions/0311-in-flight-until-echo.md) amendment).
  `.postingBroken` (three echo misses, or a false post preflight) returns the fail-open effects (publish
  `failOpen(postingBroken)`, flush, reset composition, remove the tap), then `.recordHealth(.postingBroken)` and
  `.scheduleRetry(after: delay)`. Echo loss and OS policy leave the permission status `ready`, so no permission
  transition would ever recreate the tap: the lifecycle retries on its own. A later `.retryTimerFired` returns
  `[.createTap]` while the phase stays `failOpen(postingBroken)` (the menu does not flicker); a successful
  creation moves to `running`, a failed one to `failOpen(tapUnavailable)` with the PLT-R332 backoff. The delay
  comes from `HostLifecycle.postingBrokenBackoff` (30 s, 60 s, 120 s, 240 s, then 300 s, the 5-minute cap). A new
  break within the previous delay plus `HostLifecycle.postingBrokenStableInterval` (600 s) of the previous break
  moves one step up; otherwise the backoff restarts at 30 s. A path that stays broken therefore cannot cause a
  create-and-break loop, and a recreated tap that posted for 10 minutes starts over. A permission loss in this
  phase moves to `failOpen(permissionRevoked)` and cancels the retry.
- System disables (PLT-R330, PLT-R331): every report re-enables the tap, resets and flushes. The OS disable
  event and the watchdog's enabled check can both report one disable, so reports closer than
  `HostLifecycle.disableCoalescingWindow` (1 s) count once toward the instability notice (more than 3 within
  `instabilityWindow`, 10 minutes, at most one notice per window).
- Secure-input episodes: `SecureInputMonitor.keyEvidence(generation:)` ends episode N; the next poll that still
  sees the OS flag on starts a new generation, so the tap pauses again instead of staying "resumed" while the
  OS blocks keys (PLT-R398B).

### 10.4 Per-app memory and the toggle race

`AppModeMemory` lives on the ax thread. When the user toggles with the hotkey, the tap flips the mode at once
and pushes `modeToggled(sequence, bundle, mode)` to both the ax and the main outbox. The ax thread drains its
inbox before resolving any focus change, applies the toggle to memory (PRD-R20) and stamps every published
`FocusSnapshot` with `appliedToggleSequence`. The tap's effective mode is its own override when
`override.sequence > snapshot.appliedToggleSequence` and the bundle matches, otherwise `snapshot.mode`. A
focus change resolved concurrently with a toggle therefore never flips the mode back (PLT-R391, PRD-R19).

Field-token rule (PLT-R210, PLT-R340, ENG-R1010): on a new `FocusSnapshot.generation` the pipeline keeps the
composition only when the new snapshot has the same pid and the same `fieldHandle` token as the last one. A
generation without a `fieldHandle` (AX unavailable or timed out) always counts as a focus change, because the
host cannot vouch for the text before the caret: boundary `applicationChanged` when the pid differs, otherwise
`focusChanged`. With the same owner, a changed decision (strategy, parameters, engine variant, text-focus
requirement or pause) is a `configurationChanged` boundary (`ruleChanged`); a republication with the same
owner and decision, such as the restamp after the ax thread applied a toggle, is not a boundary.

### 10.5 Engine behaviour the host relies on

Notes from the engine track (`Packages/VietnameseEngine`, public API in `Sources/VietnameseEngine/PublicAPI.swift`).
None of them changes a public signature.

- Engines are built off the tap thread. `Engine.init` does the one-time table work: the first engine of a
  process builds the generated tables (about 12 ms on an Apple M4 in a release build: ADR 0104,
  `PublicAPI.swift`). The settings publisher (W2-A) must create engines at launch and on configuration changes,
  on the utility queue, through `EngineBridge.catalog`; the tap only indexes the prebuilt `EngineCatalog`
  (PLT-R304, PLT-R305). `Orthography` is `Sendable`, so tables built on one thread are safe to read on another.
- Every commit carries a decision. When an event commits a token or expands a macro,
  `EngineOutput.decision` is non-nil: `kept(rule)`, `restored(rule)` or `macro` (ENG-R801). Tokens decided by
  rule L0 (the display equals the keys typed) report `kept(.unchanged)`. Hosts and diagnostics never need a
  "committed without a decision" case.
- `LearningSignal` values (`preferredRaw(raw:)`, `preferredVietnamese(raw:)`) carry the lowercased raw keys of
  the token, the same form the engine uses for every word-list lookup, so the host can add the value to the
  keep-as-typed or keep-Vietnamese list as is (ENG-R861). The engine never stores it; the pipeline forwards it
  in memory only.
- Return and Tab end Backspace re-opening: they clear the history (ENG-R912), so Backspace after them cannot
  re-open a word typed before them. They do not end the run's English context: the languages of the last three
  committed tokens survive Return and Tab, and only a reset clears them (ENG-R823).
- `TextEdit.deleteCount` counts grapheme clusters and `deleteUTF16Count` counts UTF-16 code units (ENG-R630,
  ENG-R631). They are equal for every engine-produced span, but differ when an edit removes a macro expansion
  that contains characters outside the Basic Multilingual Plane (an emoji is 1 cluster and 2 units). The host
  uses `deleteCount` for Backspace events (one per cluster) and `deleteUTF16Count` for UTF-16 ranges (AX
  selection replacement, marked text) (ENG-R632); `EditJob` carries both (section 9).
- Macro expansions are byte-exact: the engine does not normalise them, so the host normalises each expansion
  to NFC before building the `MacroTable` (ENG-R1101).

<!-- include: Packages/AppCore/Sources/InputHost/Snapshots/Snapshots.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Immutable values the tap reads with one atomic load each (PLT-R304, PLT-R388). FROZEN CONTRACT between the
// pipeline (consumer) and the host services (producers); docs/architecture/contracts.md section InputHost.

public import AppModel
public import Injection
public import RealtimeSupport

/// Published by the utility queue after every settings change (PLT-R1008).
public struct TapSettingsSnapshot: Sendable {
    public var generation: UInt64
    public var engines: EngineCatalog
    public var toggleHotkey: HotkeyBinding
    public var restoreHotkey: HotkeyBinding?
    /// D10. Macros in EN mode need an engine capability not in the 12.2 API (open issue for the engine track).
    public var macrosInEnglishMode: Bool
    public var rememberPerApp: Bool

    public init(
        generation: UInt64, engines: EngineCatalog, toggleHotkey: HotkeyBinding, restoreHotkey: HotkeyBinding?,
        macrosInEnglishMode: Bool, rememberPerApp: Bool
    ) {
        self.generation = generation
        self.engines = engines
        self.toggleHotkey = toggleHotkey
        self.restoreHotkey = restoreHotkey
        self.macrosInEnglishMode = macrosInEnglishMode
        self.rememberPerApp = rememberPerApp
    }
}

/// The focus owner (PLT-R381): the system-wide AX focused application, which can be a non-activating panel.
public struct FocusedApp: Sendable, Hashable {
    public var pid: Int32
    public var bundle: BundleKey
    public var appVersion: LooseVersion?
    public var engine: EngineFingerprint
    public init(pid: Int32, bundle: BundleKey, appVersion: LooseVersion?, engine: EngineFingerprint) {
        self.pid = pid
        self.bundle = bundle
        self.appVersion = appVersion
        self.engine = engine
    }
}

/// Focused element metadata (PLT-R383). Titles and URLs are never stored here.
public struct FieldContext: Sendable, Hashable {
    public var axAvailability: AXAvailability
    public var role: String?
    public var subrole: String?
    public var identifier: String?
    public var domClasses: [String]
    public var editable: Bool?
    /// Subrole `AXSecureTextField` (PLT-R387).
    public var secure: Bool

    public static let unknown = FieldContext(
        axAvailability: .unavailable, role: nil, subrole: nil, identifier: nil, domClasses: [], editable: nil,
        secure: false)

    public init(
        axAvailability: AXAvailability, role: String?, subrole: String?, identifier: String?, domClasses: [String],
        editable: Bool?, secure: Bool
    ) {
        self.axAvailability = axAvailability
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.domClasses = domClasses
        self.editable = editable
        self.secure = secure
    }
}

/// Engine variant selected by the resolved rule and settings (ENG-R850, `features`). The catalog prebuilds
/// one engine per variant so the tap never builds engines.
public struct EngineVariant: Sendable, Hashable {
    public var appContext: EngineContextKind
    public var englishRestore: Bool
    public var macros: Bool
    public init(appContext: EngineContextKind, englishRestore: Bool, macros: Bool) {
        self.appContext = appContext
        self.englishRestore = englishRestore
        self.macros = macros
    }

    public static let `default` = EngineVariant(appContext: .general, englishRestore: true, macros: true)
}

/// The resolved rule decision as the tap needs it, converted once per focus change on the ax thread.
public struct HostDecision: Sendable, Hashable {
    public var plan: InjectionPlan
    public var variant: EngineVariant
    /// Concrete PLT-R386 value (`never`, `whenKnown`, `always`).
    public var requireTextFocus: RequireTextFocus
    public var verifyReentry: VerifyReentry
    public var restoreHotkeyEnabled: Bool  // features.restoreHotkey (PLT-R353)
    public var rule: RuleID?
    public var source: DecisionSource
    public var specificity: Int
    /// The rule says `overlay: true` (Spotlight, Raycast, Alfred): while it applies, every keyDown asks the ax
    /// thread to revalidate the focus, because the panel closes without an app activation (PLT-R389).
    public var overlay: Bool

    public init(
        plan: InjectionPlan, variant: EngineVariant, requireTextFocus: RequireTextFocus, verifyReentry: VerifyReentry,
        restoreHotkeyEnabled: Bool, rule: RuleID?, source: DecisionSource, specificity: Int, overlay: Bool = false
    ) {
        self.plan = plan
        self.variant = variant
        self.requireTextFocus = requireTextFocus
        self.verifyReentry = verifyReentry
        self.restoreHotkeyEnabled = restoreHotkeyEnabled
        self.rule = rule
        self.source = source
        self.specificity = specificity
        self.overlay = overlay
    }
}

/// Why the effective VI/EN mode is what it is (PRD-R21 precedence).
public enum ModeSource: String, Sendable, Hashable, Codable {
    case ignoreRule, alwaysEnglish, alwaysVietnamese, remembered, ruleDefault, globalMode, layoutBinding
}

/// Published by the ax thread on every focus change and re-resolution (PLT-R383, PLT-R391).
public struct FocusSnapshot: Sendable {
    public var generation: FocusGeneration
    public var app: FocusedApp?
    public var field: FieldContext
    public var decision: HostDecision
    public var mode: TypingMode
    public var modeSource: ModeSource
    /// Highest tap toggle sequence the ax thread had applied to memory when it resolved `mode`. A tap toggle
    /// with a higher sequence for the same bundle overrides `mode` (race-free per-app memory, ARCHITECTURE.md).
    public var appliedToggleSequence: UInt64
    public var fieldHandle: FieldHandle?
    /// Time of the focus change (for `firstEditDelayUs`, PLT-R408).
    public var changedAt: MonotonicInstant
    /// Pause reason derived from focus alone: `.secureField`, `.passThroughRule`, `.noTextFocus`.
    public var pause: PauseReason?

    public init(
        generation: FocusGeneration, app: FocusedApp?, field: FieldContext, decision: HostDecision, mode: TypingMode,
        modeSource: ModeSource, appliedToggleSequence: UInt64, fieldHandle: FieldHandle?,
        changedAt: MonotonicInstant, pause: PauseReason?
    ) {
        self.generation = generation
        self.app = app
        self.field = field
        self.decision = decision
        self.mode = mode
        self.modeSource = modeSource
        self.appliedToggleSequence = appliedToggleSequence
        self.fieldHandle = fieldHandle
        self.changedAt = changedAt
        self.pause = pause
    }
}

public enum InputSourceKind: String, Sendable, Hashable, Codable {
    /// ASCII-capable keyboard layout: the only kind that is transformed (PLT-R371).
    case asciiLayout
    case nonASCIILayout
    case inputMethod
    case inputMode
}

public struct InputSourceInfo: Sendable, Hashable {
    public var id: InputSourceID
    public var kind: InputSourceKind
    /// Localized name for the menu (PRD-R43 "Đang dùng bàn phím {{SourceName}}"). Never logged.
    public var localizedName: String
    public var languages: [String]  // kTISPropertyInputSourceLanguages
    /// A macOS built-in Vietnamese input source (detected by language "vi" plus kind, not by ID literal).
    public var isBuiltInVietnamese: Bool

    public init(
        id: InputSourceID, kind: InputSourceKind, localizedName: String, languages: [String],
        isBuiltInVietnamese: Bool
    ) {
        self.id = id
        self.kind = kind
        self.localizedName = localizedName
        self.languages = languages
        self.isBuiltInVietnamese = isBuiltInVietnamese
    }
}

/// Published by the main thread on `kTISNotifySelectedKeyboardInputSourceChanged` (PLT-R370).
public struct InputSourceSnapshot: Sendable {
    public var generation: UInt64
    public var source: InputSourceInfo
    /// Precomputed `UCKeyTranslate` table for the current layout (PLT-R360); nil for non-ASCII sources.
    public var table: LayoutTable?
    /// Mode designated for this layout when the PLT-R373 binding is enabled.
    public var boundMode: TypingMode?

    public init(generation: UInt64, source: InputSourceInfo, table: LayoutTable?, boundMode: TypingMode?) {
        self.generation = generation
        self.source = source
        self.table = table
        self.boundMode = boundMode
    }
}

/// Published by the utility queue's secure-input poller (PLT-R395). The generation changes on every OS
/// transition. Key evidence (PLT-R398B) ends episode N: the tap stays resumed for generation N until the next
/// poll, and the next poll that still sees the OS flag on starts a new episode with a new generation, so
/// on -> off -> key -> on inside one poll interval pauses again.
public struct SecureInputSnapshot: Sendable, Hashable {
    public var generation: UInt64
    public var enabled: Bool
    public var holder: SecureInputHolder?
    public init(generation: UInt64, enabled: Bool, holder: SecureInputHolder?) {
        self.generation = generation
        self.enabled = enabled
        self.holder = holder
    }

    public static let initial = SecureInputSnapshot(generation: 0, enabled: false, holder: nil)
}

/// Published by the main thread's state machine (2.1): the parts of host state not derivable per key.
public struct LifecycleSnapshot: Sendable, Hashable {
    public enum Phase: Sendable, Hashable {
        case noPermission, starting, running, sessionInactive
        case failOpen(FailOpenReason)
    }

    public var generation: UInt64
    public var phase: Phase
    public var userDisabled: Bool
    /// The app's own hotkey recorder is capturing keys: hotkeys must not fire (PRD-R15).
    public var recorderActive: Bool
    /// Global mode when per-app memory is off or no app is known.
    public var globalMode: TypingMode
    /// The guided test is typing (PLT-R1205 steps 3-5): host state `paused(diagnosticsTest)`, every key passes
    /// unchanged and hotkeys are suspended.
    public var diagnosticsPassThrough: Bool

    public init(
        generation: UInt64, phase: Phase, userDisabled: Bool, recorderActive: Bool, globalMode: TypingMode,
        diagnosticsPassThrough: Bool = false
    ) {
        self.generation = generation
        self.phase = phase
        self.userDisabled = userDisabled
        self.recorderActive = recorderActive
        self.globalMode = globalMode
        self.diagnosticsPassThrough = diagnosticsPassThrough
    }
}

/// The five cells the tap reads, sharing one reader epoch (docs/decisions/0303-snapshot-publication.md).
public struct TapSnapshots: Sendable {
    public let epoch: ReaderEpoch
    public let settings: SnapshotCell<TapSettingsSnapshot>
    public let focus: SnapshotCell<FocusSnapshot>
    public let inputSource: SnapshotCell<InputSourceSnapshot>
    public let secureInput: SnapshotCell<SecureInputSnapshot>
    public let lifecycle: SnapshotCell<LifecycleSnapshot>

    public init(
        epoch: ReaderEpoch, settings: SnapshotCell<TapSettingsSnapshot>, focus: SnapshotCell<FocusSnapshot>,
        inputSource: SnapshotCell<InputSourceSnapshot>, secureInput: SnapshotCell<SecureInputSnapshot>,
        lifecycle: SnapshotCell<LifecycleSnapshot>
    ) {
        self.epoch = epoch
        self.settings = settings
        self.focus = focus
        self.inputSource = inputSource
        self.secureInput = secureInput
        self.lifecycle = lifecycle
    }

    /// Frees retired boxes of all five cells (utility queue, every 5 s from `TapWatchdog`, ADR 0303).
    public func reclaimAll() {
        settings.reclaim()
        focus.reclaim()
        inputSource.reclaim()
        secureInput.reclaim()
        lifecycle.reclaim()
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/InputHost/Snapshots/LayoutTable.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Layout translation table (PLT-R360, PLT-R361). Built off the hot path from the layout's `uchr` data with
// `UCKeyTranslate`; looked up on the tap by array index.

public import AppModel

/// Modifier states covered by the table. Option and Command/Control states are classified, not translated
/// (PLT-R350).
public enum LayoutModifierState: Int, Sendable, Hashable, CaseIterable {
    case none = 0
    case shift
    case capsLock
    case shiftCapsLock
}

public enum LayoutEntry: Sendable, Hashable {
    case character(Character)
    /// `UCKeyTranslate` returned no character and a non-zero dead-key state (PLT-R354).
    case deadKey
    case none
}

public struct LayoutTable: Sendable {
    public static let keyCodeCount = 128

    public let source: InputSourceID
    public let keyboardType: UInt32
    private let entries: [LayoutEntry]  // keyCodeCount * 4, index = keyCode * 4 + state
    private let reverse: [Character: KeyCode]

    /// Used by the builder and by tests with synthetic tables.
    public init(source: InputSourceID, keyboardType: UInt32, entries: [LayoutEntry]) {
        precondition(entries.count == Self.keyCodeCount * LayoutModifierState.allCases.count)
        self.source = source
        self.keyboardType = keyboardType
        self.entries = entries
        var reverse: [Character: KeyCode] = [:]
        for code in (0..<Self.keyCodeCount).reversed() {
            for state in [LayoutModifierState.shift, .none] {
                if case .character(let character) = entries[code * 4 + state.rawValue] {
                    reverse[character] = KeyCode(rawValue: UInt16(code))
                }
            }
        }
        self.reverse = reverse
    }

    /// Tap-safe: bounds check plus array read, no allocation.
    @inline(__always)
    public func entry(for keyCode: KeyCode, state: LayoutModifierState) -> LayoutEntry {
        let code = Int(keyCode.rawValue)
        guard code < Self.keyCodeCount else { return .none }
        return entries[code * 4 + state.rawValue]
    }

    /// Keycode producing `character` without modifiers or with Shift (PLT-R405, PLT-R461 step 3).
    public func keyCode(producing character: Character) -> KeyCode? { reverse[character] }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/InputHost/Engine/EngineBridge.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// How the engine is bridged (docs/decisions/0306-engine-bridge.md). The engine is a pure value type
// (`Engine.reduce`, 01-engine.md 12.2); the host keeps one `Session` on the tap thread and swaps engines only
// at hard boundaries (ENG-R1211). Engines are prebuilt off the hot path, one per variant.

internal import AppModel
public import SettingsStore
public import VietnameseEngine

/// Abstraction the pipeline is generic over, so conservation and ordering property tests can drive it with a
/// scripted fake engine independently of the engine track (13.1).
public protocol CompositionEngine {
    mutating func handle(_ event: EngineEvent) -> EngineOutput
    /// Display of the active token before the event (for `EditJob.replacedText`, PLT-R402).
    var activeDisplay: String { get }
}

public protocol CompositionEngineFactory {
    associatedtype Engine: CompositionEngine
    /// The PLT-R310 step 5 recogniser the pipeline builds from the hotkey bindings of each settings generation.
    /// Production uses `HotkeyRecognizer` (the default); test factories may name a reference recogniser.
    associatedtype Hotkeys: HotkeyRecognizing = HotkeyRecognizer
    /// Called on the tap thread at a hard boundary; MUST NOT allocate beyond copying prebuilt values.
    func makeEngine(for variant: EngineVariant, settings: TapSettingsSnapshot) -> Engine
}

/// Production engine: a `VietnameseEngine.Session` over a prebuilt `Engine`.
public struct VietnameseCompositionEngine: CompositionEngine {
    public private(set) var session: Session
    public init(engine: VietnameseEngine.Engine) { session = Session(engine: engine) }
    public mutating func handle(_ event: EngineEvent) -> EngineOutput { session.handle(event) }
    public var activeDisplay: String { session.state.activeDisplay }
}

public struct VietnameseCompositionEngineFactory: CompositionEngineFactory, Sendable {
    public init() {}
    public func makeEngine(for variant: EngineVariant, settings: TapSettingsSnapshot) -> VietnameseCompositionEngine {
        VietnameseCompositionEngine(engine: settings.engines.engine(for: variant))
    }
}

/// Eight prebuilt engines: appContext x englishRestore x macros (ENG-R850, `features`, ENG-R1107). Lookup is an
/// array index, so the tap never hashes or allocates to find an engine.
public struct EngineCatalog: Sendable {
    private let slots: [VietnameseEngine.Engine]
    /// Identifies the engine-affecting settings the catalog was built from (PRD-R27, PLT-R340). The publisher
    /// keeps it when a settings change leaves the engines alone (hotkeys, UI language, update channel), so the
    /// tap rebuilds only the hotkeys and keeps the word being typed. `nil` means unknown: every new settings
    /// generation builds a fresh engine, the safe default.
    public let revision: UInt64?

    /// Missing variants fall back to the default variant's engine (or a neutral engine for an empty catalog).
    public init(engines: [EngineVariant: VietnameseEngine.Engine], revision: UInt64? = nil) {
        let fallback =
            engines[.default] ?? engines.values.first
            ?? VietnameseEngine.Engine(configuration: EngineConfiguration(), resources: .empty)
        slots = EngineVariant.catalogOrder.map { engines[$0] ?? fallback }
        self.revision = revision
    }

    public func engine(for variant: EngineVariant) -> VietnameseEngine.Engine { slots[variant.catalogIndex] }
}

public enum MacroTableBuildIssue: Sendable, Hashable {
    case rejected(macroID: String, reason: MacroTable.ValidationError)
}

/// Pure mapping from settings to engine values. Runs on the utility queue when settings change.
public enum EngineBridge {
    /// D1, D2, D4, D5, D6 plus the variant.
    public static func configuration(for settings: EffectiveSettings, variant: EngineVariant) -> EngineConfiguration {
        EngineSettingsMapping.configuration(for: settings, variant: variant)
    }

    /// Enabled macros only; invalid entries are skipped and reported (the editor prevents them, PRD-R29).
    public static func macroTable(from macros: [StoredMacro]) -> (MacroTable, [MacroTableBuildIssue]) {
        MacroTableBuilder.build(from: macros) { try MacroTable($0) }
    }

    /// Loads bundled lexicons once (ENG-R1231: at most 50 ms) and attaches the global user lists and macros.
    public static func resources(
        settings: EffectiveSettings, macros: MacroTable, bundledLoader: () throws -> Resources
    ) rethrows -> Resources {
        try resources(
            wordLists: UserWordLists(keepAsTyped: settings.keepAsTyped, keepVietnamese: settings.keepVietnamese),
            macros: macros, bundledLoader: bundledLoader)
    }

    /// Attaches the focused app's user lists (global entries plus the words learned in that app, ENG-R862) and the
    /// macros. The engine gets word sets only, never the app (ENG-R851).
    public static func resources(
        wordLists: UserWordLists, macros: MacroTable, bundledLoader: () throws -> Resources
    ) rethrows -> Resources {
        var resources = try bundledLoader()
        resources.userKeepRaw = WordSet(wordLists.keepAsTyped)
        resources.userKeepVietnamese = WordSet(wordLists.keepVietnamese)
        resources.macros = macros
        return resources
    }

    /// `revision` identifies the engine-affecting settings (see `EngineCatalog.revision`); the publisher bumps it
    /// only when the catalog's inputs change.
    public static func catalog(
        settings: EffectiveSettings, resources: Resources, revision: UInt64? = nil
    ) -> EngineCatalog {
        EngineSettingsMapping.catalog(settings: settings, resources: resources, revision: revision)
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/InputHost/Pipeline/Events.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later

public import AppModel
public import RealtimeSupport
public import VietnameseEngine

/// The fields of a `CGEvent` the pipeline needs, read once in the callback adapter (PLT-R304 "reading event
/// fields"). Bitwise-copyable: no allocation per event.
public struct RawKeyEvent: Sendable, Hashable, BitwiseCopyable {
    public enum Kind: UInt8, Sendable, Hashable, BitwiseCopyable {
        case keyDown, keyUp, flagsChanged
        case leftMouseDown, rightMouseDown, otherMouseDown
        case scrollWheel  // only if the toggle recogniser needs it (PLT-R301)
        case tapDisabledByTimeout, tapDisabledByUserInput
    }

    public var kind: Kind
    public var keyCode: KeyCode
    public var flags: UInt64  // CGEventFlags raw value
    public var autorepeat: Bool  // kCGKeyboardEventAutorepeat
    public var keyboardType: UInt32  // kCGKeyboardEventKeyboardType
    public var unicode: InlineUTF16  // CGEventKeyboardGetUnicodeString (debug cross-check, PLT-R363)
    public var userData: Int64  // kCGEventSourceUserData (marker, PLT-R321)
    public var receivedAt: MonotonicInstant

    public init(
        kind: Kind, keyCode: KeyCode, flags: UInt64, autorepeat: Bool, keyboardType: UInt32, unicode: InlineUTF16,
        userData: Int64, receivedAt: MonotonicInstant
    ) {
        self.kind = kind
        self.keyCode = keyCode
        self.flags = flags
        self.autorepeat = autorepeat
        self.keyboardType = keyboardType
        self.unicode = unicode
        self.userData = userData
        self.receivedAt = receivedAt
    }
}

/// Return value of the callback: the event unchanged, or NULL (PLT-R310 step 10).
public enum TapVerdict: Sendable, Hashable {
    case pass
    case swallow
}

/// Step 7 classification (PLT-R310, PLT-R350-R356).
public enum KeyClass: Sendable, Hashable {
    case character(Character, fromKeypad: Bool)
    case backspace
    case forwardDelete
    case navigation
    case escape
    case returnKey
    case tab
    case commandOrControlChord
    /// Option chord producing a character: pass through, hard boundary (PLT-R350).
    case optionChord
    case deadKey
    case functionKey
    case modifierOnly
    case unmapped
}

/// Content-free outcome of one physical event, for the conservation ledger (PLT-R312) and the capture.
public enum EventOutcome: UInt8, Sendable, Hashable {
    case passed
    case held  // swallowed, ReplayJob pushed
    case consumedForEdit  // EditJob pushed (trigger replayed if abandoned)
    case consumedPairedKeyUp  // keyUp of a consumed keyDown
    case consumedAsHotkey
}

/// Tap -> main notices, carried by an SPSC ring and a `WakeSignal`.
public enum MainNotice: Sendable {
    case modeToggled(sequence: UInt64, bundle: BundleKey?, mode: TypingMode)
    case secureInputResumedByKey(generation: UInt64)
    case tapDisabled(byTimeout: Bool)
    /// ENG-R861, memory only. ENG-R862: `bundle` is the app of the focus snapshot the token was committed in, read
    /// on the tap with the snapshot it already holds, so the word belongs to that app whenever main drains the
    /// outbox (the focus may have moved by then).
    case learning(LearningSignal, bundle: BundleKey?)
    /// First echo miss of a run: the utility queue checks `CGPreflightPostEventAccess()` (ADR 0311).
    case echoMissed
    /// Three consecutive misses: the tap already failed open in this callback (PLT-R730).
    case postingBroken
    case keyboardTypeSeen(UInt32)
}

/// Tap -> ax notices.
public enum AXNotice: Sendable {
    case modeToggled(sequence: UInt64, bundle: BundleKey?, mode: TypingMode)
    /// Read the system-wide focus now: the first key after a typing pause (PLT-R382).
    case revalidateFocus
    /// PLT-R389: read the system-wide focused application and element now, and the element's attributes only when
    /// either differs from the published one: the first key after an event that can move the focus, and every key
    /// while an overlay rule applies.
    case revalidateFocusIfMoved
    /// PLT-R389: a Command or Control shortcut, Escape, Return, Tab or a click may move the focus without an app
    /// activation (a non-activating panel such as Spotlight opens or closes, a sheet takes the focus). The ax
    /// thread reads the system-wide focus over the trigger settle window (`FocusSettle.triggerDelays`).
    case revalidateFocusAfterTrigger
}

/// The two outboxes and their wake-ups.
public final class TapOutbox: Sendable {
    public let toMain: SPSCRing<MainNotice>
    public let toAX: SPSCRing<AXNotice>
    public let mainSignal: WakeSignal
    public let axSignal: WakeSignal

    public init(toMain: SPSCRing<MainNotice>, toAX: SPSCRing<AXNotice>, mainSignal: WakeSignal, axSignal: WakeSignal) {
        self.toMain = toMain
        self.toAX = toAX
        self.mainSignal = mainSignal
        self.axSignal = axSignal
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/InputHost/Pipeline/KeyPipeline.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The decision pipeline (PLT-R310) with hold/replay and conservation (PLT-R311-R317), echo (PLT-R323) and the
// secure-input resume rule (PLT-R398B). Runs only on the tap thread; not Sendable on purpose.

public import AppModel
public import Diagnostics
public import Injection
public import RealtimeSupport

/// Shared objects the pipeline reads or pushes to. Every member is Sendable and every tap-side operation on
/// it is an atomic load/store or a lock-free push.
public struct PipelineContext: Sendable {
    public var snapshots: TapSnapshots
    public var queue: JobQueue
    public var feedback: WorkerFeedback
    public var echo: EchoTracker
    public var marker: EventMarker
    public var outbox: TapOutbox
    public var metrics: PlatformMetrics
    public var tapLog: TapLogRing
    public var capture: CaptureController?
    public var watchdog: CallbackWatchdog
    /// Since-launch observations for the integration hooks (tap recoveries, first key after a secure-input
    /// release). The controller passes its own; other callers get a private one.
    public var counters: HostCounters
    /// PLT-R802: a `tapCallback` interval around every callback (one flag check when nothing records).
    public var signposts: PlatformSignposts?

    public init(
        snapshots: TapSnapshots, queue: JobQueue, feedback: WorkerFeedback, echo: EchoTracker, marker: EventMarker,
        outbox: TapOutbox, metrics: PlatformMetrics, tapLog: TapLogRing, capture: CaptureController?,
        watchdog: CallbackWatchdog, counters: HostCounters = HostCounters(), signposts: PlatformSignposts? = nil
    ) {
        self.snapshots = snapshots
        self.queue = queue
        self.feedback = feedback
        self.echo = echo
        self.marker = marker
        self.outbox = outbox
        self.metrics = metrics
        self.tapLog = tapLog
        self.capture = capture
        self.watchdog = watchdog
        self.counters = counters
        self.signposts = signposts
    }
}

/// Tap-thread pipeline. Generic over the engine factory and the clock, so production code
/// (`KeyPipeline<VietnameseCompositionEngineFactory, MachClock>`) has no existential calls on the hot path and
/// tests drive it with a scripted engine and a manual clock. The hotkey recogniser type comes from the factory
/// (`CompositionEngineFactory.Hotkeys`, `HotkeyRecognizer` by default).
///
/// Created on the tap thread by `TapThread`'s handler factory and never shared (`TapEventHandler`, ADR 0313);
/// `init` reads the snapshots once, so it must run on the tap thread too. At callback entry, after step 1, it
/// calls `EchoTracker.settle(now:)`; `.postingBroken` or `WorkerFeedback.isPostingBroken` means fail open within
/// this callback (PLT-R730). Holding while busy uses `JobQueue.inFlight`, which counts a job until its echo is
/// seen (ADR 0311). A `scrollWheel` event only feeds `HotkeyRecognizer.handle(.scroll)` and passes (PLT-R301).
/// Steady state allocates nothing outside the engine call (PLT-R305; `PipelineAllocationTests`).
public final class KeyPipeline<Factory: CompositionEngineFactory, Clock: MonotonicClock>: TapEventHandler {
    let context: PipelineContext
    let factory: Factory
    let clock: Clock
    let consumedKeys = ConsumedKeyTable()
    var engine: Factory.Engine
    /// The engine was fed since its last reset or creation; a reset of a clean engine is skipped.
    var engineDirty = false
    var hotkeys: Factory.Hotkeys
    var seen: ObservedState
    /// Sequence of the tap's last VI/EN toggle. Seeded from the focus snapshot and kept above every sequence
    /// the ax thread applied, so a recreated tap's toggles still outrank stale snapshots (contracts.md 10.4,
    /// PLT-R731).
    var toggleSequence: UInt64 = 0
    var toggleOverride: ToggleOverride?
    var keyState = KeyState()
    var outcome: EventOutcome?
    /// The last job pushed was a `BoundaryJob` (consecutive boundaries need one job).
    var lastPushWasBoundary = false
    /// PLT-R905: the key being processed goes into the typing trace, with its engine decision.
    var capturingThisKey = false
    var engineCapture: EngineCapture?

    public init(context: PipelineContext, factory: Factory, clock: Clock) {
        self.context = context
        self.factory = factory
        self.clock = clock
        let snapshots = context.snapshots
        snapshots.epoch.enter()
        (engine, hotkeys, seen, toggleSequence) = snapshots.readAll {
            settings, focus, inputSource, secureInput, lifecycle in
            let observed = ObservedState(
                settingsGeneration: settings.generation, focus: FocusIdentity(focus),
                engineVariant: focus.decision.variant, inputSourceGeneration: inputSource.generation,
                secureGeneration: secureInput.generation, lifecycleGeneration: lifecycle.generation,
                resetCount: context.feedback.compositionResetCount, stateCode: nil, secureResumedGeneration: nil,
                postingBroken: context.feedback.isPostingBroken,
                pasteKeyCode: inputSource.table?.keyCode(producing: "v"), engineRevision: settings.engines.revision)
            return (
                factory.makeEngine(for: focus.decision.variant, settings: settings),
                Factory.Hotkeys(toggle: settings.toggleHotkey, restore: settings.restoreHotkey), observed,
                focus.appliedToggleSequence
            )
        }
        snapshots.epoch.exit()
    }

    /// The whole of PLT-R310 for one event. Brackets itself with `ReaderEpoch.enter()/exit()` and
    /// `CallbackWatchdog.enter/exit`.
    public func handle(_ event: RawKeyEvent) -> TapVerdict {
        let signpost = context.signposts?.begin(.tapCallback)  // PLT-R802
        let epoch = context.snapshots.epoch
        epoch.enter()
        let start = clock.now()
        context.watchdog.enter(at: start)
        let (verdict, isProbe) = process(event, now: start)
        // T1 (PLT-R801); latency-probe events stay out of user metrics (PLT-R810).
        if !isProbe { context.metrics.callbackDuration.record(nanoseconds: clock.now().nanoseconds(since: start)) }
        context.watchdog.exit()
        epoch.exit()
        if let signpost { context.signposts?.end(.tapCallback, signpost) }
        return verdict
    }

    /// Outcome of the last physical keyboard event (nil for echoes, mouse and tap-disabled events). Read by
    /// the conservation ledger in tests and by the capture.
    public var lastOutcome: EventOutcome? { outcome }
}

/// Classification of step 7 (pure, tap-safe).
public enum KeyClassifier {
    public static func classify(_ event: RawKeyEvent, table: LayoutTable?) -> KeyClass {
        KeyClassification.classify(event, table: table)
    }
}

/// Host state per key (2.1), the same pure function the main thread uses for the menu icon.
public enum HostStateResolver {
    /// Precedence: noPermission / failOpen / starting > sessionInactive > diagnosticsTest > userDisabled >
    /// secureInput (unless resumed by key evidence for this generation) > secureField > builtInVietnameseSource >
    /// nonLatinInputSource > passThroughRule > noTextFocus (focus pause or PLT-R386 gating) > ready(mode).
    public static func resolve(
        lifecycle: LifecycleSnapshot, secureInput: SecureInputSnapshot, secureResumedGeneration: UInt64?,
        inputSource: InputSourceSnapshot, focus: FocusSnapshot, effectiveMode: TypingMode
    ) -> HostState {
        HostStateResolution.resolve(
            lifecycle: lifecycle, secureInput: secureInput, secureResumedGeneration: secureResumedGeneration,
            inputSource: inputSource, focus: focus, effectiveMode: effectiveMode)
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/InputHost/Tap/TapThread.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The `tap` thread (PLT-R203, PLT-R301-R303): one active session-level, head-insert event tap whose run-loop
// source is the only source on its run loop. Workstream W1-F2.

public import CoreFoundation
public import CoreGraphics
public import RealtimeSupport

/// Event mask of PLT-R301 (`keyDown`, `keyUp`, `flagsChanged`, `leftMouseDown`, `rightMouseDown`,
/// `otherMouseDown`) plus `scrollWheel`, which is on by default because PRD-R14 (MUST) cancels the Control+Shift
/// toggle tap on scroll; PLT-R301 allows `scrollWheel` only for that purpose. For a scroll event the callback
/// does nothing except `HotkeyRecognizer.handle(.scroll)` ("chord cancelled") and returns the event unchanged.
public struct TapEventMask: Sendable, Hashable {
    public static let standard = TapEventMask(includeScrollWheel: true)

    public var includeScrollWheel: Bool
    public init(includeScrollWheel: Bool = true) { self.includeScrollWheel = includeScrollWheel }

    public var cgMask: CGEventMask {
        var types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        if includeScrollWheel { types.append(.scrollWheel) }
        return types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
    }
}

/// The tap's mach port and run-loop source behind a protocol, so the tap thread and the watchdogs are testable
/// without the WindowServer (docs/decisions/0313-testability-seams.md). Production wraps the `CFMachPort`
/// returned by `CGEvent.tapCreate`; `FakeEventTapFactory` (TestSupport) returns a pure Swift handle.
public protocol EventTapHandle: AnyObject, Sendable {
    /// Adds the tap's run-loop source to `runLoop`, the tap thread's own run loop (PLT-R303).
    func install(on runLoop: CFRunLoop)
    /// `CGEvent.tapEnable(tap:enable:)`; any thread (watchdog and fail-open use it, PLT-R306, PLT-R730).
    func setEnabled(_ enabled: Bool)
    /// `CGEvent.tapIsEnabled(tap:)` (PLT-R331); any thread.
    var isEnabled: Bool { get }
    /// Removes the source from its run loop and invalidates the port (PLT-R730).
    func invalidate()
}

/// Creates the event tap, on the tap thread. Production: `CGEvent.tapCreate(tap: .cgSessionEventTap,
/// place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask.cgMask, callback: callback,
/// userInfo: userInfo)`. Returns nil when the OS refuses (no permission): the host enters
/// `failOpen(tapUnavailable)` (PLT-R332).
public protocol EventTapFactory: Sendable {
    func makeTap(mask: TapEventMask, callback: CGEventTapCallBack, userInfo: UnsafeMutableRawPointer?)
        -> (any EventTapHandle)?
}

/// The real tap (PLT-R301): session level, head insert, active (default) option. Never used by tests on a
/// developer Mac; they use `FakeEventTapFactory` (ADR 0313). Verified on the self-hosted runner (W2-E2).
public struct CGEventTapFactory: EventTapFactory {
    public init() {}
    public func makeTap(mask: TapEventMask, callback: CGEventTapCallBack, userInfo: UnsafeMutableRawPointer?)
        -> (any EventTapHandle)?
    {
        guard
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: mask.cgMask, callback: callback, userInfo: userInfo)
        else { return nil }
        return MachPortEventTapHandle(port: port)
    }
}

/// Per-event handler created ON the tap thread and used only there (PLT-R303). `KeyPipeline` conforms.
/// Deliberately not `Sendable`: Swift 6 cannot express "owned by this run-loop thread", so `TapThread` builds
/// the handler inside its thread entry from a `@Sendable` factory and never lets it escape that thread. This is
/// one of the two audited concurrency escape hatches (the other is `ThreadConfined`, ARCHITECTURE.md section 3).
/// `SendableMetatype`: the conformance is used on the tap thread, so it must not be isolated to an actor.
public protocol TapEventHandler: AnyObject, SendableMetatype {
    func handle(_ event: RawKeyEvent) -> TapVerdict
}

/// What the watchdog and the lifecycle owner may do with a running tap, from any thread.
public protocol TapControl: AnyObject, Sendable {
    func setEnabled(_ enabled: Bool)
    var isEnabled: Bool { get }
    /// False once the tap thread's run loop has exited (after `stop()`), true while it runs.
    var isRunning: Bool { get }
    func stop()
}

/// Owns the tap thread and the tap handle. The thread entry calls `makeHandler()` (so the non-Sendable handler
/// and the `KeyPipeline` inside it are created on the tap thread), creates the tap through the factory with a
/// C callback whose `userInfo` points at that thread's state, installs the source and runs the CFRunLoop. The
/// callback converts the `CGEvent` into a `RawKeyEvent`, calls `handler.handle`, and returns
/// `Unmanaged.passUnretained(event)` or nil. Generic over the handler, so the per-event call is static: the C
/// callback (which cannot capture generic parameters) reaches the specialised thread state through one class
/// method dispatch, without allocation or locking (PLT-R304, `TapCallbackBridge`).
///
/// A `TapThread` is single-use: after `stop()` (or a failed `start()`) the host creates a fresh one, and only
/// once `isRunning` is false (ADR 0309). Releasing the last reference stops it.
public final class TapThread<Handler: TapEventHandler>: TapControl, Sendable {
    private let runtime = TapThreadRuntime()
    private let factory: any EventTapFactory
    private let mask: TapEventMask
    private let makeHandler: @Sendable () -> Handler

    public init(
        factory: any EventTapFactory, mask: TapEventMask = .standard,
        makeHandler: @escaping @Sendable () -> Handler
    ) {
        self.factory = factory
        self.mask = mask
        self.makeHandler = makeHandler
    }

    deinit { runtime.stop() }

    /// Creates the tap on a new thread (QoS user-interactive) and runs its CFRunLoop. Returns once creation
    /// succeeded or failed; false if the factory returned nil (the thread then exits). True without a second
    /// tap when already running (PLT-R302); false after `stop()`.
    public func start() -> Bool {
        let factory = self.factory
        let mask = self.mask
        let makeHandler = self.makeHandler
        return runtime.start {
            // Tap thread (PLT-R303): the handler and the tap are created here and never leave this thread.
            let target = TapCallbackContext(handler: makeHandler())
            let userInfo = Unmanaged.passUnretained(target).toOpaque()
            guard let handle = factory.makeTap(mask: mask, callback: TapCallbackBridge.callback, userInfo: userInfo)
            else { return nil }
            return TapThreadRuntime.Session(handle: handle, target: target)
        }
    }

    public func setEnabled(_ enabled: Bool) { runtime.setEnabled(enabled) }
    public var isEnabled: Bool { runtime.isEnabled }
    public var isRunning: Bool { runtime.isRunning }

    /// Disables, invalidates the handle and stops the run loop so the thread exits (PLT-R730). Never called
    /// while the watchdog reports a callback that has not returned (ADR 0309). Does not wait for the exit.
    public func stop() { runtime.stop() }

    /// Waits until the thread has left its run loop (or never started). False on timeout. For the owner that
    /// recreates the tap after `stop()` (ADR 0309) and for tests; never called on the tap thread.
    public func waitUntilExited(timeout: TimeSpan) -> Bool { runtime.waitUntilExited(timeout: timeout) }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/InputHost/Tap/CallbackWatchdog.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Per-callback watchdog state (PLT-R306, ADR 0309). Implemented in the skeleton because both the pipeline
// (W1-F1, `enter`/`exit` on every callback) and the tap watchdog (W1-F2) use it (ADR 0313); W1-F2 owns it.

public import RealtimeSupport

/// `enter` writes the callback entry time, `exit` clears it; the utility-queue watchdog disables the tap if one
/// callback runs longer than 250 ms. The first callback after 2 s without callbacks signals `activitySignal`
/// so the watchdog arms its 250 ms check only while keys flow (PLT-R803, ADR 0309).
public final class CallbackWatchdog: Sendable {
    public static let callbackLimit: TimeSpan = .milliseconds(250)
    public static let idleAfter: TimeSpan = .seconds(2)
    private static let idleNanoseconds: UInt64 = 2_000_000_000

    private let enteredAt = Atomic<UInt64>(0)  // 0 = outside a callback
    private let lastEntry = Atomic<UInt64>(0)  // written by the tap only
    private let activitySignal: WakeSignal?

    public init(activitySignal: WakeSignal?) { self.activitySignal = activitySignal }

    /// Tap thread: first statement after `ReaderEpoch.enter()`.
    @inline(__always)
    public func enter(at now: MonotonicInstant) {
        let nanoseconds = max(now.nanoseconds, 1)
        let previous = lastEntry.load(ordering: .relaxed)
        lastEntry.store(nanoseconds, ordering: .relaxed)
        enteredAt.store(nanoseconds, ordering: .sequentiallyConsistent)
        if previous == 0 || nanoseconds &- previous > Self.idleNanoseconds { activitySignal?.signal() }
    }

    /// Tap thread: on every return path.
    @inline(__always)
    public func exit() { enteredAt.store(0, ordering: .sequentiallyConsistent) }

    /// Utility queue: nanoseconds the current callback has been running, nil when outside a callback.
    public func runningCallbackDuration(now: MonotonicInstant) -> UInt64? {
        let entered = enteredAt.load(ordering: .sequentiallyConsistent)
        return entered == 0 ? nil : now.nanoseconds(since: MonotonicInstant(nanoseconds: entered))
    }

    /// Utility queue: true while a callback is executing. After a trip, recovery waits until this is false.
    public var isInsideCallback: Bool { enteredAt.load(ordering: .sequentiallyConsistent) != 0 }

    /// Utility queue: entry time of the most recent callback (nil before the first one).
    public var lastCallbackEntry: MonotonicInstant? {
        let value = lastEntry.load(ordering: .relaxed)
        return value == 0 ? nil : MonotonicInstant(nanoseconds: value)
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/InputHost/Tap/TapWatchdog.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R306, PLT-R331 and snapshot reclamation on the utility queue (ADR 0309, ADR 0303). Workstream W1-F2.

internal import AppModel
public import RealtimeSupport

/// Why the watchdog acted.
public enum TapTrip: Sendable, Hashable {
    /// One callback ran longer than 250 ms: the tap was disabled (`CGEventTapEnable(false)`, keys flow) and
    /// the host enters `failOpen(watchdog)`. Recovery is attempted 2 s later only if the callback has returned.
    case callbackOverLimit(microseconds: UInt64)
    /// 2 s after a trip the callback still has not returned: stay in `failOpen(callbackStuck)`; never create a
    /// second tap or a second tap thread that would share the reader epoch (ADR 0309).
    case callbackStuck(microseconds: UInt64)
    /// `CGEventTapIsEnabled` false without a disabled event: run the PLT-R330 procedure.
    case unexpectedlyDisabled
}

/// Frees retired snapshot boxes (ADR 0303). `TapSnapshots` conforms; tests count calls.
public protocol SnapshotReclaiming: Sendable {
    func reclaimAll()
}

extension TapSnapshots: SnapshotReclaiming {}

/// Watchdog for the tap. The 250 ms callback check runs only while keys flow (armed by `callbackActivity()`,
/// which the tap's activity `WakeSignal` calls, disarmed after 2 s without callbacks), so idle wakeups stay at
/// zero (PLT-R803). A check that finds a callback still under the limit adds one one-shot check at the moment
/// it would cross 250 ms, so detection takes about 275 ms at worst (ADR 0309). Every 5 s (with leeway) it checks
/// `isEnabled` (PLT-R331) and calls `reclaimAll()` so retired snapshot boxes are freed even when no writer
/// publishes (ADR 0303).
///
/// After a trip the watchdog disables the tap itself (keys flow at once) and reports `onTrip`; 2 s later it
/// reports `onCallbackReturned` if the callback has returned, otherwise `onTrip(.callbackStuck)`. A stuck
/// callback is re-checked on every 5 s tick and reported as returned if it ever comes back; the watchdog never
/// touches the tap again by itself. Handlers run on the scheduler's queue (utility in production), outside
/// the watchdog's lock, so they may call back into it.
public final class TapWatchdog: Sendable {
    public static let enabledCheckInterval: TimeSpan = .seconds(5)
    public static let recoveryDelay: TimeSpan = .seconds(2)
    /// Period of the callback check while keys flow (ADR 0309).
    public static let callbackCheckInterval: TimeSpan = CallbackWatchdog.callbackLimit

    private static let enabledCheckLeeway: TimeSpan = .seconds(1)
    private static let limitNanoseconds = CallbackWatchdog.callbackLimit.unsignedNanoseconds
    private static let idleNanoseconds = CallbackWatchdog.idleAfter.unsignedNanoseconds
    /// The crossing check lands just past the limit, so "more than 250 ms" is already true when it runs.
    private static let crossingMargin: UInt64 = 1_000_000

    private enum Mode: Sendable, Hashable {
        /// Normal operation: the enabled check reports a disabled tap.
        case watching
        /// The watchdog disabled the tap; the recovery check is pending.
        case tripped
        /// The callback did not return within the recovery delay.
        case stuck
        /// The callback returned; waiting until the lifecycle owner re-enabled the tap.
        case awaitingReenable
    }

    private enum Action {
        case disableTap
        case report(TapTrip)
        case callbackReturned
    }

    /// One read of the callback watchdog and the tap, taken outside the lock.
    private struct Observation {
        var now: MonotonicInstant
        var running: UInt64?
        var lastEntry: MonotonicInstant?
        var tapRunning: Bool
        var tapEnabled: Bool
    }

    private struct State: Sendable {
        var started = false
        var mode = Mode.watching
        var armedAt: MonotonicInstant?
        var enabledTimer: (any ScheduledTimer)?
        var checkTimer: (any ScheduledTimer)?
        var crossingTimer: (any ScheduledTimer)?
        var recoveryTimer: (any ScheduledTimer)?

        mutating func disarm() {
            checkTimer?.cancel()
            crossingTimer?.cancel()
            checkTimer = nil
            crossingTimer = nil
            armedAt = nil
        }

        mutating func cancelAll() {
            disarm()
            enabledTimer?.cancel()
            recoveryTimer?.cancel()
            enabledTimer = nil
            recoveryTimer = nil
        }
    }

    private let tap: any TapControl
    private let callbacks: CallbackWatchdog
    private let snapshots: any SnapshotReclaiming
    private let scheduler: any TimerScheduler
    private let clock: any MonotonicClock
    private let onCallbackReturned: @Sendable () -> Void
    private let onTrip: @Sendable (TapTrip) -> Void
    private let state = Mutex(State())

    /// `onCallbackReturned` maps to `LifecycleInput.callbackExited`, `onTrip` to `.watchdogTripped`.
    public init(
        tap: any TapControl, callbacks: CallbackWatchdog, snapshots: any SnapshotReclaiming,
        scheduler: any TimerScheduler, clock: any MonotonicClock,
        onCallbackReturned: @escaping @Sendable () -> Void, onTrip: @escaping @Sendable (TapTrip) -> Void
    ) {
        self.tap = tap
        self.callbacks = callbacks
        self.snapshots = snapshots
        self.scheduler = scheduler
        self.clock = clock
        self.onCallbackReturned = onCallbackReturned
        self.onTrip = onTrip
    }

    deinit { state.withLock { $0.cancelAll() } }

    /// Starts the 5 s enabled check. Callbacks seen within the last 2 s arm the callback check at once, because
    /// their activity signal may have arrived before `start()`.
    public func start() {
        let observation = observe()
        let actions = state.withLock { state -> [Action] in
            guard !state.started else { return [] }
            state.started = true
            state.mode = .watching
            state.enabledTimer = scheduler.scheduleRepeating(
                every: Self.enabledCheckInterval, leeway: Self.enabledCheckLeeway
            ) { [weak self] in self?.enabledTick() }
            return armIfRecentlyActive(&state, observation)
        }
        perform(actions)
    }

    public func stop() {
        state.withLock {
            $0.cancelAll()
            $0.started = false
            $0.mode = .watching
        }
    }

    /// The tap's activity signal fired (first callback after 2 s idle): arm the 250 ms check.
    public func callbackActivity() {
        let observation = observe()
        let actions = state.withLock { state -> [Action] in
            guard state.started else { return [] }
            // Callbacks flow only through an enabled tap, so the lifecycle has re-enabled it after a recovery.
            if state.mode == .awaitingReenable && observation.tapEnabled { state.mode = .watching }
            guard state.mode == .watching, state.checkTimer == nil else { return [] }
            return arm(&state, observation)
        }
        perform(actions)
    }

    /// Called on wake, session activation, permission change (PLT-R331).
    public func checkNow() { perform(enabledCheck()) }

    // MARK: - Timers

    private func enabledTick() {
        snapshots.reclaimAll()
        perform(enabledCheck())
    }

    private func enabledCheck() -> [Action] {
        let observation = observe()
        return state.withLock { state -> [Action] in
            guard state.started else { return [] }
            switch state.mode {
            case .watching:
                return observation.tapRunning && !observation.tapEnabled ? [.report(.unexpectedlyDisabled)] : []
            case .tripped:
                return []
            case .stuck:
                guard observation.running == nil else { return [] }
                state.mode = .awaitingReenable
                return [.callbackReturned]
            case .awaitingReenable:
                guard observation.tapEnabled else { return [] }
                state.mode = .watching
                return armIfRecentlyActive(&state, observation)
            }
        }
    }

    /// The repeating 250 ms check (`crossing == false`) or the one-shot crossing check (`crossing == true`).
    private func callbackCheck(crossing: Bool) {
        let observation = observe()
        let actions = state.withLock { state -> [Action] in
            if crossing { state.crossingTimer = nil }
            guard state.started, state.mode == .watching, state.checkTimer != nil else { return [] }
            return evaluate(&state, observation, mayDisarm: !crossing)
        }
        perform(actions)
    }

    /// ADR 0309: 2 s after the trip, recovery only if the callback has returned.
    private func recoveryCheck() {
        let observation = observe()
        let actions = state.withLock { state -> [Action] in
            state.recoveryTimer = nil
            guard state.started, state.mode == .tripped else { return [] }
            if let running = observation.running {
                state.mode = .stuck
                return [.report(.callbackStuck(microseconds: running / 1_000))]
            }
            state.mode = .awaitingReenable
            return [.callbackReturned]
        }
        perform(actions)
    }

    // MARK: - Decisions (under the lock)

    private func armIfRecentlyActive(_ state: inout State, _ observation: Observation) -> [Action] {
        guard state.checkTimer == nil, let lastEntry = observation.lastEntry,
            observation.now.nanoseconds(since: lastEntry) <= Self.idleNanoseconds
        else { return [] }
        return arm(&state, observation)
    }

    private func arm(_ state: inout State, _ observation: Observation) -> [Action] {
        state.armedAt = observation.now
        state.checkTimer = scheduler.scheduleRepeating(
            every: Self.callbackCheckInterval, leeway: Self.callbackCheckInterval / 10
        ) { [weak self] in self?.callbackCheck(crossing: false) }
        return evaluate(&state, observation, mayDisarm: false)
    }

    private func evaluate(_ state: inout State, _ observation: Observation, mayDisarm: Bool) -> [Action] {
        if let running = observation.running {
            if running > Self.limitNanoseconds { return trip(&state, running: running) }
            if state.crossingTimer == nil {
                let delay = TimeSpan.nanoseconds(Self.limitNanoseconds - running + Self.crossingMargin)
                state.crossingTimer = scheduler.schedule(after: delay, leeway: delay / 10) { [weak self] in
                    self?.callbackCheck(crossing: true)
                }
            }
            return []
        }
        let lastActivity = max(observation.lastEntry ?? .zero, state.armedAt ?? .zero)
        if mayDisarm && observation.now.nanoseconds(since: lastActivity) > Self.idleNanoseconds { state.disarm() }
        return []
    }

    /// PLT-R306: disable the tap (keys flow), report, and check for recovery 2 s later.
    private func trip(_ state: inout State, running: UInt64) -> [Action] {
        state.disarm()
        state.mode = .tripped
        state.recoveryTimer = scheduler.schedule(after: Self.recoveryDelay, leeway: Self.recoveryDelay / 10) {
            [weak self] in self?.recoveryCheck()
        }
        return [.disableTap, .report(.callbackOverLimit(microseconds: running / 1_000))]
    }

    // MARK: - Effects (outside the lock)

    private func observe() -> Observation {
        let now = clock.now()
        return Observation(
            now: now, running: callbacks.runningCallbackDuration(now: now), lastEntry: callbacks.lastCallbackEntry,
            tapRunning: tap.isRunning, tapEnabled: tap.isEnabled)
    }

    private func perform(_ actions: [Action]) {
        for action in actions {
            switch action {
            case .disableTap: tap.setEnabled(false)
            case .report(let trip): onTrip(trip)
            case .callbackReturned: onCallbackReturned()
            }
        }
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/InputHost/Lifecycle/HostLifecycle.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Lifecycle state machine of the input host (02-platform.md 2.1, PLT-R330-R333, PLT-R730, PLT-R731, ADR 0309)
// as a pure value type, so it is tested deterministically without threads, taps or services (ADR 0313).
// `InputHostController` (main actor, W2-A) feeds it inputs and performs the effects. Workstream W1-F2.

internal import AppModel
public import Injection
public import RealtimeSupport

public enum LifecycleInput: Sendable, Hashable {
    case launched
    /// A permission status from `PermissionMonitor`. The caller checks permissions immediately on wake, session
    /// activation and a system tap disable (PLT-R721) and feeds the result BEFORE `.sessionActive(true)` or
    /// `.tapDisabledBySystem`, so those inputs act on fresh permissions (PLT-R330 step 1, PLT-R333).
    case permissionsChanged(PermissionStatus)
    case tapCreated
    case tapCreationFailed
    /// A retry scheduled by `.scheduleRetry` fired.
    case retryTimerFired
    case watchdogTripped(TapTrip)
    /// After a `callbackOverLimit` trip: the watchdog observed that the callback returned.
    case callbackExited
    /// `EchoTracker` reported `.postingBroken` or the post preflight turned false (PLT-R323, PLT-R730).
    case postingBroken
    case tapDisabledBySystem(byTimeout: Bool)
    case sessionActive(Bool)
    case userDisabled(Bool)
    /// The guided test of "This app misbehaves" starts (`true`) or ends (`false`) typing with its own strategy
    /// (PLT-R1205 steps 3-5). Calls nest: only the first start and the matching last end change the state, and
    /// an end without a start is ignored.
    case diagnosticsPassThrough(Bool)
}

public enum LifecycleEffect: Sendable, Hashable {
    case publish(LifecycleSnapshot.Phase)
    case createTap
    /// PLT-R730 order: stop swallowing (already true via the published phase), flush held events, reset the
    /// composition, disable and remove the tap.
    case removeTap
    /// Watchdog trip: `CGEventTapEnable(false)` only; the tap thread may be stuck, so nothing else touches it.
    case disableTap
    /// PLT-R330 step 1.
    case reenableTap
    case requestFlush(FlushReason)
    case resetComposition
    case scheduleRetry(after: TimeSpan)
    case cancelRetry
    case recordHealth(HealthEventKindCode)
    /// More than 3 system disables within 10 minutes (PLT-R330 step 5).
    case showTapInstabilityNotice
    /// The phase is unchanged but a flag the tap reads changed (diagnostics pass-through): publish the snapshot
    /// again with the current phase.
    case publishFlags
}

/// Health kinds the lifecycle records (mirrors the Diagnostics `HealthEvent.Kind` cases it uses, so this
/// module's pure state machine does not construct dated events).
public enum HealthEventKindCode: String, Sendable, Hashable {
    case tapTimeout, tapDisabledByUserInput, tapReenabled, watchdogTrip, postingBroken, permissionTransition
}

/// Phases: `starting` until permissions are known and the tap is created, `noPermission`, `running` (the tap
/// transforms, subject to per-key pauses), `sessionInactive` (PLT-R333), `failOpen(reason)` (PRD-R44: keys pass
/// unchanged). Effects come back in the order the caller performs them. Every transition into or out of
/// `failOpen` or `sessionInactive` (a pause) carries `.resetComposition` (PLT-R210); when the new phase is
/// `running` the reset comes before the publish, so the tap never transforms with a stale composition.
public struct HostLifecycle: Sendable, Hashable {
    /// PLT-R332: retry tap creation with backoff 1, 2, 5, 10 s (cap) while permissions look granted.
    public static let backoff: [TimeSpan] = [.seconds(1), .seconds(2), .seconds(5), .seconds(10)]
    /// PLT-R306: recovery attempt 2 s after a watchdog trip, only once the callback has returned (ADR 0309).
    public static let watchdogRecoveryDelay: TimeSpan = .seconds(2)
    /// PLT-R330 step 5: the notice appears when more than `instabilityThreshold` system disables fall within
    /// this window, at most once per window.
    public static let instabilityWindow: TimeSpan = .seconds(600)
    public static let instabilityThreshold = 3
    /// PLT-R330 step 5, PLT-R331: the OS disable event and the watchdog's `CGEventTapIsEnabled` check can both
    /// report one disable; reports closer than this count once toward the notice (both still run the procedure).
    public static let disableCoalescingWindow: TimeSpan = .seconds(1)
    /// PLT-R323, PLT-R730: echo loss and OS policy leave the permission status `ready`, so failOpen(postingBroken)
    /// retries the tap on this backoff while permissions look granted. A break soon after a recreation moves to
    /// the next step (cap 5 minutes), so a posting path that stays broken cannot cause a create/break loop.
    public static let postingBrokenBackoff: [TimeSpan] = [
        .seconds(30), .seconds(60), .seconds(120), .seconds(240), .seconds(300),
    ]
    /// A recreated tap that posts for longer than the previous delay plus this interval resets the backoff.
    public static let postingBrokenStableInterval: TimeSpan = .seconds(600)

    /// Who holds the one tap (PLT-R302): nobody, a creation in flight, or a live tap thread.
    private enum TapPresence: Sendable, Hashable { case none, creating, alive }

    public private(set) var phase: LifecycleSnapshot.Phase = .starting
    /// The user's "turn off" switch: a pause reason (`paused(userDisabled)`), not a lifecycle phase.
    public private(set) var userDisabled = false
    /// The guided test is typing: a pause reason (`paused(diagnosticsTest)`), not a lifecycle phase.
    public var diagnosticsPassThrough: Bool { passThroughDepth > 0 }

    /// Nesting depth of `.diagnosticsPassThrough` calls.
    private var passThroughDepth = 0

    private var launched = false
    /// nil until the first status arrives.
    private var permissionsGranted: Bool?
    private var sessionActive = true
    private var tap = TapPresence.none
    private var retryAttempt = 0
    private var retryPending = false
    /// Nanosecond instants of the latest system disables, at most `instabilityThreshold + 1`.
    private var recentDisables: [UInt64] = []
    private var lastNoticeAt: UInt64?
    /// Index into `postingBrokenBackoff` used by the latest postingBroken, and when it happened.
    private var postingBrokenAttempt = 0
    private var lastPostingBrokenAt: UInt64?

    public init() {}

    /// Pure transition: returns the effects to perform, in order. Never blocks; the caller owns timers
    /// (`TimerScheduler`) and turns their firing into `.retryTimerFired`. `now` (the services' monotonic clock)
    /// dates system disables for the PLT-R330 instability window.
    public mutating func handle(_ input: LifecycleInput, at now: MonotonicInstant) -> [LifecycleEffect] {
        switch input {
        case .launched: return launch()
        case .permissionsChanged(let status): return permissionsChanged(granted: Self.looksGranted(status))
        case .sessionActive(let active): return sessionChanged(active: active)
        case .userDisabled(let disabled): return userDisabledChanged(disabled)
        case .diagnosticsPassThrough(let on): return passThroughChanged(on)
        default: break
        }
        guard launched else { return [] }
        switch input {
        case .tapCreated: return tapCreated()
        case .tapCreationFailed: return tapCreationFailed()
        case .retryTimerFired: return retryFired()
        case .watchdogTripped(let trip): return watchdogTripped(trip, at: now)
        case .callbackExited: return callbackExited()
        case .postingBroken: return postingBroken(at: now)
        case .tapDisabledBySystem(let byTimeout):
            return systemDisabled(reason: byTimeout ? .tapTimeout : .tapDisabledByUserInput, at: now)
        case .launched, .permissionsChanged, .sessionActive, .userDisabled, .diagnosticsPassThrough: return []
        }
    }

    /// "Permissions appear granted" (PLT-R332): health `ready`. `stale` and `noPermission` do not.
    static func looksGranted(_ status: PermissionStatus) -> Bool { status.health == .ready }

    // MARK: - Inputs

    private mutating func launch() -> [LifecycleEffect] {
        guard !launched else { return [] }
        launched = true
        switch permissionsGranted {
        case nil: return []
        case false?: return move(to: .noPermission)
        case true?: return beginCreation()
        }
    }

    private mutating func permissionsChanged(granted: Bool) -> [LifecycleEffect] {
        let previous = permissionsGranted
        permissionsGranted = granted
        guard launched else { return [] }
        var effects = granted ? permissionGranted() : permissionLost()
        if let previous, previous != granted { effects.append(.recordHealth(.permissionTransition)) }
        return effects
    }

    /// PLT-R731: permission back recreates the tap without a relaunch. A failOpen(postingBroken) host keeps its
    /// own retry timer: a real revocation already moved it to failOpen(permissionRevoked).
    private mutating func permissionGranted() -> [LifecycleEffect] {
        switch (tap, phase) {
        case (.none, .noPermission), (.none, .starting), (.none, .failOpen(.permissionRevoked)):
            return beginCreation()
        case (.creating, .noPermission):
            // Lost and back while a creation is in flight: its result decides (PLT-R211, PLT-R332).
            return move(to: .starting)
        default:
            return []
        }
    }

    private mutating func permissionLost() -> [LifecycleEffect] {
        var effects = cancelPendingRetry()
        switch phase {
        case .running, .sessionInactive:
            effects += failOpenRemovingTap(.permissionRevoked)
        case .starting, .failOpen(.tapUnavailable):
            effects += move(to: .noPermission)
        case .failOpen(.postingBroken):
            effects += move(to: .failOpen(.permissionRevoked))
        case .noPermission, .failOpen(.permissionRevoked), .failOpen(.watchdog), .failOpen(.callbackStuck):
            // A tripped tap thread may still be inside its callback: it is removed once the callback returned.
            break
        }
        return effects
    }

    private mutating func tapCreated() -> [LifecycleEffect] {
        guard tap == .creating else { return [] }
        guard wantsTap else {
            tap = .none
            return [.removeTap]
        }
        tap = .alive
        retryAttempt = 0
        return move(to: sessionActive ? .running : .sessionInactive)
    }

    /// PLT-R332: failOpen(tapUnavailable), retry with backoff only while permissions look granted.
    private mutating func tapCreationFailed() -> [LifecycleEffect] {
        guard tap == .creating else { return [] }
        tap = .none
        guard wantsTap else { return [] }
        let delay = Self.backoff[min(retryAttempt, Self.backoff.count - 1)]
        retryAttempt += 1
        retryPending = true
        return move(to: .failOpen(.tapUnavailable)) + [.scheduleRetry(after: delay)]
    }

    private mutating func retryFired() -> [LifecycleEffect] {
        guard retryPending else { return [] }
        retryPending = false
        let retryPhase = phase == .failOpen(.tapUnavailable) || phase == .failOpen(.postingBroken)
        guard retryPhase, permissionsGranted == true, tap == .none else { return [] }
        // The phase stays fail-open during the attempt, so the menu does not flicker.
        tap = .creating
        return [.createTap]
    }

    private mutating func watchdogTripped(_ trip: TapTrip, at now: MonotonicInstant) -> [LifecycleEffect] {
        switch trip {
        case .callbackOverLimit:
            // PLT-R306: the watchdog already disabled the tap (keys flow); `.disableTap` repeats it from the
            // lifecycle owner. Nothing touches the tap thread, which may be stuck (ADR 0309).
            guard tapIsInstalled else { return [] }
            return publish(.failOpen(.watchdog)) + [
                .disableTap, .requestFlush(.failOpen), .resetComposition, .recordHealth(.watchdogTrip),
            ]
        case .callbackStuck:
            // ADR 0309: stay fail-open; never a second tap or tap thread (PLT-R302).
            guard phase == .failOpen(.watchdog) else { return [] }
            return move(to: .failOpen(.callbackStuck))
        case .unexpectedlyDisabled:
            // PLT-R331: the same procedure as a disabled event.
            return systemDisabled(reason: .tapReenabled, at: now)
        }
    }

    /// ADR 0309: the callback returned, so the same tap is re-enabled (or removed when permission went away).
    private mutating func callbackExited() -> [LifecycleEffect] {
        guard phase == .failOpen(.watchdog) || phase == .failOpen(.callbackStuck), tap == .alive else { return [] }
        guard permissionsGranted == true else { return failOpenRemovingTap(.permissionRevoked) }
        return [.reenableTap] + move(to: sessionActive ? .running : .sessionInactive) + [.recordHealth(.tapReenabled)]
    }

    /// PLT-R730: posting no longer works. PLT-R323: echo loss or OS policy can leave permissions `ready`, and the
    /// monitor then never reports a change, so the tap is retried on the bounded `postingBrokenBackoff`.
    private mutating func postingBroken(at now: MonotonicInstant) -> [LifecycleEffect] {
        guard tapIsInstalled else { return [] }
        let delay = notePostingBroken(at: now)
        retryPending = true
        return failOpenRemovingTap(.postingBroken) + [.recordHealth(.postingBroken), .scheduleRetry(after: delay)]
    }

    /// PLT-R330: re-enable (permissions are valid while a tap is installed: a revocation already removed it),
    /// reset, replay held events, record the reason, and the notice after more than 3 within 10 minutes.
    /// Every report runs the whole procedure (a second disable within the coalescing window is possible and needs
    /// the reset), but reports within `disableCoalescingWindow` of the last counted one count once (PLT-R331).
    private mutating func systemDisabled(reason: HealthEventKindCode, at now: MonotonicInstant) -> [LifecycleEffect] {
        guard tapIsInstalled else { return [] }
        var effects: [LifecycleEffect] = [
            .reenableTap, .resetComposition, .requestFlush(.tapDisabled), .recordHealth(reason),
        ]
        if noteSystemDisable(at: now) { effects.append(.showTapInstabilityNotice) }
        return effects
    }

    /// PLT-R333: resign, sleep or lock pause the host; activation re-validates the tap (re-enable, idempotent)
    /// after the caller fed fresh permissions, then returns to running.
    private mutating func sessionChanged(active: Bool) -> [LifecycleEffect] {
        guard active != sessionActive else { return [] }
        sessionActive = active
        guard launched else { return [] }
        if !active {
            return phase == .running ? move(to: .sessionInactive) : []
        }
        guard phase == .sessionInactive, permissionsGranted == true, tap == .alive else { return [] }
        return [.reenableTap] + move(to: .running)
    }

    /// PLT-R210: entering or leaving `paused(userDisabled)` resets the composition.
    private mutating func userDisabledChanged(_ disabled: Bool) -> [LifecycleEffect] {
        guard disabled != userDisabled else { return [] }
        userDisabled = disabled
        return launched ? [.resetComposition] : []
    }

    /// PLT-R1205, PLT-R210: entering stops transforming in the tap's next callback (publish), then resets;
    /// leaving resets first, so the tap never transforms with a stale composition, then publishes.
    private mutating func passThroughChanged(_ on: Bool) -> [LifecycleEffect] {
        let wasOn = diagnosticsPassThrough
        if on {
            passThroughDepth += 1
        } else {
            guard passThroughDepth > 0 else { return [] }
            passThroughDepth -= 1
        }
        guard diagnosticsPassThrough != wasOn, launched else { return [] }
        return on ? [.publishFlags, .resetComposition] : [.resetComposition, .publishFlags]
    }

    // MARK: - Helpers

    /// A tap is installed and supposed to be enabled (not held by the watchdog).
    private var tapIsInstalled: Bool { tap == .alive && (phase == .running || phase == .sessionInactive) }

    /// A tap may be created now: permissions look granted and no tripped tap thread may still be stuck.
    private var wantsTap: Bool {
        guard launched, permissionsGranted == true else { return false }
        switch phase {
        case .failOpen(.watchdog), .failOpen(.callbackStuck): return false
        default: return true
        }
    }

    private mutating func beginCreation() -> [LifecycleEffect] {
        tap = .creating
        return move(to: .starting) + [.createTap]
    }

    private mutating func cancelPendingRetry() -> [LifecycleEffect] {
        retryAttempt = 0
        guard retryPending else { return [] }
        retryPending = false
        return [.cancelRetry]
    }

    /// PLT-R730: stop swallowing (the published phase), replay held events, reset, then remove the tap.
    private mutating func failOpenRemovingTap(_ reason: FailOpenReason) -> [LifecycleEffect] {
        tap = .none
        return publish(.failOpen(reason)) + [.requestFlush(.failOpen), .resetComposition, .removeTap]
    }

    /// Sets the phase and returns the publish effect, without the PLT-R210 reset (callers place it).
    private mutating func publish(_ new: LifecycleSnapshot.Phase) -> [LifecycleEffect] {
        guard new != phase else { return [] }
        phase = new
        return [.publish(new)]
    }

    /// Sets the phase with the PLT-R210 reset when a pause or fail-open is entered or left.
    private mutating func move(to new: LifecycleSnapshot.Phase) -> [LifecycleEffect] {
        let old = phase
        let published = publish(new)
        guard !published.isEmpty, Self.holdsComposition(old) || Self.holdsComposition(new) else { return published }
        return new == .running ? [.resetComposition] + published : published + [.resetComposition]
    }

    private static func holdsComposition(_ phase: LifecycleSnapshot.Phase) -> Bool {
        switch phase {
        case .failOpen, .sessionInactive: true
        case .noPermission, .starting, .running: false
        }
    }

    /// PLT-R330 step 5: true when this disable makes more than `instabilityThreshold` within the window and no
    /// notice was shown during the last window.
    private mutating func noteSystemDisable(at now: MonotonicInstant) -> Bool {
        if let last = recentDisables.last,
            now.nanoseconds(since: MonotonicInstant(nanoseconds: last))
                < Self.disableCoalescingWindow.unsignedNanoseconds
        {
            return false
        }
        let window = Self.instabilityWindow.unsignedNanoseconds
        recentDisables.append(now.nanoseconds)
        recentDisables.removeAll { now.nanoseconds(since: MonotonicInstant(nanoseconds: $0)) > window }
        if recentDisables.count > Self.instabilityThreshold + 1 { recentDisables.removeFirst() }
        guard recentDisables.count > Self.instabilityThreshold else { return false }
        if let lastNoticeAt, now.nanoseconds(since: MonotonicInstant(nanoseconds: lastNoticeAt)) < window {
            return false
        }
        lastNoticeAt = now.nanoseconds
        return true
    }

    /// PLT-R323: the retry delay for this postingBroken. A break within the previous delay plus
    /// `postingBrokenStableInterval` of the previous break moves one step up the backoff; otherwise it restarts.
    private mutating func notePostingBroken(at now: MonotonicInstant) -> TimeSpan {
        let backoff = Self.postingBrokenBackoff
        if let last = lastPostingBrokenAt {
            let horizon =
                backoff[postingBrokenAttempt].unsignedNanoseconds + Self.postingBrokenStableInterval.unsignedNanoseconds
            let soon = now.nanoseconds(since: MonotonicInstant(nanoseconds: last)) < horizon
            postingBrokenAttempt = soon ? min(postingBrokenAttempt + 1, backoff.count - 1) : 0
        }
        lastPostingBrokenAt = now.nanoseconds
        return backoff[postingBrokenAttempt]
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/InputHost/Lifecycle/InputHostController.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Lifecycle owner of the input host (2.1). Main actor: it starts and stops threads, applies settings, drives
// the pure `HostLifecycle` state machine and performs its effects, and tells the shell what to show. It never
// sits on the per-keystroke path. Workstream W2-A (composition with the real services); the state machine
// itself is W1-F2. The effect, notice and settings paths live in `Integration/InputHostController+*.swift`.

public import AppModel
public import CompatRules
public import Diagnostics
public import Foundation
public import Injection
public import RealtimeSupport
public import SettingsStore
internal import VietnameseEngine

/// Everything the host needs from the platform, injected so the whole host runs under fakes in tests.
public struct InputHostDependencies: Sendable {
    public var tapFactory: any EventTapFactory
    public var poster: any EventPoster
    public var fieldAccess: any FocusedFieldAccess
    public var pasteboard: any PasteboardAccess
    public var ax: any AXProvider
    public var processes: any ProcessIdentityProvider
    public var bundleInspector: any BundleInspector
    public var inputSources: any InputSourceProvider
    public var layoutBuilder: any LayoutTableBuilding
    public var secureInput: any SecureInputProbe
    public var permissions: any PermissionProbe
    public var workspace: any WorkspaceEvents
    public var keyValueStore: any KeyValueStore
    /// Services' clock (ADR 0313). The tap pipeline itself is `KeyPipeline<_, MachClock>` in production.
    public var clock: any MonotonicClock
    /// Timers of the monitors, the tap watchdog and the lifecycle backoff (production:
    /// `DispatchTimerScheduler(queue: utilityQueue)`; tests: `ManualScheduler`).
    public var scheduler: any TimerScheduler
    public var wallClock: any WallClock
    public var metrics: PlatformMetrics
    public var health: HealthEventLog
    public var logger: any DiagnosticsLogging
    public var tapLog: TapLogRing
    public var capture: CaptureController?
    /// Serial utility queue shared with SettingsStore and Diagnostics (PLT-R203).
    public var utilityQueue: DispatchQueue
    /// PLT-R802 intervals for the tap callback, injection jobs and AX calls. When nil, the production
    /// controller creates them with the bundle identifier as subsystem.
    public var signposts: PlatformSignposts?

    public init(
        tapFactory: any EventTapFactory, poster: any EventPoster, fieldAccess: any FocusedFieldAccess,
        pasteboard: any PasteboardAccess, ax: any AXProvider, processes: any ProcessIdentityProvider,
        bundleInspector: any BundleInspector, inputSources: any InputSourceProvider,
        layoutBuilder: any LayoutTableBuilding, secureInput: any SecureInputProbe, permissions: any PermissionProbe,
        workspace: any WorkspaceEvents, keyValueStore: any KeyValueStore, clock: any MonotonicClock,
        scheduler: any TimerScheduler, wallClock: any WallClock,
        metrics: PlatformMetrics, health: HealthEventLog, logger: any DiagnosticsLogging, tapLog: TapLogRing,
        capture: CaptureController?, utilityQueue: DispatchQueue, signposts: PlatformSignposts? = nil
    ) {
        self.tapFactory = tapFactory
        self.poster = poster
        self.fieldAccess = fieldAccess
        self.pasteboard = pasteboard
        self.ax = ax
        self.processes = processes
        self.bundleInspector = bundleInspector
        self.inputSources = inputSources
        self.layoutBuilder = layoutBuilder
        self.secureInput = secureInput
        self.permissions = permissions
        self.workspace = workspace
        self.keyValueStore = keyValueStore
        self.clock = clock
        self.scheduler = scheduler
        self.wallClock = wallClock
        self.metrics = metrics
        self.health = health
        self.logger = logger
        self.tapLog = tapLog
        self.capture = capture
        self.utilityQueue = utilityQueue
        self.signposts = signposts
    }
}

/// What the shell reacts to (icon, HUD, status line, notices).
public enum HostEvent: Sendable {
    case stateChanged(HostState)
    /// `manual` = toggle hotkey or menu; the HUD shows only for manual switches (D14, PRD-R12).
    case modeChanged(TypingMode, manual: Bool, bundle: BundleKey?)
    case focusChanged(bundle: BundleKey?, rule: RuleID?)
    /// More than 3 tap disables within 10 minutes (PLT-R330 step 5), or one not recovered within 1 s (PRD-R43).
    case tapInstabilityNotice
    case conflictsDetected([ConflictingInput])
    case permissionsChanged(PermissionStatus)
    /// ENG-R861 learning signal seen twice in the same app: added to that app's learned words (ENG-R862, visible,
    /// removable and promotable to global in Settings). The shell may mention it; it never logs the word.
    case learningProposal(LearningProposal)
}

/// ENG-R862: a learning signal seen twice in one app, stored for that app only.
public struct LearningProposal: Sendable, Hashable {
    public typealias List = RestoreList
    public var list: List
    public var rawKeys: String  // content: shown to the user in Settings, never logged
    /// The app the signals came from; the learned word applies only there.
    public var app: BundleKey

    public init(list: List, rawKeys: String, app: BundleKey) {
        self.list = list
        self.rawKeys = rawKeys
        self.app = app
    }
}

/// Why the session is inactive (PLT-R333); the host is active only when none applies.
enum SessionInactiveReason: Hashable {
    case asleep, screenLocked, sessionResigned
}

@MainActor
public final class InputHostController {
    let dependencies: InputHostDependencies
    let settingsStore: SettingsStore
    let hop: any MainThreadHop
    let channels: HostChannels
    let axThread: RunLoopThread
    let focusTracker: FocusTracker
    let worker: InjectionWorker
    let settingsPublisher: TapSettingsPublisher
    let tapLogDrainer: TapLogDrainer
    let makeTapThread: TapThreadMaker
    /// The clock the tap stamps events with; the worker, the tap watchdog and the log drainer share its base.
    let tapClock: any MonotonicClock
    /// False only in tests that drive the worker step by step (`InjectionWorker.runUntilIdle`).
    let runsWorkerThread: Bool
    let ruleBox = RuleSetBox()
    /// Since-launch observations the integration hooks report (tap recoveries, first key after a secure-input
    /// release); shared with every tap session's pipeline.
    public let counters = HostCounters()
    let refresh: RefreshRequests
    var inputSourceMonitor: InputSourceMonitor
    var permissionMonitor: PermissionMonitor?
    var secureInputMonitor: SecureInputMonitor?
    var workspaceToken: (any ObservationToken)?
    var drainTimer: (any ScheduledTimer)?
    var retryTimer: (any ScheduledTimer)?
    /// Bumped on every schedule and cancel; a fire whose hop to main carries an older value is stale.
    var retryGeneration: UInt64 = 0

    var lifecycle = HostLifecycle()
    var lifecycleGeneration: UInt64 = 0
    var pendingInputs: [LifecycleInput] = []
    var processingInputs = false
    var session: TapSession?
    /// A removed session whose thread may still be exiting; its echoes are retired before the next tap.
    var retiredSession: TapSession?
    var recorderActive = false
    var started = false
    var stopped = false

    var rules: RulesLoadResult?
    var ruleInputs: RuleSetInputs?
    var settings: SettingsState?
    var latestPermissions: PermissionStatus?
    var latestToggle: (sequence: UInt64, bundle: BundleKey?, mode: TypingMode)?
    var secureResumedGeneration: UInt64?
    var lastFocusKey: FocusKey?
    var captureGap: PauseCode?
    var conflicts: [ConflictingInput] = []
    var conflictsReported = false
    var conflictsRescanned = false
    var learning = LearningTracker()
    /// Hands the ax thread's memory documents to the settings store in order (PLT-R392).
    var appModesRecorder: AppModesRecorder?
    var inactiveReasons: Set<SessionInactiveReason> = []

    public internal(set) var state: HostState = .starting

    public var onEvent: (@MainActor (HostEvent) -> Void)?

    /// Production wiring: the real tap thread and pipeline, the main dispatch queue for hops, the uptime clock
    /// for everything that shares a base with the tap's event timestamps.
    public convenience init(dependencies: InputHostDependencies, settingsStore: SettingsStore) {
        var dependencies = dependencies
        if dependencies.signposts == nil {  // PLT-R802: in all builds; the subsystem comes from the bundle
            dependencies.signposts = Bundle.main.bundleIdentifier.map { PlatformSignposts(subsystem: $0) }
        }
        self.init(
            dependencies: dependencies, settingsStore: settingsStore, hop: DispatchMainHop(),
            makeTapThread: TapSession.productionThreadMaker(factory: dependencies.tapFactory), tapClock: MachClock(),
            loadBundled: TapSettingsPublisher.bundledLoader, macOSVersion: Self.macOSVersion,
            runsWorkerThread: true, mainSignalQueue: .main)
    }

    init(
        dependencies: InputHostDependencies, settingsStore: SettingsStore, hop: any MainThreadHop,
        makeTapThread: @escaping TapThreadMaker, tapClock: any MonotonicClock,
        loadBundled: @escaping TapSettingsPublisher.BundledResourcesLoader, macOSVersion: LooseVersion,
        runsWorkerThread: Bool, mainSignalQueue: DispatchQueue? = nil
    ) {
        self.runsWorkerThread = runsWorkerThread
        self.dependencies = dependencies
        self.settingsStore = settingsStore
        self.hop = hop
        self.makeTapThread = makeTapThread
        self.tapClock = tapClock
        refresh = RefreshRequests(hop: hop)
        let initial = InitialSnapshots.make(
            source: dependencies.inputSources.currentSource(), settings: Self.placeholderSettings,
            globalMode: .vietnamese)
        // ADR 0303: tap -> main wakes on the main queue in production; tests keep the utility queue (nil), where
        // `ManualMainHop` collects the drains.
        channels = HostChannels(
            initial: initial, marker: .random(), signalQueue: dependencies.utilityQueue,
            mainSignalQueue: mainSignalQueue ?? dependencies.utilityQueue)
        axThread = RunLoopThread(name: "ax", qualityOfService: .userInitiated)
        let refresh = self.refresh
        focusTracker = FocusTracker(
            thread: axThread,
            ax: FocusChangeSignalingAXProvider(base: dependencies.ax, thread: axThread) { refresh.request() },
            processes: dependencies.processes, output: channels.snapshots.focus,
            generation: channels.focusGeneration, inbox: channels.outbox.toAX, metrics: dependencies.metrics,
            health: dependencies.health, clock: dependencies.clock, macOSVersion: macOSVersion,
            capture: dependencies.capture, signposts: dependencies.signposts, scheduler: dependencies.scheduler)
        // A settle re-read or an observer retry publishes without a notification: wake the main thread the same way.
        focusTracker.setDeferredPublicationObserver { refresh.request() }
        worker = InjectionWorker(
            queue: channels.queue, signal: channels.workerSignal, feedback: channels.feedback,
            marker: channels.marker, focusGeneration: channels.focusGeneration,
            services: InjectionServices(
                poster: dependencies.poster, fieldAccess: dependencies.fieldAccess, pasteboard: dependencies.pasteboard,
                clock: tapClock, metrics: dependencies.metrics, health: dependencies.health,
                logger: dependencies.logger, capture: dependencies.capture, signposts: dependencies.signposts))
        settingsPublisher = TapSettingsPublisher(
            cell: channels.snapshots.settings, logger: dependencies.logger, loadBundled: loadBundled)
        tapLogDrainer = TapLogDrainer(
            ring: dependencies.tapLog, health: dependencies.health, logger: dependencies.logger, clock: tapClock,
            wallClock: dependencies.wallClock)
        let inputSourceCell = channels.snapshots.inputSource
        inputSourceMonitor = InputSourceMonitor(
            provider: dependencies.inputSources, builder: dependencies.layoutBuilder
        ) { snapshot in
            inputSourceCell.publish(snapshot)
            refresh.request()
        }
        refresh.connect { [weak self] in self?.refreshState() }
        makeMonitors()
        connectSignals()
    }

    /// Ready after launch within 300 ms target / 1 s gate when permissions are granted (S1). The first settings
    /// snapshot (engine catalog with the bundled lists, ENG-R1231) is built on the utility queue before the
    /// lifecycle may create the tap, so the first key already has the real engines.
    public func start(rules: RulesLoadResult, settings: SettingsState) {
        guard !started, !stopped else { return }
        started = true
        self.rules = rules
        self.settings = settings
        let publisher = settingsPublisher
        dependencies.utilityQueue.sync {
            publisher.preloadResources()
            publisher.publish(settings)
        }
        startServices(rules: rules, settings: settings)
        feed(.launched)
        detectConflicts()
    }

    public func stop() {
        guard !stopped else { return }
        stopped = true
        stopServices()
    }

    /// Rebuilds engines and snapshots (utility queue) and re-resolves focus (ax) (PLT-R1008, PRD-R27).
    /// Before `start` it only records the state; `start` publishes it.
    public func apply(settings: SettingsState) {
        guard !stopped else { return }
        self.settings = settings
        guard started else { return }
        applySettings(settings)
    }

    /// Menu radio or click-to-toggle (D16). Hard boundary; updates per-app memory (PRD-R20).
    public func setMode(_ mode: TypingMode, manual: Bool) {
        focusTracker.setMode(mode)
        refreshAfterAXWork()
        onEvent?(.modeChanged(mode, manual: manual, bundle: currentFocus().app?.bundle))
    }

    /// Status for the menu "Với <App>" submenu and diagnostics.
    public func currentFocus() -> FocusSnapshot { channels.snapshots.focus.load() }

    /// The current layout's key table (PLT-R360), for the hotkey recorder and the latency probe.
    public func currentLayoutTable() -> LayoutTable? { channels.snapshots.inputSource.load().table }

    /// Enabled input sources (IDs and names), for the layout binding in Settings (PLT-R373).
    public func enabledInputSources() -> [InputSourceInfo] { dependencies.inputSources.enabledSources() }

    /// Immediate secure-input poll when the menu opens (PLT-R395).
    public func refreshSecureInput() -> SecureInputSnapshot {
        secureInputMonitor?.pollNow() ?? channels.snapshots.secureInput.load()
    }

    /// Immediate permission check on menu open, wake and session activation (PLT-R721).
    public func refreshPermissions() -> PermissionStatus {
        guard let monitor = permissionMonitor else { return latestPermissions ?? Self.unknownPermissions }
        let status = monitor.checkNow()
        latestPermissions = status
        return status
    }

    /// Onboarding's permission screen is visible: poll every second for at most 5 minutes (PLT-R711).
    public func setPermissionFastPolling(_ enabled: Bool) {
        permissionMonitor?.setFastPolling(enabled)
    }

    /// The settings window's recorder is capturing keys: suspend hotkeys (PRD-R15).
    public func setRecorderActive(_ active: Bool) {
        guard active != recorderActive else { return }
        recorderActive = active
        publishLifecycle(lifecycle.phase)
    }

    /// The guided test of "This app misbehaves" is about to type (`true`) or has finished (`false`)
    /// (PLT-R1205 steps 3-5). While on, the tap passes every keyboard event unchanged without feeding the engine,
    /// hotkeys are suspended so nothing is written to per-app memory and the manual mode stays as it is, and the
    /// composition is reset on entry and exit (PLT-R210). Calls nest; each `true` needs one `false`. The tap reads
    /// the flag from the lifecycle snapshot (PLT-R304: no lock, no allocation).
    public func setDiagnosticsPassThrough(_ on: Bool) {
        guard !stopped else { return }
        feed(.diagnosticsPassThrough(on))
    }

    /// Data for the diagnostics report (PLT-R1202), metadata only.
    public func reportContext() -> HostReportContext {
        HostReportContext(
            state: state, focus: currentFocus(), decision: focusTracker.currentDecision(),
            inputSource: channels.snapshots.inputSource.load(),
            enabledSources: dependencies.inputSources.enabledSources(),
            secureInput: channels.snapshots.secureInput.load(),
            permissions: latestPermissions ?? Self.unknownPermissions, tapEnabled: session?.thread.isEnabled ?? false,
            conflicts: conflicts)
    }
}

/// Host-side inputs of `DiagnosticsReport` (assembled by ShellCore).
public struct HostReportContext: Sendable {
    public var state: HostState
    public var focus: FocusSnapshot
    public var decision: ResolvedDecision?
    public var inputSource: InputSourceSnapshot
    public var enabledSources: [InputSourceInfo]
    public var secureInput: SecureInputSnapshot
    public var permissions: PermissionStatus
    public var tapEnabled: Bool
    public var conflicts: [ConflictingInput]
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/InputHost/Hotkeys/Hotkeys.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Hotkey recogniser (PRD-R14, PRD-R15, PRD-R18, PLT-R310 step 5) and recorder (PRD-R15, PRD-R16). Pure value
// types: the recogniser lives on the tap thread inside the pipeline, the recorder in the settings UI.

public import AppModel
public import RealtimeSupport

public enum HotkeyInput: Sendable, Hashable {
    /// `flagsChanged` with the side-specific modifier state after the change (keyCode identifies the key).
    case flagsChanged(keyCode: KeyCode, modifiers: ModifierKeys, at: MonotonicInstant)
    case keyDown(keyCode: KeyCode, modifiers: ModifierKeys, autorepeat: Bool, at: MonotonicInstant)
    case keyUp(keyCode: KeyCode, at: MonotonicInstant)
    case pointerDown(at: MonotonicInstant)
    case scroll(at: MonotonicInstant)
}

public enum HotkeyResult: Sendable, Hashable {
    case none
    /// Modifier-only tap completed: fire on release of the last modifier (PRD-R14). Modifier events are never
    /// swallowed.
    case toggleTap
    /// Key combo matched on keyDown: the pipeline consumes this keyDown and its keyUp.
    case toggleCombo
    /// The restore binding matched on keyDown: the pipeline feeds `.restoreToggle` to the engine and consumes
    /// the key only if the engine returns an edit (PLT-R353, ENG-R701-R703).
    case restoreCandidate
}

/// Toggle tap: cancels on any other key, mouse button or scroll during the hold, on holds longer than 500 ms,
/// and ignores autorepeat (PRD-R14).
///
/// Auto-repeat events never fire a hotkey and never cancel a tap: they belong to a key pressed before the chord
/// started. A restore binding is recognised only as a key or key combo (it must be a key the pipeline can
/// consume, PRD-R18, PLT-R353); a modifier-only restore binding is ignored. Logic: `HotkeyRecognition.swift`.
public struct HotkeyRecognizer: Sendable {
    public static let maximumTapDuration: TimeSpan = .milliseconds(500)
    let toggle: HotkeyBinding
    let restore: HotkeyBinding?
    var toggleTap: HotkeyChordTracker?

    public init(toggle: HotkeyBinding, restore: HotkeyBinding?) {
        self.toggle = toggle
        self.restore = restore
        toggleTap = HotkeyChordTracker(binding: toggle)
    }

    public mutating func handle(_ input: HotkeyInput) -> HotkeyResult { recognize(input) }
}

public enum RecorderState: Sendable, Hashable {
    case idle
    case recording(held: ModifierKeys, key: KeyCode?)
    case finished(HotkeyBinding, conflict: SystemShortcutConflict?)
    case rejected(RecorderRejection)
}

public enum RecorderRejection: String, Sendable, Hashable {
    /// Modifier-only chord outside the PRD-R15 list; for the restore role every modifier-only chord (PRD-R18).
    case unsupportedModifierTap
    case keyWithoutModifierForToggle
}

/// macOS shortcuts the recorder warns about but accepts (PRD-R16).
public enum SystemShortcutConflict: String, Sendable, Hashable, CaseIterable {
    case spotlight  // Command+Space
    case selectPreviousInputSource  // Control+Space
    case selectNextInputSource  // Control+Option+Space
    case characterViewer  // Control+Command+Space
    case appSwitcher  // Command+Tab
    case quitApp  // Command+Q
    case closeWindow  // Command+W
}

/// Captures a binding in any press order and finishes when every key is released (PRD-R15). Logic:
/// `HotkeyRecording.swift`.
public struct HotkeyRecorder: Sendable {
    let role: HotkeyRole
    let layout: LayoutTable?
    var session = HotkeyRecordingSession()
    var state = RecorderState.idle

    public init(role: HotkeyRole) { self.init(role: role, layout: nil) }

    /// `layout` names the conflicts that depend on the typed character (Command+Q, Command+W) on non-US layouts
    /// such as AZERTY or Dvorak; without it the ABC key positions are used.
    public init(role: HotkeyRole, layout: LayoutTable?) {
        self.role = role
        self.layout = layout
    }

    public mutating func handle(_ input: HotkeyInput) -> RecorderState { record(input) }

    public static func conflict(for binding: HotkeyBinding) -> SystemShortcutConflict? {
        conflict(for: binding, layout: nil)
    }

    /// PRD-R16 conflict, resolving letter keys through `layout` when given.
    public static func conflict(for binding: HotkeyBinding, layout: LayoutTable?) -> SystemShortcutConflict? {
        SystemShortcutCatalog.conflict(for: binding, layout: layout)
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/InputHost/InputSource/InputSources.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Input-source awareness (PLT-R360-R373). TIS calls run on the main thread only; `UCKeyTranslate` is a pure
// function over `uchr` bytes and may run anywhere off the tap.

public import AppModel
public import Foundation

/// Raw `uchr` data of a keyboard layout (`kTISPropertyUnicodeKeyLayoutData`).
public struct KeyboardLayoutData: Sendable, Hashable {
    public var source: InputSourceID
    public var uchr: Data
    public init(source: InputSourceID, uchr: Data) {
        self.source = source
        self.uchr = uchr
    }
}

public protocol ObservationToken: AnyObject, Sendable {
    func cancel()
}

/// Production (`TISInputSourceProvider`): `TISCopyCurrentKeyboardInputSource`,
/// `TISCopyCurrentKeyboardLayoutInputSource` + `TISGetInputSourceProperty(kTISPropertyUnicodeKeyLayoutData)`,
/// `TISCreateInputSourceList` (enabled sources), `LMGetKbdType()`, and `DistributedNotificationCenter`
/// observers for `kTISNotifySelectedKeyboardInputSourceChanged` and
/// `kTISNotifyEnabledKeyboardInputSourcesChanged`. Read-only: never selects or enables a source.
@MainActor
public protocol InputSourceProvider: Sendable {
    func currentSource() -> InputSourceInfo
    func currentLayoutData() -> KeyboardLayoutData?
    func enabledSources() -> [InputSourceInfo]
    /// Layout data of any installed layout by ID (tests build QWERTZ/AZERTY/Dvorak tables without selecting).
    func layoutData(for id: InputSourceID) -> KeyboardLayoutData?
    func currentKeyboardType() -> UInt32
    func observeChanges(_ handler: @escaping @MainActor @Sendable () -> Void) -> any ObservationToken
}

/// Builds the 128 x 4 table with `UCKeyTranslate(layout, keyCode, kUCKeyActionDown, modifierState,
/// keyboardType, 0, &deadKeyState, ...)` for the states none, Shift, Caps Lock, Shift+Caps Lock (PLT-R360).
public protocol LayoutTableBuilding: Sendable {
    func build(from data: KeyboardLayoutData, keyboardType: UInt32) throws -> LayoutTable
}

/// Throws `LayoutTableError` when the `uchr` data is not a keyboard layout or `UCKeyTranslate` rejects it. A
/// control character (Return, Tab, arrows, function keys) is `.none`; a key that only changes the dead-key state
/// is `.deadKey` (PLT-R354). Logic: `UCKeyTranslateTable.swift`.
public struct UCKeyTranslateLayoutBuilder: LayoutTableBuilding {
    public init() {}
    public func build(from data: KeyboardLayoutData, keyboardType: UInt32) throws -> LayoutTable {
        try UCKeyTranslateTable.build(from: data, keyboardType: keyboardType)
    }
}

public enum LayoutTableError: Error, Sendable, Hashable {
    case invalidLayoutData
    case translationFailed(status: Int32)
}

/// Main thread: on every source change builds (or reuses) the table, classifies the source (PLT-R371,
/// PLT-R372), applies the PLT-R373 binding and publishes an `InputSourceSnapshot`; signals a hard boundary.
/// A snapshot (with a new generation) is published only when the source, its table or its bound mode changed.
/// Logic: `InputSourceMonitor+Refresh.swift`.
@MainActor
public final class InputSourceMonitor {
    let provider: any InputSourceProvider
    let builder: any LayoutTableBuilding
    let publish: @Sendable (InputSourceSnapshot) -> Void
    var binding = LayoutBindingConfiguration(enabled: false, vietnamese: [], english: [])
    var keyboardType: UInt32?
    var tables: [LayoutTableKey: LayoutTable] = [:]
    var lastPublished: InputSourceSnapshot?
    var generation: UInt64 = 0
    var observation: (any ObservationToken)?

    public init(
        provider: any InputSourceProvider, builder: any LayoutTableBuilding,
        publish: @escaping @Sendable (InputSourceSnapshot) -> Void
    ) {
        self.provider = provider
        self.builder = builder
        self.publish = publish
    }

    public func start() { begin() }
    public func stop() { end() }
    public func apply(binding: LayoutBindingConfiguration) {
        self.binding = binding
        refresh()
    }

    /// The tap saw a keyboard type without a table (ISO/ANSI/JIS): build one.
    public func keyboardTypeSeen(_ keyboardType: UInt32) { adopt(keyboardType: keyboardType) }
}

public struct LayoutBindingConfiguration: Sendable, Hashable {
    public var enabled: Bool
    public var vietnamese: Set<InputSourceID>
    public var english: Set<InputSourceID>
    public init(enabled: Bool, vietnamese: Set<InputSourceID>, english: Set<InputSourceID>) {
        self.enabled = enabled
        self.vietnamese = vietnamese
        self.english = english
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/InputHost/SecureInput/SecureInput.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Secure Event Input (PLT-R395-R398C, P0-1). Only two pause signals exist: the OS secure-input state and an
// `AXSecureTextField` focus (PLT-R398A). No heuristics.

public import AppModel
public import Foundation
public import RealtimeSupport

/// Production (`SystemSecureInputProbe`): `IsSecureEventInputEnabled()` (Carbon); holder via
/// `IORegistryEntryCreateCFProperty(IORegistryGetRootEntry(kIOMainPortDefault), "IOConsoleUsers", ...)`,
/// selecting the entry of the current console session and reading `kCGSSessionSecureInputPID`.
/// Never calls `EnableSecureEventInput` (PLT-R398).
public protocol SecureInputProbe: Sendable {
    func isSecureEventInputEnabled() -> Bool
    func secureInputHolderPID() -> Int32?
}

public struct SystemSecureInputProbe: SecureInputProbe {
    public init() {}
    public func isSecureEventInputEnabled() -> Bool { SecureInputSystem.isEnabled() }
    public func secureInputHolderPID() -> Int32? { SecureInputSystem.holderPID() }
}

/// Identity of a process for focus, holder naming and conflict detection.
public struct ProcessIdentity: Sendable, Hashable {
    public var pid: Int32
    /// Bundle ID, or SHA-256 of the executable path for bundle-less processes (PLT-R393).
    public var bundle: BundleKey
    public var bundleURL: URL?
    public var shortVersion: String?  // CFBundleShortVersionString
    public var buildVersion: String?  // CFBundleVersion (fingerprint cache key)
    public var appCategory: String?  // LSApplicationCategoryType
    public var localizedName: String?
    /// `proc_name`, used to recognise `loginwindow` without a bundle-ID literal (PLT-R396, PLT-R501).
    public var processName: String

    public init(
        pid: Int32, bundle: BundleKey, bundleURL: URL?, shortVersion: String?, buildVersion: String?,
        appCategory: String?, localizedName: String?, processName: String
    ) {
        self.pid = pid
        self.bundle = bundle
        self.bundleURL = bundleURL
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
        self.appCategory = appCategory
        self.localizedName = localizedName
        self.processName = processName
    }
}

/// Production (`SystemProcessIdentityProvider`): `NSRunningApplication(processIdentifier:)`, `proc_pidpath`,
/// `proc_name`, `Bundle(url:)`.
public protocol ProcessIdentityProvider: Sendable {
    func identity(of pid: Int32) -> ProcessIdentity?
    func isAlive(_ pid: Int32) -> Bool  // kill(pid, 0) != ESRCH
    func runningApplications() -> [ProcessIdentity]
    /// The application NSWorkspace calls frontmost (the dev recorder's attribution when AX names no focused
    /// application, PLT-R904A). Never a focus source: PLT-R381 keeps the system-wide AX focus authoritative.
    func frontmostApplication() -> ProcessIdentity?
}

extension ProcessIdentityProvider {
    /// Providers without a frontmost application (fakes) report none.
    public func frontmostApplication() -> ProcessIdentity? { nil }
}

/// Polls every 2 s with 10 % leeway through the injected scheduler and on demand (menu open), publishes a
/// `SecureInputSnapshot` and names the likely holder with the data-driven hint key (PLT-R396, PLT-R397).
///
/// Episodes and generations (PLT-R398B): the generation changes on every OS transition. `keyEvidence(generation:)`
/// ENDS episode N: the tap stays resumed for generation N until the next poll, and the next poll that still sees
/// the OS flag on starts a new episode with a new generation even though no "off" was observed in between
/// (on -> off -> key -> on inside one poll interval must pause again, not stay resumed).
///
/// Snapshots are published in poll order, one at a time, outside the poll lock: `publish` may call back into
/// the monitor (`pollNow`, `keyEvidence`); a snapshot produced meanwhile is published after it returns.
/// Logic: `SecureInputMonitor+Polling.swift`.
public final class SecureInputMonitor: Sendable {
    public static let pollInterval: TimeSpan = .seconds(2)
    /// PLT-R803: at least 10 % leeway on every timer.
    public static let pollLeeway: TimeSpan = .milliseconds(200)

    let probe: any SecureInputProbe
    let processes: any ProcessIdentityProvider
    let hintKey: @Sendable (BundleKey) -> String?
    let scheduler: any TimerScheduler
    let delivery: OrderedDelivery<SecureInputSnapshot>
    let state = Mutex(SecureInputMonitorState())

    public init(
        probe: any SecureInputProbe, processes: any ProcessIdentityProvider,
        hintKey: @escaping @Sendable (BundleKey) -> String?, scheduler: any TimerScheduler,
        publish: @escaping @Sendable (SecureInputSnapshot) -> Void
    ) {
        self.probe = probe
        self.processes = processes
        self.hintKey = hintKey
        self.scheduler = scheduler
        self.delivery = OrderedDelivery(publish)
    }

    public func start() { beginPolling() }
    public func stop() { endPolling() }
    /// Synchronous poll (menu open, PLT-R395).
    public func pollNow() -> SecureInputSnapshot { poll() }
    /// The tap processed a key while paused for secure input (PLT-R398B): records the episode end; the state
    /// stays "resumed" for this generation until the next poll (see the type comment).
    public func keyEvidence(generation: UInt64) { recordKeyEvidence(generation: generation) }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/InputHost/Focus/Focus.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Focus tracking on the `ax` thread (PLT-R380-R387, PLT-R510, PLT-R520-R523, T6 <= 30 ms p95).

public import AppModel
public import CompatRules
public import Diagnostics
public import Foundation
public import Injection
public import RealtimeSupport
public import SettingsStore

public struct AXFocusedElement: Sendable, Hashable {
    public var pid: Int32
    public var element: AXElementReference
    public init(pid: Int32, element: AXElementReference) {
        self.pid = pid
        self.element = element
    }
}

/// Attributes read on focus change; all bounded reads (PLT-R343). Title and URL only when a rule needs them,
/// and only for matching in memory.
public struct FocusAttributes: Sendable, Hashable {
    public var role: String?
    public var subrole: String?
    public var identifier: String?  // kAXIdentifierAttribute
    public var domClasses: [String]  // "AXDOMClassList" when exposed
    public var editable: Bool?
    /// Nearest parent first: up to 6 (5.2), or up to the nearest `AXWebArea` when a document URL was requested
    /// and the web area is further up. Matching uses the first 6.
    public var ancestorRoles: [String]
    /// Transient. The `AXURL` of the focused web area (5.5): only when the element is an `AXWebArea` or lies
    /// inside one, never for browser chrome such as the omnibox. The tracker drops it otherwise.
    public var documentURL: String?
    public var windowTitle: String?  // transient
    public init(
        role: String?, subrole: String?, identifier: String?, domClasses: [String], editable: Bool?,
        ancestorRoles: [String], documentURL: String?, windowTitle: String?
    ) {
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.domClasses = domClasses
        self.editable = editable
        self.ancestorRoles = ancestorRoles
        self.documentURL = documentURL
        self.windowTitle = windowTitle
    }
}

public enum AXNotificationKind: String, Sendable, Hashable, CaseIterable {
    case focusedElementChanged  // kAXFocusedUIElementChangedNotification
    case focusedWindowChanged  // kAXFocusedWindowChangedNotification
    case applicationActivated  // kAXApplicationActivatedNotification
    case titleChanged  // kAXTitleChangedNotification (only for titlePattern bundles)
}

public struct AXAttributeRequest: Sendable, Hashable {
    public var includeDocumentURL: Bool
    public var includeWindowTitle: Bool
    public init(includeDocumentURL: Bool, includeWindowTitle: Bool) {
        self.includeDocumentURL = includeDocumentURL
        self.includeWindowTitle = includeWindowTitle
    }
}

/// Accessibility for focus tracking, called only on the ax thread. Production (`SystemAXProvider`):
/// `AXUIElementCreateSystemWide`, `AXUIElementCreateApplication`, `AXUIElementSetMessagingTimeout(…, 0.1)` on
/// every application element and the system-wide element (PLT-R384), `kAXFocusedApplicationAttribute`,
/// `kAXFocusedUIElementAttribute`, `kAXParentAttribute`, `AXObserverCreate` / `AXObserverAddNotification` /
/// `AXObserverGetRunLoopSource`. Never sets `AXEnhancedUserInterface`; sets `AXManualAccessibility` only on
/// request (PLT-R385).
///
/// The system-wide focus is read in two steps so the circuit breaker can stop every query to a slow pid
/// (PLT-R384): the focused application comes from the system-wide element, the focused element from that
/// application's element.
public protocol AXProvider: Sendable {
    /// pid of the system-wide focused application (`kAXFocusedApplicationAttribute`, PLT-R381); nil when none.
    func focusedApplication() -> AXCallResult<Int32?>
    /// The focused element of application `pid` (`kAXFocusedUIElementAttribute`); nil when it has none.
    func focusedElement(pid: Int32) -> AXCallResult<AXFocusedElement?>
    func attributes(of element: AXFocusedElement, request: AXAttributeRequest) -> AXCallResult<FocusAttributes>
    /// Observer whose run-loop source the caller adds to the ax run loop. The handler runs on the ax thread.
    /// nil when the app took none of the notifications, or (`.complete`) refused one it may take later.
    func observe(
        pid: Int32, notifications: Set<AXNotificationKind>, mode: AXObservationMode,
        handler: @escaping @Sendable (AXNotificationKind) -> Void
    ) -> (any AXObservation)?
    /// `AXManualAccessibility = true` when a rule says `axEnable: manual`; the caller records it (PLT-R385).
    func enableManualAccessibility(pid: Int32) -> Bool
}

extension AXProvider {
    /// All the notifications or none (`AXObservationMode.complete`).
    public func observe(
        pid: Int32, notifications: Set<AXNotificationKind>,
        handler: @escaping @Sendable (AXNotificationKind) -> Void
    ) -> (any AXObservation)? {
        observe(pid: pid, notifications: notifications, mode: .complete, handler: handler)
    }
}

/// How an observer treats an app that cannot complete a notification registration yet (PLT-R380).
public enum AXObservationMode: Sendable, Hashable {
    /// All the notifications or none: a refusal (`kAXErrorCannotComplete`, an app still launching) gives nil so
    /// the focus tracker tries again later.
    case complete
    /// Keep the notifications the app took and skip the refused ones: the focus tracker's last attempt.
    case bestEffort
}

/// A registered AXObserver; `invalidate` removes notifications and its run-loop source.
public protocol AXObservation: AnyObject, Sendable {
    var runLoopSource: CFRunLoopSource { get }
    func invalidate()
}

/// Rules as the focus tracker needs them. `RuleSet` conforms (InputHost extension); fakes in TestSupport.
public protocol FocusDecisionResolving: Sendable {
    func resolve(_ context: MatchContext) -> ResolvedDecision
    var overlayBundles: Set<BundleKey> { get }
    var titlePatternBundles: Set<BundleKey> { get }
    func fingerprint(bundleURL: URL, bundle: BundleKey) -> EngineFingerprint
}

/// PLT-R384: 3 timeouts within 10 s for one pid stop AX queries to that pid for 60 s. `recordTimeout` returns
/// true when this timeout opened the breaker (the caller records one health event). Logic:
/// `AXCircuitBreaker+Logic.swift`.
public struct AXCircuitBreaker: Sendable {
    let threshold: Int
    let windowNanoseconds: UInt64
    let cooldownNanoseconds: UInt64
    var recentTimeouts: [Int32: [MonotonicInstant]] = [:]
    var openUntil: [Int32: MonotonicInstant] = [:]

    public init(threshold: Int = 3, window: TimeSpan = .seconds(10), cooldown: TimeSpan = .seconds(60)) {
        self.threshold = max(1, threshold)
        windowNanoseconds = Self.nanoseconds(window)
        cooldownNanoseconds = Self.nanoseconds(cooldown)
    }

    public mutating func recordTimeout(pid: Int32, at: MonotonicInstant) -> Bool { record(pid: pid, at: at) }
    public func isOpen(pid: Int32, at: MonotonicInstant) -> Bool { openUntil[pid].map { at < $0 } ?? false }
}

/// The focus tracker. Owns AXObservers on the focused app and on `overlay` apps (PLT-R380), treats the
/// system-wide AX focus as authoritative (PLT-R381), resolves rules and per-app mode, and publishes a
/// `FocusSnapshot` plus the current generation before the next key is processed (PLT-R391).
///
/// Every public method may be called from any thread: it hops to the ax thread (`RunLoopThread.perform`) and
/// returns. Rules are resolved only when the focus context changes or rules/settings change (PLT-R523). The
/// state lives in `FocusCore` (FocusCore*.swift), confined to the ax thread.
public final class FocusTracker: Sendable {
    let thread: RunLoopThread
    let core: ThreadConfined<FocusCore>
    let mirror = FocusMirror()

    public init(
        thread: RunLoopThread, ax: any AXProvider, processes: any ProcessIdentityProvider,
        output: SnapshotCell<FocusSnapshot>, generation: CurrentFocusGeneration, inbox: SPSCRing<AXNotice>,
        metrics: PlatformMetrics, health: HealthEventLog, clock: any MonotonicClock, macOSVersion: LooseVersion,
        capture: CaptureController? = nil, signposts: PlatformSignposts? = nil, scheduler: (any TimerScheduler)? = nil
    ) {
        self.thread = thread
        let services = FocusCore.Services(
            thread: thread, ax: ax, processes: processes, output: output, generation: generation, inbox: inbox,
            metrics: metrics, health: health, clock: clock, macOSVersion: macOSVersion, capture: capture,
            signposts: signposts, scheduler: scheduler)
        core = ThreadConfined(FocusCore(services: services, mirror: mirror))
    }

    public func start(rules: any FocusDecisionResolving, memory: AppModeMemory) {
        perform { [self] core in core.start(sink: self, rules: rules, memory: memory) }
    }

    public func stop() { perform { $0.stop() } }
    /// Hop to the ax thread; re-resolve the current focus (rules or overrides changed, PLT-R540 acceptance).
    public func update(rules: any FocusDecisionResolving) { perform { $0.update(rules: rules) } }
    public func update(settings: EffectiveSettings, appModes: AppModesDocument) {
        perform { $0.update(settings: settings, appModes: appModes) }
    }

    /// NSWorkspace activation and wake (PLT-R381): rescan overlay apps and revalidate system-wide focus. The
    /// idle-key flag (PLT-R382) arrives through the inbox and revalidates without the rescan.
    public func revalidate() { perform { $0.revalidate(scanOverlays: true) } }
    /// Drains `inbox` (tap toggles first, then revalidation) on the ax thread; wired to the AX wake signal.
    public func drainInbox() { perform { $0.drainInbox() } }

    /// Menu radio or click-to-toggle (D16): same memory update as a hotkey toggle, without a tap sequence
    /// (PRD-R20).
    public func setMode(_ mode: TypingMode) { perform { $0.setMode(mode) } }

    /// Receives every changed `app-modes.json` document (on the ax thread) so the owner can persist it through
    /// `SettingsStore.recordAppModes` (PLT-R392, PRD-R23).
    public func setMemoryObserver(_ observer: (@Sendable (AppModesDocument) -> Void)?) {
        perform { $0.memoryObserver = observer }
    }

    /// Called on the ax thread after a settle re-read or an observer retry published a snapshot (PLT-R391), so the
    /// main thread follows like it does after a notification (`FocusChangeSignalingAXProvider`). Must not block.
    public func setDeferredPublicationObserver(_ observer: (@Sendable () -> Void)?) {
        perform { $0.deferred.publicationObserver = observer }
    }

    /// Rule decision behind the last published snapshot, for the diagnostics report (any thread).
    public func currentDecision() -> ResolvedDecision? { mirror.decision }

    /// Bundles on which `AXManualAccessibility` was set because a rule asked for it (PLT-R385 "record that it
    /// did"; any thread).
    public func manualAccessibilityBundles() -> Set<BundleKey> { mirror.manualAccessibility }
}

/// Conversion done once per focus change (rule decision -> tap decision), PLT-R386 `byEngine` resolution.
/// A shipped `paste` strategy that needs an opt-in the user has not given falls back to the first non-paste
/// strategy of the rule's chain (PLT-R460). Logic: `HostDecisionMapping.swift`.
public enum HostDecisionMapper {
    public static func map(_ decision: ResolvedDecision, engine: EngineFingerprint, optedIntoPaste: Bool)
        -> HostDecision
    {
        HostDecisionMapping.map(decision, engine: engine, optedIntoPaste: optedIntoPaste)
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/InputHost/Memory/AppModeMemory.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Per-app VI/EN memory (PLT-R390-R393, PRD-R19-R23). A value type owned by the ax thread; persisted through
// SettingsStore (`recordAppModes`, 5 s debounce).

public import AppModel
public import SettingsStore

public struct ModeResolution: Sendable, Hashable {
    public var mode: TypingMode
    public var source: ModeSource
    /// "Bỏ qua ứng dụng này": the app sees raw keys and the toggle does nothing (PRD-R21); implemented as a
    /// user override with strategy `passThrough` (PLT-R390).
    public var ignored: Bool

    public init(mode: TypingMode, source: ModeSource, ignored: Bool) {
        self.mode = mode
        self.source = source
        self.ignored = ignored
    }
}

/// Entries are kept most recently used first, as in `app-modes.json`. "Remembered" entries are those without an
/// explicit rule (`nil` or `.remember`); only they count towards the 1,000 limit and only they are evicted.
/// With `rememberPerApp` off (D12), memory and rule defaults are not used, explicit rules still are. The first
/// focus of an unknown app records the mode it got (D13 "seen for the first time"). Logic:
/// `AppModeMemory+Logic.swift`.
public struct AppModeMemory: Sendable, Hashable {
    var global: TypingMode
    var rememberPerApp: Bool
    var firstSeen: FirstSeenMode
    var entries: [AppModeEntry]

    public init(document: AppModesDocument, rememberPerApp: Bool, firstSeen: FirstSeenMode) {
        global = document.globalMode
        self.rememberPerApp = rememberPerApp
        self.firstSeen = firstSeen
        entries = Self.normalized(document.apps)
    }

    /// PRD-R21: ignore > always English > always Vietnamese > remembered > rule `defaultMode` / D13 > global.
    public func resolve(bundle: BundleKey?, ruleDefault: FirstSeenMode) -> ModeResolution {
        resolution(bundle: bundle, ruleDefault: ruleDefault)
    }

    /// Manual toggle while `bundle` is the focus owner (PRD-R20). Updates the global mode too.
    public mutating func recordToggle(bundle: BundleKey?, mode: TypingMode) { applyToggle(bundle: bundle, mode: mode) }

    /// Most-recently-used ordering for the Apps pane; LRU eviction at 1,000 remembered entries (PLT-R392).
    public mutating func touch(_ bundle: BundleKey) { moveToFront(bundle) }

    public mutating func setRule(_ rule: PerAppRule?, for bundle: BundleKey) { applyRule(rule, for: bundle) }

    public var globalMode: TypingMode { global }
    public func document() -> AppModesDocument { AppModesDocument(globalMode: global, apps: entries) }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/InputHost/Permissions/Permissions.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Permissions (PLT-R701-R741). Probes are cheap system calls made off the tap thread.

public import AppModel
internal import Foundation
public import RealtimeSupport
public import SettingsStore

/// Production (`SystemPermissionProbe`): `AXIsProcessTrusted()`, `CGPreflightPostEventAccess()`,
/// `CGPreflightListenEventAccess()`, `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`,
/// `CGRequestListenEventAccess()`, `CGRequestPostEventAccess()`; the signing identity digest comes from
/// `SecCodeCopySelf` + `SecCodeCopyDesignatedRequirement`.
///
/// PLT-R701: `AXIsProcessTrusted()` follows the switch live. The two CoreGraphics preflights keep the answer they
/// had when the process started (Apple DTS on the developer forums, threads 727984 and 720840), so they never
/// decide on their own that a permission is still missing; `canListenToEventsNow()` is the live Input Monitoring
/// check.
public protocol PermissionProbe: Sendable {
    func isAccessibilityTrusted() -> Bool
    func canPostEvents() -> Bool
    /// `CGPreflightListenEventAccess()`: the Input Monitoring answer at launch.
    func canListenToEvents() -> Bool
    /// PLT-R702, PLT-R731: Input Monitoring as it is now, by creating a listen-only key tap and releasing it at
    /// once (a passive tap never holds keys back). Creating a tap for keys can make macOS prompt for Input
    /// Monitoring, so the monitor calls this only once it knows the tap needs that permission.
    func canListenToEventsNow() -> Bool
    func promptForAccessibility()
    func requestListenEventAccess() -> Bool
    func requestPostEventAccess() -> Bool
    /// Digest of the designated requirement, to detect `stale` grants after OS updates (PLT-R720).
    func signingIdentityDigest() -> String?
}

public struct PermissionStatus: Sendable, Hashable {
    public enum Health: String, Sendable, Hashable { case ready, noPermission, stale }
    public var accessibility: PermissionState
    public var postEvent: PermissionState
    public var listenEvent: PermissionState
    /// Input Monitoring needed and still missing: the tap could not be created while Accessibility is granted and
    /// neither the launch-time preflight nor the live check sees Input Monitoring (PLT-R702).
    public var listenEventRequired: Bool
    public var health: Health
    public init(
        accessibility: PermissionState, postEvent: PermissionState, listenEvent: PermissionState,
        listenEventRequired: Bool, health: Health
    ) {
        self.accessibility = accessibility
        self.postEvent = postEvent
        self.listenEvent = listenEvent
        self.listenEventRequired = listenEventRequired
        self.health = health
    }
}

/// Every 2 s while not ready, every 30 s while ready (timers from the injected scheduler, utility queue in
/// production), immediately on wake, session activation and menu open (PLT-R721). Remembers the identity digest
/// of the last grant (key-value store) for `stale`.
///
/// `onChange` runs for the first check after `start()` and then whenever the status changes, in check order,
/// one at a time and outside the check lock: it may call back into the monitor (`checkNow`, `setTapUnavailable`);
/// a status produced meanwhile is delivered after it returns. Logic: `PermissionMonitor+Checks.swift`.
public final class PermissionMonitor: Sendable {
    public static let notReadyInterval: TimeSpan = .seconds(2)
    public static let readyInterval: TimeSpan = .seconds(30)
    public static let onboardingInterval: TimeSpan = .seconds(1)
    /// PLT-R711: fast polling stops by itself after 5 minutes.
    public static let onboardingLimit: TimeSpan = .seconds(300)
    /// `KeyValueStore` key of the last granted identity (a 52-bit hash of the designated requirement digest).
    public static let lastGrantedDigestKey = "PermissionLastGrantedIdentity"

    let probe: any PermissionProbe
    let store: any KeyValueStore
    let scheduler: any TimerScheduler
    let delivery: OrderedDelivery<PermissionStatus>
    let state = Mutex(PermissionMonitorState())

    public init(
        probe: any PermissionProbe, store: any KeyValueStore, scheduler: any TimerScheduler,
        onChange: @escaping @Sendable (PermissionStatus) -> Void
    ) {
        self.probe = probe
        self.store = store
        self.scheduler = scheduler
        self.delivery = OrderedDelivery(onChange)
    }

    public func start() { beginChecks() }
    public func stop() { endChecks() }
    /// Checks at once and returns the newest status. When the check runs on main its status is delivered inside the
    /// call, and that delivery may already have replaced it (a `ready` whose tap failed, PLT-R702): the replacement
    /// is returned then, never the replaced status, so a caller that records or feeds the result (menu open, wake,
    /// PLT-R721) agrees with what the receivers were told.
    public func checkNow() -> PermissionStatus {
        let status = check()
        return latest ?? status
    }
    /// The status of the most recent check, already set while an older status is still being delivered. A receiver
    /// that forwards statuses compares the one in hand with this and drops it when a newer one is queued behind it,
    /// so a `ready` replaced during its own delivery (the tap it allowed failed, PLT-R702) never reaches the UI
    /// after its replacement (PRD-R40 screen 2). `nil` before the first check.
    public var latest: PermissionStatus? { state.withLock { $0.last } }
    /// Onboarding polls every 1 s for at most 5 minutes while visible (PLT-R711).
    public func setFastPolling(_ enabled: Bool) { updateFastPolling(enabled) }
    /// The lifecycle reports that the tap could not be created. With Accessibility granted and Input Monitoring
    /// missing (launch-time preflight and live check) this sets `listenEventRequired` (PLT-R702); the live check
    /// clears it when the user turns Input Monitoring on while the app runs (PLT-R731).
    public func setTapUnavailable(_ unavailable: Bool) { updateTapUnavailable(unavailable) }
}

extension PermissionProbe {
    /// A probe without a live check answers with the launch-time preflight. A wrapper forwards the live check
    /// explicitly (`RevocablePermissionProbe`), or this default would hide the wrapped probe's.
    public func canListenToEventsNow() -> Bool { canListenToEvents() }
}

/// "Đặt lại quyền" (PLT-R740): runs `/usr/bin/tccutil reset Accessibility <own bundle ID>` after the user
/// confirms. Never automatic, never without a bundle ID (PLT-R741), never with sudo.
public protocol PermissionResetting: Sendable {
    func resetAccessibility(bundleIdentifier: String) throws
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/InputHost/Workspace/Workspace.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later

public import AppModel

public enum WorkspaceEvent: Sendable, Hashable {
    case applicationActivated(pid: Int32)  // revalidation trigger only (PLT-R381)
    case willSleep, didWake  // PLT-R333
    case sessionResignedActive, sessionBecameActive  // Fast User Switching (PLT-R333)
    case screenLocked, screenUnlocked
}

/// Production (`NSWorkspaceEvents`): `NSWorkspace.shared.notificationCenter` for
/// `didActivateApplicationNotification`, `willSleepNotification`, `didWakeNotification`,
/// `sessionDidResignActiveNotification`, `sessionDidBecomeActiveNotification`, and
/// `DistributedNotificationCenter` for the screen lock and unlock notifications (names in
/// `ReverseDNSConstants.swift`, allowed by scripts/lint-bundle-ids.allow).
@MainActor
public protocol WorkspaceEvents: Sendable {
    func observe(_ handler: @escaping @MainActor @Sendable (WorkspaceEvent) -> Void) -> any ObservationToken
}

/// Another Vietnamese input method running, or a built-in Vietnamese source enabled (PLT-R399, onboarding
/// screen 5). The app never terminates or modifies other apps.
public enum ConflictingInput: Sendable, Hashable {
    case runningApp(bundle: BundleKey, name: String)
    case builtInVietnameseSource(id: InputSourceID, name: String)
}

/// Pure: each conflicting app once (by bundle) in `running` order, then each enabled Vietnamese input source once.
public enum ConflictDetector {
    public static func detect(
        running: [ProcessIdentity], enabledSources: [InputSourceInfo], conflictingApps: Set<BundleKey>
    ) -> [ConflictingInput] {
        var seenApps = Set<BundleKey>()
        let apps = running.filter { conflictingApps.contains($0.bundle) && seenApps.insert($0.bundle).inserted }
            .map { ConflictingInput.runningApp(bundle: $0.bundle, name: $0.localizedName ?? $0.processName) }
        var seenSources = Set<InputSourceID>()
        let sources = enabledSources.filter { $0.isBuiltInVietnamese && seenSources.insert($0.id).inserted }
            .map { ConflictingInput.builtInVietnameseSource(id: $0.id, name: $0.localizedName) }
        return apps + sources
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/InputHost/Probes/Probes.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Diagnostics drivers that type into the user's Mac. They exist for the product owner to run by hand from the
// Diagnostics window; automated tests use fakes only. Wave-2 contract (workstream W2-C).
//
// Every event these drivers post carries the probe kind of the event marker (bit 23, PLT-R321): the tap
// processes it as physical and routes its metrics to the probe histograms, so user metrics exclude it
// (PLT-R810), and it can never be mistaken for the worker's own echo (ADR 0311). The blocking pacing runs on a
// dedicated thread, never on the tap or the main thread.

public import AppModel
public import CompatRules
public import Diagnostics
public import Injection
public import RealtimeSupport

/// PLT-R810: posts physical-like key events tagged with the probe marker (processed by the pipeline as
/// physical, excluded from user metrics) into the probe window's text view with the three timing profiles.
public final class LatencyProbeDriver: Sendable {
    let poster: any EventPoster
    let marker: EventMarker
    let clock: any MonotonicClock
    let sequence = ProbeSequence()
    let changes = Mutex<[LatencyProbeObservedChange]>([])
    /// How long after the last key the driver keeps collecting text changes.
    let settle: TimeSpan

    public convenience init(poster: any EventPoster, marker: EventMarker, clock: any MonotonicClock) {
        self.init(poster: poster, marker: marker, clock: clock, settle: .milliseconds(150))
    }

    init(poster: any EventPoster, marker: EventMarker, clock: any MonotonicClock, settle: TimeSpan) {
        self.poster = poster
        self.marker = marker
        self.clock = clock
        self.settle = settle
    }

    /// Pass-through run: types `keys` (key codes from the current layout) with `profile` spacing and returns one
    /// sample per key. Every key changes the text once and the window applies keys in order, so the k-th text
    /// change belongs to the k-th delivered key, however late it arrives (a time window would credit a late
    /// change to the next key in the burst profile). `shouldContinue` is read before every key on the typing
    /// thread; once it returns false nothing more is posted.
    public func run(
        profile: LatencyProbeResult.Profile, keys: [KeyCode],
        shouldContinue: @escaping @Sendable () -> Bool = { true }
    ) async -> [LatencyProbeSample] {
        let (posted, observed) = await type(keys, profile: profile, shouldContinue: shouldContinue)
        return LatencyProbeMath.correlate(posted, changes: observed.map(\.instant))
    }

    /// Measured run: returns the samples of the keys at `edits` (indices into `keys`), each matched in order to
    /// a change that shows the composed character (`LatencyProbeChange.composed`). The deletion half of an
    /// edit and the plain keys around it are not counted (PLT-R810 T4).
    public func run(
        profile: LatencyProbeResult.Profile, keys: [KeyCode], edits: [Int],
        shouldContinue: @escaping @Sendable () -> Bool = { true }
    ) async -> [LatencyProbeSample] {
        let (posted, observed) = await type(keys, profile: profile, shouldContinue: shouldContinue)
        let editKeys = edits.compactMap { posted.indices.contains($0) ? posted[$0] : nil }
        let composed = observed.filter { $0.kind == .composed }.map(\.instant)
        return LatencyProbeMath.correlate(editKeys, changes: composed)
    }

    private func type(
        _ keys: [KeyCode], profile: LatencyProbeResult.Profile, shouldContinue: @escaping @Sendable () -> Bool
    ) async -> ([LatencyProbePostedKey], [LatencyProbeObservedChange]) {
        changes.withLock { $0.removeAll() }
        let posted = await DedicatedThread.run(name: "latency-probe") {
            self.postAll(keys, every: profile.keyInterval, shouldContinue: shouldContinue)
        }
        return (posted, changes.withLock { $0 })
    }

    /// Called by the probe window (main thread) for every text change of its text view; `kind` tells whether
    /// the text now ends with the composed character of the measured run (`LatencyProbeScript.composed`).
    public func textChanged(at instant: MonotonicInstant, kind: LatencyProbeChange = .plain) {
        changes.withLock { $0.append(LatencyProbeObservedChange(instant: instant, kind: kind)) }
    }

    /// T2 from the probe decide-to-posted histogram recorded during the measured run (`decideToPosted`), T4 as
    /// the measured text-change latency minus the pass-through baseline of the same profile (02-platform.md
    /// 8.1), both at p50 and p99 in microseconds.
    public func result(
        profile: LatencyProbeResult.Profile, baseline: [LatencyProbeSample], measured: [LatencyProbeSample],
        decideToPosted: HistogramSnapshot
    ) -> LatencyProbeResult.ProfileResult {
        LatencyProbeMath.result(
            profile: profile, baseline: baseline, measured: measured, decideToPosted: decideToPosted)
    }
}

/// What a text change of the probe window shows: the composed character of the measured run (the visible
/// result of an edit) or anything else (a pass-through key, the deletion half of an edit, a space).
public enum LatencyProbeChange: Sendable, Hashable {
    case plain
    case composed

    /// Classifies the probe text view's content after a change.
    public init(text: String) {
        self = text.last == LatencyProbeScript.composed ? .composed : .plain
    }
}

struct LatencyProbeObservedChange: Sendable, Hashable {
    var instant: MonotonicInstant
    var kind: LatencyProbeChange
}

/// A key the driver typed: when, and whether the poster accepted it (an undelivered key has no change).
struct LatencyProbePostedKey: Sendable, Hashable {
    var instant: MonotonicInstant
    var delivered: Bool
}

/// Stop request for a driver that types into the user's Mac (PLT-R1205, PLT-R810, PLT-R387). The main thread
/// sets it (Stop, window closed, app switched); the dedicated typing thread reads the flag before every event
/// and runs the focus check before every step. A failed focus check latches the stop.
public final class ProbeStopSignal: Sendable {
    private let stopped = Atomic<Bool>(false)
    private let stillFocused: @Sendable () -> Bool

    /// `stillFocused` answers whether the field under test still has keyboard focus (bounded AX call,
    /// PLT-R342); it runs on the typing thread, never on the main thread.
    public init(stillFocused: @escaping @Sendable () -> Bool = { true }) {
        self.stillFocused = stillFocused
    }

    public func stop() { stopped.store(true, ordering: .releasing) }

    public var isStopped: Bool { stopped.load(ordering: .acquiring) }

    /// False once stopped; otherwise runs the focus check and stops when it fails.
    public func shouldContinue() -> Bool {
        guard !isStopped else { return false }
        guard stillFocused() else {
            stop()
            return false
        }
        return true
    }
}

/// PLT-R1205 step 3: candidate strategies tried in a field the user confirmed is empty and safe.
public struct GuidedTestCandidate: Sendable, Hashable {
    public var strategy: InjectionStrategy
    public var inlineCompletion: InlineCompletionMode
    public var interEventDelayUs: Int  // 0, 2,000, 5,000
    public init(strategy: InjectionStrategy, inlineCompletion: InlineCompletionMode, interEventDelayUs: Int) {
        self.strategy = strategy
        self.inlineCompletion = inlineCompletion
        self.interEventDelayUs = interEventDelayUs
    }
}

public enum GuidedTestCandidateResult: Sendable, Hashable {
    case passedByReadback
    case failedByReadback(residue: Bool)
    case needsHumanAnswer  // "Do you see 'đá â'? Yes / No"
    case humanSaidYes, humanSaidNo
    /// The readable field was not empty before typing (for example residue of an earlier candidate): nothing
    /// was typed. The test never types into a field with content.
    case fieldNotEmpty
    /// The stop signal fired (Stop, panel closed, focus moved) before the candidate finished: typing ended at
    /// once and nothing was removed, so no backspace can reach another field (PLT-R1205 step 3, PLT-R387).
    case stopped
}

public final class GuidedTestRunner: Sendable {
    let poster: any EventPoster
    let fieldAccess: any FocusedFieldAccess
    let marker: EventMarker
    let clock: any MonotonicClock
    /// Read when a run or removal starts, so a runner kept for the process lifetime follows input source
    /// changes (PLT-R405, PLT-R373).
    let currentLayout: @Sendable () -> LayoutTable?
    let sequence = ProbeSequence()

    /// Current strategy first, then the PLT-R1205 list: `backspaceReplace` with `axSelection`, with
    /// `placeholder`, `selectReplace`, `axReplace` for native apps, then the current strategy paced at 2 and
    /// 5 ms. Without a known current strategy the default plan stands in for it.
    public static func candidates(isNativeApp: Bool) -> [GuidedTestCandidate] {
        GuidedTestPlans.candidates(current: nil, isNativeApp: isNativeApp)
    }

    /// Same list with the focused field's current plan first (PLT-R1205 step 3 "current strategy").
    public static func candidates(current: InjectionPlan?, isNativeApp: Bool) -> [GuidedTestCandidate] {
        GuidedTestPlans.candidates(current: current, isNativeApp: isNativeApp)
    }

    public convenience init(
        poster: any EventPoster, fieldAccess: any FocusedFieldAccess, marker: EventMarker, clock: any MonotonicClock
    ) {
        self.init(poster: poster, fieldAccess: fieldAccess, marker: marker, clock: clock, layout: nil)
    }

    /// `layout` supplies the key codes of the canary keys (PLT-R405); without it the US positions are used.
    public convenience init(
        poster: any EventPoster, fieldAccess: any FocusedFieldAccess, marker: EventMarker, clock: any MonotonicClock,
        layout: LayoutTable?
    ) {
        self.init(poster: poster, fieldAccess: fieldAccess, marker: marker, clock: clock, currentLayout: { layout })
    }

    /// `currentLayout` is read at the start of every run and removal, so the canary's key codes match the layout
    /// in use at that moment (PLT-R405); nil falls back to the US positions.
    public init(
        poster: any EventPoster, fieldAccess: any FocusedFieldAccess, marker: EventMarker, clock: any MonotonicClock,
        currentLayout: @escaping @Sendable () -> LayoutTable?
    ) {
        self.poster = poster
        self.fieldAccess = fieldAccess
        self.marker = marker
        self.clock = clock
        self.currentLayout = currentLayout
    }

    /// Types the canary "đá â" with `candidate`, reads it back through AX when possible and removes it again
    /// with the same strategy, reporting residue (PLT-R1205 step 3, PLT-R410). When the field cannot be read the
    /// text stays for the user to judge: the result is `.needsHumanAnswer` and `removeTestText` follows the
    /// answer. `stop` is checked before every event and its focus check before every step and before the
    /// removal; once it fires the result is `.stopped` and nothing more is posted.
    public func run(
        _ candidate: GuidedTestCandidate, field: FieldHandle?, stop: ProbeStopSignal = ProbeStopSignal()
    ) async -> GuidedTestCandidateResult {
        await DedicatedThread.run(name: "guided-test") { self.typeAndVerify(candidate, field: field, stop: stop) }
    }

    /// Removes the canary after a human answer. Returns whether text remained (nil when the field cannot be
    /// read, or when `stop` fired and nothing was removed).
    public func removeTestText(
        _ candidate: GuidedTestCandidate, field: FieldHandle?, stop: ProbeStopSignal = ProbeStopSignal()
    ) async -> Bool? {
        await DedicatedThread.run(name: "guided-test") { self.remove(candidate, field: field, stop: stop) }
    }

    /// Rule suggestion in the 5.4 schema (PLT-R1205 step 4); a URL prefix only if the user ticked "include page
    /// address" and edited it down to a host-level prefix. The suggestion is shown and copied on its own; the
    /// diagnostics report never contains its URL (ADR 0312).
    public static func suggestion(
        context: MatchContext, best: GuidedTestCandidate, appVersion: String?, macOS: String, date: String,
        includeURLPrefix: String?
    ) -> Rule {
        GuidedTestSuggestion.rule(
            context: context, best: best, appVersion: appVersion, macOS: macOS, date: date,
            includeURLPrefix: includeURLPrefix)
    }
}

/// Probe-kind marker sequence shared by one driver's events (23 bits, wraps).
final class ProbeSequence: Sendable {
    private let value = Atomic<UInt32>(0)
    func next() -> UInt32 { value.wrappingAdd(1, ordering: .relaxed).newValue & EventMarker.sequenceMask }
}
```
<!-- /include -->

## 11. ShellCore

Owned files: `Packages/AppCore/Sources/ShellCore/**`, `Tests/ShellCoreTests/**` (workstream W1-G).
Isolation: values are any; `InterfaceLanguageModel` and `UpdaterControlling` are main-actor.

### 11.1 Runtime UI-language switch (PRD-R63)

Strings are looked up per **selected** language, not per system language. Xcode compiles each String Catalog
in `App/Resources/Localization/` into `vi.lproj/<Table>.strings` and `en.lproj/<Table>.strings(dict)` (the
skeleton build shows `vi.lproj/Localizable.strings` and `en.lproj/Localizable.strings` in the bundle). `Localizer`
opens `Bundle(path: appBundle.path(forResource: language.rawValue, ofType: "lproj"))` and calls
`localizedString(forKey:value:table:)` on that sub-bundle, so `Bundle.main`'s preferred localization (which
follows macOS) is never consulted. Formatting uses `String(format:locale:arguments:)` with the selected
`Locale`, so `.stringsdict` plurals and number formats follow the selected language (PRD-R65). The app name is
always an argument (`"onboarding.welcome.title" = "Chào mừng bạn đến với %@"`). `InterfaceLanguageModel` is an
`ObservableObject` (ADR 0315: `@Observable` needs macOS 14); when settings change D18 it swaps the `Localizer`,
SwiftUI views (which hold it, or a model relaying its changes, as `@ObservedObject` and render
`Text(verbatim: localizer.string(...))`) re-render, AppKit menus are rebuilt on their next open, the status
item's accessibility label and open window titles are refreshed. Sparkle's own update window follows macOS
localization and Sparkle picks localized release notes by the macOS language, so each release links one
bilingual notes page, Vietnamese first (PRD-R51, [0304](../decisions/0304-sparkle-version-pin.md) amendment).
System pane names come from `SystemPaneTable` in the macOS language (PRD-R64).

Status lines (PRD-R43, section 6 of 02-platform.md): `StatusLine.forState` takes the host state, the secure-input
holder hint, the app name, the frontmost app's `FrontmostAppStatus` (matrix status and one-line limitation note
from `compat-matrix.json`) and whether the tap was just re-enabled, so it can produce every row of the PRD-R43
table, including "App in Known limitation list" and "paused: no text field detected" with the one-click
`.overrideTextFocus(bundle:)` action (a user override with `requireTextFocus: never`, PLT-R540). With
`safeMode: true` (`SettingsState.safeMode`, PLT-R1009) it shows `status.safeMode` with the
`.safeModeChoices` action, which opens the safe-mode alert (reset, use the saved settings, report), below the
host-state lines and above the tap notice and the known limitation. Because a host-state line (for example
`paused(noTextFocus)` when the menu is opened from the desktop) can hide the safe-mode line,
`DiagnosticsNavigation.destination(reportProblemFor:lastFrontmost:safeMode:)` returns `.safeModeChoices` for both
report items while in safe mode, and `pathToSafeModeChoices(menu:safeMode:)` pins that the choices stay at most
two clicks away under every host state. `paused(diagnosticsTest)` shows no line:
the guided test's panel says what is happening.

Bug report paths (PRD-R47): GitHub uses `Brand.repositoryURL` (nil hides the button); email builds a
`MailDraft` that the App sends with `NSSharingService(named: .composeEmail)` including the JSON report as an
attachment, falling back to `mailtoURL` (subject and body only) when no mail service exists.

Report flows (W3-B): the menu's `Báo lỗi...`, the status line's `Báo lỗi...` and the safe-mode report choice
open the bug report sheet (`DiagnosticsWindowController.openBugReport(preselected:)`); `Báo lỗi với ứng dụng
này...` opens the misbehaves panel (PLT-R1205). The picker lists `RecentReportApps.choices` (the Apps pane's
apps, most recent first, without this app, at most 20) and preselects the last frontmost app
(`RecentReportApps.preselection`). The sheet reads the host context once when it opens
(`DiagnosticsServices.reportSession`), so later choices never report the sheet's own window as the focus.
Every preview shows exactly what its paths write (`ReportPreviewFormat`, PLT-R1204): the ADR 0501 block for
Copy report and Open GitHub, the JSON file for Send by email and Save file. The report's health events are the
earlier sessions' events from the log followed by this session's (`HealthEvent.reportList`, PRD-R46).

<!-- include: Packages/AppCore/Sources/ShellCore/Brand.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The single runtime source of the product name (CLAUDE.md "Name (temporary)"). Values come from Info.plist
// keys that project.yml fills from Config/Brand.xcconfig; nothing here is hard-coded. Implemented in the
// skeleton because the App reads it at launch (ADR 0313); workstream W1-G owns it.

internal import AppModel
public import Foundation

public struct Brand: Sendable, Hashable {
    /// Info.plist keys (App/Info.plist): `CFBundleDisplayName` = $(APP_DISPLAY_NAME), `AppSlug` = $(APP_SLUG),
    /// `AppSiteHost` = $(APP_SITE_HOST), `AppSupportEmail` = $(APP_SUPPORT_EMAIL),
    /// `AppRepositoryURL` = $(APP_REPOSITORY_URL), `AppLegacyStorageFolderNames` =
    /// $(APP_LEGACY_STORAGE_FOLDER_NAMES) (semicolon-separated, ADR 0307).
    public enum InfoKey {
        public static let displayName = "CFBundleDisplayName"
        public static let slug = "AppSlug"
        public static let siteHost = "AppSiteHost"
        public static let supportEmail = "AppSupportEmail"  // VERIFY with Pa (QA-R51)
        public static let repositoryURL = "AppRepositoryURL"  // VERIFY with Pa (PRD-R47, QA-R60)
        public static let legacyStorageFolderNames = "AppLegacyStorageFolderNames"
        public static let bundleIdentifier = "CFBundleIdentifier"
        public static let version = "CFBundleShortVersionString"
        public static let build = "CFBundleVersion"
    }

    public var displayName: String
    public var slug: String
    public var siteHost: String
    public var bundleIdentifier: String
    public var version: String  // CFBundleShortVersionString
    public var build: String  // CFBundleVersion
    public var supportEmail: String?
    /// GitHub repository for issue forms; nil until Pa decides (the GitHub path is hidden then).
    public var repositoryURL: URL?
    /// Storage folder names used by earlier product names, newest first, for the one-time move after a rename
    /// (ADR 0307, `LegacyStorageMigrator`).
    public var legacyStorageFolderNames: [String]

    public init(
        displayName: String, slug: String, siteHost: String, bundleIdentifier: String, version: String, build: String,
        supportEmail: String?, repositoryURL: URL? = nil, legacyStorageFolderNames: [String] = []
    ) {
        self.displayName = displayName
        self.slug = slug
        self.siteHost = siteHost
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.build = build
        self.supportEmail = supportEmail
        self.repositoryURL = repositoryURL
        self.legacyStorageFolderNames = legacyStorageFolderNames
    }

    /// Reads the bundle; traps with a clear message if a required key is missing or empty (a build
    /// configuration error, never a user-facing state).
    public static func from(_ bundle: Bundle) -> Brand {
        from(info: bundle.infoDictionary ?? [:])
    }

    /// Same as `from(_:)` over a plain dictionary (tests).
    public static func from(info: [String: Any]) -> Brand {
        func required(_ key: String) -> String {
            guard let value = info[key] as? String, !value.isEmpty, !value.hasPrefix("$(") else {
                preconditionFailure("Info.plist key \(key) is missing; check Config/Brand.xcconfig and App/Info.plist")
            }
            return value
        }
        func optional(_ key: String) -> String? {
            guard let value = info[key] as? String, !value.isEmpty, !value.hasPrefix("$(") else { return nil }
            return value
        }
        let repository = optional(InfoKey.repositoryURL).flatMap { value -> URL? in
            guard let url = URL(string: value), url.scheme == "https", url.host != nil else { return nil }
            return url
        }
        let legacy = (optional(InfoKey.legacyStorageFolderNames) ?? "")
            .split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return Brand(
            displayName: required(InfoKey.displayName), slug: required(InfoKey.slug),
            siteHost: required(InfoKey.siteHost), bundleIdentifier: required(InfoKey.bundleIdentifier),
            version: optional(InfoKey.version) ?? "0", build: optional(InfoKey.build) ?? "0",
            supportEmail: optional(InfoKey.supportEmail), repositoryURL: repository,
            legacyStorageFolderNames: legacy)
    }

    /// Folder name under Application Support and Logs: the display name if it is pure ASCII, else the slug
    /// (PLT-R903). Frozen at the first public release (docs/decisions/0307-settings-file-layout.md).
    public var storageFolderName: String { Self.folderName(displayName: displayName, slug: slug) }

    /// PLT-R903 rule, shared with the legacy-folder migration.
    public static func folderName(displayName: String, slug: String) -> String {
        displayName.allSatisfy(\.isASCII) ? displayName : slug
    }

    public var siteURL: URL { URL(string: "https://\(siteHost)/")! }
    /// URL scheme that may only open Settings (PLT-R909).
    public var urlScheme: String { slug }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/ShellCore/Localization.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Runtime UI-language switch without restart (PRD-R63, docs/architecture/contracts.md "Localisation").
//
// Strings live in String Catalogs (`App/Resources/Localization/*.xcstrings`, one table per feature area so
// parallel workstreams never edit the same file). Xcode compiles each catalog into `vi.lproj/<Table>.strings`
// and `en.lproj/<Table>.strings(dict)`. Lookup NEVER relies on the process's preferred languages: the
// `Localizer` opens the `.lproj` sub-bundle of the language selected in Settings (D18) and resolves every key
// there, so switching language re-renders immediately and is independent of the macOS language.

public import AppModel
public import Combine
public import Foundation
public import RealtimeSupport

/// String tables (catalog file names). Owned per workstream (docs/architecture/workstreams.md).
public enum StringTable: String, Sendable, CaseIterable {
    /// Buttons and app-wide words. Named `Localizable` because it is the default table (ADR 0310).
    case common = "Localizable"
    case menu = "Menu"  // status item, menu, HUD, VoiceOver labels (PRD-R10, PRD-R11)
    case status = "Status"  // status lines and error states (PRD-R43), secure-input hints (PLT-R397)
    case onboarding = "Onboarding"  // PRD-R40 screens 1-8
    case settings = "Settings"  // five panes (PRD-R24, PRD-R25)
    case macros = "Macros"  // section 8
    case apps = "Apps"  // section 9
    case diagnostics = "Diagnostics"  // PLT-R1201, PLT-R1205, PRD-R47
    case support = "Support"  // About & Support, donation block (PRD-R59)
    case updates = "Updates"  // PRD-R50-R54
    case composition = "Composition"  // composition root notices: safe mode, move failed, conflicts
    #if DEV_RECORDER
    case devRecorder = "DevRecorder"  // PLT-R904A dev builds' typing recorder; the catalog ships in Debug builds only
    #endif
}

/// Resolves keys for one language. Immutable; a new instance is created on language change.
public struct Localizer: Sendable {
    public let language: InterfaceLanguage
    public let locale: Locale
    private let selected: Bundle?
    private let fallback: Bundle?

    /// `appBundle` contains `vi.lproj` and `en.lproj`.
    public init(language: InterfaceLanguage, appBundle: Bundle) {
        self.language = language
        locale = Self.locale(for: language)
        selected = Self.languageBundle(language, in: appBundle)
        // ADR 0310: a key missing in the selected language falls back to Vietnamese, the source language.
        fallback = language == .vietnamese ? nil : Self.languageBundle(.vietnamese, in: appBundle)
    }

    /// Looks up `key` in `table` of the selected language's lproj; falls back to Vietnamese, then to the key
    /// itself (a missing key is a test failure, never a crash).
    public func string(_ key: String, table: StringTable) -> String {
        if let value = Self.lookup(key, table: table, in: selected) { return value }
        if let value = Self.lookup(key, table: table, in: fallback) { return value }
        return key
    }

    /// True when the selected language or the Vietnamese fallback defines `key` (data-driven keys such as
    /// secure-input hints are shown only when copy exists, PLT-R397).
    public func contains(_ key: String, table: StringTable) -> Bool {
        Self.lookup(key, table: table, in: selected) != nil || Self.lookup(key, table: table, in: fallback) != nil
    }

    /// Format with arguments (the app name is always an argument, never part of the copy):
    /// `String(format:locale:arguments:)` over the localized format, so `.stringsdict` plural rules apply.
    public func format(_ key: String, table: StringTable, _ arguments: any CVarArg...) -> String {
        format(key, table: table, arguments: arguments)
    }

    /// Array form of `format(_:table:_:)` for callers that hold the arguments as a list (status lines).
    public func format(_ key: String, table: StringTable, arguments: [any CVarArg]) -> String {
        let template = string(key, table: table)
        guard !arguments.isEmpty else { return template }
        return String(format: template, locale: locale, arguments: arguments)
    }

    /// PRD-R65: dates, numbers and versions in the selected language.
    public func formatDate(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .long, time: .omitted, locale: locale))
    }

    /// PRD-R65: an ISO calendar day (`YYYY-MM-DD`, as `compat-matrix.json` writes `lastVerified`) in the selected
    /// language, in the same long style as `formatDate`. Text that is not a valid day is returned unchanged.
    public func formatDay(iso day: String, timeZone: TimeZone = .current) -> String {
        // `YYYY-MM-DD` with ASCII digits, parsed by hand (Swift `Regex` needs macOS 13).
        let fields = day.split(separator: "-", omittingEmptySubsequences: false)
        guard fields.map(\.count) == [4, 2, 2],
            fields.allSatisfy({ $0.allSatisfy { ("0"..."9").contains($0) } })
        else { return day }
        let parts = DateComponents(year: Int(fields[0]), month: Int(fields[1]), day: Int(fields[2]))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // A day that does not exist (2026-02-30) rolls over in `date(from:)`; reading it back catches that.
        guard let date = calendar.date(from: parts) else { return day }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == parts.year, back.month == parts.month, back.day == parts.day else { return day }
        return date.formatted(
            Date.FormatStyle(date: .long, time: .omitted, locale: locale, calendar: calendar, timeZone: timeZone))
    }

    public func formatNumber(_ number: Int) -> String {
        number.formatted(IntegerFormatStyle<Int>(locale: locale))
    }

    /// Countdown of the typing-trace HUD (PLT-R905), `m:ss`.
    /// Arithmetic instead of `Duration.TimeFormatStyle` (macOS 13); both interface languages write `m:ss` with
    /// ASCII digits. Rounds to the nearest second, half to even, as that style did.
    public func formatCountdown(_ remaining: TimeSpan) -> String {
        let seconds = Int(max(remaining, .zero).inSeconds.rounded(.toNearestOrEven))
        let secondsPart = seconds % 60
        return "\(seconds / 60):\(secondsPart < 10 ? "0" : "")\(secondsPart)"
    }

    static func locale(for language: InterfaceLanguage) -> Locale {
        switch language {
        case .vietnamese: Locale(identifier: "vi_VN")
        case .english: Locale(identifier: "en_US")
        }
    }

    private static func languageBundle(_ language: InterfaceLanguage, in appBundle: Bundle) -> Bundle? {
        appBundle.path(forResource: language.rawValue, ofType: "lproj").flatMap(Bundle.init(path:))
    }

    /// Sentinel returned by `localizedString` when the key is absent, so a translation that happens to equal
    /// its key is still found.
    private static let missing = "\u{1}missing\u{1}"

    private static func lookup(_ key: String, table: StringTable, in bundle: Bundle?) -> String? {
        guard let bundle else { return nil }
        let value = bundle.localizedString(forKey: key, value: missing, table: table.rawValue)
        return value == missing ? nil : value
    }
}

/// Observable current language for SwiftUI views and AppKit controllers (menus rebuild on open).
/// `ObservableObject` (not `@Observable`, which needs macOS 14; ADR 0315): SwiftUI views hold it as
/// `@ObservedObject` or observe a model that forwards its `objectWillChange`; AppKit controllers use `afterChange`.
@MainActor
public final class InterfaceLanguageModel: ObservableObject {
    @Published public private(set) var localizer: Localizer
    private let appBundle: Bundle

    public init(language: InterfaceLanguage, appBundle: Bundle) {
        self.appBundle = appBundle
        localizer = Localizer(language: language, appBundle: appBundle)
    }

    /// Called when settings change; views observing `localizer` re-render (PRD-R63).
    public func select(_ language: InterfaceLanguage) {
        guard language != localizer.language else { return }
        localizer = Localizer(language: language, appBundle: appBundle)
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/ShellCore/SystemPanes.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// System Settings (macOS 13 and later) and System Preferences (macOS 12) pane names and deep links keyed by macOS
// version and the MACOS language (PLT-R704, PRD-R64, ADR 0315), loaded from the resource `SystemPanes.json`. UI
// copy is in the interface language; pane names quoted inside it are in the system language so they match what
// the user sees on screen.
//
// SystemPanes.json shape:
// { "schemaVersion": 1,
//   "entries": [ { "macOS": {"min": "13.0", "max": "26.99"},
//                  "names": { "vi": {"systemSettings": "Cài đặt hệ thống", "privacySecurity": "...",
//                                    "accessibility": "Trợ năng", "inputMonitoring": "...", "keyboard": "...",
//                                    "textReplacements": "...", "usersGroups": "...", "loginItems": "..."},
//                             "en": {...} },
//                  "deepLinks": { "accessibility": "x-apple.systempreferences:...", ... } } ] }
// Every entry is VERIFY on a real system in that language and version before release.

public import AppModel
public import Foundation

public enum SystemPane: String, Sendable, Hashable, CaseIterable {
    case accessibility, inputMonitoring, keyboard, inputSources, loginItems
}

public struct SystemPaneNames: Sendable, Hashable, Codable {
    /// "System Settings" from macOS 13, "System Preferences" on macOS 12.
    public var systemSettings: String
    public var privacySecurity: String
    public var accessibility: String  // "Device Control and Data Access" on macOS 27 (PLT-R701)
    public var inputMonitoring: String
    public var keyboard: String
    public var textReplacements: String
    /// The pane that holds Login Items: "Users & Groups" on macOS 12, "General" from macOS 13.
    public var usersGroups: String
    public var loginItems: String

    public init(
        systemSettings: String, privacySecurity: String, accessibility: String, inputMonitoring: String,
        keyboard: String, textReplacements: String, usersGroups: String, loginItems: String
    ) {
        self.systemSettings = systemSettings
        self.privacySecurity = privacySecurity
        self.accessibility = accessibility
        self.inputMonitoring = inputMonitoring
        self.keyboard = keyboard
        self.textReplacements = textReplacements
        self.usersGroups = usersGroups
        self.loginItems = loginItems
    }
}

/// Why `SystemPanes.json` was rejected (a build error: the resource ships with the app).
public enum SystemPaneTableError: Error, Sendable, Hashable {
    case unsupportedSchema(Int)
    case noEntries
    case missingEnglishNames(entry: Int)
    case invalidDeepLink(entry: Int, pane: String)
}

public struct SystemPaneTable: Sendable {
    public static let schemaVersion = 1
    /// Language used when the macOS language has no names in the table.
    static let fallbackLanguage = "en"

    private struct Document: Decodable {
        var schemaVersion: Int
        var entries: [Entry]
    }

    private struct Entry: Decodable {
        var macOS: VersionRange
        var names: [String: SystemPaneNames]
        var deepLinks: [String: String]
    }

    private let entries: [Entry]

    public init(resource: Data) throws {
        let document = try JSONDecoder().decode(Document.self, from: resource)
        guard document.schemaVersion == Self.schemaVersion else {
            throw SystemPaneTableError.unsupportedSchema(document.schemaVersion)
        }
        guard !document.entries.isEmpty else { throw SystemPaneTableError.noEntries }
        for (index, entry) in document.entries.enumerated() {
            guard entry.names[Self.fallbackLanguage] != nil else {
                throw SystemPaneTableError.missingEnglishNames(entry: index)
            }
            for (pane, link) in entry.deepLinks where URL(string: link)?.scheme == nil {
                throw SystemPaneTableError.invalidDeepLink(entry: index, pane: pane)
            }
        }
        entries = document.entries
    }

    /// `systemLanguage` is the macOS primary language (BCP 47); unknown languages fall back to English.
    public func names(macOS: LooseVersion, systemLanguage: String) -> SystemPaneNames {
        let names = entry(for: macOS).names
        let language = Self.primaryLanguage(systemLanguage)
        // Every entry has English names (checked in `init`).
        return names[language] ?? names[Self.fallbackLanguage]!
    }

    public func deepLink(_ pane: SystemPane, macOS: LooseVersion) -> URL? {
        entry(for: macOS).deepLinks[pane.rawValue].flatMap(URL.init(string:))
    }

    /// The entry whose range contains `macOS`; outside every range, the nearest one (a newer macOS than the
    /// table knows uses the newest entry until the table is updated).
    private func entry(for macOS: LooseVersion) -> Entry {
        if let match = entries.first(where: { $0.macOS.contains(macOS) }) { return match }
        let older = entries.filter { range in range.macOS.max.map { $0 < macOS } ?? false }
        let newest = older.max { ($0.macOS.max ?? macOS) < ($1.macOS.max ?? macOS) }
        return newest ?? entries[0]
    }

    /// "vi-VN" -> "vi", "en_GB" -> "en", "zh-Hant-TW" -> "zh".
    static func primaryLanguage(_ tag: String) -> String {
        let separators = CharacterSet(charactersIn: "-_")
        return tag.components(separatedBy: separators).first?.lowercased() ?? fallbackLanguage
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/ShellCore/StatusPresentation.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Menu-bar icon states (PRD-R10), menu model (PRD-R11) and status lines (PRD-R43). Pure functions of host
// state, testable without AppKit.

public import AppModel
public import CompatRules
public import Diagnostics
public import Foundation
public import SettingsStore

/// PRD-R10 glyph states; every case has a VoiceOver label key in the `Menu` table. The glyphs are Pa's KV mark
/// (S7): the letters are solid or dimmed and a badge sits in the dot's place, so no state relies on colour alone
/// (PRD-R67).
public enum StatusIconState: String, Sendable, Hashable, CaseIterable {
    case vietnamese  // solid KV, emerald dot
    case english  // dimmed KV, grey dot
    case ignoredApp  // dimmed KV, ring
    case secureInputVietnamese  // solid KV, lock badge
    case secureInputEnglish  // dimmed KV, lock badge
    case paused  // faint KV, pause bars (non-Latin source and other pauses)
    case notWorking  // faint KV with a slash (permission missing or tap failed)
    case capturing  // solid KV, recording ring while a typing trace records (PLT-R905)

    public var accessibilityLabelKey: String { "icon.\(rawValue).accessibilityLabel" }
    /// Asset catalog image set with light, dark and high-contrast variants; not a template.
    public var imageName: String { "StatusIcon-\(rawValue)" }
}

public enum StatusPresentation {
    /// Precedence: capturing (PLT-R905 requires the changed icon for the whole recording) > host state.
    /// `ignored` is the frontmost app's "Bỏ qua" rule; `mode` picks V or E for the lock badge.
    public static func iconState(state: HostState, mode: TypingMode, ignored: Bool, capturing: Bool)
        -> StatusIconState
    {
        if capturing { return .capturing }
        switch state {
        case .noPermission, .failOpen: return .notWorking
        case .starting: return .paused
        case .ready(let readyMode):
            if ignored { return .ignoredApp }
            return readyMode == .vietnamese ? .vietnamese : .english
        case .paused(let reason):
            return pausedIcon(reason, mode: mode)
        }
    }

    /// The `capturing` input of `iconState`: true while a trace session runs, including the gaps in which secure
    /// input or a secure field stops the recording (`isRecording` is false then and stays the tap's record gate).
    /// PLT-R905: "changed menu-bar icon for the whole duration".
    public static func isCapturing(_ capture: CaptureController, now: Date) -> Bool {
        capture.remaining(now: now) != nil
    }

    private static func pausedIcon(_ reason: PauseReason, mode: TypingMode) -> StatusIconState {
        switch reason {
        case .secureInput, .secureField:
            return mode == .vietnamese ? .secureInputVietnamese : .secureInputEnglish
        case .passThroughRule:
            return .ignoredApp
        case .nonLatinInputSource, .builtInVietnameseSource, .sessionInactive, .userDisabled, .noTextFocus,
            .diagnosticsTest:
            return .paused
        }
    }

    /// VoiceOver label key for the status item (PLT-R211: the label is truthful about the reason). PRD-R10
    /// labels are used where they fit; the dimmed and slashed glyphs, which cover several states, get a
    /// reason-specific label otherwise, so every pause reason is said in plain words even without a status line.
    public static func accessibilityLabelKey(icon: StatusIconState, state: HostState) -> String {
        switch (icon, state) {
        case (.paused, .starting):
            return MenuText.iconStarting.rawValue
        case (.paused, .paused(.noTextFocus)):
            return MenuText.iconPausedNoTextFocus.rawValue
        case (.paused, .paused(.userDisabled)):
            return MenuText.iconPausedUserDisabled.rawValue
        case (.paused, .paused(.sessionInactive)):
            return MenuText.iconPausedSessionInactive.rawValue
        case (.paused, .paused(.diagnosticsTest)):
            return MenuText.iconPausedDiagnosticsTest.rawValue
        case (.notWorking, .failOpen(let reason)) where reason != .permissionRevoked:
            return MenuText.iconNotWorkingFailOpen.rawValue
        default:
            return icon.accessibilityLabelKey
        }
    }
}

/// One status line (PRD-R11 item 1, PRD-R43): message key, arguments and a single concrete action.
public struct StatusLine: Sendable, Hashable {
    public enum Action: Sendable, Hashable {
        case grantPermission, resumeOnboarding
        case showHolderApp(pid: Int32)
        case secureInputHelp, reportProblem
        case learnMore(URL)
        case none
        /// "paused: no text field detected" (02-platform.md section 6, custom text views): one click writes a
        /// user override with `requireTextFocus: never` for this app (PLT-R540).
        case overrideTextFocus(bundle: BundleKey)
        /// `failOpen(callbackStuck)`: only reopening the app recovers (ADR 0309).
        case reopenApp
        /// Crash-loop safe mode (PLT-R1009): the safe-mode choices (reset, use the saved settings, report).
        case safeModeChoices
        /// Settings not being saved (PLT-R1006, PLT-R1007): the Settings window, whose notice explains it and
        /// offers the fix.
        case openSettings
    }

    public var key: String  // in the `Status` table
    public var arguments: [String]  // app names, source names, never typed content
    public var action: Action
    /// Optional second line in the `Status` table: the data-driven secure-input hint (PLT-R397, PLT-R398C) or
    /// the honest built-in fallback while permission is missing (PLT-R206).
    public var hintKey: String?
    /// Label of the action item (`Status` table) and its arguments; nil when the action is `.none`.
    public var actionLabelKey: String?
    public var actionLabelArguments: [String]

    public init(
        key: String, arguments: [String], action: Action, hintKey: String? = nil, actionLabelKey: String? = nil,
        actionLabelArguments: [String] = []
    ) {
        self.key = key
        self.arguments = arguments
        self.action = action
        self.hintKey = hintKey
        self.actionLabelKey = actionLabelKey
        self.actionLabelArguments = actionLabelArguments
    }

    /// Precedence: host state lines (permission, secure input with holder and hint, fail-open, non-Latin
    /// source, built-in Vietnamese source, no text focus with override action) > crash-loop safe mode
    /// (PLT-R1009) > settings not being saved (`storeNotices`, PLT-R1006, PLT-R1007) > tap re-enabled notice >
    /// "App in Known limitation list" for the frontmost app (PRD-R43) > nil.
    /// While a host-state line hides the safe-mode line, the report item still opens the safe-mode choices
    /// (`DiagnosticsNavigation.destination(reportProblemFor:lastFrontmost:safeMode:)`).
    /// `onboardingCompleted == false` turns the permission action into "resume onboarding at screen 2"
    /// (PRD-R41). `safeMode` is `SettingsState.safeMode`.
    public static func forState(
        _ state: HostState, holderHintKey: String?, appName: String, frontmostApp: FrontmostAppStatus?,
        tapRecentlyReenabled: Bool, onboardingCompleted: Bool = true, safeMode: Bool = false,
        storeNotices: [StoreNotice] = []
    ) -> StatusLine? {
        let context = StatusLineBuilder(
            appName: appName, holderHintKey: holderHintKey, frontmostApp: frontmostApp,
            onboardingCompleted: onboardingCompleted)
        if let line = context.hostLine(for: state) { return line }
        if safeMode { return context.safeModeLine() }
        if let line = storeNotices.lazy.compactMap(context.unsavedSettingsLine).first { return line }
        if tapRecentlyReenabled { return context.tapReenabledLine() }
        return context.knownLimitationLine()
    }
}

/// What the status line needs to know about the frontmost app (PRD-R43 "App in Known limitation list").
public struct FrontmostAppStatus: Sendable, Hashable {
    public var bundle: BundleKey
    public var displayName: String
    /// From `compat-matrix.json` through `MatrixStatusResolver.displayStatus`.
    public var matrixStatus: MatrixStatus?
    /// The matrix entry's one-line note in the interface language (data, not code).
    public var limitationNote: String?
    public var learnMore: URL?

    public init(
        bundle: BundleKey, displayName: String, matrixStatus: MatrixStatus?, limitationNote: String?, learnMore: URL?
    ) {
        self.bundle = bundle
        self.displayName = displayName
        self.matrixStatus = matrixStatus
        self.limitationNote = limitationNote
        self.learnMore = learnMore
    }

    /// PRD-R43 "App in Known limitation list", PRD-R35: the matrix row that stands for the whole app, after the
    /// 120-day rule (QA-R19); its note in the interface language; "Tìm hiểu thêm" opens the site's compatibility
    /// page, which lists the app with its note (the matrix has no per-entry link).
    public init(
        bundle: BundleKey, displayName: String, matrix: MatrixDocument?, today: Date, language: InterfaceLanguage,
        siteURL: URL
    ) {
        let entry = matrix?.appEntry(for: bundle)
        self.init(
            bundle: bundle, displayName: displayName,
            matrixStatus: entry.map { MatrixStatusResolver.displayStatus($0, today: today) },
            limitationNote: entry?.note.map { language == .vietnamese ? $0.vi : $0.en },
            learnMore: entry == nil ? nil : CompatibilityPage.url(siteURL: siteURL, language: language))
    }
}

/// The site's compatibility matrix page; the paths are those of site/lib/routes.mjs (`compat`), the host comes
/// from the brand.
public enum CompatibilityPage {
    public static func url(siteURL: URL, language: InterfaceLanguage) -> URL {
        let path = language == .vietnamese ? "tuong-thich/" : "en/compatibility/"
        return URL(string: path, relativeTo: siteURL)?.absoluteURL ?? siteURL
    }
}

/// PRD-R11 menu, top to bottom. Built when the menu opens (within 100 ms, PRD-R13).
public struct MenuModel: Sendable, Hashable {
    public var statusLine: StatusLine?
    public var mode: TypingMode
    public var toggleHotkeyDisplay: String
    public var method: TypingMethod
    public var frontmostApp: FrontmostAppMenu?
    public var appName: String
    public var updateCheckEnabled: Bool

    public struct FrontmostAppMenu: Sendable, Hashable {
        public var bundle: BundleKey
        public var displayName: String
        public var rule: PerAppRule  // checked item of the submenu

        public init(bundle: BundleKey, displayName: String, rule: PerAppRule) {
            self.bundle = bundle
            self.displayName = displayName
            self.rule = rule
        }
    }

    public init(
        statusLine: StatusLine?, mode: TypingMode, toggleHotkeyDisplay: String, method: TypingMethod,
        frontmostApp: FrontmostAppMenu?, appName: String, updateCheckEnabled: Bool
    ) {
        self.statusLine = statusLine
        self.mode = mode
        self.toggleHotkeyDisplay = toggleHotkeyDisplay
        self.method = method
        self.frontmostApp = frontmostApp
        self.appName = appName
        self.updateCheckEnabled = updateCheckEnabled
    }

    /// The menu in PRD-R11 order; `StatusItemController` renders it item by item.
    public var entries: [MenuEntry] { MenuEntry.entries(for: self) }
}

public enum HotkeyDisplay {
    /// "⌃⇧" for the Control+Shift tap, "⌥⌘K" for combos, in the selected language for words.
    public static func string(for binding: HotkeyBinding, localizer: Localizer) -> String {
        switch binding {
        case .modifierTap(let chord): chordString(chord, localizer: localizer)
        case .keyCombo(let modifiers, let keyCode):
            modifierSymbols(modifiers) + HotkeyKeyNames.name(for: keyCode, localizer: localizer)
        case .key(let keyCode): HotkeyKeyNames.name(for: keyCode, localizer: localizer)
        }
    }

    private static func chordString(_ chord: ModifierTapChord, localizer: Localizer) -> String {
        switch chord {
        case .rightCommand: localizer.format(MenuText.hotkeyRight, "⌘")
        case .rightOption: localizer.format(MenuText.hotkeyRight, "⌥")
        case .controlShift, .commandShift, .optionShift, .controlOption: modifierSymbols(chord.modifiers)
        }
    }

    /// Apple's display order: fn, Control, Option, Shift, Command.
    static func modifierSymbols(_ modifiers: ModifierKeys) -> String {
        var symbols = ""
        if modifiers.contains(.function) { symbols += "fn" }
        if modifiers.contains(.control) { symbols += "⌃" }
        if modifiers.contains(.option) { symbols += "⌥" }
        if modifiers.contains(.shift) { symbols += "⇧" }
        if modifiers.contains(.command) { symbols += "⌘" }
        return symbols
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/ShellCore/Onboarding.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Onboarding flow (PRD-R40-R42, PLT-R710-R712). The state machine is pure; App/ renders the screens.

public import AppModel
public import Foundation
public import InputHost

public enum OnboardingScreen: Int, Sendable, Hashable, CaseIterable {
    case welcome = 1
    case permission, typingMethod, switching, conflicts, importFrom, tryIt, done
}

public struct OnboardingInputs: Sendable, Hashable {
    public var permission: PermissionStatus
    public var conflicts: [ConflictingInput]
    public var importCandidates: [ImportCandidate]
    /// Only the permission screen after losing permission (PRD-R42).
    public var permissionLostAfterCompletion: Bool
    public init(
        permission: PermissionStatus, conflicts: [ConflictingInput], importCandidates: [ImportCandidate],
        permissionLostAfterCompletion: Bool
    ) {
        self.permission = permission
        self.conflicts = conflicts
        self.importCandidates = importCandidates
        self.permissionLostAfterCompletion = permissionLostAfterCompletion
    }
}

/// Screen 6: a known export file or competitor app was detected (PRD-R69: only by explicit click).
public struct ImportCandidate: Sendable, Hashable {
    public var appName: String
    public var bundle: BundleKey?

    public init(appName: String, bundle: BundleKey?) {
        self.appName = appName
        self.bundle = bundle
    }
}

public struct OnboardingFlow: Sendable, Hashable {
    public private(set) var screen: OnboardingScreen
    /// PRD-R42 variant: only screen 2 is shown, then the flow finishes.
    public let permissionOnly: Bool
    /// The last screen was left (the window closes and onboarding counts as completed, PRD-R42).
    public private(set) var isFinished = false
    /// Permission state as last seen, for the "Đã cấp quyền" check mark (PRD-R40 "Live state").
    public private(set) var permissionGranted: Bool
    /// Set when the grant advanced the flow by itself, so the next screen can confirm it; cleared on the next move.
    public private(set) var advancedByGrant = false
    /// PLT-R702: the tap was seen to need Input Monitoring during this onboarding; its row then stays on screen 2,
    /// as granted once the need cleared (`PermissionScreenContent`).
    public private(set) var inputMonitoringSeen = false
    /// PLT-R702: the latest status needs Input Monitoring, and whether `CGRequestListenEventAccess()` was already
    /// called for this onboarding.
    private var inputMonitoringNeeded = false
    private var inputMonitoringRequested = false
    private var history: [OnboardingScreen] = []

    public init(inputs: OnboardingInputs) {
        self.init(inputs: inputs, startAt: .welcome)
    }

    /// `startAt: .permission` resumes at screen 2 (PRD-R41). The permission-lost variant always starts there.
    public init(inputs: OnboardingInputs, startAt: OnboardingScreen) {
        permissionOnly = inputs.permissionLostAfterCompletion
        screen = permissionOnly ? .permission : startAt
        permissionGranted = Self.isGranted(inputs.permission)
        inputMonitoringSeen = inputs.permission.listenEventRequired
        inputMonitoringNeeded = inputs.permission.listenEventRequired
    }

    /// Screens 5 and 6 are skipped when their condition is false; screen 2 has no "Bỏ qua".
    public mutating func next(inputs: OnboardingInputs) {
        observe(inputs.permission)
        // PRD-R40: screen 2 cannot be left forward until permission is granted.
        if screen == .permission && !permissionGranted { return }
        advance(inputs: inputs)
    }

    public mutating func back() {
        guard !isFinished, let previous = history.popLast() else { return }
        advancedByGrant = false
        screen = previous
    }

    public mutating func skip(inputs: OnboardingInputs) {
        guard canSkip, !isFinished else { return }
        advance(inputs: inputs)
    }

    public var canSkip: Bool { screen != .permission }

    /// "Quay lại" is shown on every screen that has a previous one (PRD-R40).
    public var canGoBack: Bool { !history.isEmpty && !isFinished }

    /// Permission granted while on screen 2: advance within 1 s (PRD-R40 "Live state"). The permission monitor
    /// polls every 1 s while onboarding is visible (PLT-R711), so the flow advances on the first poll after the
    /// grant. In the PRD-R42 variant the screen stays to show "Đã cấp quyền" until the user closes it.
    ///
    /// PRD-R40, PLT-R702: a grant that is withdrawn before the user moved on (typically a `ready` whose tap creation
    /// failed in the same delivery, so the tap needs Input Monitoring) takes the flow back to screen 2, which then
    /// shows what is missing; screen 2 is never left forward without permission.
    public mutating func permissionChanged(_ status: PermissionStatus, inputs: OnboardingInputs) {
        let wasGranted = permissionGranted
        observe(status)
        guard !isFinished, !permissionOnly else { return }
        if advancedByGrant, !permissionGranted, history.last == .permission {
            advancedByGrant = false
            screen = history.removeLast()
            return
        }
        guard screen == .permission, permissionGranted, !wasGranted else { return }
        advance(inputs: inputs)
        advancedByGrant = true
    }

    /// PLT-R702: true once, the first time the Input Monitoring row shows as needed, so the caller asks macOS
    /// (`CGRequestListenEventAccess()`) to list the app and show its own prompt, without waiting for a click.
    public mutating func takeInputMonitoringRequest() -> Bool {
        guard inputMonitoringNeeded, !inputMonitoringRequested else { return false }
        inputMonitoringRequested = true
        return true
    }

    /// Accessibility trusted and, when macOS demands it, Input Monitoring too (PLT-R701, PLT-R702).
    public static func isGranted(_ status: PermissionStatus) -> Bool { status.health == .ready }

    private mutating func observe(_ status: PermissionStatus) {
        permissionGranted = Self.isGranted(status)
        inputMonitoringNeeded = status.listenEventRequired
        if inputMonitoringNeeded { inputMonitoringSeen = true }
    }

    private mutating func advance(inputs: OnboardingInputs) {
        advancedByGrant = false
        guard let following = following(screen, inputs: inputs), !permissionOnly else {
            isFinished = true
            return
        }
        history.append(screen)
        screen = following
    }

    private func following(_ current: OnboardingScreen, inputs: OnboardingInputs) -> OnboardingScreen? {
        var candidate = OnboardingScreen(rawValue: current.rawValue + 1)
        while let screen = candidate, !Self.isShown(screen, inputs: inputs) {
            candidate = OnboardingScreen(rawValue: screen.rawValue + 1)
        }
        return candidate
    }

    private static func isShown(_ screen: OnboardingScreen, inputs: OnboardingInputs) -> Bool {
        switch screen {
        case .conflicts: !inputs.conflicts.isEmpty
        case .importFrom: !inputs.importCandidates.isEmpty
        default: true
        }
    }
}

/// PLT-R710: the app must run from /Applications or ~/Applications and not be translocated before asking for
/// permissions; otherwise offer to move itself and relaunch.
public enum AppLocationCheck {
    public enum Result: Sendable, Hashable {
        case ok
        case mustMove(reason: Reason)
    }

    public enum Reason: String, Sendable, Hashable { case translocated, readOnlyVolume, outsideApplications }

    /// Gatekeeper path randomisation runs quarantined apps from a read-only mount under a directory with this
    /// name (VERIFY on current macOS; the App may also ask `SecTranslocateIsTranslocatedURL`).
    static let translocationComponent = "AppTranslocation"

    public static func evaluate(bundleURL: URL, homeDirectory: URL, isOnReadOnlyVolume: Bool) -> Result {
        let bundle = bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        if bundle.pathComponents.contains(translocationComponent) { return .mustMove(reason: .translocated) }
        if isOnReadOnlyVolume { return .mustMove(reason: .readOnlyVolume) }
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            homeDirectory.appendingPathComponent("Applications", isDirectory: true),
        ]
        let inside = roots.contains { isDescendant(bundle, of: $0.standardizedFileURL.resolvingSymlinksInPath()) }
        return inside ? .ok : .mustMove(reason: .outsideApplications)
    }

    private static func isDescendant(_ url: URL, of root: URL) -> Bool {
        let path = url.pathComponents
        let rootPath = root.pathComponents
        return path.count > rootPath.count && Array(path.prefix(rootPath.count)) == rootPath
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/ShellCore/BugReport.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Bug report sheet logic (PRD-R47-R49, PLT-R1204, PLT-R1205) and report assembly (PLT-R1202).

public import AppModel
public import CompatRules
public import Diagnostics
public import Foundation
public import InputHost
public import SettingsStore

public struct BugReportDraft: Sendable, Hashable {
    public var app: BundleKey?
    public var appName: String?
    public var symptom: DiagnosticsReport.Symptom
    /// "Bạn gõ gì và mong ra gì?": typed by the user on purpose; goes only into the issue body or mail they
    /// send themselves, never into the diagnostics block.
    public var userDescription: String
    public var reproducesInPracticeField: Bool?

    public init(
        app: BundleKey?, appName: String?, symptom: DiagnosticsReport.Symptom, userDescription: String,
        reproducesInPracticeField: Bool?
    ) {
        self.app = app
        self.appName = appName
        self.symptom = symptom
        self.userDescription = userDescription
        self.reproducesInPracticeField = reproducesInPracticeField
    }
}

public enum ReportAssembler {
    /// Metadata only (PLT-R1202). The reported app is the draft's app, else the focused app; only its memory
    /// entry (PLT-R913) and its user override (PLT-R541, as a typed projection, ADR 0312) are included. The
    /// draft's free text never enters the report.
    public static func report(
        identity: AppIdentity, system: SystemInfo, host: HostReportContext, settings: SettingsState,
        metrics: MetricsSnapshot, health: [HealthEvent], probe: LatencyProbeResult?, draft: BugReportDraft?,
        now: Date
    ) -> DiagnosticsReport {
        let reportedApp = draft?.app ?? host.focus.app?.bundle
        // PLT-R541, ADR 0312: for the focused app the override that decided, so `rule.id` and
        // `rule.userOverride` agree when the app has several; else the app's newest stored override.
        let decisionOverride = host.focus.app?.bundle == reportedApp ? host.decision?.userOverride : nil
        let storedOverride = ReportedOverrideSource.override(for: reportedApp, in: settings.ruleOverrides)
        return DiagnosticsReport(
            generatedAt: now, app: identity, system: system, hostState: host.state.code,
            keyboard: ReportSections.keyboard(host), permissions: ReportSections.permissions(host),
            tap: ReportSections.tap(host, health: health, now: now), secureInput: ReportSections.secureInput(host),
            focus: ReportSections.focus(host),
            rule: ReportSections.rule(host.decision, userOverride: decisionOverride ?? storedOverride),
            settings: ReportSections.settings(settings),
            reportedAppMode: ReportSections.reportedAppMode(settings, reportedApp: reportedApp),
            latency: DiagnosticsReport.LatencySection(metrics: metrics, probe: probe),
            healthEvents: ReportSections.recentHealth(health), conflictingInputApps: ReportSections.conflicts(host),
            userReport: ReportSections.userReport(draft))
    }

    /// Typed projection of the reported app's user override (PLT-R541, ADR 0312): copies strategy, params,
    /// fallback, gating and metadata match fields; drops `summary`, `provenance`, `web.urlPrefixes` and
    /// `titlePattern` (listed by name in `omittedMatchFields`, values never copied, PLT-R1203).
    public static func reportedOverride(from rule: Rule) -> DiagnosticsReport.ReportedOverride {
        let match = rule.match
        let ax = match.ax
        var omitted: [DiagnosticsReport.OmittedMatchField] = []
        if match.web?.urlPrefixes != nil { omitted.append(.webURLPrefixes) }
        if match.titlePattern != nil { omitted.append(.titlePattern) }
        let reportedMatch = DiagnosticsReport.ReportedMatch(
            bundleIds: match.bundleIds, bundleGroup: match.bundleGroup, engines: match.engines,
            appCategories: match.appCategories, appVersion: match.appVersion, macOS: match.macOS, axRoles: ax?.roles,
            axSubroles: ax?.subroles, axIdentifiers: ax?.identifiers, axDomClasses: ax?.domClasses,
            axAncestorRoles: ax?.ancestorRoles, axEditable: ax?.editable)
        let action = rule.action
        return DiagnosticsReport.ReportedOverride(
            id: rule.id, match: reportedMatch, strategy: action.strategy,
            parameters: action.params.map(reportedParameters), fallback: action.fallback,
            requireTextFocus: action.requireTextFocus, verifyReentry: action.verifyReentry,
            engineContext: action.engineContext, omittedMatchFields: omitted)
    }

    private static func reportedParameters(_ params: StrategyParams) -> DiagnosticsReport.ReportedParameters {
        DiagnosticsReport.ReportedParameters(
            unicodeChunk: params.unicodeChunk, interEventDelayUs: params.interEventDelayUs,
            postDeleteSettleUs: params.postDeleteSettleUs, firstEditDelayUs: params.firstEditDelayUs,
            inlineCompletion: params.inlineCompletion, allowMultiCharEvents: params.allowMultiCharEvents,
            allowSplit: params.allowSplit, longTextThreshold: params.longTextThreshold,
            restoreDelayMs: params.restoreDelayMs, verifyAfterEdit: params.verifyAfterEdit)
    }
}

/// A mail draft for "Gửi qua email" (PRD-R47). The App sends it with
/// `NSSharingService(named: .composeEmail)`: `recipients`, `subject`, the body as the first item and the JSON
/// report file URL as an attachment. Only when no mail service is available does it fall back to a `mailto:`
/// URL with subject and body and no attachment (the sheet then offers "Lưu tệp..." for the JSON).
public struct MailDraft: Sendable, Hashable {
    public var recipients: [String]
    public var subject: String
    public var body: String
    /// Suggested file name of the attachment, `<slug>-report-YYYYMMDD-HHMM.json`.
    public var attachmentFileName: String

    public init(recipients: [String], subject: String, body: String, attachmentFileName: String) {
        self.recipients = recipients
        self.subject = subject
        self.body = body
        self.attachmentFileName = attachmentFileName
    }
}

/// The three ways out of the bug report sheet (PRD-R47, PRD-R49).
public enum BugReportPath: String, Sendable, Hashable, CaseIterable { case github, email, saveFile }

public enum BugReportComposer {
    /// Paths the sheet offers: GitHub only with a repository URL, email only with a support address; saving the
    /// file always works (PRD-R49: the flow works without a GitHub account).
    public static func availablePaths(brand: Brand) -> [BugReportPath] {
        BugReportPath.allCases.filter { path in
            switch path {
            case .github: brand.repositoryURL != nil
            case .email: brand.supportEmail != nil
            case .saveFile: true
            }
        }
    }

    /// GitHub issue-form URL with the summary in the body (the full block is copied to the clipboard after the
    /// sheet says so, PRD-R48). `repository` is `Brand.repositoryURL`; when it is nil the GitHub button is
    /// hidden and email/save remain (PRD-R49).
    public static func githubIssueURL(repository: URL, draft: BugReportDraft, report: DiagnosticsReport) -> URL {
        IssueFormURL.make(repository: repository, draft: draft, report: report)
    }

    /// Mail draft to `Brand.supportEmail` (nil when the brand has no support address).
    public static func mail(draft: BugReportDraft, report: DiagnosticsReport, brand: Brand, localizer: Localizer)
        -> MailDraft?
    {
        guard let address = brand.supportEmail else { return nil }
        let summary = BugReportSummary(draft: draft, report: report)
        let fileName = attachmentFileName(slug: brand.slug, date: report.generatedAt)
        return MailDraft(
            recipients: [address], subject: summary.mailSubject(localizer, appName: brand.displayName),
            body: summary.mailBody(localizer, appName: brand.displayName, attachment: fileName),
            attachmentFileName: fileName)
    }

    /// `mailto:` fallback (subject and body only; attachments are impossible with `mailto:`).
    public static func mailtoURL(_ draft: MailDraft) -> URL? {
        guard !draft.recipients.isEmpty else { return nil }
        let recipients = draft.recipients.map(URLQueryEncoding.encodeAddress).joined(separator: ",")
        let subject = URLQueryEncoding.encode(draft.subject)
        // RFC 6068: line breaks in the body are CRLF.
        let body = URLQueryEncoding.encode(draft.body.replacingOccurrences(of: "\n", with: "\r\n"))
        return URL(string: "mailto:\(recipients)?subject=\(subject)&body=\(body)")
    }

    /// `<slug>-report-YYYYMMDD-HHMM.json` in the user's time zone.
    static func attachmentFileName(slug: String, date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let stamp = String(
            format: "%04d%02d%02d-%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0,
            parts.minute ?? 0)
        return "\(slug)-report-\(stamp).json"
    }
}

/// Collects macOS version and build, architecture, model identifier (sysctl `hw.model`), languages.
public enum SystemInfoReader {
    public static func current(uiLanguage: InterfaceLanguage) -> SystemInfo {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return SystemInfo(
            macOSVersion: versionString(version), macOSBuild: sysctlString("kern.osversion") ?? "unknown",
            architecture: hardwareArchitecture(), modelIdentifier: sysctlString("hw.model") ?? "unknown",
            uiLanguage: uiLanguage, systemLanguage: Locale.preferredLanguages.first ?? "en")
    }

    static func versionString(_ version: OperatingSystemVersion) -> String {
        let base = "\(version.majorVersion).\(version.minorVersion)"
        return version.patchVersion == 0 ? base : "\(base).\(version.patchVersion)"
    }

    /// Hardware class (PRD-R45): Apple silicon reports `arm64` even when the process runs translated.
    static func hardwareArchitecture() -> String {
        if sysctlInt("hw.optional.arm64") == 1 { return "arm64" }
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func sysctlInt(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}

/// An app the user can pick in the sheet (PRD-R47 item 1): recent apps, the last frontmost one first.
public struct BugReportAppChoice: Sendable, Hashable {
    public var bundle: BundleKey
    public var name: String

    public init(bundle: BundleKey, name: String) {
        self.bundle = bundle
        self.name = name
    }
}

/// Buttons of the bug report sheet, in display order.
public enum BugReportAction: String, Sendable, Hashable, CaseIterable {
    /// Visible without opening the preview, so "Copy report" is the third click from the menu (section 12).
    case copyReport
    case github, email, saveFile
    /// PRD-R49 "test in the practice field".
    case practiceField
    case openDiagnostics

    /// The sheet control (label and VoiceOver hint keys) of this button (PRD-R66).
    public var control: DiagnosticsControl {
        switch self {
        case .copyReport: .copyReport
        case .github: .github
        case .email: .email
        case .saveFile: .saveFile
        case .practiceField: .practiceButton
        case .openDiagnostics: .openDiagnostics
        }
    }
}

/// PRD-R47-R49 sheet state without UI: the draft, the preview disclosure and the outputs of each path.
public struct BugReportSheet: Sendable, Hashable {
    public var apps: [BugReportAppChoice]
    public private(set) var draft: BugReportDraft
    public var previewExpanded = false
    /// Which output the preview shows (PLT-R1204); the copied block first, because "Copy report" is the
    /// shortest path (section 12).
    public var previewFormat: ReportPreviewFormat = .copiedBlock
    public let paths: [BugReportPath]

    /// `preselected` is the last frontmost app (PRD-R47 item 1); it is added to `apps` when missing.
    public init(apps: [BugReportAppChoice], preselected: BugReportAppChoice?, brand: Brand) {
        var list = apps
        if let preselected, !list.contains(where: { $0.bundle == preselected.bundle }) {
            list.insert(preselected, at: 0)
        }
        self.apps = list
        paths = BugReportComposer.availablePaths(brand: brand)
        draft = BugReportDraft(
            app: preselected?.bundle, appName: preselected?.name, symptom: .other, userDescription: "",
            reproducesInPracticeField: nil)
    }

    public var actions: [BugReportAction] {
        BugReportAction.allCases.filter { action in
            switch action {
            case .github: paths.contains(.github)
            case .email: paths.contains(.email)
            case .copyReport, .saveFile, .practiceField, .openDiagnostics: true
            }
        }
    }

    public mutating func selectApp(_ bundle: BundleKey?) {
        let choice = bundle.flatMap { key in apps.first { $0.bundle == key } }
        draft.app = choice?.bundle
        draft.appName = choice?.name
    }

    public mutating func select(_ symptom: DiagnosticsReport.Symptom) { draft.symptom = symptom }
    public mutating func setDescription(_ text: String) { draft.userDescription = text }
    public mutating func setReproducesInPracticeField(_ value: Bool?) { draft.reproducesInPracticeField = value }

    /// The report for this draft: the user's choices without the free text, and nothing about an app other
    /// than the selected one (PLT-R913, PLT-R541). Pass the report built for the draft when the App can rebuild
    /// it; otherwise sections of a previously reported app are dropped here.
    public func report(from base: DiagnosticsReport) -> DiagnosticsReport {
        var report = base
        report.userReport = ReportSections.userReport(draft)
        if report.reportedAppMode?.bundle != draft.app { report.reportedAppMode = nil }
        if let override = report.rule?.userOverride, !Self.matches(override, draft.app) {
            report.rule?.userOverride = nil
        }
        return report
    }

    private static func matches(_ override: DiagnosticsReport.ReportedOverride, _ app: BundleKey?) -> Bool {
        guard let app else { return false }
        return override.match.bundleIds?.contains(app) == true
    }

    /// PLT-R1204, PRD-R47 item 4: the preview shows exactly what the paths of `format` write.
    public func preview(_ report: DiagnosticsReport, format: ReportPreviewFormat) -> String { format.text(report) }

    /// The preview in the chosen `previewFormat`.
    public func preview(_ report: DiagnosticsReport) -> String { preview(report, format: previewFormat) }

    /// The block written to the clipboard by "Copy report" and "Mở GitHub" (QA-R44), after the notice (PRD-R48).
    public func clipboardText(_ report: DiagnosticsReport) -> String { ReportPreviewFormat.copiedBlock.text(report) }

    /// The JSON file for "Gửi qua email" and "Lưu tệp..." (PRD-R47).
    public func attachment(_ report: DiagnosticsReport) throws -> Data { try DiagnosticsRenderer.json(report) }

    public func attachmentFileName(slug: String, report: DiagnosticsReport) -> String {
        BugReportComposer.attachmentFileName(slug: slug, date: report.generatedAt)
    }

    public func githubURL(repository: URL, report: DiagnosticsReport) -> URL {
        BugReportComposer.githubIssueURL(repository: repository, draft: draft, report: report)
    }

    public func mail(report: DiagnosticsReport, brand: Brand, localizer: Localizer) -> MailDraft? {
        BugReportComposer.mail(draft: draft, report: report, brand: brand, localizer: localizer)
    }
}

/// Buttons of the Diagnostics window (PLT-R1201), in display order.
public enum DiagnosticsWindowAction: String, Sendable, Hashable, CaseIterable {
    case copyReport, misbehaves, recordTrace, latencyTest, openLogs
}

/// What the report menu items open (PRD-R11 items 4 and 6, PLT-R1205 step 1).
public enum DiagnosticsDestination: Sendable, Hashable {
    case bugReport(preselected: BundleKey?)
    case misbehaves(BundleKey)
    /// Crash-loop safe mode (PLT-R1009): the safe-mode choices (reset, use saved settings, report, later) come
    /// first, so reset and exit stay reachable whichever status line is showing.
    case safeModeChoices
}

/// Navigation from the menu to the report (02-platform.md section 12: a first-time user produces a report in
/// at most 3 clicks from the menu).
public enum DiagnosticsNavigation {
    public enum Click: Sendable, Hashable {
        case statusItem
        case menu(MenuEntry)
        case sheet(BugReportAction)
    }

    /// Where a report request comes from.
    public enum Origin: Sendable, Hashable {
        /// The status menu: PRD-R11 items 4 and 6 and the status line's "Báo lỗi...".
        case menu
        /// The Settings window: an Apps pane row or detail sheet (PRD-R37), About & Support, a store notice.
        case settings
    }

    /// From the menu, "Báo lỗi..." opens the bug report sheet with the last frontmost app and "Báo lỗi với ứng
    /// dụng này..." opens the misbehaves flow for that app (the user focused the problem field first, PLT-R1205
    /// step 1; its panel continues to the sheet). In safe mode both open the safe-mode choices, whose "Report a
    /// Problem..." button continues to the report (PLT-R1009). From Settings the sheet opens pre-filled with the
    /// app (PRD-R37); Settings shows the safe-mode choices in its own notice.
    public static func destination(
        reportProblemFor bundle: BundleKey?, lastFrontmost: BundleKey?, safeMode: Bool = false,
        origin: Origin = .menu
    ) -> DiagnosticsDestination {
        guard origin == .menu else { return .bugReport(preselected: bundle ?? lastFrontmost) }
        if safeMode { return .safeModeChoices }
        if let bundle { return .misbehaves(bundle) }
        return .bugReport(preselected: lastFrontmost)
    }

    /// PLT-R1009: the shortest click path from the closed menu to the safe-mode choices. The status line's own
    /// action when the safe-mode line is showing, else the report item (a host-state line can outrank the
    /// safe-mode line). Nil outside safe mode or when the menu offers neither.
    public static func pathToSafeModeChoices(menu: MenuModel, safeMode: Bool) -> [Click]? {
        guard safeMode else { return nil }
        if let line = menu.statusLine, line.action == .safeModeChoices, menu.entries.contains(.statusAction(line)) {
            return [.statusItem, .menu(.statusAction(line))]
        }
        guard menu.entries.contains(.reportProblem),
            destination(reportProblemFor: nil, lastFrontmost: nil, safeMode: true) == .safeModeChoices
        else { return nil }
        return [.statusItem, .menu(.reportProblem)]
    }

    /// The shortest click path from the closed menu to "Copy report": open the menu, choose "Báo lỗi...", press
    /// "Copy report" in the sheet. Nil when the menu or the sheet do not offer the step.
    public static func pathToCopyReport(menu: MenuModel, sheet: BugReportSheet) -> [Click]? {
        guard menu.entries.contains(.reportProblem), sheet.actions.contains(.copyReport) else { return nil }
        guard case .bugReport = destination(reportProblemFor: nil, lastFrontmost: menu.frontmostApp?.bundle) else {
            return nil
        }
        return [.statusItem, .menu(.reportProblem), .sheet(.copyReport)]
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/ShellCore/BugReport/RecentReportApps.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Apps offered by the bug report sheet's picker (PRD-R47 item 1): the apps of the Apps pane, that is the apps the
// user has typed in from the per-app memory, most recent first, plus apps with a compatibility override (PRD-R34).
// Bundle IDs and display names only: nothing typed, no window titles, no paths (PLT-R1203).

public import AppModel
public import SettingsStore

public enum RecentReportApps {
    /// The picker lists at most this many apps.
    public static let limit = 20
    /// Display names are cut to this many characters.
    public static let maximumNameLength = 80

    /// The Apps pane's apps in its order (`AppsPaneModel.orderedBundles`), without this app (`own` is the running
    /// bundle's identifier, compared without case as LaunchServices does) and without keys of processes that have
    /// no bundle ID (`sha256:`), at most `limit`. `name` resolves the installed app's display name; a missing or
    /// blank name falls back to the bundle ID.
    public static func choices(
        appModes: AppModesDocument, overrides: [StoredRuleOverride], excluding own: String?, limit: Int = limit,
        name: (BundleKey) -> String?
    ) -> [BugReportAppChoice] {
        let bundles = AppsPaneModel.orderedBundles(appModes: appModes, overrides: overrides)
            .filter { offerable($0, excluding: own) }
            .prefix(max(0, limit))
        return bundles.map { BugReportAppChoice(bundle: $0, name: displayName(name($0), fallback: $0)) }
    }

    /// The app to preselect, "the last frontmost app" (PRD-R47 item 1). From the status menu the focused app is the
    /// app the user was typing in, because opening the menu does not activate this app. When the report starts in
    /// one of this app's own windows (Settings, Diagnostics), the most recent other app of `recent` stands in.
    public static func preselection(
        focused: BundleKey?, recent: [BugReportAppChoice], excluding own: String?, name: (BundleKey) -> String?
    ) -> BugReportAppChoice? {
        guard let focused, offerable(focused, excluding: own) else { return recent.first }
        return recent.first { $0.bundle == focused }
            ?? BugReportAppChoice(bundle: focused, name: displayName(name(focused), fallback: focused))
    }

    static func offerable(_ bundle: BundleKey, excluding own: String?) -> Bool {
        guard !bundle.isExecutableHash else { return false }
        guard let own else { return true }
        return bundle.rawValue.lowercased() != own.lowercased()
    }

    /// One line of at most `maximumNameLength` characters: control characters and line or paragraph separators
    /// become spaces, runs of white space collapse, surrounding white space is trimmed.
    static func displayName(_ raw: String?, fallback: BundleKey) -> String {
        var scalars = String.UnicodeScalarView()
        var lastWasSpace = true
        for scalar in (raw ?? "").unicodeScalars {
            let isSpace: Bool =
                switch scalar.properties.generalCategory {
                case .control, .lineSeparator, .paragraphSeparator, .spaceSeparator: true
                default: false
                }
            if isSpace {
                if !lastWasSpace { scalars.append(" ") }
            } else {
                scalars.append(scalar)
            }
            lastWasSpace = isSpace
        }
        var name = String(scalars)
        if name.last == " " { name.removeLast() }
        guard !name.isEmpty else { return fallback.rawValue }
        return String(name.prefix(maximumNameLength))
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/ShellCore/BugReport/ReportPreview.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// What the report previews show (PLT-R1204, PRD-R47 item 4): byte for byte the text a path writes, never a
// paraphrase. The Diagnostics window and the "This app misbehaves" panel copy only the block, so they show the
// block; the bug report sheet also attaches or saves the JSON file, so its preview offers both. The Diagnostics
// window also shows the same report in the interface language (PLT-R1201, PRD-R62).

public import AppModel
public import Diagnostics
internal import Foundation

public enum ReportPreviewFormat: String, Sendable, Hashable, CaseIterable {
    /// The diagnostics block (ADR 0501) that "Copy report" and "Mở GitHub" put on the clipboard.
    case copiedBlock
    /// The JSON file that "Gửi qua email" attaches and "Lưu tệp..." saves (PLT-R1202 "plain text and JSON").
    case attachedFile

    /// Exactly the text the paths of this format write. The JSON is empty only when it cannot be encoded, in
    /// which case those paths fail as well and say so.
    public func text(_ report: DiagnosticsReport) -> String {
        switch self {
        case .copiedBlock: DiagnosticsRenderer.issueBlock(report)
        case .attachedFile: (try? DiagnosticsRenderer.json(report)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
    }

    /// The sheet buttons whose output this format shows.
    public var paths: [BugReportAction] {
        switch self {
        case .copiedBlock: [.copyReport, .github]
        case .attachedFile: [.email, .saveFile]
        }
    }
}

/// What the Diagnostics window shows of one report: the PLT-R1201 information in the interface language (the
/// plain-text report, PLT-R1202), the exact text "Copy report" writes (PLT-R1204) and the latency histograms.
public struct ReportDisplay: Sendable, Hashable {
    public let information: String
    public let copyPreview: String
    public let histograms: [LatencyHistogram]

    public init(report: DiagnosticsReport, language: InterfaceLanguage) {
        information = DiagnosticsRenderer.plainText(report, language: language)
        copyPreview = ReportPreviewFormat.copiedBlock.text(report)
        histograms = LatencyHistograms.make(report.latency.metrics)
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/ShellCore/BugReport/LatencyHistograms.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The latency histograms of the Diagnostics window (PLT-R1201): one per 02-platform.md 8.1 metric that the report
// carries (PLT-R801), drawn from the report's own histogram snapshots, so the window and the copied percentiles
// always describe the same samples. Content-free: bucket bounds and counts only.

public import Diagnostics
public import Foundation

/// The report's latency metrics in report order; raw values are the ADR 0501 `latency.<metric>` key segments.
public enum LatencyMetric: String, Sendable, Hashable, CaseIterable {
    case t1, t2, t3, echo, t5, t6

    public func histogram(in metrics: MetricsSnapshot) -> HistogramSnapshot {
        switch self {
        case .t1: metrics.callbackDuration
        case .t2: metrics.decideToPosted
        case .t3: metrics.decideToPostedWithAX
        case .echo: metrics.echoRoundTrip
        case .t5: metrics.heldWait
        case .t6: metrics.focusRefresh
        }
    }

    /// Name and plain definition of the metric (02-platform.md 8.1).
    public var title: DiagnosticsText {
        switch self {
        case .t1: .latencyT1
        case .t2: .latencyT2
        case .t3: .latencyT3
        case .echo: .latencyEcho
        case .t5: .latencyT5
        case .t6: .latencyT6
        }
    }
}

public struct LatencyHistogram: Sendable, Hashable, Identifiable {
    public struct Bin: Sendable, Hashable {
        /// Every sample of the bin took at most this long; `UInt64.max` for the open-ended last bucket.
        public var upperBoundNanoseconds: UInt64
        public var count: UInt64
        /// `count` relative to the fullest bin of this histogram (0...1), for the bar length.
        public var fraction: Double
    }

    public var metric: LatencyMetric
    public var samples: UInt64
    /// From the first to the last non-empty bucket, empty buckets in between included; empty without samples.
    public var bins: [Bin]
    public var id: LatencyMetric { metric }
}

public enum LatencyHistograms {
    public static func make(_ metrics: MetricsSnapshot) -> [LatencyHistogram] {
        LatencyMetric.allCases.map { metric in
            let snapshot = metric.histogram(in: metrics)
            return LatencyHistogram(metric: metric, samples: snapshot.count, bins: bins(snapshot))
        }
    }

    static func bins(_ snapshot: HistogramSnapshot) -> [LatencyHistogram.Bin] {
        let buckets = snapshot.buckets
        guard let first = buckets.firstIndex(where: { $0 > 0 }), let last = buckets.lastIndex(where: { $0 > 0 }),
            let fullest = buckets.max(), fullest > 0
        else { return [] }
        return (first...last).map { index in
            LatencyHistogram.Bin(
                upperBoundNanoseconds: upperBound(ofBucket: index, bucketCount: buckets.count), count: buckets[index],
                fraction: Double(buckets[index]) / Double(fullest))
        }
    }

    /// The upper bound of a bucket as the snapshot's own `percentile` reports it, so the bins follow whatever
    /// bucket layout `HistogramSnapshot` uses and agree with the percentiles of the copied report.
    static func upperBound(ofBucket index: Int, bucketCount: Int) -> UInt64 {
        var buckets = [UInt64](repeating: 0, count: bucketCount)
        buckets[index] = 1
        return HistogramSnapshot(buckets: buckets).percentile(1) ?? UInt64.max
    }

    /// A duration with its unit, at most two significant digits, in the interface locale: `511 ns`, `16 µs`,
    /// `2,1 ms` (Vietnamese) or `2.1 ms` (English), `4.3 s`; `∞` for the open-ended bucket.
    public static func label(nanoseconds: UInt64, locale: Locale) -> String {
        guard nanoseconds != UInt64.max else { return "∞" }
        let units: [(divisor: Double, symbol: String)] = [(1e9, "s"), (1e6, "ms"), (1e3, "µs")]
        let value = Double(nanoseconds)
        guard let unit = units.first(where: { value >= $0.divisor }) else { return String(nanoseconds) + " ns" }
        let number = (value / unit.divisor).formatted(
            FloatingPointFormatStyle<Double>(locale: locale).precision(.significantDigits(1...2)))
        return number + " " + unit.symbol
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/ShellCore/AppsPane.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Apps pane model (PRD-R34-R38).

public import AppModel
public import CompatRules
public import Foundation
public import SettingsStore

public struct AppsPaneRow: Sendable, Hashable, Identifiable {
    public var id: BundleKey { bundle }
    public var bundle: BundleKey
    public var rule: PerAppRule  // Nhớ lựa chọn / Luôn tiếng Anh / Luôn tiếng Việt / Bỏ qua
    public var rememberedMode: TypingMode?
    public var status: MatrixStatus  // after the 120-day rule (QA-R19)
    public var note: LocalizedNote?
    public var compatibilityMode: CompatibilityModeChoice
    /// Name from the matrix row, for apps that are not installed (the App prefers the installed app's name).
    public var matrixDisplayName: String?
    /// When the user chose `compatibilityMode` or applied the guided test's result ("set by you on <date>",
    /// PLT-R541): the stored override's `createdAt`. Nil for automatic.
    public var compatibilitySetOn: Date?
}

/// PRD-R36: "Chế độ tương thích" under Advanced, at most three plain choices plus automatic. Choosing one writes
/// a user override (scope "this app", PLT-R540) and attaches it to the next bug report for that app.
public enum CompatibilityModeChoice: String, Sendable, Hashable, CaseIterable {
    case automatic  // reset to automatic (removes the override)
    case typeSlower  // backspaceReplace with 5 ms pacing
    case selectThenType  // selectReplace
    case pasteText  // paste, requiresUserOptIn, clipboard explanation (PLT-R460, PLT-R462)
    /// Not a choice: the app's slot holds a guided test result (PLT-R1205 step 5) whose action is none of the
    /// modes above, for example `backspaceReplace` with `axSelection`, `axReplace` or `passThrough` (PLT-R540).
    /// Shown so the pane never says "automatic" while that override is in force; "Tự động" removes it.
    case guidedTest

    /// PRD-R36: what the pane offers, automatic plus at most three plain choices.
    public static let choices: [CompatibilityModeChoice] = [.automatic, .typeSlower, .selectThenType, .pasteText]

    /// The radio group of the app detail sheet: the choices, plus the guided test's result while it is in force.
    public static func options(current: CompatibilityModeChoice) -> [CompatibilityModeChoice] {
        current == .guidedTest ? choices + [.guidedTest] : choices
    }

    /// PRD-R36: whether the user can pick this row. The guided test's result is a status row in the radio group
    /// (shown selected, never selectable), so the pane offers no fourth non-automatic choice; "Tự động" removes it.
    public var isSelectable: Bool { self != .guidedTest }

    /// PLT-R408: 5 ms between synthetic events.
    static let slowerPacingMicroseconds = 5_000

    /// Rule JSON for `rule-overrides.json` (02-platform.md 5.4 shape, `id` prefixed `user.`), or nil for
    /// `.automatic`, which means "remove this app's compatibility override", and for `.guidedTest`, which the pane
    /// never writes. `date` is `YYYY-MM-DD`.
    /// `.pasteText` carries no `requiresUserOptIn` gate: the Apps pane shows the clipboard explanation before the
    /// user picks it, and that choice is the user's opt-in for this app (PLT-R460, PLT-R462).
    public func overrideRule(for bundle: BundleKey, date: String) -> JSONValue? {
        guard let action else { return nil }
        return .object([
            "id": .string(Self.ruleID(for: bundle).rawValue),
            "summary": .string("Compatibility mode chosen in the Apps pane: \(rawValue)"),
            "match": .object(["bundleIds": .array([.string(bundle.rawValue)])]),
            "action": .object(action),
            "provenance": .object(["source": .string("user-suggestion"), "date": .string(date)]),
        ])
    }

    private var action: [String: JSONValue]? {
        switch self {
        case .automatic, .guidedTest: nil
        case .typeSlower:
            [
                "strategy": .string(InjectionStrategy.backspaceReplace.rawValue),
                "params": .object(["interEventDelayUs": .number(Double(Self.slowerPacingMicroseconds))]),
            ]
        case .selectThenType: ["strategy": .string(InjectionStrategy.selectReplace.rawValue)]
        case .pasteText: ["strategy": .string(InjectionStrategy.paste.rawValue)]
        }
    }

    /// One compatibility override per app: `user.compat.<bundle>` with characters outside the rule ID alphabet
    /// replaced (`sha256:` keys become `sha256-`), the slot the guided test's "this app" result shares
    /// (`PerAppOverrideSlot.compat`, PLT-R540).
    public static func ruleID(for bundle: BundleKey) -> RuleID { PerAppOverrideSlot.compat.ruleID(for: bundle) }

    /// Reads the state back from the app's slot (the inverse of `overrideRule`): a mode only when the rule does
    /// exactly what the pane writes for it, "type here anyway" aside (it rides along with any mode, PLT-R540);
    /// any other action there is a guided test result (`.guidedTest`). Nil for other rules and for a slot rule
    /// without a known strategy, which the rule loader rejects (it is not in force).
    init?(overrideRule rule: JSONValue) {
        guard let id = rule["id"]?.stringValue, id.hasPrefix(PerAppOverrideSlot.compat.prefix),
            var action = rule["action"]?.objectValue,
            let strategy = action["strategy"]?.stringValue, InjectionStrategy(rawValue: strategy) != nil
        else { return nil }
        action["requireTextFocus"] = nil
        self = Self.choices.first { $0.action == action } ?? .guidedTest
    }
}

public enum AppsPaneModel {
    /// Most recent first: apps typed in (memory order) plus apps with explicit rules (PRD-R34), then apps that
    /// only have a compatibility override. The status is the matrix row that stands for the whole app
    /// (`MatrixDocument.appEntry(for:)`) after the 120-day rule; web-app and in-app rows are for the detail view.
    public static func rows(
        appModes: AppModesDocument, overrides: [StoredRuleOverride], matrix: MatrixDocument?, today: Date
    ) -> [AppsPaneRow] {
        let modes = compatibilityModes(overrides)
        let entries = Dictionary(appModes.apps.map { ($0.bundle, $0) }, uniquingKeysWith: { first, _ in first })
        return orderedBundles(appModes: appModes, modes: modes).map { bundle in
            let entry = entries[bundle]
            let matrixEntry = matrix?.appEntry(for: bundle)
            return AppsPaneRow(
                bundle: bundle, rule: entry?.rule ?? .remember, rememberedMode: entry?.mode,
                status: matrixEntry.map { MatrixStatusResolver.displayStatus($0, today: today) } ?? .notVerified,
                note: matrixEntry?.note, compatibilityMode: modes[bundle]?.choice ?? .automatic,
                matrixDisplayName: matrixEntry?.displayName, compatibilitySetOn: modes[bundle]?.createdAt)
        }
    }

    /// The apps of the pane in display order, each once: the per-app memory (most recently used first, PRD-R34),
    /// then the apps that only have a compatibility override. The bug report picker lists the same apps
    /// (PRD-R47 item 1, `RecentReportApps`).
    public static func orderedBundles(appModes: AppModesDocument, overrides: [StoredRuleOverride]) -> [BundleKey] {
        orderedBundles(appModes: appModes, modes: compatibilityModes(overrides))
    }

    private static func orderedBundles(
        appModes: AppModesDocument, modes: [BundleKey: (choice: CompatibilityModeChoice, createdAt: Date)]
    ) -> [BundleKey] {
        var bundles = appModes.apps.map(\.bundle)
        for bundle in modes.keys.sorted() where !bundles.contains(bundle) { bundles.append(bundle) }
        var seen: Set<BundleKey> = []
        return bundles.filter { seen.insert($0).inserted }
    }

    /// Newest compatibility override per app.
    private static func compatibilityModes(_ overrides: [StoredRuleOverride])
        -> [BundleKey: (choice: CompatibilityModeChoice, createdAt: Date)]
    {
        var modes: [BundleKey: (choice: CompatibilityModeChoice, createdAt: Date)] = [:]
        for stored in overrides.sorted(by: { $0.createdAt > $1.createdAt }) {
            guard let choice = CompatibilityModeChoice(overrideRule: stored.rule),
                case .array(let ids)? = stored.rule["match"]?["bundleIds"]
            else { continue }
            for case .string(let raw) in ids {
                guard let bundle = BundleKey(rawValue: raw), modes[bundle] == nil else { continue }
                modes[bundle] = (choice, stored.createdAt)
            }
        }
        return modes
    }
}

/// The app detail sheet (PRD-R35, PRD-R36): status and note of the app row, the web-app and in-app rows of the
/// matrix, and the compatibility mode under Advanced.
public struct AppDetail: Sendable, Hashable {
    public let row: AppsPaneRow
    /// `MatrixDocument.scopedEntries(for:)` with their display status, only shown here.
    public let scoped: [ScopedStatus]
    /// ISO date of the app row's last verification, if any.
    public let lastVerified: String?

    public struct ScopedStatus: Sendable, Hashable {
        public var entry: MatrixEntry
        public var status: MatrixStatus
    }

    public init(row: AppsPaneRow, matrix: MatrixDocument?, today: Date) {
        self.row = row
        scoped = (matrix?.scopedEntries(for: row.bundle) ?? []).map {
            ScopedStatus(entry: $0, status: MatrixStatusResolver.displayStatus($0, today: today))
        }
        lastVerified = matrix?.appEntry(for: row.bundle)?.lastVerified
    }
}

extension CompatibilityModeChoice {
    /// `YYYY-MM-DD` in the user's calendar day.
    static func day(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// PRD-R48, PLT-R462: the paste mode is chosen only after the clipboard explanation.
    public var needsClipboardExplanation: Bool { self == .pasteText }

    public var title: AppsText {
        switch self {
        case .automatic: .compatAutomatic
        case .typeSlower: .compatTypeSlower
        case .selectThenType: .compatSelectThenType
        case .pasteText: .compatPasteText
        case .guidedTest: .compatGuidedTest
        }
    }

    /// PRD-R36: one sentence per choice (and for the guided test's state).
    public var explanation: AppsText {
        switch self {
        case .automatic: .compatAutomaticExplanation
        case .typeSlower: .compatTypeSlowerExplanation
        case .selectThenType: .compatSelectThenTypeExplanation
        case .pasteText: .compatPasteTextExplanation
        case .guidedTest: .compatGuidedTestExplanation
        }
    }
}

extension PerAppRule {
    /// PRD-R34 column labels.
    public var appsTitle: AppsText {
        switch self {
        case .remember: .ruleRemember
        case .alwaysEnglish: .ruleAlwaysEnglish
        case .alwaysVietnamese: .ruleAlwaysVietnamese
        case .ignore: .ruleIgnore
        }
    }
}

extension MatrixStatus {
    /// PRD-R35 labels.
    public var appsTitle: AppsText {
        switch self {
        case .works: .statusWorks
        case .worksWithNotes: .statusWorksWithNotes
        case .notVerified: .statusNotVerified
        case .knownLimitation: .statusKnownLimitation
        }
    }

    /// SF Symbol shown with the label, so the status never relies on colour alone (PRD-R67).
    public var symbolName: String {
        switch self {
        case .works: "checkmark.circle"
        case .worksWithNotes: SettingsSymbol.info
        case .notVerified: "questionmark.circle"
        case .knownLimitation: "exclamationmark.triangle"
        }
    }
}

extension AppsPaneRow {
    /// Remembered mode column (PRD-R34).
    public var rememberedModeTitle: AppsText {
        switch rememberedMode {
        case .vietnamese: .modeVietnamese
        case .english: .modeEnglish
        case nil: .modeNone
        }
    }

    /// The matrix note in the interface language (PRD-R35).
    public func noteText(_ language: InterfaceLanguage) -> String? {
        note.map { language == .vietnamese ? $0.vi : $0.en }
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/ShellCore/Services.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later

internal import AppModel
public import Foundation
internal import ServiceManagement

/// Launch at login (PLT-R205, D17). Production: `SMAppService.mainApp` `status`, `register()`, `unregister()`;
/// `requiresApproval` opens System Settings > Login Items via `SMAppService.openSystemSettingsLoginItems()`.
/// macOS 12 has no `SMAppService` (ADR 0315): the status is `unavailable`, the user adds the app by hand and
/// `openSystemSettings()` opens System Preferences > Users & Groups.
public protocol LoginItemService: Sendable {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

public enum LoginItemStatus: String, Sendable, Hashable {
    case enabled, notRegistered, requiresApproval, notFound
    /// macOS 12: the app cannot register itself; the user adds it in System Preferences (ADR 0315).
    case unavailable
}

/// `register()` and `unregister()` on macOS 12, where the app cannot change its own login item.
public struct LoginItemUnavailable: Error, Sendable, Hashable {
    public init() {}
}

/// Thin wrapper; `status(from:)` and the macOS 12 branch are unit tested because the other members change the
/// user's login items (verified by Pa, traceability PLT-R205).
public struct SMAppServiceLoginItem: LoginItemService {
    private let usesService: Bool
    private let openLegacyLoginItems: @Sendable () -> Void

    /// - Parameter openLegacyLoginItems: macOS 12 only. Opens System Preferences > Users & Groups (the
    ///   `loginItems` deep link of SystemPanes.json) so the user can add the app to Login Items.
    public init(openLegacyLoginItems: @escaping @Sendable () -> Void = {}) {
        self.init(usesService: Self.serviceExists, openLegacyLoginItems: openLegacyLoginItems)
    }

    /// `usesService: false` is the macOS 12 behaviour (tests run it on any system).
    init(usesService: Bool, openLegacyLoginItems: @escaping @Sendable () -> Void) {
        self.usesService = usesService
        self.openLegacyLoginItems = openLegacyLoginItems
    }

    static var serviceExists: Bool {
        if #available(macOS 13, *) { true } else { false }
    }

    public var status: LoginItemStatus {
        if usesService, #available(macOS 13, *) { return Self.status(from: SMAppService.mainApp.status) }
        return .unavailable
    }

    public func register() throws {
        guard usesService, #available(macOS 13, *) else { throw LoginItemUnavailable() }
        try SMAppService.mainApp.register()
    }

    public func unregister() throws {
        guard usesService, #available(macOS 13, *) else { throw LoginItemUnavailable() }
        try SMAppService.mainApp.unregister()
    }

    public func openSystemSettings() {
        guard usesService, #available(macOS 13, *) else { return openLegacyLoginItems() }
        SMAppService.openSystemSettingsLoginItems()
    }

    @available(macOS 13, *)
    static func status(from status: SMAppService.Status) -> LoginItemStatus {
        switch status {
        case .enabled: .enabled
        case .notRegistered: .notRegistered
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }
}

/// What the About & Support pane needs from the Sparkle wrapper (App/Updater), so its view model is testable.
@MainActor
public protocol UpdaterControlling: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    var channel: UpdateChannelSelection { get set }
    func checkForUpdates()
}

public enum UpdateChannelSelection: String, Sendable, Hashable { case stable, beta }

/// PLT-R909: `<slug>://` may only open Settings; every other component or parameter is ignored.
public enum URLSchemeRouter {
    public enum Route: Sendable, Hashable { case openSettings, ignore }

    /// Any URL with the app's scheme opens Settings and nothing else: host, path, query and fragment never select
    /// a pane, change a setting, start a capture or export data.
    public static func route(_ url: URL, scheme: String) -> Route {
        guard let urlScheme = url.scheme, !scheme.isEmpty else { return .ignore }
        return urlScheme.caseInsensitiveCompare(scheme) == .orderedSame ? .openSettings : .ignore
    }
}

/// Donation block (PRD-R59; Pa's decision S8: a bank VietQR code only, no MoMo). The bank name and the account
/// number are shown next to the code; the account holder's name is never shown (the VietQR payload carries no
/// name, the payer's bank app shows it after the scan). The QR image is a bundled asset generated by
/// `scripts/make-vietqr.py`, never fetched.
public struct DonationInfo: Sendable, Hashable {
    public var bankName: String
    public var accountNumber: String
    public var vietQRImageName: String  // asset catalog name
    public var githubSponsorsURL: URL?  // shown once Pa has a sponsor page (PRD-R57)
    public static let standard = DonationInfo(
        bankName: "LioBank", accountNumber: "688688678", vietQRImageName: "DonationVietQR", githubSponsorsURL: nil)
}
```
<!-- /include -->

## 12. App: AppShell components and the Sparkle wrapper

Owned files: `App/Sources/Shell/**`, `App/Sources/Onboarding/**`, `App/Resources/Localization/{Localizable,Menu,Status,Onboarding}.xcstrings`,
`App/Resources/Assets.xcassets/**`, `App/Resources/SystemPanes.json` (W1-G); `App/Sources/Composition/**` and the
`Composition` table (W2-A); `App/Sources/Settings/**` and the `Settings`, `Macros`, `Apps`, `Support` tables
(W2-B); `App/Sources/Diagnostics/**` and the `Diagnostics` table (W2-C); `App/Sources/Updater/**` and the
`Updates` table (W2-D). Isolation: main actor throughout. Framework choice: [0305](../decisions/0305-ui-framework.md).

String Catalogs (`App/Resources/Localization/`, one table per feature area, `StringTable` in ShellCore):
`Localizable` (common words), `Menu`, `Status`, `Onboarding`, `Settings`, `Macros`, `Apps`, `Diagnostics`,
`Support`, `Updates` and `Composition` (the composition root's safe-mode, move-failed and conflict notices,
keys in ShellCore's `CompositionText`). Every table is read through `Localizer` in the selected language.

The skeleton's `AppMain` shows `BootstrapStatusItem` (a programmatically drawn template glyph from
`StatusGlyph`, a status line and Quit), so the App target launches without touching any unimplemented contract.
W1-G replaces it with `StatusItemController`; W2-A removes it from the launch path. The Sparkle delegate methods
are `nonisolated` and read main-actor state through `MainActor.assumeIsolated` (Sparkle calls them on the main
thread).

<!-- include: App/Sources/Composition/AppEnvironment.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Composition root (workstream W2-A). Builds every production service once, wires AppCore modules together
// and owns the window controllers. Main actor only. The launch order is `LaunchSequence` (InputHost
// Integration, tested with fakes); the shell and onboarding wiring live in `AppEnvironment+*.swift`.

import AppKit
import AppModel
import Carbon.HIToolbox
import CompatRules
import Diagnostics
import Injection
import InputHost
import RealtimeSupport
import SettingsStore
import ShellCore

@MainActor
final class AppEnvironment {
    let brand: Brand
    let language: InterfaceLanguageModel
    let settingsStore: SettingsStore
    let host: InputHostController
    /// Created by the launch's shell step (PRD-R9), after the location check and the settings load.
    private(set) var statusItem: StatusItemController?
    /// Created by the launch's last step (PLT-R1101).
    private(set) var updater: UpdaterController?

    let paths: StoragePaths
    let utility: DispatchQueue
    let keyValues = UserDefaultsKeyValueStore()
    let launchGuard: LaunchGuard
    let diagnostics: DiagnosticsWiring
    let loginItem = SMAppServiceLoginItem(openLegacyLoginItems: AppEnvironment.openLegacyLoginItems)
    let settingsChanges = MainActorRelay<SettingsState>()
    /// System uptime at launch: keys pressed before it do not count for the relaunch policy (PLT-R1105).
    let launchUptime = ProcessInfo.processInfo.systemUptime
    var settings = SettingsState()
    var safeMode = false
    var launch: LaunchSequence?
    var switchHUD: SwitchHUDController?
    var onboarding: OnboardingWindowController?
    /// PRD-R40 screen 6: competitor apps seen running while onboarding is open, kept after the user quits them on
    /// screen 5 so the import offer still appears.
    var importCandidates: [ImportCandidate] = []
    var settingsWindow: SettingsWindowController?
    var diagnosticsWindow: DiagnosticsWindowController?
    /// The latest latency probe result (PLT-R810), included in the next diagnostics report.
    var latencyProbeResult: LatencyProbeResult?
    lazy var paneTable: SystemPaneTable? = Self.loadPaneTable()
    /// The bundled compatibility matrix, read the first time the menu opens (PRD-R43 known-limitation line).
    lazy var matrix: MatrixDocument? = SettingsResources.bundledMatrix()
    #if INTEGRATION_HOOKS
    /// The self-hosted runner's test build only: answers the integration hooks (ADR 0502).
    let integrationHooks: IntegrationHooksApp
    #endif
    /// QA-R42: the first launch after an update checks the host once it left `starting`.
    var selfCheckPending = false
    /// PRD-R43: the "tap re-enabled" line stays in the status menu for a while after an instability notice.
    var tapReenabledUntil: Date?
    var lastMenuRefresh: Date?
    /// The quit under way (AppEnvironment+Quit.swift): settings flushed off the main actor, reply through the run loop.
    var quit: QuitCoordinator?

    /// Launch order (S1 target 300 ms to tap active): LaunchGuard -> AppLocationCheck (move offer before any
    /// permission request, PLT-R710) -> LegacyStorageMigrator -> SettingsStore.load ->
    /// RulesLoader.load(compat-rules.json) -> InputHostController.start -> StatusItemController -> onboarding if
    /// not completed (PRD-R40, PRD-R42) -> UpdaterController.start.
    init(bundle: Bundle) {
        brand = Brand.from(bundle)
        language = InterfaceLanguageModel(language: DefaultSettings.v1.interfaceLanguage, appBundle: bundle)
        paths = StoragePaths(folder: brand.storageFolderName)
        utility = DispatchQueue(label: brand.slug + ".utility", qos: .utility)
        launchGuard = LaunchGuard(store: keyValues)
        diagnostics = DiagnosticsWiring(
            paths: paths, subsystem: brand.bundleIdentifier, utility: utility, defaults: .standard)
        let relay = settingsChanges
        settingsStore = SettingsStore(
            location: StorageLocation(directory: paths.applicationSupport), fileSystem: LocalFileSystem(),
            wallClock: SystemWallClock(), writtenBy: brand.version, queue: utility, launchGuard: launchGuard,
            onChange: { relay.send($0) })
        var hostDependencies = InputHostDependencies.production(
            diagnostics: diagnostics, keyValues: keyValues, utility: utility)
        #if INTEGRATION_HOOKS
        integrationHooks = IntegrationHooksApp(instrumenting: &hostDependencies)
        #endif
        host = InputHostController(dependencies: hostDependencies, settingsStore: settingsStore)
        settingsChanges.connect { [weak self] state in self?.settingsChanged(state) }
        host.onEvent = { [weak self] event in self?.hostEvent(event) }
    }

    func start() {
        diagnostics.logger.log(.lifecycle(.launched(appIdentity)), level: .notice)
        let sequence = LaunchSequence(
            launchGuard: launchGuard, appVersion: bundleVersion, wallClock: SystemWallClock(),
            scheduler: DispatchTimerScheduler(queue: utility), steps: self)
        launch = sequence
        Task {
            switch await sequence.run() {
            case .running(let safeMode): self.launched(safeMode: safeMode)
            case .relocating, .quit: NSApp.terminate(nil)
            }
        }
    }

    /// `<slug>://...` opens Settings and nothing else (PLT-R909).
    func handle(url: URL) {
        guard URLSchemeRouter.route(url, scheme: brand.urlScheme) == .openSettings else { return }
        openSettings()
    }

    // MARK: Launch results

    /// `CFBundleShortVersionString` plus the build, so an update clears a crash loop (W1-B request).
    var bundleVersion: String { LaunchSequence.versionString(short: brand.version, build: brand.build) }

    var appIdentity: AppIdentity {
        AppIdentity(
            displayName: brand.displayName, slug: brand.slug, bundleIdentifier: brand.bundleIdentifier,
            version: brand.version, build: brand.build, channel: settings.effective.updateChannel)
    }

    private func launched(safeMode: Bool) {
        self.safeMode = safeMode
        diagnostics.startMaintenance()
        if safeMode {
            diagnostics.logger.log(
                .lifecycle(.safeModeEntered(recentCrashes: launchGuard.recentCrashes)), level: .error)
            diagnostics.health.record(HealthEvent(kind: .safeModeEntered, at: Date()))
            DispatchQueue.main.async { [weak self] in self?.presentSafeMode() }
        }
        selfCheckPending = UpdateSelfCheck(store: keyValues).noteLaunch(version: bundleVersion) == .versionChanged
        evaluateSelfCheck()
    }

    /// Every settings change: the host (engines, rules, focus), the language, the shell and the updater.
    func settingsChanged(_ state: SettingsState) {
        reportNewNotices(state.notices)
        settings = state
        safeMode = state.safeMode  // PLT-R1009: the store decides; leaving safe mode reloads the files
        host.apply(settings: state)
        #if DEV_RECORDER
        noteDevSettings(state)  // PLT-R904A
        #endif
        language.select(state.effective.interfaceLanguage)
        statusItem?.setClickToToggle(state.effective.clickIconToToggle)
        settingsWindow?.settingsChanged(state)  // changes made elsewhere show at once (menu, memory, import)
        applyUpdaterSettings()
        updateIcon()
    }

    /// PLT-R1006, PLT-R1007, PLT-R1202: each new store notice is logged (contracts.md `LogEvent.SettingsEvent`)
    /// and recorded as a health event, so the log and the report show the episode even if Settings never opens.
    /// Compared with `settings.notices`, which still holds the previous state.
    func reportNewNotices(_ notices: [StoreNotice]) {
        let now = Date()
        for notice in StoreNoticeReporting.added(previous: settings.notices, current: notices) {
            if let event = StoreNoticeReporting.logEvent(notice) {
                diagnostics.logger.log(.settings(event), level: StoreNoticeReporting.logLevel(notice))
            }
            if let health = StoreNoticeReporting.healthEvent(notice, at: now) { diagnostics.health.record(health) }
        }
    }

    /// D19-D21 from the store reach Sparkle through `apply`, which never reports back (setting the controller's
    /// properties would record the stored values as new user choices, PRD-R6).
    func applyUpdaterSettings() {
        updater?.apply(UpdatePreferences(settings.effective))
    }

    /// PLT-R1105: seconds since the last key press since launch (`.infinity` when none) and the system's secure
    /// input state. Read once, when Sparkle offers the immediate install.
    func keyboardIdleState() -> (secondsSinceLastKey: Double, secureInputOn: Bool) {
        let systemIdle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let idle = KeyboardIdleReading.secondsSinceLastKey(
            systemIdleSeconds: systemIdle, secondsSinceLaunch: ProcessInfo.processInfo.systemUptime - launchUptime)
        return (secondsSinceLastKey: idle, secureInputOn: IsSecureEventInputEnabled())
    }

    /// macOS 12 (ADR 0315): no `SMAppService`, so the System Preferences button opens System Preferences >
    /// Users & Groups, where the user adds the app to Login Items by hand.
    nonisolated private static func openLegacyLoginItems() {
        guard let url = loadPaneTable()?.deepLink(.loginItems, macOS: InputHostController.macOSVersion) else { return }
        NSWorkspace.shared.open(url)
    }

    nonisolated private static func loadPaneTable() -> SystemPaneTable? {
        guard let url = Bundle.main.url(forResource: "SystemPanes", withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else { return nil }
        return try? SystemPaneTable(resource: data)
    }
}

// MARK: - Launch steps

extension AppEnvironment: LaunchSteps {
    func resolveLocation() async -> LaunchLocationDecision {
        #if DEBUG || INTEGRATION_HOOKS
        // Development builds run from DerivedData; the move offer is a shipped-app behaviour (PLT-R710). The
        // runner's test build is installed at one fixed path whose TCC grants a move would lose, and it never
        // shows a modal offer (scripts/run-integration.sh build).
        return .proceed
        #else
        let bundleURL = Bundle.main.bundleURL
        let launchGuard = self.launchGuard
        let files = FileManagerRelocationFiles()
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let relocator = AppRelocator(
            files: files, relauncher: WorkspaceRelauncher(beforeLaunch: { launchGuard.markSurvived() }),
            applicationsDirectory: AppRelocator.applicationsDirectory(
                system: URL(fileURLWithPath: "/Applications", isDirectory: true),
                user: home.appendingPathComponent("Applications", isDirectory: true), files: files))
        let gate = LocationGate<AppLocationCheck.Reason>(
            verdict: { Self.locationVerdict(bundleURL) },
            offer: { [language, brand] reason in
                MoveOfferAlert.ask(reason: reason, appName: brand.displayName, language: language) == .move
            },
            reportFailure: { [weak self] _ in
                guard let self else { return }
                CompositionAlerts.moveFailed(appName: brand.displayName, localizer: language.localizer)
            }, relocator: relocator, bundleURL: bundleURL)
        return await gate.resolve()
        #endif
    }

    static func locationVerdict(_ bundleURL: URL) -> LocationGate<AppLocationCheck.Reason>.Verdict {
        let readOnly = (try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? false
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        switch AppLocationCheck.evaluate(bundleURL: bundleURL, homeDirectory: home, isOnReadOnlyVolume: readOnly) {
        case .ok: return .ok
        case .mustMove(let reason): return .mustMove(reason)
        }
    }

    func migrateLegacyStorage() {
        let brand = self.brand
        let bases = paths.bases
        utility.sync {
            _ = LegacyStorageMigrator.migrate(
                current: brand.storageFolderName, legacyNames: brand.legacyStorageFolderNames, bases: bases,
                fileSystem: LocalFileSystem())
        }
    }

    func loadSettings() async -> SettingsState {
        let state = await settingsStore.load()
        reportNewNotices(state.notices)
        settings = state
        language.select(state.effective.interfaceLanguage)
        return state
    }

    func loadRules() -> RulesLoadResult {
        let url =
            Bundle.main.url(forResource: "compat-rules", withExtension: "json")
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/compat-rules.json")
        return RulesLoader.load(contentsOf: url)
    }

    func startHost(rules: RulesLoadResult, settings: SettingsState) {
        host.start(rules: rules, settings: settings)
        #if INTEGRATION_HOOKS
        startIntegrationHooks()
        #endif
    }

    func showShell(settings: SettingsState, safeMode: Bool) {
        let item = StatusItemController(language: language, actions: self) { [unowned self] in menuModel() }
        statusItem = item
        switchHUD = SwitchHUDController(language: language)
        item.setClickToToggle(settings.effective.clickIconToToggle)
        updateIcon()
        #if DEV_RECORDER
        startDevRecorder(statusItem: item, settings: settings)  // PLT-R904A: always on in dev builds
        #endif
    }

    func presentOnboarding(settings: SettingsState) {
        presentOnboarding(startAt: nil)
    }

    /// PLT-R1101: D19-D21 are applied before Sparkle starts; changes the user makes in the updater (About & Support,
    /// Sparkle's window) are written to settings.json as explicit keys, one key per change (PRD-R6).
    func startUpdater(settings: SettingsState) {
        let controller = UpdaterController(
            idleState: { [weak self] in self?.keyboardIdleState() ?? (secondsSinceLastKey: 0, secureInputOn: true) },
            dependencies: .live(bundle: .main, logger: diagnostics.logger, language: language))
        let store = settingsStore
        controller.onPreferenceChange = { change in
            Task { await store.updateSettings { change.apply(to: &$0) } }
        }
        updater = controller
        controller.apply(UpdatePreferences(settings.effective))
        controller.start()
    }
}
```
<!-- /include -->

<!-- include: App/Sources/Shell/StatusItemController.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Menu-bar status item and menu (PRD-R9-R13), switch HUD (PRD-R12) and capture HUD (PLT-R905).
// Workstream W1-G.

import AppKit
import AppModel
import Combine
import RealtimeSupport
import ShellCore

/// Actions the menu triggers; implemented by AppEnvironment.
@MainActor
protocol StatusMenuActions: AnyObject {
    func setMode(_ mode: TypingMode)
    func setMethod(_ method: TypingMethod)
    func setRule(_ rule: PerAppRule, for bundle: BundleKey)
    func reportProblem(for bundle: BundleKey?)
    func openMacros()
    func openSettings()
    func checkForUpdates()
    func openSupport()
    func performStatusAction(_ action: StatusLine.Action)
}

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let language: InterfaceLanguageModel
    private let menuModel: @MainActor () -> MenuModel
    private weak var actions: (any StatusMenuActions)?
    private var iconState: StatusIconState = .notWorking
    private var labelKey: String?
    private var appName: String?
    private var clickToToggle = false
    private var languageObservation: AnyCancellable?
    #if DEV_RECORDER
    /// PLT-R904A: the dev recorder's badge and menu items.
    var devRecorder: DevRecorderController? {
        didSet {
            devRecorder?.indicatorChanged = { [weak self] in self?.applyIcon() }
            devRecorder?.announce = { [weak self] text in self?.announce(text) }
            applyIcon()
        }
    }
    #endif

    /// `menuModel` is called from `menuNeedsUpdate(_:)` so the menu is rebuilt on every open (PRD-R13).
    init(
        language: InterfaceLanguageModel, actions: any StatusMenuActions,
        menuModel: @escaping @MainActor () -> MenuModel
    ) {
        self.language = language
        self.actions = actions
        self.menuModel = menuModel
        // PRD-R9: always visible; the default behavior does not allow the user to remove it.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusButtonClicked(_:))
        applyIcon()
        observeLanguage()
    }

    /// Catalog image `StatusIconState.imageName` (via `StatusGlyph`) plus `accessibilityLabel` from the Menu table.
    func show(_ state: StatusIconState) {
        show(state, accessibilityLabelKey: nil)
    }

    /// `accessibilityLabelKey` from `StatusPresentation.accessibilityLabelKey(icon:state:)` keeps the VoiceOver
    /// label truthful for states that share a glyph (PLT-R211).
    func show(_ state: StatusIconState, accessibilityLabelKey: String?) {
        iconState = state
        labelKey = accessibilityLabelKey
        appName = menuModel().appName
        applyIcon()
    }

    /// D16: primary click toggles when enabled; the menu then opens on secondary click.
    func setClickToToggle(_ enabled: Bool) {
        clickToToggle = enabled
        statusItem.menu = enabled ? nil : menu
        statusItem.button?.sendAction(on: enabled ? [.leftMouseUp, .rightMouseUp] : [.leftMouseUp])
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let model = menuModel()
        appName = model.appName
        menu.removeAllItems()
        #if DEV_RECORDER
        if let devRecorder {
            for item in DevRecorderMenu.items(for: devRecorder, localizer: language.localizer) { menu.addItem(item) }
        }
        #endif
        let builder = StatusMenuBuilder(localizer: language.localizer, target: self)
        for entry in model.entries { menu.addItem(builder.item(for: entry, model: model)) }
    }

    // MARK: - Icon and language

    private func applyIcon() {
        guard let button = statusItem.button else { return }
        // Not a template: the variant follows the button's effective appearance (StatusGlyph).
        button.image = StatusGlyph.image(for: iconState)
        let localizer = language.localizer
        button.setAccessibilityLabel(localizer.string(labelKey ?? iconState.accessibilityLabelKey, table: .menu))
        #if DEV_RECORDER
        if let devRecorder, devRecorder.isRecording, let image = button.image {
            button.image = DevRecorderBadge.image(over: image, flashing: devRecorder.isFlashing)
            let label = localizer.string(labelKey ?? iconState.accessibilityLabelKey, table: .menu)
            button.setAccessibilityLabel(label + ", " + localizer.string(DevRecorderText.badgeLabel))
        }
        #endif
        if let appName { button.setAccessibilityHelp(localizer.format(MenuText.statusItemHint, appName)) }
    }

    #if DEV_RECORDER
    /// PRD-R66: the marker confirmation is spoken, from the status item's window, without taking focus.
    private func announce(_ text: String) {
        guard let window = statusItem.button?.window else { return }
        NSAccessibility.post(
            element: window, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
    #endif

    /// PRD-R63: the status item's label follows a language change at once; the menu is rebuilt on next open.
    private func observeLanguage() {
        languageObservation = language.afterChange { [weak self] in self?.applyIcon() }
    }

    // MARK: - Actions (targets of the menu items built by StatusMenuBuilder)

    @objc private func statusButtonClicked(_ sender: Any?) {
        guard clickToToggle else { return }
        let event = NSApp.currentEvent
        let secondary = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if secondary {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            actions?.setMode(menuModel().mode.toggled)
        }
    }

    @objc func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = TypingMode(rawValue: raw) else { return }
        actions?.setMode(mode)
    }

    @objc func selectMethod(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let method = TypingMethod(rawValue: raw) else { return }
        actions?.setMethod(method)
    }

    @objc func selectRule(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? RuleChoice else { return }
        actions?.setRule(choice.rule, for: choice.bundle)
    }

    @objc func reportForApp(_ sender: NSMenuItem) {
        actions?.reportProblem(for: (sender.representedObject as? BundleChoice)?.bundle)
    }

    @objc func reportProblem(_ sender: NSMenuItem) { actions?.reportProblem(for: nil) }
    @objc func openMacros(_ sender: NSMenuItem) { actions?.openMacros() }
    @objc func openSettings(_ sender: NSMenuItem) { actions?.openSettings() }
    @objc func checkForUpdates(_ sender: NSMenuItem) { actions?.checkForUpdates() }
    @objc func openSupport(_ sender: NSMenuItem) { actions?.openSupport() }

    @objc func performStatusAction(_ sender: NSMenuItem) {
        guard let action = (sender.representedObject as? StatusActionBox)?.action else { return }
        actions?.performStatusAction(action)
    }
}

/// Non-activating panel near the bottom centre showing V or E for 600 ms; respects Reduce Motion; posts an
/// accessibility announcement; never shown for automatic per-app switches (PRD-R12, PRD-R66).
@MainActor
final class SwitchHUDController {
    private let language: InterfaceLanguageModel
    private let panel = HUDPanelFactory.switchPanel()
    private var indicator: SwitchIndicator?

    convenience init(language: InterfaceLanguageModel) {
        self.init(language: language, scheduler: DispatchTimerScheduler(queue: .main))
    }

    /// `scheduler` must deliver on the main queue; timing lives in ShellCore's `SwitchIndicator`.
    init(language: InterfaceLanguageModel, scheduler: any TimerScheduler) {
        self.language = language
        indicator = SwitchIndicator(scheduler: scheduler) { [weak self] change in self?.apply(change) }
    }

    /// Callers pass only manual toggles with D14 on (`SwitchIndicator.shouldShow`); automatic per-app switches
    /// never reach here (PRD-R12).
    func show(_ mode: TypingMode) {
        indicator?.show(mode)
    }

    private func apply(_ change: SwitchIndicator.Change) {
        switch change {
        case .show(let mode):
            let localizer = language.localizer
            let glyph = localizer.string(mode == .vietnamese ? MenuText.hudVietnameseGlyph : MenuText.hudEnglishGlyph)
            let announcement = localizer.string(
                mode == .vietnamese ? MenuText.hudVietnameseAnnouncement : MenuText.hudEnglishAnnouncement)
            HUDPanelFactory.present(panel, content: SwitchHUDView(glyph: glyph, label: announcement))
            HUDPanelFactory.announce(announcement, from: panel)  // PRD-R66
        case .hide:
            HUDPanelFactory.dismiss(panel)
        }
    }
}

/// Floating countdown with a Stop button on all Spaces and above full-screen apps while a typing trace
/// records (PLT-R905).
@MainActor
final class CaptureHUDController {
    private let language: InterfaceLanguageModel
    private let stop: @MainActor () -> Void
    private let panel = HUDPanelFactory.capturePanel()

    init(language: InterfaceLanguageModel, stop: @escaping @MainActor () -> Void) {
        self.language = language
        self.stop = stop
    }

    func show(remaining: TimeSpan) {
        let localizer = language.localizer
        let content = CaptureHUDView(
            title: localizer.string(MenuText.captureTitle),
            remaining: localizer.format(MenuText.captureRemaining, localizer.formatCountdown(remaining)),
            stopTitle: localizer.string(MenuText.captureStop),
            stopLabel: localizer.string(MenuText.captureStopLabel),
            stopHint: localizer.string(MenuText.captureStopHint),
            stop: { [weak self] in self?.stop() })
        HUDPanelFactory.presentCapture(panel, content: content)
    }

    func hide() {
        panel.orderOut(nil)
    }
}
```
<!-- /include -->

<!-- include: App/Sources/Onboarding/OnboardingWindowController.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Onboarding window, 640 x 480 pt, centred, not floating, eight screens driven by ShellCore's OnboardingFlow
// (PRD-R40-R42). Workstream W1-G.

import AppKit
import AppModel
import Combine
import InputHost
import SettingsStore
import ShellCore
import SwiftUI

@MainActor
protocol OnboardingActions: AnyObject {
    func openPermissionPane()  // deep link from SystemPanes.json (PLT-R704)
    func openInputMonitoringPane()  // PLT-R702, only when macOS demands Input Monitoring
    /// PLT-R702: `CGRequestListenEventAccess()` once, when screen 2 first shows Input Monitoring as needed.
    func requestInputMonitoringAccess()
    func resetPermission() -> PermissionReset.Outcome  // PLT-R740, after confirmation
    func relaunch()  // PLT-R712
    func setTypingMethod(_ method: TypingMethod)
    /// PRD-R40 screen 4 "Đổi phím chuyển", recorded inline: the tap's hotkeys are suspended while the recorder
    /// captures keys (ADR 0305), the recorded binding is saved as the toggle key (D11, PRD-R6 explicit).
    func setHotkeyRecorderActive(_ active: Bool)
    func saveToggleHotkey(_ binding: HotkeyBinding)
    func currentLayout() -> LayoutTable?
    func openConflictHelp(_ conflict: ConflictingInput)  // PRD-R40 screen 5 help page (never quits other apps)
    func openKeyboardPane()  // PRD-R40 screen 5, built-in Vietnamese source
    func setOpenAtLogin(_ enabled: Bool)
    /// False on macOS 12, where the app cannot add itself to the login items (ADR 0315).
    var canOpenAtLogin: Bool { get }
    /// PRD-R40 screen 6, PRD-R32: the user's macros, for the import preview's duplicates.
    func currentMacros() async -> [StoredMacro]
    /// The merged list after the user confirmed the preview.
    func saveImportedMacros(_ macros: [StoredMacro])
    func complete()
    /// The window closed; `completed == false` means before the last screen (PRD-R41: the status line then offers
    /// to resume at screen 2, and fast permission polling stops).
    func onboardingClosed(completed: Bool)
}

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    static let contentSize = NSSize(width: 640, height: 480)

    private let model: OnboardingModel
    private var languageObservation: AnyCancellable?

    required init?(coder: NSCoder) { nil }

    /// `startAt: .permission` for the "permission lost" variant (PRD-R42) and for resuming (PRD-R41).
    /// `appName` comes from `Brand`; `panes` from `SystemPaneTable` for the running macOS and its language
    /// (PRD-R64); `method` and `mode` are the current typing method and VI/EN mode.
    init(
        flow: OnboardingFlow, language: InterfaceLanguageModel, actions: any OnboardingActions,
        inputs: @escaping @MainActor () -> OnboardingInputs, appName: String, panes: SystemPaneNames,
        method: TypingMethod = .telex, mode: TypingMode = .vietnamese, toggleHotkey: HotkeyBinding = .defaultToggle
    ) {
        model = OnboardingModel(
            flow: flow, language: language, actions: actions, inputs: inputs, appName: appName, panes: panes,
            method: method, mode: mode, toggleHotkey: toggleHotkey)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize), styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.level = .normal  // PRD-R40: not floating
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: OnboardingRootView(model: model))
        window.setContentSize(Self.contentSize)
        window.center()
        super.init(window: window)
        window.delegate = self
        model.onFinish = { [weak self] in self?.close() }
        refreshTitle()
        observeLanguage()
    }

    /// Called by the permission monitor (1 s polling while visible, PLT-R711).
    func permissionChanged(_ status: PermissionStatus) {
        model.permissionChanged(status)
    }

    /// VI/EN changes feed the try-it checklist ("press the toggle hotkey once and back", PRD-R40 screen 7).
    func modeChanged(_ mode: TypingMode) {
        model.modeChanged(mode)
    }

    func windowWillClose(_ notification: Notification) {
        model.windowClosed()
    }

    /// ADR 0305: another window or app took the keyboard, so the recorder stops taking key events.
    func windowDidResignKey(_ notification: Notification) {
        model.interruptHotkeyRecording()
    }

    /// PRD-R63: the window title follows a language change; SwiftUI content re-renders by itself.
    private func refreshTitle() {
        window?.title = model.localizer.format(OnboardingText.windowTitle, model.appName)
    }

    private func observeLanguage() {
        languageObservation = model.language.afterChange { [weak self] in self?.refreshTitle() }
    }
}
```
<!-- /include -->

<!-- include: App/Sources/Settings/SettingsWindowController.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Settings window with at most five panes (PRD-R24-R28), macros editor (PRD-R29-R33) and Apps pane
// (PRD-R34-R38). Workstream W2-B; System Settings style sidebar layout W8-D (Pa, 2026-11-14). A normal window (not
// floating) whose size and position are remembered (PRD-R28); SwiftUI content in an NSHostingController (ADR 0305).

import AppKit
import AppModel
import Combine
import CompatRules
import InputHost
import SettingsStore
import ShellCore
import SwiftUI

/// The pane identifiers used by the composition root (`show(.macros)`, `show(.aboutSupport)`).
typealias SettingsPane = SettingsPaneKind

/// What the Settings window asks the composition root to do; implemented by AppEnvironment.
@MainActor
protocol SettingsActions: AnyObject {
    /// "Báo lỗi..." (About & Support, safe-mode notice) and "Báo lỗi với ứng dụng này..." (PRD-R37): the bug report
    /// sheet, pre-filled with `bundle` when given.
    func reportProblemFromSettings(for bundle: BundleKey?)
    /// "Chẩn đoán..." (D26 entry, W2-C's diagnostics window).
    func openDiagnostics()
    /// PRD-R40: onboarding can be reopened from About & Support.
    func reopenOnboarding()
    /// ADR 0305: the tap suspends hotkeys while the recorder captures keys
    /// (`InputHostController.setRecorderActive(_:)`).
    func setHotkeyRecorderActive(_ active: Bool)
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    /// A new name for the System Settings style layout (W8-D), so the window opens once at its new default size
    /// instead of the frame saved for the old layout; from then on it is remembered again (PRD-R28).
    static let frameAutosaveName = "SettingsWindow.sidebar"
    static let defaultSize = NSSize(
        width: SettingsWindowLayout.defaultWidth, height: SettingsWindowLayout.defaultHeight)
    static let minimumSize = NSSize(
        width: SettingsWindowLayout.minimumWidth, height: SettingsWindowLayout.minimumHeight)

    private let model: SettingsWindowModel
    private var languageObservation: AnyCancellable?

    /// Forwarded to the model; set by the composition root after construction.
    weak var actions: (any SettingsActions)? {
        didSet { model.actions = actions }
    }

    required init?(coder: NSCoder) { nil }

    /// - Parameters:
    ///   - brand: app name, slug, version and site host (never hard-coded).
    ///   - matrix: the bundled `compat-matrix.json`; nil shows every app as not verified (PRD-R35).
    ///   - panes: System Settings / System Preferences names of the running macOS (PRD-R64, ADR 0315).
    ///   - inputSources: enabled input sources for the layout binding (PLT-R373), read when the pane appears.
    ///   - layout: the current layout table, so the recorder names Command+Q / Command+W on any layout.
    init(
        store: SettingsStore, language: InterfaceLanguageModel, updater: any UpdaterControlling,
        loginItem: any LoginItemService, brand: Brand = .from(.main),
        matrix: MatrixDocument? = SettingsResources.bundledMatrix(), panes: SystemPaneNames,
        inputSources: @escaping @MainActor () -> [InputSourceInfo] = { [] },
        layout: @escaping @MainActor () -> LayoutTable? = { nil },
        keyValues: any KeyValueStore = UserDefaultsKeyValueStore()
    ) {
        model = SettingsWindowModel(
            commands: SettingsCommands(store: store), language: language, updater: updater, loginItem: loginItem,
            brand: brand, matrix: matrix, panes: panes, inputSources: inputSources, layout: layout,
            disclosures: AdvancedDisclosureMemory(store: keyValues))
        let window = SettingsWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SettingsRootView(model: model))
        Self.configure(window)
        window.setContentSize(Self.defaultSize)
        window.center()
        window.setFrameAutosaveName(Self.frameAutosaveName)  // PRD-R28: size and position remembered
        super.init(window: window)
        window.delegate = self
        window.selectPane = { [weak model] pane in model?.select(pane) }
        refreshTitle()
        observeLanguage()
    }

    /// Window traits of the layout, shared with the snapshot tool (scripts/snapshots): a normal window that does not
    /// float above other apps (PRD-R28), resizable down to about the size System Settings allows. Like System
    /// Settings, the content runs under a transparent, unified title bar (an empty toolbar gives it the taller
    /// height): the sidebar fills the window's full height with the window buttons inside it, and the pane's name
    /// sits in the title bar row (`SettingsRootView`). The window title stays set for VoiceOver and the Window menu,
    /// only hidden.
    static func configure(_ window: NSWindow) {
        window.level = .normal
        window.contentMinSize = minimumSize
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        let toolbar = NSToolbar(identifier: "SettingsWindow.toolbar")
        toolbar.allowsUserCustomization = false
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    /// Shows the window on `pane` (menu "Cài đặt...", "Gõ tắt...", "Ủng hộ...", the URL scheme, PLT-R909).
    func show(_ pane: SettingsPane) {
        model.select(pane)
        present()
    }

    /// Opens the General pane with the toggle recorder already recording and focused. `role: .restoreLastWord`
    /// opens the Typing pane's restore recorder instead. Onboarding screen 4 records inline (PRD-R40).
    func showHotkeyRecorder(role: HotkeyRole = .toggleMode) {
        model.select(role == .toggleMode ? .general : .typing)
        if role == .restoreLastWord { model.setAdvancedExpanded(true, for: .typing) }
        present()
        model.startRecording(role)
    }

    /// The composition root forwards `SettingsStore`'s `onChange` here on the main actor, so changes made
    /// elsewhere (menu, per-app memory, import) show at once.
    func settingsChanged(_ state: SettingsState) {
        model.apply(state)
    }

    func windowWillClose(_ notification: Notification) {
        model.cancelRecording()
    }

    /// ADR 0305, PRD-R67: once another app or window takes the keyboard, the recorder stops swallowing keys and
    /// the tap's hotkeys work again.
    func windowDidResignKey(_ notification: Notification) {
        model.interruptRecording()
    }

    private func present() {
        Task { await model.refresh() }
        showWindow(nil)
        NSApp.bringToFront()
        window?.makeKeyAndOrderFront(nil)
    }

    /// PRD-R63: the title follows a language change; SwiftUI content re-renders by itself.
    private func refreshTitle() {
        window?.title = model.localizer.format(SettingsText.windowTitle, model.brand.displayName)
    }

    private func observeLanguage() {
        languageObservation = model.language.afterChange { [weak self] in self?.refreshTitle() }
    }
}

/// Command+1 to Command+5 select the panes in sidebar order (PRD-R67), by the digit typed or, on layouts whose number
/// row types other characters, by the number row key. Only plain Command digits are taken; the
/// hotkey recorder sees every key first through its local monitor (ADR 0305), and a sheet has its own window.
final class SettingsWindow: NSWindow {
    var selectPane: (@MainActor (SettingsPaneKind) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, let selectPane,
            let pane = SettingsPaneKind.forKeyEquivalent(
                characters: event.charactersIgnoringModifiers, keyCode: event.keyCode,
                modifierFlags: UInt64(event.modifierFlags.rawValue))
        {
            selectPane(pane)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Bundled data the window reads.
enum SettingsResources {
    /// `compat-matrix.json` copied into the bundle by the build (PRD-R38); nil when missing or invalid.
    static func bundledMatrix(bundle: Bundle = .main) -> MatrixDocument? {
        bundle.url(forResource: "compat-matrix", withExtension: "json").flatMap(MatrixLoader.load(contentsOf:))
    }
}
```
<!-- /include -->

<!-- include: App/Sources/Diagnostics/DiagnosticsWindowController.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Diagnostics window (PLT-R1201), "This app misbehaves" flow (PLT-R1205), bug report sheet (PRD-R47-R49),
// typing trace review (PLT-R905) and latency probe window (PLT-R810). Workstream W2-C.

import AppKit
import AppModel
import Combine
import Diagnostics
import ShellCore
import SwiftUI

@MainActor
final class DiagnosticsWindowController: NSWindowController, NSWindowDelegate {
    static let contentSize = NSSize(width: 620, height: 560)

    private let language: InterfaceLanguageModel
    private let services: DiagnosticsServices
    private let model: DiagnosticsWindowModel
    private var misbehaves: MisbehavesPanelController?
    private var bugReport: BugReportController?
    private var trace: TypingTraceCoordinator?
    private var probe: LatencyProbeWindowController?

    required init?(coder: NSCoder) { nil }

    /// `report` builds a fresh report (W2-A: `ReportAssembler.report` with the host's context). Without
    /// `services` only the report and its buttons work; each driver appears when its service is provided.
    init(
        language: InterfaceLanguageModel, report: @escaping @MainActor () -> DiagnosticsReport,
        services: DiagnosticsServices = DiagnosticsServices()
    ) {
        self.language = language
        self.services = services
        model = DiagnosticsWindowModel(language: language, services: services, report: report)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("Diagnostics")
        window.contentViewController = NSHostingController(rootView: DiagnosticsWindowView(model: model))
        window.setContentSize(Self.contentSize)
        window.center()
        super.init(window: window)
        window.delegate = self
        model.perform = { [weak self] action in self?.perform(action) }
        WindowTitles.follow(language, window: window) { $0.string(DiagnosticsText.windowTitle) }
    }

    /// Opens the window with a freshly generated report (the text shown is the text copied, PLT-R1204). The
    /// report is built before this app activates, so the focus section names the field the user was in. `build`
    /// replaces the live report, for example with the bug report sheet's report of the same moment.
    func showReport(using build: (@MainActor () -> DiagnosticsReport)? = nil) {
        model.refresh(using: build)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.bringToFront()
    }

    /// "Báo lỗi..." (PRD-R11 item 6, PRD-R47): the sheet with the Apps pane's apps and the last frontmost app
    /// chosen: `preselected` (the focused app when the menu item was chosen), or the most recent other app when that
    /// is this app or unknown. The host context is read now, before the sheet takes the focus.
    /// `symptom` is the one chosen in the misbehaves panel when the sheet continues from it (PRD-R49).
    func openBugReport(preselected: BundleKey?, symptom: DiagnosticsReport.Symptom = .other) {
        let apps = services.recentApps()
        let choice = RecentReportApps.preselection(
            focused: preselected, recent: apps, excluding: services.resolvedBrand.bundleIdentifier,
            name: services.appName)
        let draft = BugReportDraft(
            app: choice?.bundle, appName: choice?.name, symptom: symptom, userDescription: "",
            reproducesInPracticeField: nil)
        let build = reportBuilder()
        bugReport?.close()
        let controller = BugReportController(
            draft: draft, apps: apps, build: build, language: language, services: services)
        controller.openDiagnostics = { [weak self] in self?.showReport(using: { build(nil) }) }
        bugReport = controller
        controller.present()
    }

    /// The composition root's builder bound to the context of this moment; without it, the window's live report
    /// of this moment, which the sheet projects onto the draft (`BugReportSheet.report(from:)`).
    private func reportBuilder() -> DiagnosticsServices.ReportBuilder {
        if let session = services.reportSession { return session() }
        let base = model.freshReport()
        return { _ in base }
    }

    /// The app the window's report flows name while this window has the focus (PRD-R47 item 1).
    func lastFrontmostApp() -> BundleKey? { services.lastFrontmost(recent: services.recentApps())?.bundle }

    /// PLT-R1205 step 1: the user focused the problem field, then chose the menu item. The panel reads the focus
    /// snapshot and binds its report before it takes keyboard focus for the symptom (step 6); the snapshot
    /// belongs to `bundle` (the menu's frontmost app) unless focus moved since. Opened from the Diagnostics window
    /// the live focus is this app: the panel then names `bundle` in the report and asks the user to click into
    /// the problem field.
    func startMisbehavesFlow(for bundle: BundleKey?) {
        let controller = MisbehavesPanelController(
            language: language, services: services, bundle: bundle,
            report: { [weak self] in self?.model.currentReport() },
            openBugReport: { [weak self] app, symptom in self?.openBugReport(preselected: app, symptom: symptom) })
        misbehaves = controller
        controller.present()
    }

    func startTypingTrace() {
        guard let capture = services.trace else { return }
        let coordinator =
            trace
            ?? TypingTraceCoordinator(
                language: language, services: capture, appName: services.resolvedBrand.displayName)
        trace = coordinator
        coordinator.confirmAndStart(over: window)
    }

    func runLatencyProbe() {
        guard let latency = services.latency else { return }
        let controller =
            probe
            ?? LatencyProbeWindowController(
                language: language, services: latency, appName: services.resolvedBrand.displayName)
        probe = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.bringToFront()
    }

    private func perform(_ action: DiagnosticsWindowAction) {
        switch action {
        case .copyReport: model.copyReport()
        case .misbehaves: startMisbehavesFlow(for: lastFrontmostApp())
        case .recordTrace: startTypingTrace()
        case .latencyTest: runLatencyProbe()
        case .openLogs: model.openLogs()
        }
    }
}

@MainActor
final class BugReportController: NSWindowController, NSWindowDelegate {
    static let contentSize = NSSize(width: 560, height: 620)

    private let model: BugReportModel
    private let language: InterfaceLanguageModel
    private var practice: PracticeFieldWindowController?

    required init?(coder: NSCoder) { nil }

    /// Shows the exact redacted text before anything is copied or saved (PLT-R1204, PRD-R48). `apps` fill the
    /// picker (PRD-R47 item 1); `build` makes the report for each change of the draft.
    init(
        draft: BugReportDraft, apps: [BugReportAppChoice], build: @escaping DiagnosticsServices.ReportBuilder,
        language: InterfaceLanguageModel, services: DiagnosticsServices = DiagnosticsServices()
    ) {
        self.language = language
        model = BugReportModel(draft: draft, apps: apps, build: build, language: language, services: services)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize), styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("BugReport")
        window.contentViewController = NSHostingController(rootView: BugReportView(model: model))
        window.setContentSize(Self.contentSize)
        window.center()
        super.init(window: window)
        window.delegate = self
        model.openPracticeField = { [weak self] in self?.showPracticeField() }
        model.window = { [weak self] in self?.window }
        WindowTitles.follow(language, window: window) { $0.string(DiagnosticsText.sheetTitle) }
    }

    /// "Mở cửa sổ chẩn đoán" (set by the composition root, which owns the Diagnostics window).
    var openDiagnostics: () -> Void {
        get { model.openDiagnostics }
        set { model.openDiagnostics = newValue }
    }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.bringToFront()
    }

    private func showPracticeField() {
        let controller = practice ?? PracticeFieldWindowController(language: language)
        practice = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }
}

/// Window titles follow a runtime language change (PRD-R63); SwiftUI content re-renders by itself.
@MainActor
enum WindowTitles {
    /// Unique address for the window's associated observation (never dereferenced).
    private static let observationKey = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)

    static func follow(
        _ language: InterfaceLanguageModel, window: NSWindow, title: @escaping @MainActor (Localizer) -> String
    ) {
        window.title = title(language.localizer)
        let observation = language.afterChange { [weak window] in window?.title = title(language.localizer) }
        // The window owns its title observation, which ends when the window is deallocated (ADR 0315:
        // `withObservationTracking` needs macOS 14).
        objc_setAssociatedObject(window, observationKey, observation, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}
```
<!-- /include -->

<!-- include: App/Sources/Diagnostics/DiagnosticsServices.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// What the composition root (W2-A) hands to the Diagnostics controllers, and the AppKit side effects of the
// report paths: clipboard (only after the PRD-R48 notice), save panel, mail draft with attachment, opening
// URLs and the logs folder.

import AppKit
import AppModel
import CompatRules
import Diagnostics
import InputHost
import RealtimeSupport
import ShellCore

/// Services of the Diagnostics windows. Every member is optional: a missing service hides its feature.
@MainActor
struct DiagnosticsServices {
    /// Builds the report of one report flow for the user's current choices (PLT-R1202).
    typealias ReportBuilder = @MainActor (BugReportDraft?) -> DiagnosticsReport

    var brand: Brand?
    /// The report for a bug report draft with the host's live context (`ReportAssembler.report`). The misbehaves
    /// panel falls back to it only without `reportSession`: the panel takes the focus in some steps (PLT-R1205
    /// step 6), and the live context then names this app's own panel.
    var reportForDraft: ((BugReportDraft?) -> DiagnosticsReport)?
    /// A builder bound to the host context read when it is called: the bug report sheet calls it once when it
    /// opens, so a choice made later in the sheet (whose window then has the focus) still describes the field
    /// the user was typing in.
    var reportSession: (() -> ReportBuilder)?
    /// The apps of the Apps pane for the sheet's picker, most recent first (PRD-R47 item 1, `RecentReportApps`).
    var recentApps: () -> [BugReportAppChoice] = { [] }
    /// Display name of an installed app; nil falls back to the bundle ID.
    var appName: (BundleKey) -> String? = { _ in nil }
    /// Focus snapshot of the field the user wants to test (PLT-R1205 step 1).
    var currentFocus: (() -> FocusSnapshot)?
    var guidedTest: GuidedTestServices?
    var trace: TypingTraceServices?
    var latency: LatencyProbeServices?
    /// `~/Library/Logs/<folder>/` (PLT-R903).
    var logsFolder: URL?
    /// "Use this for me now": stores the user override; it applies on the next keystroke (PLT-R540).
    var applyOverride: ((Rule) -> Void)?

    init(
        brand: Brand? = nil, reportForDraft: ((BugReportDraft?) -> DiagnosticsReport)? = nil,
        reportSession: (() -> ReportBuilder)? = nil, recentApps: @escaping () -> [BugReportAppChoice] = { [] },
        appName: @escaping (BundleKey) -> String? = { _ in nil }, currentFocus: (() -> FocusSnapshot)? = nil,
        guidedTest: GuidedTestServices? = nil, trace: TypingTraceServices? = nil, latency: LatencyProbeServices? = nil,
        logsFolder: URL? = nil, applyOverride: ((Rule) -> Void)? = nil
    ) {
        self.brand = brand
        self.reportForDraft = reportForDraft
        self.reportSession = reportSession
        self.recentApps = recentApps
        self.appName = appName
        self.currentFocus = currentFocus
        self.guidedTest = guidedTest
        self.trace = trace
        self.latency = latency
        self.logsFolder = logsFolder
        self.applyOverride = applyOverride
    }

    /// The bundle's brand when the composition root did not pass one.
    var resolvedBrand: Brand { brand ?? Brand.from(.main) }

    /// "The last frontmost app" (PRD-R47 item 1): the focused app, or the most recent other app of `recent` while
    /// one of this app's windows has the focus.
    func lastFrontmost(recent: [BugReportAppChoice]) -> BugReportAppChoice? {
        RecentReportApps.preselection(
            focused: currentFocus?().app?.bundle, recent: recent, excluding: resolvedBrand.bundleIdentifier,
            name: appName)
    }
}

/// PLT-R1205 step 3. The composition root provides this only when the host has a diagnostics pass-through;
/// without it the guided test is never offered (`MisbehavesTarget.offersGuidedTest`).
///
/// `setPassThrough(true)` must make the pipeline pass every keyboard event unchanged while the runner types:
/// the engine is not fed, no per-app memory or manual mode is written (English mode is not a substitute: it
/// records a manual switch and still runs macros), and the composition is reset on entry and exit (PLT-R210).
/// `setPassThrough(false)` restores the previous behaviour. Calls are balanced: one `false` follows every
/// `true`. Requested from W2-A as `InputHostController.setDiagnosticsPassThrough(_:)`, backed by a pause
/// reason such as `PauseCode.diagnosticsTest`.
@MainActor
struct GuidedTestServices {
    var runner: GuidedTestRunner
    var setPassThrough: (Bool) -> Void
    var macOSVersion: String
    /// Today as `YYYY-MM-DD` for the suggestion's provenance.
    var today: () -> String
    /// Bounded AX reads of the guided test's focus check, called on the typing thread (PLT-R342).
    var focusAX: any AXProvider = SystemAXProvider()
}

/// PLT-R905. `captureStateChanged` switches the menu-bar icon (W2-A: `StatusIconState` capturing).
@MainActor
struct TypingTraceServices {
    var capture: CaptureController
    var scheduler: any TimerScheduler
    var wallClock: any WallClock
    var captureStateChanged: (Bool) -> Void
}

/// PLT-R810. The driver shares the per-launch event marker with the pipeline; `onResult` keeps the result for
/// the next report (`ReportAssembler.report(probe:)`).
@MainActor
struct LatencyProbeServices {
    var driver: LatencyProbeDriver
    var metrics: PlatformMetrics
    var clock: any MonotonicClock
    var wallClock: any WallClock
    var layout: () -> LayoutTable?
    var method: () -> TypingMethod
    var onResult: (LatencyProbeResult) -> Void
}

/// AppKit side effects of the report flows.
@MainActor
enum ReportActions {
    /// PRD-R48: callers show the clipboard notice before this runs; the only intentional clipboard write.
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func open(_ url: URL) { NSWorkspace.shared.open(url) }

    static func openFolder(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    /// Save panel for the JSON report or an exported trace; `write` runs with the chosen URL.
    static func save(
        suggestedName: String, over window: NSWindow?, write: @escaping @MainActor (URL) -> Bool,
        done: @escaping @MainActor (Bool?) -> Void
    ) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return done(nil) }
                done(write(url))
            }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    enum MailOutcome { case composed, fallbackWithoutAttachment, unavailable }

    /// "Gửi qua email" (PRD-R47): the system mail service with the JSON file attached; otherwise a `mailto:`
    /// draft without the attachment (the sheet then points to "Lưu tệp...").
    static func email(_ draft: MailDraft, attachment: Data) -> MailOutcome {
        if let service = NSSharingService(named: .composeEmail), let file = temporaryFile(attachment, draft) {
            service.recipients = draft.recipients
            service.subject = draft.subject
            let items: [Any] = [draft.body, file]
            if service.canPerform(withItems: items) {
                service.perform(withItems: items)
                return .composed
            }
        }
        guard let url = BugReportComposer.mailtoURL(draft), NSWorkspace.shared.open(url) else { return .unavailable }
        return .fallbackWithoutAttachment
    }

    /// The attachment in a private temporary folder (0600): metadata only (PLT-R1203).
    private static func temporaryFile(_ data: Data, _ draft: MailDraft) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = folder.appendingPathComponent(draft.attachmentFileName)
        do {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        } catch {
            return nil
        }
    }
}
```
<!-- /include -->

<!-- include: App/Sources/Updater/UpdaterController.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Thin wrapper around Sparkle 2 (PLT-R1101-R1110, PRD-R50-R55, docs/decisions/0304-sparkle-version-pin.md).
// Workstream W2-D.
//
// Settings D19-D21 live in settings.json (PLT-R1001); this controller mirrors them into Sparkle at launch and on
// every change, and reports user changes made here (About & Support pane, Sparkle's update window) back through
// `onPreferenceChange` so the composition root writes them to the settings store. Sparkle starts only when the
// bundle carries an https feed on the site host and a valid EdDSA key (PLT-R1102).

import AppKit
import AppModel
import Diagnostics
import ShellCore
import Sparkle

/// What the controller needs from the outside. `live` is the production wiring; tests pass fakes.
@MainActor
struct UpdaterDependencies {
    /// The app's Info.plist: brand keys, and the Sparkle keys checked before start.
    var info: [String: Any]
    /// Runs work on a later turn of the main queue, after blocks already queued there (production:
    /// `DispatchQueue.main.async`). Sparkle ends a failed session on such a turn once it is acknowledged.
    var onNextMainTurn: @MainActor (_ work: @escaping @MainActor () -> Void) -> Void
    var logger: (any DiagnosticsLogging)?
    /// The interface language of the moment (D18): the update-failed alert follows it, not the macOS language.
    var localizer: @MainActor () -> Localizer
    var presenter: any UpdateFailurePresenting
    var openURL: @MainActor (URL) -> Void
    var makeDriver: UpdateDriverFactory

    static func live(
        bundle: Bundle = .main, logger: (any DiagnosticsLogging)? = nil, language: InterfaceLanguageModel? = nil
    ) -> UpdaterDependencies {
        let fallback = Localizer(language: .vietnamese, appBundle: bundle)
        return UpdaterDependencies(
            info: bundle.infoDictionary ?? [:], onNextMainTurn: Self.mainQueueAsync, logger: logger,
            localizer: { language?.localizer ?? fallback }, presenter: AlertUpdateFailurePresenter(),
            openURL: { _ = NSWorkspace.shared.open($0) }, makeDriver: SparkleDriver.factory(bundle: bundle))
    }

    private static func mainQueueAsync(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }
}

@MainActor
final class UpdaterController: NSObject, UpdaterControlling {
    /// User changes of D19-D21 made through this controller; the composition root persists them with
    /// `change.apply(to:)` inside `SettingsStore.updateSettings` (PRD-R6: only the changed key becomes explicit).
    var onPreferenceChange: (@MainActor (UpdatePreferenceChange) -> Void)?

    private let dependencies: UpdaterDependencies
    private let brand: Brand
    private let idleState: @MainActor () -> KeyboardIdleState
    private var preferences = UpdatePreferences.shipped
    /// What Sparkle reported right after the last push. A later read-back that differs is a choice the user made
    /// in Sparkle's own window; one that never moved (a setter Sparkle ignored) is not (PRD-R6).
    private var sparkleBaseline: SparkleChoices?
    private var driver: (any UpdateDriving)?
    private var startAttempted = false

    /// `idleState` answers "seconds since the last key press, and is secure input on?" for the relaunch policy
    /// (PLT-R1105). Use `.infinity` seconds when no key was pressed since launch.
    init(
        idleState: @escaping @MainActor () -> (secondsSinceLastKey: Double, secureInputOn: Bool),
        dependencies: UpdaterDependencies = .live()
    ) {
        self.dependencies = dependencies
        brand = Brand.from(info: dependencies.info)
        self.idleState = {
            let state = idleState()
            return KeyboardIdleState(secondsSinceLastKey: state.secondsSinceLastKey, secureInputOn: state.secureInputOn)
        }
        super.init()
    }

    /// Starts Sparkle once, as the last step of the launch order. Without a valid configuration nothing starts, the
    /// refusal is logged and "Check for updates" stays disabled (PLT-R1102).
    func start() {
        guard !startAttempted else { return }
        startAttempted = true
        if let refusal = UpdaterConfiguration.refusal(info: dependencies.info) {
            log(.failed(code: refusal.rawValue), level: .error)
            return
        }
        let driver = dependencies.makeDriver(self) { [weak self] error, acknowledgement in
            guard let self else { return acknowledgement() }
            presentFailure(error, acknowledgement: acknowledgement)
        }
        driver.sendsSystemProfile = false  // PRD-R55, also off in Info.plist and filtered by the delegate.
        push(preferences, to: driver)
        do {
            try driver.start()
            self.driver = driver
        } catch {
            log(.failed(code: (error as NSError).code), level: .error)
        }
    }

    /// Applies D19-D21 from the settings store, at launch (before `start`) and after every settings change.
    /// Idempotent, and the stored values are never reported back through `onPreferenceChange`. A value the user
    /// moved in Sparkle's own update window since the last push is adopted first (reported once, so the store
    /// keeps it) rather than overwritten by the store's older value: the store publishes on every change, also
    /// while Sparkle's window is open (PLT-R1001, PRD-R6).
    func apply(_ next: UpdatePreferences) {
        let moves = sparkleMoves().filter { next.applying($0) != next }
        commit(moves.reduce(next) { $0.applying($1) })
        for change in moves { onPreferenceChange?(change) }
    }

    var currentPreferences: UpdatePreferences { preferences }

    // MARK: UpdaterControlling

    var canCheckForUpdates: Bool { driver?.canCheckForUpdates ?? false }

    var automaticallyChecksForUpdates: Bool {
        get { preferences.automaticallyCheck }
        set { userChanged(.automaticallyCheck(newValue)) }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { preferences.automaticallyInstall }
        set { userChanged(.automaticallyInstall(newValue)) }
    }

    var channel: UpdateChannelSelection {
        get { UpdateChannelPolicy.selection(for: preferences.channel) }
        set { userChanged(.channel(UpdateChannelPolicy.channel(for: newValue))) }
    }

    func checkForUpdates() {
        guard let driver, driver.canCheckForUpdates else { return }
        driver.checkForUpdates()
    }

    // MARK: Internals

    private func userChanged(_ change: UpdatePreferenceChange) {
        let next = preferences.applying(change)
        guard next != preferences else { return }
        commit(next)
        onPreferenceChange?(change)
    }

    private func commit(_ next: UpdatePreferences) {
        let previous = preferences
        preferences = next
        guard let driver else { return }
        push(next, to: driver)
        // Sparkle's documented call after a channel change, so the new channel is used without waiting a day.
        if previous.channel != next.channel { driver.resetUpdateCycleAfterShortDelay() }
    }

    /// Writes only values that differ: setting `automaticallyChecksForUpdates` makes Sparkle reschedule its cycle.
    private func push(_ preferences: UpdatePreferences, to driver: any UpdateDriving) {
        if driver.automaticallyChecksForUpdates != preferences.automaticallyCheck {
            driver.automaticallyChecksForUpdates = preferences.automaticallyCheck
        }
        if driver.automaticallyDownloadsUpdates != preferences.automaticallyInstall {
            driver.automaticallyDownloadsUpdates = preferences.automaticallyInstall
        }
        sparkleBaseline = SparkleChoices(of: driver)
    }

    /// Sparkle's update window has an "automatically download and install" checkbox that writes Sparkle's own
    /// defaults. Adopting it at the end of a session keeps settings.json the single source (PLT-R1001). Only a
    /// value that moved since the last push counts: Sparkle silently ignores `automaticallyDownloadsUpdates` when
    /// the bundle disallows automatic updates, and that must never turn into an explicit D20 (PRD-R6).
    private func adoptSparkleChoices() { apply(preferences) }

    /// The Sparkle values that moved since the last push, as preference changes.
    private func sparkleMoves() -> [UpdatePreferenceChange] {
        guard let driver, let baseline = sparkleBaseline else { return [] }
        let current = SparkleChoices(of: driver)
        var moves: [UpdatePreferenceChange] = []
        if current.automaticallyCheck != baseline.automaticallyCheck {
            moves.append(.automaticallyCheck(current.automaticallyCheck))
        }
        if current.automaticallyDownload != baseline.automaticallyDownload {
            moves.append(.automaticallyInstall(current.automaticallyDownload))
        }
        return moves
    }

    /// PRD-R43 update-failed alert. The failure itself is logged by `updater(_:didAbortWithError:)`.
    ///
    /// Sparkle closes its "Checking for updates" and progress windows only when the session ends, which happens on
    /// the main-queue turn after the acknowledgement. So the session is acknowledged first and the alert is shown
    /// on a later turn: it never sits on top of a frozen progress window, and "Thử lại" can start a new check.
    private func presentFailure(_ error: NSError, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        dependencies.onNextMainTurn { [weak self] in self?.showFailureAlert() }
    }

    private func showFailureAlert() {
        let content = UpdateFailureContent(
            localizer: dependencies.localizer(), appName: brand.displayName, version: brand.version,
            siteHost: brand.siteHost)
        switch dependencies.presenter.present(content) {
        case .retry:
            checkForUpdates()
        case .download:
            dependencies.openURL(content.downloadURL)
        case .close:
            break
        }
    }

    private func log(_ event: LogEvent.UpdateEvent, level: LogLevel) {
        dependencies.logger?.log(.update(event), level: level)
    }
}

/// The two Sparkle settings the user can flip in Sparkle's own windows.
private struct SparkleChoices: Equatable {
    var automaticallyCheck: Bool
    var automaticallyDownload: Bool

    @MainActor
    init(of driver: any UpdateDriving) {
        automaticallyCheck = driver.automaticallyChecksForUpdates
        automaticallyDownload = driver.automaticallyDownloadsUpdates
    }
}

/// `SPUUpdaterDelegate` is `NS_SWIFT_UI_ACTOR` in Sparkle 2.10.1, so its requirements are main-actor isolated and
/// these witnesses are checked by the compiler. The ADR 0313 pattern (`nonisolated` plus `MainActor.assumeIsolated`)
/// is not used: under Swift 6 region isolation it cannot store Sparkle's non-Sendable install block in main-actor
/// state.
extension UpdaterController: SPUUpdaterDelegate {
    /// `["beta"]` only after the user opted in (PLT-R1101, PRD-R53).
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UpdateChannelPolicy.allowedChannels(for: preferences.channel)
    }

    /// Install on quit by default (PLT-R1105). The handler is taken, and run at once, only when the keyboard has
    /// been idle for 60 s with secure input off and the update is not critical. Otherwise this returns false:
    /// returning true stalls Sparkle's update cycle until the handler runs, which would disable "Check for
    /// updates", stop the 24 h schedule and hide critical updates (PRD-R54) while the keyboard stays busy.
    func updater(
        _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        switch RelaunchGate.decision(for: idleState(), isCritical: item.isCriticalUpdate) {
        case .installNow:
            log(.installingNow, level: .info)
            immediateInstallHandler()
            return true
        case .installOnQuit:
            log(.installScheduledOnQuit, level: .info)
            return false
        }
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        log(.checkStarted(manual: updateCheck == .updates), level: .info)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        log(.updateFound(build: item.versionString), level: .notice)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let code = (error as NSError).code
        guard UpdateFailureFilter.isFailure(code: code) else { return }
        log(.failed(code: code), level: .error)
    }

    func updater(
        _ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        adoptSparkleChoices()
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        adoptSparkleChoices()
    }

    /// PRD-R55: no system profile, even if a future Info.plist turned profiling on.
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }

    /// PLT-R906: the appcast request carries no extra parameters.
    func feedParameters(for updater: SPUUpdater, sendingSystemProfile sendingProfile: Bool) -> [[String: String]] {
        []
    }
}
```
<!-- /include -->

## 13. TestSupport and CompatHarness

Owned files: `Sources/TestSupport/Fakes/<Area>/**` per area owner (Diagnostics W1-A, Settings W1-B, Rules
W1-C, Injection W1-D, Host W1-E, Tap W1-F2), `Sources/TestSupport/Pipeline/**` (W1-F1),
`Sources/TestSupport/Scenario/**`, `Sources/CompatHarness/**`, `Tests/TestSupportTests/Scenario/**`,
`compat/scenarios/**` (W2-E1). `Sources/TestSupport/Fakes/Common/**` is skeleton-provided and frozen. Isolation:
test code; fakes are `Sendable` so they can stand in for production services on any thread.

Implemented in the skeleton, with seam tests ([0313](../decisions/0313-testability-seams.md)): `Fakes/Common`
(`InMemoryFileSystem`, `ManualClock`, `FixedWallClock`, `InMemoryKeyValueStore`, `ManualScheduler`,
`RecordingLogger`, `SimulatedTextField` with all five behaviours), `FakeEventPoster`, `FakeFocusedFieldAccess`,
`FakePasteboard`, `FakeDecisionResolver`, `FakeEventTapFactory`/`FakeEventTapHandle`. Still `unimplemented()`:
the host fakes (W1-E), `ScriptedEngine`, `SimulatedWindowServer`, `ConservationLedger`, `RandomEventGenerator`,
`PipelineHarness` (W1-F1) and the scenario runner (W2-E1).

`compat-harness` (executable) runs only on the self-hosted runner: `compat-harness run --scenarios
compat/scenarios --profile normal|fast|burst --report out.json`. It posts physical-like events from its own
process, so the app treats them as physical input. Every command has `--dry-run`, the only mode allowed on a
developer Mac and the mode hosted CI runs; the live commands also need `COMPAT_HARNESS_LIVE=1` (ADR 0502).

W2-E2 additions (`Sources/TestSupport/Scenario/`, ADR 0502 "Integration hooks" and "Platform baseline"):

- **App profiles and configuration** (`AppProfiles.swift`, `AppConfiguration.swift`, `AppConfigurator.swift`):
  every scenario runs on factory defaults plus its `method` plus the profile in `compat/scenarios/profiles/` that
  lists it; `SettingsFileAppConfigurator` writes the four settings files of the test build (backup once, restore
  after the run) and restarts it through `AppUnderTestControl`.
- **Integration hooks** (`AppHooks.swift`, `FileDropHookChannel.swift`, below): the harness side of the test
  build's hooks; `HookStateProbe` answers the `paused`, `holderBundleId` and `firstKeyAfterReleaseComposed`
  expectations; the `testHook` setup step (`ScenarioHookStep.swift`) is in the scenario schema since W3-A.
- **Measurements** (`AppMetrics.swift`, `ProcessMetrics.swift`, `RegressionGate.swift`, `Soak.swift`): T2, T3, T5,
  T6 from the app's histograms after the `BenchWorkload`, T4 from its latency probe, C1, C2, M1 from
  `ProcessSampling`, M2 from the soak; the PLT-R822 gate against `perf/platform-baseline.json`.
- **Privacy and egress** (`PrivacyCanary.swift`, `EgressCheck.swift`): canary scan after canary scenarios over
  `PrivacyEvidenceSource`; `compat-harness egress` over `ConnectionSampler`.

The App does not link TestSupport: both sides share the Codable wire types of `Diagnostics/IntegrationHooks.swift`.
W3-A added the app side (ADR 0502 "Integration hooks"): the testable core in `InputHost/IntegrationHooks/`
(`IntegrationHookServer`, `PosixHookDirectory`, `VnodeDirectoryWatcher`, `IntegrationHookInstruments` with
`TimeoutSimulatingTapFactory` and `RevocablePermissionProbe`, `InputHostHookActions`) and `HostCounters` in the
pipeline, started only by `App/Sources/IntegrationHooks/` under the `INTEGRATION_HOOKS` condition, which only the
`Integration` configuration (`Config/Integration.xcconfig`) sets. `scripts/verify-release.sh` fails a release that
carries the hooks' marker.

<!-- include: Packages/AppCore/Sources/Diagnostics/IntegrationHooks.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Wire format of the integration hooks (ADR 0502, "Integration hooks"; QA-R11, PLT-R821, 13.2 "tap timeout
// injection (test hook)"). One Codable definition shared by the harness (TestSupport, FileDropHookChannel) and the
// app's INTEGRATION_HOOKS test build (InputHost `IntegrationHookServer`, App/Sources/IntegrationHooks). Release
// builds link these value types but never answer a request: the watcher exists only under the compilation
// condition. Metadata only (PLT-R901): no typed text, window titles, URLs or app names ever reach a response.

public import AppModel

/// A test hook a scenario triggers (`testHook` setup step).
public enum AppTestHook: String, Sendable, Hashable, Codable, CaseIterable {
    /// The app disables its event tap as macOS does after a callback timeout, then runs its normal recovery
    /// (PLT-R330). QA-R11: the engine state MUST be reset after recovery.
    case tapTimeout
    /// The app's trust check reports Accessibility as revoked (PLT-R730 fail-open, PRD-R44).
    case revokePermission
    /// Ends `revokePermission`: the trust check reports the real value again, so the app re-creates its tap
    /// without a relaunch (7.3).
    case restorePermission
}

/// One request to the app under test.
public enum AppHookCommand: Sendable, Hashable {
    /// Host state, secure-input holder and the PLT-R801 metrics.
    case state
    /// Zeroes every histogram and counter of `PlatformMetrics`, so a measured workload starts clean.
    case resetMetrics
    case trigger(AppTestHook)
    /// Runs the built-in latency probe (PLT-R810) with one profile and returns its T2 and T4 percentiles.
    case latencyProbe(LatencyProbeResult.Profile)
    /// Starts an update check now, as "Check for Updates" does (13.7 egress test).
    case checkForUpdates

    /// Wire name of the command.
    public var name: String {
        switch self {
        case .state: "state"
        case .resetMetrics: "resetMetrics"
        case .trigger(let hook): hook.rawValue
        case .latencyProbe: "latencyProbe"
        case .checkForUpdates: "checkForUpdates"
        }
    }

    /// The command a request names. `unknownCommand` for a name outside the contract, `unsupported` for
    /// `latencyProbe` without its profile.
    public static func parse(name: String, profile: LatencyProbeResult.Profile?) -> Result<
        AppHookCommand, AppHookErrorCode
    > {
        switch name {
        case "state": return .success(.state)
        case "resetMetrics": return .success(.resetMetrics)
        case "checkForUpdates": return .success(.checkForUpdates)
        case "latencyProbe":
            guard let profile else { return .failure(.unsupported) }
            return .success(.latencyProbe(profile))
        default:
            guard let hook = AppTestHook(rawValue: name) else { return .failure(.unknownCommand) }
            return .success(.trigger(hook))
        }
    }
}

/// Why the app refused a request. The wire carries the raw value in `AppHookResponse.error`, never content.
public enum AppHookErrorCode: String, Error, Sendable, Hashable, Codable, CaseIterable {
    /// The command name is not part of the contract.
    case unknownCommand
    /// The request cannot be served by this build or right now: an unknown `formatVersion`, a malformed or
    /// oversized request, `latencyProbe` without a profile or without a Latin layout, no tap to time out, no
    /// updater yet.
    case unsupported
    /// Another request is still running (one at a time), or the latency probe window lost focus.
    case busy
}

/// `request-<sequence>.json`.
public struct AppHookRequest: Sendable, Hashable, Codable {
    public static let formatVersion = 1
    public var formatVersion: Int
    public var sequence: UInt64
    public var command: String
    public var profile: LatencyProbeResult.Profile?

    public init(sequence: UInt64, command: AppHookCommand) {
        formatVersion = Self.formatVersion
        self.sequence = sequence
        self.command = command.name
        if case .latencyProbe(let profile) = command { self.profile = profile }
    }
}

/// App state for scenario expectations and soak counters. Metadata only (PLT-R901): no text, no titles.
public struct AppStateSnapshot: Sendable, Hashable, Codable {
    public enum State: String, Sendable, Hashable, Codable { case noPermission, starting, ready, paused, failOpen }

    public var processIdentifier: Int32
    public var state: State
    /// The mode while `ready`.
    public var mode: TypingMode?
    public var pauseReason: PauseCode?
    public var failOpenReason: FailOpenReason?
    /// Likely holder of Secure Event Input while paused for it (PLT-R396).
    public var secureInputHolderBundleId: BundleKey?
    /// PLT-R398B: whether the first key-down after the most recent secure-input release was composed; nil before
    /// the first release of this process.
    public var firstKeyAfterSecureInputReleaseComposed: Bool?
    /// Tap re-enables after a timeout (system or `tapTimeout` hook) since launch.
    public var tapRecoveries: UInt64
    /// Of those, recoveries after which the engine state was reset (QA-R11 expects every one).
    public var engineResetsAfterTapRecovery: UInt64
    public var metrics: MetricsSnapshot

    public init(
        processIdentifier: Int32, state: State, mode: TypingMode? = nil, pauseReason: PauseCode? = nil,
        failOpenReason: FailOpenReason? = nil, secureInputHolderBundleId: BundleKey? = nil,
        firstKeyAfterSecureInputReleaseComposed: Bool? = nil, tapRecoveries: UInt64 = 0,
        engineResetsAfterTapRecovery: UInt64 = 0, metrics: MetricsSnapshot
    ) {
        self.processIdentifier = processIdentifier
        self.state = state
        self.mode = mode
        self.pauseReason = pauseReason
        self.failOpenReason = failOpenReason
        self.secureInputHolderBundleId = secureInputHolderBundleId
        self.firstKeyAfterSecureInputReleaseComposed = firstKeyAfterSecureInputReleaseComposed
        self.tapRecoveries = tapRecoveries
        self.engineResetsAfterTapRecovery = engineResetsAfterTapRecovery
        self.metrics = metrics
    }

    /// The snapshot of a host state (02-platform.md 2.1). Only codes cross the wire: the input source name of
    /// `nonLatinInputSource`, the rule of `passThroughRule` and the holder's display name are dropped (PLT-R901);
    /// the holder appears as its bundle ID only, and only while paused for secure input.
    public init(
        processIdentifier: Int32, hostState: HostState, firstKeyAfterSecureInputReleaseComposed: Bool?,
        tapRecoveries: UInt64, engineResetsAfterTapRecovery: UInt64, metrics: MetricsSnapshot
    ) {
        self.init(
            processIdentifier: processIdentifier, state: .starting,
            firstKeyAfterSecureInputReleaseComposed: firstKeyAfterSecureInputReleaseComposed,
            tapRecoveries: tapRecoveries, engineResetsAfterTapRecovery: engineResetsAfterTapRecovery, metrics: metrics)
        switch hostState {
        case .noPermission: state = .noPermission
        case .starting: state = .starting
        case .ready(let typingMode):
            state = .ready
            mode = typingMode
        case .paused(let reason):
            state = .paused
            pauseReason = reason.code
            if case .secureInput(let holder) = reason { secureInputHolderBundleId = holder?.bundle }
        case .failOpen(let reason):
            state = .failOpen
            failOpenReason = reason
        }
    }

    /// Keys pass through untransformed: paused (any reason) or failed open.
    public var passesKeysThrough: Bool { state == .paused || state == .failOpen || state == .noPermission }
}

/// `response-<sequence>.json`.
public struct AppHookResponse: Sendable, Hashable, Codable {
    public var formatVersion: Int
    public var sequence: UInt64
    public var ok: Bool
    /// Error code when `ok` is false (`AppHookErrorCode` raw value), never content. A string on the wire, so a
    /// harness also reads a code a newer build adds.
    public var error: String?
    public var state: AppStateSnapshot?
    public var latencyProbe: LatencyProbeResult?

    public init(
        sequence: UInt64, ok: Bool = true, error: String? = nil, state: AppStateSnapshot? = nil,
        latencyProbe: LatencyProbeResult? = nil
    ) {
        formatVersion = AppHookRequest.formatVersion
        self.sequence = sequence
        self.ok = ok
        self.error = error
        self.state = state
        self.latencyProbe = latencyProbe
    }

    /// A refusal carrying the request's sequence number.
    public static func refused(sequence: UInt64, _ code: AppHookErrorCode) -> AppHookResponse {
        AppHookResponse(sequence: sequence, ok: false, error: code.rawValue)
    }

    /// The error as a known code; nil when `ok` or when the code is unknown to this build.
    public var errorCode: AppHookErrorCode? { error.flatMap(AppHookErrorCode.init(rawValue:)) }
}

/// File names of the hooks directory (`~/Library/Application Support/<storage folder>/IntegrationHooks/`).
public enum IntegrationHookFiles {
    /// Directory name below the app's Application Support folder.
    public static let directoryName = "IntegrationHooks"
    static let requestPrefix = "request-"
    static let responsePrefix = "response-"
    static let suffix = ".json"

    public static func requestName(_ sequence: UInt64) -> String { requestPrefix + String(sequence) + suffix }
    public static func responseName(_ sequence: UInt64) -> String { responsePrefix + String(sequence) + suffix }

    /// The sequence of `request-<n>.json` (decimal digits only, no sign, no leading `+`, fits UInt64); nil for
    /// every other name, including the harness's temporary files.
    public static func requestSequence(fileName name: String) -> UInt64? {
        guard name.hasPrefix(requestPrefix), name.hasSuffix(suffix) else { return nil }
        let digits = name.dropFirst(requestPrefix.count).dropLast(suffix.count)
        guard !digits.isEmpty, digits.count <= 20, digits.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else {
            return nil
        }
        return UInt64(digits)
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/InputHost/IntegrationHooks/IntegrationHookServer.swift until="public actor IntegrationHookServer" -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The app side of the integration hooks (ADR 0502, "Integration hooks"; W3-A): for every `request-<n>.json` in
// the hooks directory, run the command and answer `response-<n>.json` carrying the request's own sequence number.
// Only the INTEGRATION_HOOKS test build creates a server (App/Sources/IntegrationHooks); it starts with one scan, so
// a request written before the watcher began is answered too, then scans again on every directory change. One
// command runs at a time: a request arriving meanwhile is answered `busy`. Responses carry codes and numbers only
// (PLT-R901); requests are never deleted and never answered twice.

public import Diagnostics
internal import Foundation

/// What the hooks can do to the running app. Production: `InputHostHookActions`; tests: fakes.
public protocol IntegrationHookActions: Sendable {
    func state() async -> AppStateSnapshot
    func resetMetrics() async
    /// The tap timed out and recovered (PLT-R330), or why not.
    func simulateTapTimeout() async -> HookActionOutcome
    /// Revokes (`true`) or restores the Accessibility answer of the trust check and waits until the host acted on
    /// it (PLT-R730 fail-open, 7.3 re-grant).
    func setAccessibilityRevoked(_ revoked: Bool) async -> HookActionOutcome
    func runLatencyProbe(_ profile: LatencyProbeResult.Profile) async -> LatencyProbeOutcome
    func checkForUpdates() async -> HookActionOutcome
}

public enum HookActionOutcome: Sendable, Hashable {
    case done
    /// Not possible in this state: no tap to time out, no updater yet (`unsupported`).
    case unavailable
    /// The host did not reach the expected state in time (`busy`).
    case timedOut
}

public enum LatencyProbeOutcome: Sendable, Hashable {
    case result(LatencyProbeResult)
    /// No Latin layout for the probe script (`unsupported`).
    case unavailable
    /// The probe window lost focus, so the run stopped (`busy`).
    case interrupted
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/InputHost/IntegrationHooks/IntegrationHookDirectory.swift until="/// POSIX implementation" -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The hooks directory of the INTEGRATION_HOOKS test build (ADR 0502, "Integration hooks"):
// `~/Library/Application Support/<storage folder>/IntegrationHooks/`, 0700, requests and responses 0600. The app
// reads `request-<n>.json` and writes `response-<n>.json` atomically (temporary file, fsync, rename); it never
// deletes either file (the harness does). Symbolic links, files of another user and non-regular files are refused
// without being opened for reading content; requests are capped in size. File I/O on the hooks queue only, never
// on the tap, inject or ax threads (PLT-R203, PLT-R305).

internal import Diagnostics
public import Foundation

/// Why a request file was not read.
public enum HookFileRefusal: Error, Sendable, Hashable {
    /// Gone between the listing and the read (the harness removed it).
    case missing
    case symbolicLink
    case notRegularFile
    /// Owned by another user.
    case foreignOwner
    case tooLarge
    case unreadable(errno: Int32)
}

/// Why the hooks directory cannot be used; the app then does not answer hooks at all.
public enum HookDirectoryError: Error, Sendable, Hashable {
    case symbolicLink
    case notDirectory
    case foreignOwner
    case io(errno: Int32)
}

/// What the hooks server needs from the directory. Production: `PosixHookDirectory`; tests: an in-memory fake.
public protocol IntegrationHookFileAccess: Sendable {
    /// Creates the directory (0700) or checks the existing one: a real directory of the current user, tightened to
    /// 0700.
    func prepare() throws(HookDirectoryError)
    /// Sequence numbers of the `request-<n>.json` files present, ascending.
    func requestSequences() -> [UInt64]
    /// The request's bytes: a regular file of the current user, at most `maxBytes`.
    func readRequest(_ sequence: UInt64, maxBytes: Int) -> Result<Data, HookFileRefusal>
    func responseExists(_ sequence: UInt64) -> Bool
    /// `response-<n>.json`, 0600, written atomically.
    func writeResponse(_ data: Data, sequence: UInt64) throws(HookDirectoryError)
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/InputHost/Pipeline/HostCounters.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Content-free observations of the host since launch that the integration hooks report in `AppStateSnapshot`
// (ADR 0502, "Integration hooks"): tap recoveries after a timeout and the engine resets that came with them
// (PLT-R330, QA-R11), and whether the first key-down after a secure-input release was composed (PLT-R398B). Always
// on in every build (two counters and one byte); written on the tap thread with relaxed atomics only, no lock and
// no allocation (PLT-R304, PLT-R305). Unlike `PlatformMetrics` they are never reset: they count since launch.

internal import Diagnostics
internal import RealtimeSupport

public final class HostCounters: Sendable {
    /// The main thread re-enabled the tap after a `tapDisabledByTimeout` (system or the `tapTimeout` hook).
    let tapRecoveries = AtomicCounter()
    /// The pipeline handled a `tapDisabledByTimeout` and its engine was left reset (QA-R11).
    let engineResetsAfterTapRecovery = AtomicCounter()
    /// 0: no secure-input release seen yet; 1: the first key-down after the latest release passed uncomposed;
    /// 2: it was composed.
    private let firstKeyAfterRelease = Atomic<UInt8>(0)

    public init() {}

    public var tapRecoveryCount: UInt64 { tapRecoveries.value }
    public var engineResetsAfterTapRecoveryCount: UInt64 { engineResetsAfterTapRecovery.value }

    /// PLT-R398B: nil before the first release of this process.
    public var firstKeyAfterSecureInputReleaseComposed: Bool? {
        switch firstKeyAfterRelease.load(ordering: .relaxed) {
        case 0: nil
        case 1: false
        default: true
        }
    }

    /// Tap thread, once per release (the first key-down after it).
    @inline(__always)
    func recordFirstKeyAfterSecureInputRelease(composed: Bool) {
        firstKeyAfterRelease.store(composed ? 2 : 1, ordering: .relaxed)
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/TestSupport/Fakes/Common/SimulatedTextField.swift until="    // MARK: Decoding" -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Text field model used by the injection tests (W1-D), the pipeline harness (W1-F1) and the guided-test tests
// (W2-C): caret, selection, inline-completion suggestion, per-event processing. Applies synthetic and replayed
// events the way a Cocoa field does. Shared fake implemented in the skeleton (ADR 0313): integrator-owned and
// frozen in wave 1; a workstream that needs another behaviour asks the integrator.
//
// Key codes are the public macOS virtual key codes (Carbon `Events.h`): Delete 0x33, Forward Delete 0x75,
// arrows 0x7B-0x7E, Return 0x24, Tab 0x30, Escape 0x35, ANSI V 0x09.

internal import AppModel
internal import CoreGraphics
public import Injection
public import InputHost
internal import RealtimeSupport

public final class SimulatedTextField: Sendable {
    public enum Behaviour: Sendable, Hashable {
        /// Plain Cocoa field.
        case cocoa
        /// Address bar, Spotlight, Sheets (4.3): after an insertion at the end, if the text is a proper prefix of
        /// a suggestion, the remainder is appended and selected. Backspace then deletes only the selection.
        case inlineCompletion(suggestions: [String])
        /// Edit-mode transition (section 6): the first keyDown after focus (init, `click`, `reset`) is dropped.
        case dropsFirstEventAfterFocus
        /// Remote clients: synthetic events insert the character their key code produces in the layout, not
        /// their Unicode payload (needs a layout in `apply(_:layout:)`).
        case ignoresUnicodePayload
        /// Terminals: events are buffered and applied `maxEventsPerRead` at a time (`flushPendingReads()`
        /// applies the rest). Shift+arrow does not select.
        case terminalReadsInBatches(maxEventsPerRead: Int)
    }

    public enum KeyCodes {
        public static let delete: UInt16 = 0x33
        public static let forwardDelete: UInt16 = 0x75
        public static let leftArrow: UInt16 = 0x7B
        public static let rightArrow: UInt16 = 0x7C
        public static let downArrow: UInt16 = 0x7D
        public static let upArrow: UInt16 = 0x7E
        public static let returnKey: UInt16 = 0x24
        public static let tab: UInt16 = 0x30
        public static let escape: UInt16 = 0x35
        public static let ansiV: UInt16 = 0x09
    }

    /// PLT-R343: bounded AX reads.
    public static let maximumAXTextUnits = 64

    private enum Operation: Sendable {
        case insert(String)
        case backspace
        case forwardDelete
        case moveLeft(extend: Bool)
        case moveRight(extend: Bool)
        case paste
        case ignored
    }

    private struct State {
        var text: String
        var selection: TextRange
        var dropNextKeyDown: Bool
        var pending: [Operation] = []
        var droppedEvents = 0
        var appliedEvents = 0
    }

    public let behaviour: Behaviour
    private let pasteboardText: (@Sendable () -> String?)?
    private let state: Mutex<State>

    /// `pasteboardText` answers Command+V (for example `FakePasteboard.plainText`).
    public init(behaviour: Behaviour = .cocoa, text: String = "", pasteboardText: (@Sendable () -> String?)? = nil) {
        self.behaviour = behaviour
        self.pasteboardText = pasteboardText
        let caret = text.utf16.count
        state = Mutex(
            State(
                text: text, selection: TextRange(location: caret, length: 0),
                dropNextKeyDown: behaviour == .dropsFirstEventAfterFocus))
    }

    public var text: String { state.withLock { $0.text } }
    /// UTF-16 selection (`CFRange` semantics).
    public var selection: TextRange { state.withLock { $0.selection } }
    public var selectedText: String {
        state.withLock { Self.substring($0.text, $0.selection) }
    }
    /// KeyDowns dropped by `dropsFirstEventAfterFocus`.
    public var droppedEventCount: Int { state.withLock { $0.droppedEvents } }
    /// KeyDowns that changed or could have changed the text.
    public var appliedEventCount: Int { state.withLock { $0.appliedEvents } }
    /// Buffered events not yet read (terminal behaviour).
    public var pendingReadCount: Int { state.withLock { $0.pending.count } }

    /// A synthetic event posted by the worker. `layout` resolves Command+V on non-QWERTY layouts and is
    /// required by `ignoresUnicodePayload`.
    public func apply(_ event: SyntheticKeyEvent, layout: LayoutTable? = nil) {
        guard event.isKeyDown else { return }
        let operation = decode(
            keyCode: event.keyCode, flags: event.flags, unicode: event.unicode, layout: layout,
            preferLayout: behaviour == .ignoresUnicodePayload)
        submit(operation)
    }

    /// A replayed or passed-through physical event. Uses the event's Unicode string like Cocoa does, falling
    /// back to the layout table when the string is empty.
    public func apply(_ record: KeyEventRecord, layout: LayoutTable) {
        guard record.kind == .keyDown else { return }
        let operation = decode(
            keyCode: record.keyCode, flags: record.flags, unicode: record.unicode, layout: layout, preferLayout: false)
        submit(operation)
    }

    /// Mouse click: moves the caret, clears the selection, counts as a focus change.
    public func click(at offset: Int) {
        state.withLock { state in
            let caret = min(max(0, offset), state.text.utf16.count)
            state.selection = TextRange(location: caret, length: 0)
            if behaviour == .dropsFirstEventAfterFocus { state.dropNextKeyDown = true }
        }
    }

    /// New focus with fresh content.
    public func reset(text: String = "") {
        state.withLock { state in
            state = State(
                text: text, selection: TextRange(location: text.utf16.count, length: 0),
                dropNextKeyDown: behaviour == .dropsFirstEventAfterFocus)
        }
    }

    /// Terminal behaviour: applies every buffered event.
    public func flushPendingReads() {
        state.withLock { state in
            let pending = state.pending
            state.pending.removeAll()
            for operation in pending { perform(operation, on: &state) }
        }
    }

    // MARK: AX surface used by FakeFocusedFieldAccess

    public func axSelectedRange() -> TextRange { selection }

    /// At most `maximumAXTextUnits` UTF-16 units (PLT-R343).
    public func axText(in range: TextRange) -> String {
        state.withLock { state in
            let clamped = Self.clamp(range, in: state.text)
            let bounded = TextRange(location: clamped.location, length: min(clamped.length, Self.maximumAXTextUnits))
            return Self.substring(state.text, bounded)
        }
    }

    public func axSetSelectedRange(_ range: TextRange) {
        state.withLock { $0.selection = Self.clamp(range, in: $0.text) }
    }

    /// Replaces the selection like `kAXSelectedTextAttribute` does; no inline completion is offered.
    public func axSetSelectedText(_ text: String) {
        state.withLock { state in Self.replaceSelection(with: text, in: &state) }
    }
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/TestSupport/Fakes/Common/ManualScheduler.swift until="    private func add(" -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Deterministic `TimerScheduler` over `ManualClock` (ADR 0313). Tests advance virtual time; due timers fire
// synchronously on the caller's thread in deadline order. Shared fake: integrator-owned (frozen in wave 1).

public import RealtimeSupport

public final class ManualScheduler: TimerScheduler, Sendable {
    private struct Entry {
        var id: UInt64
        var deadline: UInt64
        var interval: UInt64?
        var leeway: TimeSpan
        var handler: @Sendable () -> Void
    }

    private final class Timer: ScheduledTimer {
        let id: UInt64
        let owner: ManualScheduler
        init(id: UInt64, owner: ManualScheduler) {
            self.id = id
            self.owner = owner
        }
        func cancel() { owner.cancel(id) }
    }

    public let clock: ManualClock
    private let entries = Mutex<[Entry]>([])
    private let nextID = Atomic<UInt64>(1)

    public init(clock: ManualClock) { self.clock = clock }

    public func schedule(after delay: TimeSpan, leeway: TimeSpan, _ handler: @escaping @Sendable () -> Void)
        -> any ScheduledTimer
    {
        add(delay: delay, interval: nil, leeway: leeway, handler)
    }

    public func scheduleRepeating(
        every interval: TimeSpan, leeway: TimeSpan, _ handler: @escaping @Sendable () -> Void
    ) -> any ScheduledTimer {
        add(delay: interval, interval: interval, leeway: leeway, handler)
    }

    /// Advances the clock by `duration`, firing every timer that becomes due, in deadline order (a repeating
    /// timer fires once per elapsed interval).
    public func advance(by duration: TimeSpan) {
        let target = clock.now().nanoseconds &+ duration.unsignedNanoseconds
        while let entry = popDue(before: target) {
            if clock.now().nanoseconds < entry.deadline {
                clock.sleep(until: MonotonicInstant(nanoseconds: entry.deadline))
            }
            entry.handler()
        }
        if clock.now().nanoseconds < target { clock.sleep(until: MonotonicInstant(nanoseconds: target)) }
    }

    /// Timers still scheduled.
    public var pendingCount: Int { entries.withLock { $0.count } }

    /// Intervals of the repeating timers still scheduled (PLT-R803 tests: nothing faster than 2 s at rest).
    public var repeatingIntervals: [TimeSpan] {
        entries.withLock { $0.compactMap { $0.interval.map { TimeSpan.nanoseconds(Int64(clamping: $0)) } } }
    }

    /// Delay until the earliest pending deadline, if any.
    public var nextDeadline: MonotonicInstant? {
        entries.withLock { $0.map(\.deadline).min().map { MonotonicInstant(nanoseconds: $0) } }
    }
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/TestSupport/Fakes/Injection/InjectionFakes.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Injection service fakes, implemented in the skeleton (ADR 0313) so the worker (W1-D), the pipeline harness
// (W1-F1) and the guided test (W2-C) can test in parallel. W1-D owns this directory and may add behaviours;
// existing behaviours keep their meaning.

internal import AppModel
internal import Foundation
public import Injection
public import RealtimeSupport

/// Records every posted event and optionally forwards it to a sink (simulated field, window-server model, echo
/// loopback). `CGEventPost` never reports failure, so a revoked permission is modelled as `.silentlyDropping`:
/// posts "succeed" but nothing is delivered and no echo comes back (ADR 0311).
public final class FakeEventPoster: EventPoster, Sendable {
    public enum Posted: Sendable, Hashable {
        case synthetic(SyntheticKeyEvent, userData: Int64)
        case replay(KeyEventRecord, userData: Int64)
    }

    public enum Mode: Sendable, Hashable {
        /// Normal: recorded in `posted` and forwarded to the sink.
        case delivering
        /// Permission revoked or OS policy: recorded in `dropped`, not forwarded (no delivery, no echo).
        case silentlyDropping
        /// `CGEvent` creation fails: throws `.eventCreationFailed`, nothing recorded.
        case failingCreation
    }

    private struct State {
        var mode: Mode = .delivering
        var posted: [Posted] = []
        var dropped: [Posted] = []
    }

    private let sink: (@Sendable (Posted) -> Void)?
    private let state = Mutex(State())

    public init(sink: (@Sendable (Posted) -> Void)? = nil) { self.sink = sink }

    /// Delivered events, in posting order.
    public var posted: [Posted] { state.withLock { $0.posted } }
    /// Events posted while `.silentlyDropping`.
    public var dropped: [Posted] { state.withLock { $0.dropped } }
    public var mode: Mode { state.withLock { $0.mode } }
    public func setMode(_ mode: Mode) { state.withLock { $0.mode = mode } }

    public func post(_ event: SyntheticKeyEvent, userData: Int64) throws(PostError) {
        try deliver(.synthetic(event, userData: userData))
    }

    public func replay(_ record: KeyEventRecord, userData: Int64) throws(PostError) {
        try deliver(.replay(record, userData: userData))
    }

    private func deliver(_ item: Posted) throws(PostError) {
        let mode = state.withLock { state -> Mode in
            switch state.mode {
            case .delivering: state.posted.append(item)
            case .silentlyDropping: state.dropped.append(item)
            case .failingCreation: break
            }
            return state.mode
        }
        switch mode {
        case .delivering: sink?(item)
        case .silentlyDropping: return
        case .failingCreation: throw .eventCreationFailed
        }
    }
}

extension FakeEventPoster.Posted {
    /// The `kCGEventSourceUserData` the event carried.
    public var userData: Int64 {
        switch self {
        case .synthetic(_, let userData), .replay(_, let userData): userData
        }
    }
}

/// AX field access backed by a `SimulatedTextField`; can time out, be unavailable or ignore writes on demand.
public final class FakeFocusedFieldAccess: FocusedFieldAccess, Sendable {
    /// `writesIgnored`: every write reports success and does nothing. `textWritesIgnored`: selection writes
    /// apply, text writes report success and do nothing (4.5 "writes may silently do nothing").
    public enum Behaviour: Sendable, Hashable { case normal, timeout, unavailable, writesIgnored, textWritesIgnored }

    private let field: SimulatedTextField
    private let behaviourState: Mutex<Behaviour>
    private let calls = Atomic<Int>(0)

    public init(field: SimulatedTextField, behaviour: Behaviour = .normal) {
        self.field = field
        behaviourState = Mutex(behaviour)
    }

    public var behaviour: Behaviour { behaviourState.withLock { $0 } }
    public func setBehaviour(_ behaviour: Behaviour) { behaviourState.withLock { $0 = behaviour } }
    /// Number of AX calls made (bounded-call tests, PLT-R342).
    public var callCount: Int { calls.load(ordering: .relaxed) }

    public func selectedRange(_ field: FieldHandle, timeout: TimeSpan) -> AXCallResult<Injection.TextRange> {
        read { self.field.axSelectedRange() }
    }

    public func text(_ field: FieldHandle, in range: Injection.TextRange, timeout: TimeSpan) -> AXCallResult<String> {
        read { self.field.axText(in: range) }
    }

    public func setSelectedRange(_ field: FieldHandle, to range: Injection.TextRange, timeout: TimeSpan)
        -> AXCallResult<Void>
    {
        write(text: false) { self.field.axSetSelectedRange(range) }
    }

    public func setSelectedText(_ field: FieldHandle, to text: String, timeout: TimeSpan) -> AXCallResult<Void> {
        write(text: true) { self.field.axSetSelectedText(text) }
    }

    private func read<Value: Sendable>(_ body: () -> Value) -> AXCallResult<Value> {
        calls.wrappingAdd(1, ordering: .relaxed)
        switch behaviour {
        case .normal, .writesIgnored, .textWritesIgnored: return .success(body())
        case .timeout: return .timedOut
        case .unavailable: return .unavailable
        }
    }

    private func write(text: Bool, _ body: () -> Void) -> AXCallResult<Void> {
        calls.wrappingAdd(1, ordering: .relaxed)
        switch behaviour {
        case .normal:
            body()
            return .success(())
        case .textWritesIgnored:
            if !text { body() }
            return .success(())
        case .writesIgnored: return .success(())
        case .timeout: return .timedOut
        case .unavailable: return .unavailable
        }
    }
}

/// Multi-item, multi-type pasteboard with file promises, lazy data and slow reads for PLT-R461 tests.
public final class FakePasteboard: PasteboardAccess, Sendable {
    /// Conditions a real pasteboard can be in that make a snapshot impossible (PLT-R461 step 1).
    public enum Condition: Sendable, Hashable {
        case filePromise
        case lazyDataUnavailable
        case slowRead
        case writeFails
    }

    private struct State {
        var items: [PasteboardItemData]
        var changeCount = 1
        var conditions: Set<Condition> = []
        var writes = 0
    }

    private let state: Mutex<State>

    public init(items: [PasteboardItemData] = []) { state = Mutex(State(items: items)) }

    public var changeCount: Int { state.withLock { $0.changeCount } }
    public var items: [PasteboardItemData] { state.withLock { $0.items } }
    /// Number of `writeTransient` calls (coalescing tests).
    public var transientWriteCount: Int { state.withLock { $0.writes } }

    /// The plain-text value Command+V would paste (wire into `SimulatedTextField(pasteboardText:)`).
    public var plainText: String? {
        state.withLock { state in
            state.items.first?.data[PasteboardTypeName.plainText].flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    public func set(_ condition: Condition, _ active: Bool) {
        state.withLock { state in
            if active { state.conditions.insert(condition) } else { state.conditions.remove(condition) }
        }
    }

    /// Simulates the user copying something during the restore window.
    public func userCopies(_ item: PasteboardItemData) {
        state.withLock { state in
            state.items = [item]
            state.changeCount += 1
        }
    }

    public func snapshot(limits: PasteboardLimits) throws(PasteboardError) -> PasteboardSnapshot {
        let result: Result<PasteboardSnapshot, PasteboardError> = state.withLock { state in
            if state.conditions.contains(.filePromise) { return .failure(.filePromise) }
            if state.conditions.contains(.lazyDataUnavailable) { return .failure(.lazyDataUnavailable) }
            if state.conditions.contains(.slowRead) { return .failure(.timedOut) }
            let total = state.items.reduce(0) { sum, item in sum + item.data.values.reduce(0) { $0 + $1.count } }
            if total > limits.maxTotalBytes { return .failure(.tooLarge) }
            return .success(PasteboardSnapshot(changeCount: state.changeCount, items: state.items, totalBytes: total))
        }
        return try result.get()
    }

    public func writeTransient(_ text: String) throws(PasteboardError) -> Int {
        let result: Result<Int, PasteboardError> = state.withLock { state in
            if state.conditions.contains(.writeFails) { return .failure(.writeFailed) }
            var data: [String: Data] = [PasteboardTypeName.plainText: Data(text.utf8)]
            for marker in PasteboardTypeName.markers { data[marker] = Data() }
            state.items = [
                PasteboardItemData(types: [PasteboardTypeName.plainText] + PasteboardTypeName.markers, data: data)
            ]
            state.changeCount += 1
            state.writes += 1
            return .success(state.changeCount)
        }
        return try result.get()
    }

    public func restore(_ snapshot: PasteboardSnapshot) throws(PasteboardError) {
        let failed = state.withLock { state -> Bool in
            if state.conditions.contains(.writeFails) { return true }
            state.items = snapshot.items
            state.changeCount += 1
            return false
        }
        if failed { throw .writeFailed }
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/TestSupport/Fakes/Host/HostFakes.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Host-service fakes (W1-E). Pure Swift state behind a lock; no AX, TIS, IORegistry or TCC access. Observer
// callbacks run synchronously on the caller's thread, outside the fake's lock.

public import AppModel
import ApplicationServices
public import CompatRules
public import Foundation
public import Injection
public import InputHost
import RealtimeSupport

public final class FakeAXProvider: AXProvider, Sendable {
    private struct Observer {
        var id: UInt64
        var pid: Int32
        var notifications: Set<AXNotificationKind>
        var handler: @Sendable (AXNotificationKind) -> Void
    }

    private struct State {
        var focusedPID: Int32?
        var attributes: [Int32: FocusAttributes] = [:]
        var elements: [Int32: UInt16] = [:]
        var timingOut: Set<Int32> = []
        var unavailable: Set<Int32> = []
        var observers: [Observer] = []
        var nextObserverID: UInt64 = 1
        var manualRequests: [Int32] = []
        var elementQueries: [Int32: Int] = [:]
        var attributeQueries: [Int32: Int] = [:]
        var lastRequest: AXAttributeRequest?
        var refusedObservers: [Int32: Int] = [:]
        var refusedNotifications: [Int32: Set<AXNotificationKind>] = [:]
        var observeAttempts: [Int32: Int] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    /// Sets the focused app/element; posts the given notification to observers. `element` names the focused
    /// element within the app: the same number is the same `AXUIElement` (CFEqual), another number another one,
    /// so tests can move focus between fields of one app or keep it on one field while its attributes change.
    public func focus(pid: Int32, attributes: FocusAttributes, notify: AXNotificationKind?, element: UInt16 = 0) {
        state.withLock {
            $0.focusedPID = pid
            $0.attributes[pid] = attributes
            $0.elements[pid] = element
        }
        if let notify { post(notify, from: pid) }
    }

    /// AX names no focused application (the system-wide element has none).
    public func clearFocusedApplication() { state.withLock { $0.focusedPID = nil } }

    /// The focused application has no focused element.
    public func focusWithoutElement(pid: Int32, notify: AXNotificationKind?) {
        state.withLock {
            $0.focusedPID = pid
            $0.attributes[pid] = nil
        }
        if let notify { post(notify, from: pid) }
    }

    /// Delivers `kind` to the observers registered for `pid` (only if they asked for it).
    public func post(_ kind: AXNotificationKind, from pid: Int32) {
        let handlers = state.withLock { state in
            state.observers.filter { $0.pid == pid && $0.notifications.contains(kind) }.map(\.handler)
        }
        for handler in handlers { handler(kind) }
    }

    public func setTimingOut(pid: Int32, _ timingOut: Bool) {
        state.withLock {
            if timingOut { $0.timingOut.insert(pid) } else { $0.timingOut.remove(pid) }
        }
    }

    /// The next `times` observer requests for `pid` fail, like an app that has just launched and answers
    /// `AXObserverAddNotification` with `kAXErrorCannotComplete` (seen in the macOS 27 VM).
    public func refuseObservers(pid: Int32, times: Int) {
        state.withLock { $0.refusedObservers[pid] = max(0, times) }
    }

    /// `pid` refuses `kind` for good: a `.complete` request that includes it fails, a `.bestEffort` one gets the
    /// other notifications.
    public func refuseNotification(pid: Int32, _ kind: AXNotificationKind) {
        _ = state.withLock { $0.refusedNotifications[pid, default: []].insert(kind) }
    }

    /// Observer requests for `pid` so far, refused ones included.
    public func observeAttempts(pid: Int32) -> Int { state.withLock { $0.observeAttempts[pid, default: 0] } }

    public func setUnavailable(pid: Int32, _ unavailable: Bool) {
        state.withLock {
            if unavailable { $0.unavailable.insert(pid) } else { $0.unavailable.remove(pid) }
        }
    }

    public func focusedApplication() -> AXCallResult<Int32?> { .success(state.withLock { $0.focusedPID }) }

    public func focusedElement(pid: Int32) -> AXCallResult<AXFocusedElement?> {
        let (timingOut, unavailable, hasElement, element) = state.withLock { state in
            state.elementQueries[pid, default: 0] += 1
            return (
                state.timingOut.contains(pid), state.unavailable.contains(pid), state.attributes[pid] != nil,
                state.elements[pid] ?? 0
            )
        }
        if timingOut { return .timedOut }
        if unavailable { return .unavailable }
        guard hasElement else { return .success(nil) }
        return .success(AXFocusedElement(pid: pid, element: Self.elementReference(pid: pid, element: element)))
    }

    /// Fixture limits that keep every synthetic reference distinct and inside `Int32`.
    static let maximumFakePID: Int32 = 99_999
    static let maximumFakeElement: UInt16 = 20_000

    /// An application element is a local reference: creating it sends no AX message. Element 0 is the app's
    /// own reference; other elements use unused pids above 1,000,000, one per (pid, element) with the full pid.
    static func elementReference(pid: Int32, element: UInt16) -> AXElementReference {
        precondition((0...maximumFakePID).contains(pid), "fake pids stay below 100,000")
        precondition(element <= maximumFakeElement, "fake element numbers stay at or below 20,000")
        let reference = element == 0 ? pid : 1_000_000 + Int32(element) * (maximumFakePID + 1) + pid
        return AXElementReference(AXUIElementCreateApplication(reference))
    }

    public func attributes(of element: AXFocusedElement, request: AXAttributeRequest) -> AXCallResult<FocusAttributes> {
        let (timingOut, stored) = state.withLock { state in
            state.lastRequest = request
            state.attributeQueries[element.pid, default: 0] += 1
            return (state.timingOut.contains(element.pid), state.attributes[element.pid])
        }
        if timingOut { return .timedOut }
        guard var attributes = stored else { return .unavailable }
        if !request.includeDocumentURL { attributes.documentURL = nil }
        if !request.includeWindowTitle { attributes.windowTitle = nil }
        return .success(attributes)
    }

    public func observe(
        pid: Int32, notifications: Set<AXNotificationKind>, mode: AXObservationMode,
        handler: @escaping @Sendable (AXNotificationKind) -> Void
    ) -> (any AXObservation)? {
        let id = state.withLock { state -> UInt64? in
            state.observeAttempts[pid, default: 0] += 1
            if let refused = state.refusedObservers[pid], refused > 0 {
                state.refusedObservers[pid] = refused - 1
                return nil
            }
            let refused = notifications.intersection(state.refusedNotifications[pid] ?? [])
            if mode == .complete, !refused.isEmpty { return nil }
            let accepted = notifications.subtracting(refused)
            guard !accepted.isEmpty else { return nil }
            defer { state.nextObserverID += 1 }
            state.observers.append(
                Observer(id: state.nextObserverID, pid: pid, notifications: accepted, handler: handler))
            return state.nextObserverID
        }
        guard let id else { return nil }
        return FakeAXObservation { [weak self] in self?.removeObserver(id) }
    }

    public func enableManualAccessibility(pid: Int32) -> Bool {
        state.withLock { $0.manualRequests.append(pid) }
        return true
    }

    public var manualAccessibilityRequests: [Int32] { state.withLock { $0.manualRequests } }
    /// pid -> notifications of every live observer.
    public var observedNotifications: [Int32: Set<AXNotificationKind>] {
        state.withLock { state in
            Dictionary(state.observers.map { ($0.pid, $0.notifications) }, uniquingKeysWith: { $0.union($1) })
        }
    }

    /// Number of `focusedElement` queries per pid (circuit-breaker tests).
    public func elementQueryCount(pid: Int32) -> Int { state.withLock { $0.elementQueries[pid, default: 0] } }
    /// Number of `attributes(of:)` reads per pid (PLT-R389: a moved-only check of an unchanged focus reads none).
    public func attributeQueryCount(pid: Int32) -> Int { state.withLock { $0.attributeQueries[pid, default: 0] } }
    public var lastAttributeRequest: AXAttributeRequest? { state.withLock { $0.lastRequest } }

    private func removeObserver(_ id: UInt64) { state.withLock { $0.observers.removeAll { $0.id == id } } }
}

/// Observation with an inert run-loop source (never signalled), so adding it to the ax run loop is harmless.
public final class FakeAXObservation: AXObservation, Sendable {
    /// CF run-loop sources may be added and removed from any thread (CFRunLoop is thread-safe).
    private struct Source: @unchecked Sendable { let source: CFRunLoopSource }
    /// Gives the source a unique `info` pointer. Run loops keep sources in a set compared with `CFEqual`, and
    /// two version-0 sources with all-zero contexts are equal: removing one would remove the other (for example
    /// `RunLoopThread`'s keep-alive source, which ends the thread).
    private final class Identity: Sendable {}

    private let identity = Identity()
    private let source: Source
    private let onInvalidate: @Sendable () -> Void
    private let invalidated = Atomic<Bool>(false)

    init(onInvalidate: @escaping @Sendable () -> Void) {
        var context = CFRunLoopSourceContext()
        context.info = Unmanaged.passUnretained(identity).toOpaque()
        source = Source(source: CFRunLoopSourceCreate(nil, 0, &context))
        self.onInvalidate = onInvalidate
    }

    public var runLoopSource: CFRunLoopSource { source.source }
    public var isInvalidated: Bool { invalidated.load(ordering: .sequentiallyConsistent) }

    public func invalidate() {
        guard !invalidated.exchange(true, ordering: .sequentiallyConsistent) else { return }
        onInvalidate()
    }
}

public final class FakeProcessIdentityProvider: ProcessIdentityProvider, Sendable {
    private struct State {
        var processes: [Int32: ProcessIdentity]
        var order: [Int32]
        var dead: Set<Int32> = []
        var identityLookups: [Int32: Int] = [:]
        var runningApplicationScans = 0
        var frontmost: Int32?
    }

    private let state: Mutex<State>

    /// How often `identity(of:)` was asked for `pid` (cost checks, PLT-R382).
    public func identityLookups(of pid: Int32) -> Int { state.withLock { $0.identityLookups[pid] ?? 0 } }
    /// How often `runningApplications()` ran (a full scan in production).
    public var runningApplicationScans: Int { state.withLock { $0.runningApplicationScans } }

    public init(processes: [ProcessIdentity]) {
        state = Mutex(
            State(
                processes: Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { _, last in last }),
                order: processes.map(\.pid)))
    }

    public func identity(of pid: Int32) -> ProcessIdentity? {
        state.withLock { state in
            state.identityLookups[pid, default: 0] += 1
            return state.dead.contains(pid) ? nil : state.processes[pid]
        }
    }

    public func isAlive(_ pid: Int32) -> Bool { state.withLock { $0.processes[pid] != nil && !$0.dead.contains(pid) } }

    public func runningApplications() -> [ProcessIdentity] {
        state.withLock { state in
            state.runningApplicationScans += 1
            return state.order.filter { !state.dead.contains($0) }.compactMap { state.processes[$0] }
        }
    }

    /// The application NSWorkspace would call frontmost (the dev recorder's attribution, PLT-R904A).
    public func setFrontmost(_ pid: Int32?) { state.withLock { $0.frontmost = pid } }

    public func frontmostApplication() -> ProcessIdentity? {
        state.withLock { state in state.frontmost.flatMap { state.processes[$0] } }
    }

    public func add(_ process: ProcessIdentity) {
        state.withLock {
            if $0.processes[process.pid] == nil { $0.order.append(process.pid) }
            $0.processes[process.pid] = process
            $0.dead.remove(process.pid)
        }
    }

    /// The process exits: `isAlive` is false and its identity is gone.
    public func terminate(pid: Int32) { _ = state.withLock { $0.dead.insert(pid) } }

    /// A plausible identity for tests (`bundleURL` under /Applications, process name from the bundle's last part).
    public static func process(
        pid: Int32, bundle: String, name: String? = nil, version: String? = "1.0", build: String? = "1"
    ) -> ProcessIdentity {
        let key = BundleKey(rawValue: bundle)!
        let processName = bundle.split(separator: ".").last.map(String.init) ?? bundle
        return ProcessIdentity(
            pid: pid, bundle: key, bundleURL: URL(fileURLWithPath: "/Applications/\(processName).app"),
            shortVersion: version, buildVersion: build, appCategory: nil, localizedName: name ?? processName,
            processName: processName)
    }
}

public final class FakeSecureInputProbe: SecureInputProbe, Sendable {
    private struct State {
        var enabled = false
        var holderPID: Int32?
        var polls = 0
    }

    private let state = Mutex(State())

    public init() {}

    public func set(enabled: Bool, holderPID: Int32?) {
        state.withLock {
            $0.enabled = enabled
            $0.holderPID = holderPID
        }
    }

    public func isSecureEventInputEnabled() -> Bool {
        state.withLock {
            $0.polls += 1
            return $0.enabled
        }
    }

    public func secureInputHolderPID() -> Int32? { state.withLock { $0.holderPID } }
    /// Number of `isSecureEventInputEnabled` calls (polls).
    public var pollCount: Int { state.withLock { $0.polls } }
}

/// `listen` is the launch-time Input Monitoring preflight; `setLiveListen` gives the live check its own answer, as in
/// production, where the preflight keeps its launch answer after a grant (PLT-R701, PLT-R731).
public final class FakePermissionProbe: PermissionProbe, Sendable {
    private struct State {
        var trusted: Bool
        var post: Bool
        var listen: Bool
        /// The live Input Monitoring answer; nil follows `listen`.
        var liveListen: Bool?
        var digest: String? = "fake-signing-identity"
        var accessibilityPrompts = 0
        var listenRequests = 0
        var postRequests = 0
        var liveListenChecks = 0
    }

    private let state: Mutex<State>

    public init(trusted: Bool = true, post: Bool = true, listen: Bool = true) {
        state = Mutex(State(trusted: trusted, post: post, listen: listen))
    }

    public func set(trusted: Bool, post: Bool, listen: Bool) {
        state.withLock {
            $0.trusted = trusted
            $0.post = post
            $0.listen = listen
        }
    }

    /// Simulates another signing identity (a different build) or an unsigned build (`nil`).
    public func setSigningIdentityDigest(_ digest: String?) { state.withLock { $0.digest = digest } }

    /// The answer of the live Input Monitoring check (`canListenToEventsNow`); nil makes it follow `listen` again.
    public func setLiveListen(_ live: Bool?) { state.withLock { $0.liveListen = live } }

    public func isAccessibilityTrusted() -> Bool { state.withLock { $0.trusted } }
    public func canPostEvents() -> Bool { state.withLock { $0.post } }
    public func canListenToEvents() -> Bool { state.withLock { $0.listen } }
    public func canListenToEventsNow() -> Bool {
        state.withLock {
            $0.liveListenChecks += 1
            return $0.liveListen ?? $0.listen
        }
    }
    public func promptForAccessibility() { state.withLock { $0.accessibilityPrompts += 1 } }
    public func requestListenEventAccess() -> Bool {
        state.withLock {
            $0.listenRequests += 1
            return $0.listen
        }
    }

    public func requestPostEventAccess() -> Bool {
        state.withLock {
            $0.postRequests += 1
            return $0.post
        }
    }

    public func signingIdentityDigest() -> String? { state.withLock { $0.digest } }

    public var accessibilityPromptCount: Int { state.withLock { $0.accessibilityPrompts } }
    public var listenRequestCount: Int { state.withLock { $0.listenRequests } }
    public var postRequestCount: Int { state.withLock { $0.postRequests } }
    /// Number of live Input Monitoring checks (each creates a listen-only tap in production, PLT-R702).
    public var liveListenCheckCount: Int { state.withLock { $0.liveListenChecks } }
}

@MainActor
public final class FakeInputSourceProvider: InputSourceProvider {
    private var current: InputSourceInfo
    private var layouts: [InputSourceID: KeyboardLayoutData]
    private var handlers: [UInt64: @MainActor @Sendable () -> Void] = [:]
    private var nextHandlerID: UInt64 = 1
    public var enabled: [InputSourceInfo] = []
    public var keyboardType: UInt32 = 40
    /// Layout data returned for the current source when it is not an ASCII layout (the underlying layout).
    public var underlyingLayout: InputSourceID?

    public init(current: InputSourceInfo, layouts: [InputSourceID: KeyboardLayoutData]) {
        self.current = current
        self.layouts = layouts
    }

    /// Simulates the user selecting `source` and the selection notification.
    public func select(_ source: InputSourceInfo) {
        current = source
        notifyChange()
    }

    /// Delivers a change notification without changing the selection (for example, enabled sources changed).
    public func notifyChange() {
        for handler in handlers.values { handler() }
    }

    public var observerCount: Int { handlers.count }

    public func currentSource() -> InputSourceInfo { current }
    public func currentLayoutData() -> KeyboardLayoutData? { layouts[underlyingLayout ?? current.id] }
    public func enabledSources() -> [InputSourceInfo] { enabled }
    public func layoutData(for id: InputSourceID) -> KeyboardLayoutData? { layouts[id] }
    public func currentKeyboardType() -> UInt32 { keyboardType }
    public func observeChanges(_ handler: @escaping @MainActor @Sendable () -> Void) -> any ObservationToken {
        let id = nextHandlerID
        nextHandlerID += 1
        handlers[id] = handler
        return FakeObservationToken { [weak self] in
            onMainActor { self?.handlers[id] = nil }
        }
    }
}

@MainActor
public final class FakeWorkspaceEvents: WorkspaceEvents {
    private var handlers: [UInt64: @MainActor @Sendable (WorkspaceEvent) -> Void] = [:]
    private var nextID: UInt64 = 1

    public init() {}

    public func send(_ event: WorkspaceEvent) {
        for handler in handlers.values { handler(event) }
    }

    public var observerCount: Int { handlers.count }

    public func observe(_ handler: @escaping @MainActor @Sendable (WorkspaceEvent) -> Void) -> any ObservationToken {
        let id = nextID
        nextID += 1
        handlers[id] = handler
        return FakeObservationToken { [weak self] in
            onMainActor { self?.handlers[id] = nil }
        }
    }
}

/// Runs `body` synchronously when already on the main thread (tests), otherwise hops to the main actor.
private func onMainActor(_ body: @escaping @MainActor @Sendable () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { body() }
    } else {
        Task { @MainActor in body() }
    }
}

/// Calls `onCancel` once.
public final class FakeObservationToken: ObservationToken {
    private let onCancel: @Sendable () -> Void
    private let cancelled = Atomic<Bool>(false)

    public init(onCancel: @escaping @Sendable () -> Void) { self.onCancel = onCancel }

    public var isCancelled: Bool { cancelled.load(ordering: .sequentiallyConsistent) }

    public func cancel() {
        guard !cancelled.exchange(true, ordering: .sequentiallyConsistent) else { return }
        onCancel()
    }
}

public final class FakeBundleInspector: BundleInspector, Sendable {
    private let bundles: [URL: FakeBundle]

    public init(bundles: [URL: FakeBundle]) { self.bundles = bundles }
    public struct FakeBundle: Sendable, Hashable {
        public var frameworks: [String]
        public var helpers: [String]
        /// Paths relative to the bundle, for example `Contents/MacOS/libxul.dylib`.
        public var files: [String]
        public var info: [String: JSONValue]
        public init(frameworks: [String], helpers: [String], files: [String], info: [String: JSONValue]) {
            self.frameworks = frameworks
            self.helpers = helpers
            self.files = files
            self.info = info
        }
    }

    public func frameworkNames(in bundle: URL) -> [String] { bundles[bundle]?.frameworks ?? [] }
    public func helperAppNames(in bundle: URL) -> [String] { bundles[bundle]?.helpers ?? [] }

    /// Same contract as the production inspector (PLT-R510): `directory` is a folder inside a known bundle, and
    /// a file matches when it lies at most `maxDepth` levels below it (1 = directly inside).
    public func containsFile(named name: String, in directory: URL, maxDepth: Int) -> Bool {
        let target = directory.standardizedFileURL.path
        guard
            let (bundleURL, bundle) = bundles.first(where: { url, _ in
                let root = url.standardizedFileURL.path
                return target == root || target.hasPrefix(root + "/")
            })
        else { return false }
        let folder = target.dropFirst(bundleURL.standardizedFileURL.path.count).split(separator: "/")
        return bundle.files.contains { path in
            let components = path.split(separator: "/")
            guard components.last.map(String.init) == name, components.starts(with: folder) else { return false }
            return components.count - folder.count <= maxDepth
        }
    }

    public func infoDictionary(of bundle: URL) -> [String: JSONValue]? { bundles[bundle]?.info }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/TestSupport/Fakes/Rules/RulesFakes.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Scripted decision resolver so focus tests (W1-E) do not depend on the rules implementation (W1-C).
// Implemented in the skeleton (ADR 0313); W1-C owns this directory and may add helpers.

public import AppModel
public import CompatRules
public import Foundation
public import InputHost
internal import RealtimeSupport

public final class FakeDecisionResolver: FocusDecisionResolving, Sendable {
    private let decisions: [BundleKey: ResolvedDecision]
    private let fallback: ResolvedDecision
    private let fingerprints: [BundleKey: EngineFingerprint]
    private let contexts = Mutex<[MatchContext]>([])
    public let overlayBundles: Set<BundleKey>
    public let titlePatternBundles: Set<BundleKey>

    public init(
        decisions: [BundleKey: ResolvedDecision], fallback: ResolvedDecision, overlayBundles: Set<BundleKey> = [],
        titlePatternBundles: Set<BundleKey> = [], fingerprints: [BundleKey: EngineFingerprint] = [:]
    ) {
        self.decisions = decisions
        self.fallback = fallback
        self.overlayBundles = overlayBundles
        self.titlePatternBundles = titlePatternBundles
        self.fingerprints = fingerprints
    }

    public func resolve(_ context: MatchContext) -> ResolvedDecision {
        contexts.withLock { $0.append(context) }
        return context.bundle.flatMap { decisions[$0] } ?? fallback
    }

    /// Every context passed to `resolve` (W1-E: "resolution happens once per focus change").
    public var resolvedContexts: [MatchContext] { contexts.withLock { $0 } }

    public func fingerprint(bundleURL: URL, bundle: BundleKey) -> EngineFingerprint {
        fingerprints[bundle] ?? .native
    }

    /// A decision equivalent to the 5.4 `defaults` block, with `byEngine` resolved per PLT-R386 (`whenKnown` for
    /// native and Catalyst apps, `never` otherwise).
    public static func defaultDecision(engine: EngineFingerprint) -> ResolvedDecision {
        ResolvedDecision(
            rule: nil, source: .default, specificity: 0, strategy: .backspaceReplace, params: .defaults,
            fallback: [.passThrough], defaultMode: .inherit,
            requireTextFocus: engine == .native || engine == .catalyst ? .whenKnown : .never,
            verifyReentry: .whenReadable, axEnable: .none, overlay: false, requiresUserOptIn: false,
            engineContext: .general, features: .defaults)
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/TestSupport/Fakes/Tap/TapFakes.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Event tap fakes (ADR 0313): never create a real tap and never talk to the WindowServer. Implemented in the
// skeleton; workstream W1-F2 owns this directory and may add behaviours.

public import CoreFoundation
public import CoreGraphics
public import InputHost
internal import RealtimeSupport

/// Pure Swift tap handle. `install` adds a run-loop source that does nothing unless a test schedules a block
/// with `performOnTapThread` (so the tap thread's run loop has a source and keeps running), and records
/// enable/disable calls.
public final class FakeEventTapHandle: EventTapHandle, Sendable {
    /// CF run-loop objects are thread-safe to add, signal, wake and remove from any thread.
    private struct Installation: @unchecked Sendable {
        var source: CFRunLoopSource
        var runLoop: CFRunLoop
    }

    private struct State {
        var enabled = true
        var installed = false
        var invalidated = false
        var enableCalls: [Bool] = []
        var installation: Installation?
        var installedRunLoop: Installation?
    }

    /// Blocks run by the source's perform callback, on the thread whose run loop holds the source.
    private final class PerformQueue: Sendable {
        private let blocks = Mutex<[@Sendable () -> Void]>([])
        func append(_ block: @escaping @Sendable () -> Void) { blocks.withLock { $0.append(block) } }
        func drain() {
            let pending = blocks.withLock { blocks -> [@Sendable () -> Void] in
                defer { blocks.removeAll() }
                return blocks
            }
            for block in pending { block() }
        }
    }

    private let state = Mutex(State())
    private let queue = PerformQueue()

    public init() {}

    public func install(on runLoop: CFRunLoop) {
        var context = CFRunLoopSourceContext()
        context.info = Unmanaged.passUnretained(queue).toOpaque()
        context.perform = { info in
            guard let info else { return }
            Unmanaged<PerformQueue>.fromOpaque(info).takeUnretainedValue().drain()
        }
        let source = CFRunLoopSourceCreate(nil, 0, &context)
        CFRunLoopAddSource(runLoop, source, .commonModes)
        let installation = Installation(source: source!, runLoop: runLoop)
        state.withLock {
            $0.installed = true
            $0.installation = installation
            $0.installedRunLoop = installation
        }
    }

    public func setEnabled(_ enabled: Bool) {
        state.withLock {
            $0.enabled = enabled
            $0.enableCalls.append(enabled)
        }
    }

    public var isEnabled: Bool { state.withLock { $0.enabled && !$0.invalidated } }

    public func invalidate() {
        let installation = state.withLock { state -> Installation? in
            state.invalidated = true
            state.enabled = false
            defer { state.installation = nil }
            return state.installation
        }
        if let installation { CFRunLoopRemoveSource(installation.runLoop, installation.source, .commonModes) }
    }

    /// Simulates the OS disabling the tap without a disabled event (PLT-R331 path).
    public func systemDisables() { state.withLock { $0.enabled = false } }

    /// Runs `block` on the thread whose run loop holds this handle's source, as the tap's own callbacks would
    /// run. False when the handle is not installed or already invalidated.
    @discardableResult
    public func performOnTapThread(_ block: @escaping @Sendable () -> Void) -> Bool {
        guard let installation = state.withLock({ $0.installation }) else { return false }
        queue.append(block)
        CFRunLoopSourceSignal(installation.source)
        CFRunLoopWakeUp(installation.runLoop)
        return true
    }

    public var isInstalled: Bool { state.withLock { $0.installed } }
    public var isInvalidated: Bool { state.withLock { $0.invalidated } }
    public var enableCalls: [Bool] { state.withLock { $0.enableCalls } }
    /// Identity of the run loop the source was added to (PLT-R303 tests compare it with the tap thread's).
    public var installedRunLoopIdentity: ObjectIdentifier? {
        state.withLock { $0.installedRunLoop.map { ObjectIdentifier($0.runLoop) } }
    }
}

/// Returns `FakeEventTapHandle`s, or nil while `failCreation` is set (PLT-R332 backoff tests).
public final class FakeEventTapFactory: EventTapFactory, Sendable {
    private struct State {
        var failCreation: Bool
        var handles: [FakeEventTapHandle] = []
        var masks: [TapEventMask] = []
        var userInfos: [UInt] = []
    }

    private let state: Mutex<State>

    public init(failCreation: Bool = false) { state = Mutex(State(failCreation: failCreation)) }

    public func setFailCreation(_ fail: Bool) { state.withLock { $0.failCreation = fail } }
    /// Handles created so far (PLT-R302: tests assert at most one is alive).
    public var handles: [FakeEventTapHandle] { state.withLock { $0.handles } }
    public var requestedMasks: [TapEventMask] { state.withLock { $0.masks } }
    /// `userInfo` of every request as a bit pattern (0 for nil), so a test can hand it to the callback bridge
    /// from a `@Sendable` block.
    public var userInfoBitPatterns: [UInt] { state.withLock { $0.userInfos } }

    public func makeTap(mask: TapEventMask, callback: CGEventTapCallBack, userInfo: UnsafeMutableRawPointer?)
        -> (any EventTapHandle)?
    {
        state.withLock { state in
            state.masks.append(mask)
            state.userInfos.append(UInt(bitPattern: userInfo))
            guard !state.failCreation else { return nil }
            let handle = FakeEventTapHandle()
            state.handles.append(handle)
            return handle
        }
    }
}

/// `TapControl` without a thread: records enable calls and stops; `systemDisables()` turns the tap off the way
/// the OS does, without an enable call (PLT-R331 tests of `TapWatchdog`).
public final class FakeTapControl: TapControl, Sendable {
    private struct State {
        var enabled: Bool
        var running: Bool
        var enableCalls: [Bool] = []
        var stopCalls = 0
    }

    private let state: Mutex<State>

    public init(enabled: Bool = true, running: Bool = true) {
        state = Mutex(State(enabled: enabled, running: running))
    }

    public func setEnabled(_ enabled: Bool) {
        state.withLock {
            $0.enabled = enabled
            $0.enableCalls.append(enabled)
        }
    }

    public var isEnabled: Bool { state.withLock { $0.enabled && $0.running } }
    public var isRunning: Bool { state.withLock { $0.running } }

    public func stop() {
        state.withLock {
            $0.running = false
            $0.stopCalls += 1
        }
    }

    public func systemDisables() { state.withLock { $0.enabled = false } }
    public var enableCalls: [Bool] { state.withLock { $0.enableCalls } }
    public var stopCalls: Int { state.withLock { $0.stopCalls } }
}

/// Counts `reclaimAll()` calls (ADR 0303: the watchdog's 5 s tick frees retired snapshot boxes).
public final class FakeSnapshotReclaimer: SnapshotReclaiming, Sendable {
    private let calls = Atomic<Int>(0)
    public init() {}
    public func reclaimAll() { calls.wrappingAdd(1, ordering: .relaxed) }
    public var reclaimCount: Int { calls.load(ordering: .relaxed) }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/TestSupport/Pipeline/PipelineSupport.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Pipeline property-test support (13.1): scripted engine, window-server queue model, deterministic harness,
// conservation ledger and seeded event generator. Workstream W1-F1. `SimulatedTextField` and the injection
// fakes live in Fakes/Common and Fakes/Injection (implemented in the skeleton, ADR 0313). The logic lives in
// the files next to this one (ScriptedEngine, ConservationLedger, RandomEventGenerator, PipelineHarness,
// ReferenceJobConsumer, PipelineFixtures); this file is the public surface.

internal import AppModel
public import Diagnostics
public import Injection
public import InputHost
internal import RealtimeSupport
public import VietnameseEngine

/// Scripted engine: maps typed characters to edits with a tiny Telex-like table (aa -> â, s -> acute on the
/// last vowel, w -> ư), enough to exercise deletes and inserts without the real engine. Rules in
/// `ScriptedComposer`.
public struct ScriptedEngine: CompositionEngine {
    private var composer = ScriptedComposer()
    private let log: EngineEventLog?

    public init() { log = nil }
    init(log: EngineEventLog?) { self.log = log }

    public mutating func handle(_ event: EngineEvent) -> EngineOutput {
        log?.handled(event)
        return composer.handle(event)
    }

    public var activeDisplay: String { composer.display }
}

/// Uses the reference recogniser so the suites run before W1-E's `HotkeyRecognizer` lands; switch `Hotkeys`
/// to `HotkeyRecognizer` to run them against the production recogniser.
public struct ScriptedEngineFactory: CompositionEngineFactory, Sendable {
    public typealias Hotkeys = ReferenceHotkeyRecognizer
    public let log: EngineEventLog?

    public init() { log = nil }
    public init(log: EngineEventLog) { self.log = log }

    public func makeEngine(for variant: EngineVariant, settings: TapSettingsSnapshot) -> ScriptedEngine {
        log?.made(variant)
        return ScriptedEngine(log: log)
    }
}

/// What happened to each physical event (PLT-R312). The harness reports every physical keyboard event with its
/// tap outcome and every delivery to the field; `violations()` checks the rules in `LedgerState`.
public final class ConservationLedger: Sendable {
    public struct Violation: Sendable, Hashable, CustomStringConvertible {
        public var eventIndex: Int
        public var reason: String
        public var description: String { "event \(eventIndex): \(reason)" }
    }

    private let state = Mutex(LedgerState())

    public init() {}
    public func physical(_ index: Int, _ event: RawKeyEvent, outcome: EventOutcome?) {
        state.withLock { $0.physical(index, event, outcome: outcome) }
    }
    public func delivered(_ record: KeyEventRecord, asReplayOf index: Int) {
        state.withLock { $0.delivered(record, asReplayOf: index) }
    }
    public func passedThrough(_ index: Int) { state.withLock { $0.passedThrough(index) } }
    /// The event's replay or edit was posted while the poster was `.silentlyDropping` (ADR 0311): allowed only
    /// after posting broke, and the total must equal `PlatformMetrics.lostWhilePostingBroken`.
    public func lostWhilePostingBroken(_ index: Int) { state.withLock { $0.lost(index) } }
    /// The edit job created for the physical event `index` reached the field (its final event passed the tap).
    public func editDelivered(forEvent index: Int) { state.withLock { $0.editDelivered(index) } }
    /// The event was processed while the tap was failing open: it must pass (PLT-R730); its keyUp pairing and
    /// ordering are not checked, because fail-open stops holding by design.
    public func processedWhileFailingOpen(_ index: Int) { state.withLock { $0.failingOpen(index) } }
    /// The poster stopped (false) or resumed (true) delivering. Losses are allowed only while it does not.
    public func postingWorks(_ works: Bool) { state.withLock { $0.postingWorks(works) } }
    /// `PlatformMetrics.lostWhilePostingBroken` at the end of the run.
    public func lostMetric(_ value: UInt64) { state.withLock { $0.lostMetric = value } }
    /// A property the harness checks itself (fail-open, echo handling, PLT-R210 resets).
    public func violation(_ index: Int, _ reason: String) { state.withLock { $0.extra(index, reason) } }
    /// Exactly one outcome per physical keyboard event, replays once and in order, keyUp pairing (PLT-R313).
    /// Conservation is checked only while posting works; losses after posting broke are counted, never silent.
    public func violations() -> [Violation] { state.withLock { $0.violations() } }
}

/// Model of the WindowServer event queue between the HID system or `CGEventPost` and the session tap
/// (ADR 0311). Physical events and posted synthetic events enter one FIFO and reach the tap in that order;
/// what the tap passes reaches the field. In `.lagging` mode physical events wait in the queue until a
/// `.tapDrains` step, so a key typed before the worker posted reaches the tap after the posting finished: the
/// case that a "posted = done" definition of in flight gets wrong (`serverQueueLag` in the review).
public final class SimulatedWindowServer {
    public enum Mode: Sendable, Hashable {
        /// The tap receives each event as soon as it is enqueued.
        case immediate
        /// Events wait until the harness runs a `.tapDrains` step.
        case lagging
    }

    public enum Pending: Sendable {
        case physical(index: Int, RawKeyEvent)
        case posted(FakeEventPoster.Posted)
    }

    public let mode: Mode
    private var queue: [Pending] = []
    private var head = 0

    public init(mode: Mode) { self.mode = mode }
    public func enqueue(_ pending: Pending) { queue.append(pending) }
    public func drain(maxEvents: Int) -> [Pending] {
        let end = head + min(max(0, maxEvents), queue.count - head)
        let drained = Array(queue[head..<end])
        head = end
        if head == queue.count {
            queue.removeAll(keepingCapacity: true)
            head = 0
        }
        return drained
    }
    public var count: Int { queue.count - head }
}

/// Seeded random interleavings of keys, chords, mouse downs, focus, settings and input-source changes,
/// tap-disabled events, secure-input toggles and permission changes (section 3 acceptance: 100,000 sequences). Rules in `GeneratorCore`.
public struct RandomEventGenerator: Sendable {
    public enum Step: Sendable, Hashable {
        case key(RawKeyEvent)
        case focusChange
        case secureInput(Bool)
        case permission(Bool)
        case advanceMicroseconds(UInt64)
        case workerRuns(maxJobs: Int)
        /// The tap receives up to `maxEvents` queued events (meaningful with `SimulatedWindowServer.Mode.lagging`).
        case tapDrains(maxEvents: Int)
        /// The poster starts or stops dropping silently (permission revoked mid-sequence, ADR 0311).
        case postingWorks(Bool)
        /// A new settings generation (PLT-R1008): the restore binding and the engine revision vary.
        case settingsChange
        /// A new input-source generation with the same layout (PLT-R340).
        case inputSourceChange
    }

    private var core: GeneratorCore

    public init(seed: UInt64) { core = GeneratorCore(seed: seed, includePostingBreaks: false) }
    /// `includePostingBreaks` adds `.postingWorks` steps (the posting-broken suite).
    public init(seed: UInt64, includePostingBreaks: Bool) {
        core = GeneratorCore(seed: seed, includePostingBreaks: includePostingBreaks)
    }
    public mutating func sequence(length: Int) -> [Step] { core.sequence(length: length) }
}

/// Wires a `KeyPipeline<ScriptedEngineFactory, ManualClock>` and a job consumer (W1-F1: a reference consumer;
/// W2-A: the real `InjectionWorker` in step mode) to a `FakeEventPoster` whose events go through a
/// `SimulatedWindowServer` back into the pipeline (echoes) and on into a `SimulatedTextField`. `run` executes
/// the steps, then settles: it drains the server and the queue and lets echo timeouts expire, so the ledger
/// sees every delivery.
public final class PipelineHarness {
    private let core: HarnessCore

    public init(
        field: SimulatedTextField, layout: LayoutTable, clock: ManualClock,
        server: SimulatedWindowServer.Mode = .immediate
    ) {
        core = HarnessCore(field: field, layout: layout, clock: clock, server: server, policy: .untilEcho)
    }
    /// `policy: .untilPosted` is the self-check of ADR 0311: with `.lagging` it must produce ordering violations.
    public init(
        field: SimulatedTextField, layout: LayoutTable, clock: ManualClock, server: SimulatedWindowServer.Mode,
        policy: InFlightPolicy
    ) {
        core = HarnessCore(field: field, layout: layout, clock: clock, server: server, policy: policy)
    }
    public func run(_ steps: [RandomEventGenerator.Step]) { core.run(steps) }
    public var ledger: ConservationLedger { core.ledger }
    public var field: SimulatedTextField { core.field }
    public var metrics: PlatformMetrics { core.metrics }
    public var engineLog: EngineEventLog { core.engineLog }
    /// Notices the pipeline sent to the main thread, drained after every step.
    public var mainNotices: [MainNotice] { core.mainNotices }
    public var statistics: HarnessStatistics { core.statistics }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/TestSupport/Scenario/Scenario.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Compatibility scenario files (PLT-R530): `compat/scenarios/<id>.json`, schema
// compat/schema/scenario.schema.json. Executed by `compat-harness` on the self-hosted runner only.

public import AppModel
public import Foundation
public import RealtimeSupport

public struct Scenario: Sendable, Hashable, Codable {
    public enum TimingProfile: String, Sendable, Hashable, Codable { case normal, fast, burst }
    public enum Readback: String, Sendable, Hashable, Codable { case ax, webdriver, terminalCapture, human }
    public enum Method: String, Sendable, Hashable, Codable { case telex, vni }

    public struct SetupStep: Sendable, Hashable, Codable {
        public enum Action: String, Sendable, Hashable, Codable, CaseIterable {
            case launch, openURL, seedHistory, focusField, selectInputSource, setSecureInput, wait
            /// Triggers an integration hook of the app under test: `tapTimeout`, `revokePermission` or
            /// `restorePermission`, optionally `@N` to fire after the first N entries of `keys` (QA-R11). Answered
            /// only by the app's INTEGRATION_HOOKS test build (ADR 0502).
            case testHook
        }

        public var action: Action
        public var value: String?

        public init(action: Action, value: String? = nil) {
            self.action = action
            self.value = value
        }
    }

    public struct Expectation: Sendable, Hashable, Codable {
        public var text: String?
        public var paused: Bool?
        public var holderBundleId: BundleKey?
        public var firstKeyAfterReleaseComposed: Bool?
        /// PLT-R422: no read-back text (the key script's, and every `repeat` word's) holds the placeholder U+200B.
        public var noPlaceholderResidue: Bool?

        public init(
            text: String? = nil, paused: Bool? = nil, holderBundleId: BundleKey? = nil,
            firstKeyAfterReleaseComposed: Bool? = nil, noPlaceholderResidue: Bool? = nil
        ) {
            self.text = text
            self.paused = paused
            self.holderBundleId = holderBundleId
            self.firstKeyAfterReleaseComposed = firstKeyAfterReleaseComposed
            self.noPlaceholderResidue = noPlaceholderResidue
        }
    }

    /// `repeat` in the file (PLT-R422 gate, section 4 acceptance): after the key script passes, `words`
    /// randomised words of the Telex soak corpus drawn with `seed`, each typed after `prefix` at `timing` and
    /// read back on its own; every word must read back as exactly its corpus text.
    public struct Repetition: Sendable, Hashable, Codable {
        public var words: Int
        public var seed: UInt64
        public var timing: TimingProfile
        /// Typed before every word; must leave the field empty or its content selected, so the word replaces it
        /// (`command+l` in an address bar).
        public var prefix: [String]

        public init(words: Int, seed: UInt64, timing: TimingProfile, prefix: [String]) {
            self.words = words
            self.seed = seed
            self.timing = timing
            self.prefix = prefix
        }
    }

    public var id: String
    public var targetBundleId: BundleKey
    public var setup: [SetupStep]
    /// Physical key names (`a`, `shift`, `space`, `return`, `backspace`, ...), layout-independent positions.
    public var keys: [String]
    public var timing: TimingProfile
    public var method: Method
    public var layout: InputSourceID?
    public var expect: Expectation
    public var readback: Readback
    public var repetition: Repetition?

    public init(
        id: String, targetBundleId: BundleKey, setup: [SetupStep], keys: [String], timing: TimingProfile,
        method: Method, layout: InputSourceID? = nil, expect: Expectation, readback: Readback,
        repetition: Repetition? = nil
    ) {
        self.id = id
        self.targetBundleId = targetBundleId
        self.setup = setup
        self.keys = keys
        self.timing = timing
        self.method = method
        self.layout = layout
        self.expect = expect
        self.readback = readback
        self.repetition = repetition
    }

    enum CodingKeys: String, CodingKey {
        case id, targetBundleId, setup, keys, timing, method, layout, expect, readback
        case repetition = "repeat"
    }
}

/// Posts physical-like events (harness process, its own event source) with the timing profile.
public protocol KeyboardDriver: Sendable {
    func type(_ keys: [String], profile: Scenario.TimingProfile) async throws
}

public protocol ScenarioReadback: Sendable {
    func currentText(of scenario: Scenario) async throws -> String
}

public struct ScenarioResult: Sendable, Hashable, Codable {
    public enum Outcome: String, Sendable, Hashable, Codable { case pass, fail, needsHuman }
    public var scenario: String
    public var outcome: Outcome
    public var observedText: String?
    public var durationSeconds: Double
    /// Why the outcome is `fail` or `needsHuman` (failing stage and error description: bundle ids, identifiers,
    /// error names, never typed text, PLT-R901); nil on `pass`. Optional in `results.json` (PLT-R530, QA-R21).
    public var reason: String?

    public init(
        scenario: String, outcome: Outcome, observedText: String?, durationSeconds: Double, reason: String? = nil
    ) {
        self.scenario = scenario
        self.outcome = outcome
        self.observedText = observedText
        self.durationSeconds = durationSeconds
        self.reason = reason
    }
}

public struct ScenarioRunner: Sendable {
    let driver: any KeyboardDriver
    let readback: any ScenarioReadback
    let setup: any ScenarioSetupPerformer
    let probe: (any ScenarioStateProbe)?
    let clock: any MonotonicClock

    public init(driver: any KeyboardDriver, readback: any ScenarioReadback) {
        self.init(driver: driver, readback: readback, setup: NoScenarioSetup(), probe: nil, clock: MachClock())
    }

    /// Full form used by `compat-harness`: performs the setup steps, asks `probe` for the app state the
    /// expectation names (paused, holder, first key after release) and times the run with `clock`.
    public init(
        driver: any KeyboardDriver, readback: any ScenarioReadback, setup: any ScenarioSetupPerformer,
        probe: (any ScenarioStateProbe)?, clock: any MonotonicClock
    ) {
        self.driver = driver
        self.readback = readback
        self.setup = setup
        self.probe = probe
        self.clock = clock
    }

    public func run(_ scenario: Scenario) async -> ScenarioResult { await execute(scenario) }

    /// Every `*.json` file of `directory`, sorted by file name, decoded strictly and validated
    /// (`ScenarioLoader`). Throws `ScenarioLoadError` naming the first invalid file.
    public static func load(directory: URL) throws -> [Scenario] {
        try ScenarioLoader().load(directory: directory)
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/TestSupport/Scenario/AppHooks.swift until="/// Scenario expectations from the app's own state" -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Harness side of the app under test's integration hooks (QA-R11, PLT-R821, 13.2 "tap timeout injection (test
// hook)", "permission revocation during typing"). The app answers only in the test build that the self-hosted
// runner installs (compiled with the INTEGRATION_HOOKS condition, never in a release). The wire format is one
// shared Codable definition, Diagnostics/IntegrationHooks.swift (ADR 0502, "Integration hooks"), which the app's
// hooks server decodes and encodes too. The harness reaches the app through `AppHookClient`; the file-drop
// transport is FileDropHookChannel.swift, tests use an in-memory app.

internal import AppModel
public import Diagnostics
internal import Foundation

public enum AppHookError: Error, Sendable, Hashable, CustomStringConvertible {
    /// No answer within the timeout: the app is not running, or it is not the hooks build.
    case timeout(command: String)
    case rejected(command: String, code: String)
    case malformedResponse(command: String)
    case missingPayload(command: String)

    public var description: String {
        switch self {
        case .timeout(let command):
            "integration hook '" + command + "' timed out (is the INTEGRATION_HOOKS test build running?)"
        case .rejected(let command, let code): "integration hook '" + command + "' rejected: " + code
        case .malformedResponse(let command): "integration hook '" + command + "' answered with malformed JSON"
        case .missingPayload(let command): "integration hook '" + command + "' answered without its payload"
        }
    }
}

/// Sends one hook command to the app under test and returns its answer. Live: `FileDropHookChannel` over the
/// app's hooks directory; tests: an in-memory app.
public protocol AppHookClient: Sendable {
    func send(_ command: AppHookCommand) async throws -> AppHookResponse
}

extension AppHookClient {
    public func state() async throws -> AppStateSnapshot {
        guard let state = try await accepted(.state).state else { throw AppHookError.missingPayload(command: "state") }
        return state
    }

    public func trigger(_ hook: AppTestHook) async throws { _ = try await accepted(.trigger(hook)) }

    public func resetMetrics() async throws { _ = try await accepted(.resetMetrics) }

    public func latencyProbe(_ profile: LatencyProbeResult.Profile) async throws -> LatencyProbeResult {
        guard let result = try await accepted(.latencyProbe(profile)).latencyProbe else {
            throw AppHookError.missingPayload(command: "latencyProbe")
        }
        return result
    }

    /// The response when `ok`, otherwise `AppHookError.rejected`.
    func accepted(_ command: AppHookCommand) async throws -> AppHookResponse {
        let response = try await send(command)
        guard response.ok else { throw AppHookError.rejected(command: command.name, code: response.error ?? "error") }
        return response
    }
}
```
<!-- /include -->

## 14. TestHost app (QA-R10)

Owned files: `TestHost/**` (W2-E1). A normal AppKit app (`TestHost` target, bundle ID `<dev bundle
ID>.testhost`, ad-hoc signed because it needs no permissions); the skeleton window has the native text field,
W2-E1 adds one view per remaining field kind; every field exposes its text through AX by accessibility
identifier, web fields mirror their DOM value into a native field. Local test pages under
`TestHost/Resources/Pages/` reproduce inline autocomplete, a first-keystroke edit-mode transition and a
contenteditable composer without network resources (13.2); the same files are served to real browsers on the
self-hosted runner. W2-E2 added a second window (`testhost.second.*` fields, one of them showing each Escape as
`<esc>`), a Reset fields button the harness presses before each TestHost scenario, and a Window menu whose
Command+1, Command+2 and Command+3 move the focus inside a key script (per-window rules, the T6 workload).

<!-- include: TestHost/Sources/TestHostFields.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// QA-R10 contract: each field exposes its current text to the runner through AX (`AXValue` of the element
// with this accessibility identifier). Web fields mirror their DOM value into a native read-only field through
// a WKScriptMessageHandler so AX readback works the same way (WebFields.swift). Workstream W2-E1.
// The window title and labels are fixed English test-fixture text, not product copy.

import AppKit

enum TestHostField: String, CaseIterable {
    case nativeTextField = "testhost.native.textField"
    case nativeTextView = "testhost.native.textView"
    case webInput = "testhost.web.input"
    case webTextarea = "testhost.web.textarea"
    case webContentEditable = "testhost.web.contentEditable"
    /// Selects the suggested remainder after the caret like a browser address bar (4.3).
    case addressBarWithCompletion = "testhost.sim.addressBar"
    /// Drops the first event after entering edit mode and autocompletes from a column (Sheets/Excel, 6).
    case spreadsheetCell = "testhost.sim.sheetCell"
    /// `NSSecureTextField`: asserts no transformation (PLT-R387).
    case passwordField = "testhost.native.password"
    /// Second window (SecondWindow.swift): per-window rules, privacy canary strategies, restore hotkey.
    case secondTextField = "testhost.second.textField"
    case secondTextView = "testhost.second.textView"
    case secondPlainField = "testhost.second.plainField"
    /// Shows every Escape that reaches it as `<esc>` (PLT-R353).
    case escapeField = "testhost.second.escapeField"
    /// Name field of the save sheet that Command+S attaches to the second window (SaveSheet.swift, PLT-R389 and the
    /// PLT-R340 late focus change: Pa's T5.5 report of 2026-11-14).
    case sheetName = "testhost.sheet.name"
    /// Read-only mirror of the sheet's name field in the second window. An AX focus request focuses the second
    /// window's text view, the "document" Command+S is typed in, so a scenario can read the sheet back.
    case sheetMirror = "testhost.sheet.mirror"
    /// Search field of the non-activating panel that Command+K opens, with inline completion like Spotlight's
    /// (SearchPanel.swift, PLT-R389, Pa's items 7 and 9 of 2026-11-14).
    case panelSearch = "testhost.panel.search"
    /// Read-only transcript of the search panel in the main window: each closed search followed by `<esc>`, then
    /// the current query. An AX focus request focuses the main window's text field.
    case panelMirror = "testhost.panel.mirror"
}

/// Identifier of the button that clears every field of both windows (pressed by the harness before each
/// TestHost scenario, TestHostControls.resetFields).
let resetFieldsIdentifier = "testhost.resetFields"

@MainActor
final class TestHostWindowController: NSWindowController {
    private var access: [TestHostField: (get: () -> String, reset: () -> Void)] = [:]
    private var views: [TestHostField: NSView] = [:]
    let web = WebFieldsController()
    let secureInput = SecureInputHolder()
    /// Window > Show Search Panel (Command+K), SearchPanel.swift.
    let searchPanel = SearchPanelController()
    /// Called by the Reset fields button; the app delegate also clears the second window.
    var onReset: (() -> Void)?

    required init?(coder: NSCoder) { nil }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 760), styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "TestHost"
        window.center()
        super.init(window: window)
        let layout = TestHostLayout()
        buildNativeFields(into: layout)
        buildWebFields(into: layout)
        let panelMirror = searchPanel.mirror
        access[.panelMirror] = ({ panelMirror.stringValue }, { [searchPanel] in searchPanel.reset() })
        layout.addRow("Search panel (mirror)", panelMirror)
        layout.addRow("Secure input", secureInput.checkbox)
        layout.addRow("", resetButton())
        window.contentView = layout.contentView()
        window.initialFirstResponder = layout.firstField
        web.loadPage(named: WebFieldsController.pages[0])
        searchPanel.mirror.onFocusRequest = { @MainActor [weak self] in self?.focus(.nativeTextField) }
    }

    private func buildNativeFields(into layout: TestHostLayout) {
        let textField = NSTextField(string: "")
        textField.placeholderString = "Type here"
        describe(textField, .nativeTextField, "Native text field", "Plain NSTextField.")
        access[.nativeTextField] = ({ textField.stringValue }, { textField.stringValue = "" })
        views[.nativeTextField] = textField
        layout.addRow("Native text field", textField)

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 80))
        textView.isRichText = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        describe(textView, .nativeTextView, "Native text view", "Multi-line NSTextView.")
        access[.nativeTextView] = ({ textView.string }, { textView.string = "" })
        layout.addRow("Native text view", Self.scrolling(textView, height: 80))

        let addressBar = InlineCompletionTextView(
            identifier: TestHostField.addressBarWithCompletion.rawValue, label: "Simulated address bar",
            hint: "Completes from history inline and selects the suggested remainder.")
        access[.addressBarWithCompletion] = ({ addressBar.string }, { addressBar.replaceAll(with: "") })
        views[.addressBarWithCompletion] = addressBar
        layout.addRow("Address bar (inline completion)", Self.toolbar(addressBar.embedded()))

        let cell = SpreadsheetCellTextView(
            identifier: TestHostField.spreadsheetCell.rawValue, label: "Simulated spreadsheet cell",
            hint: "Loses keys while entering edit mode and autocompletes from its column.")
        let dropped = NSTextField(labelWithString: "Dropped keys: 0")
        dropped.setAccessibilityIdentifier("testhost.sim.sheetCell.dropped")
        cell.onDroppedKey = { dropped.stringValue = "Dropped keys: " + String($0) }
        access[.spreadsheetCell] = ({ cell.string }, { cell.replaceAll(with: "") })
        layout.addRow("Spreadsheet cell", cell.embedded())
        layout.addRow("", dropped)

        let password = ReadableSecureTextField(string: "")
        describe(password, .passwordField, "Password field", "Secure text field; text must arrive untransformed.")
        access[.passwordField] = ({ password.stringValue }, { password.stringValue = "" })
        layout.addRow("Password", password)
    }

    private func buildWebFields(into layout: TestHostLayout) {
        layout.addRow("Page", web.picker)
        web.webView.translatesAutoresizingMaskIntoConstraints = false
        web.webView.heightAnchor.constraint(equalToConstant: 220).isActive = true
        layout.addRow("Web view", web.webView)
        let labels: [TestHostField: String] = [
            .webInput: "Web input (mirror)", .webTextarea: "Web textarea (mirror)",
            .webContentEditable: "Web contenteditable (mirror)",
        ]
        for field in WebFieldsController.mirroredFields {
            guard let mirror = web.mirrors[field] else { continue }
            access[field] = ({ [web] in web.text(of: field) }, { [web] in web.reset(field) })
            layout.addRow(labels[field] ?? field.rawValue, mirror)
        }
    }

    private func describe(_ view: NSView, _ field: TestHostField, _ label: String, _ hint: String) {
        view.setAccessibilityIdentifier(field.rawValue)
        view.setAccessibilityLabel(label)
        view.setAccessibilityHelp(hint)
    }

    private func resetButton() -> NSButton {
        let button = NSButton(title: "Reset fields", target: self, action: #selector(resetFields(_:)))
        button.setAccessibilityIdentifier(resetFieldsIdentifier)
        button.setAccessibilityLabel("Reset fields")
        button.setAccessibilityHelp("Clears every field of both windows before the next scenario.")
        return button
    }

    /// Clears both windows, shows `fields.html` again and leaves no field focused, like a fresh launch: the next
    /// scenario's `focusField` is then a real focus change, which the app under test treats as a word boundary.
    /// Without it, a scenario that focused the field the previous one used continued the previous word (the
    /// cleared text is invisible to the app's tap), and its first word stayed untransformed in the VM runs.
    @objc private func resetFields(_ sender: Any?) {
        resetAll()
        web.blurPage()
        web.resetPage()
        onReset?()
        window?.makeFirstResponder(nil)
    }

    /// Clears every field of this window, native and web.
    func resetAll() {
        for field in access.values { field.reset() }
    }

    /// Brings this window forward and focuses a native field (Window menu, Command+1 and Command+3), caret at the
    /// end (`placeCaretAtEnd`).
    func focus(_ field: TestHostField) {
        guard let view = views[field] else { return }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(view)
        placeCaretAtEnd(of: view)
    }

    static func scrolling(_ textView: NSTextView, height: CGFloat) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        textView.autoresizingMask = [.width]
        return scroll
    }

    /// Wraps the address bar in an element with the toolbar role, like a browser's omnibox (rules match
    /// `ancestorRoles: ["AXToolbar"]`, 5.6).
    private static func toolbar(_ content: NSView) -> NSView {
        let container = NSView()
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.toolbar)
        container.setAccessibilityLabel("Simulated browser toolbar")
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    /// Clears a field before a scenario step.
    func reset(_ field: TestHostField) { access[field]?.reset() }

    /// Current text, as the runner would read it through AX.
    func text(of field: TestHostField) -> String { access[field]?.get() ?? "" }

    /// Opens a local page passed by the runner (`openURL` setup step with the TestHost target).
    func open(_ url: URL) { web.load(url) }
}
```
<!-- /include -->

## 15. SpikeIMK (spike S1, PLT-R398D)

Owned files: `SpikeIMK/**` (skeleton, done; Pa runs it). Question: does an InputMethodKit input method still
receive key events in iTerm2 and Terminal.app while secure keyboard entry is on (event taps do not, Apple
TN2150), and can it still commit text? The spike is an `IMKServer` with one `IMKInputController` subclass that
counts `handle(_:client:)` key-downs with and without `IsSecureEventInputEnabled()`, and, only when "Commit
test" is ticked in its input menu, replaces `;` with `✓` through the IMK client; the menu (`menu()`) shows the
counters. It stores counts only, never characters, and never creates an event tap or posts CGEvents
(PLT-R207). Pa builds it, copies `SpikeIMK.app` to `~/Library/Input Methods/`, enables it in System Settings >
Keyboard > Text Input > Input Sources, and follows `SpikeIMK/README.md`; the result is recorded as
`docs/decisions/03NN-spike-s1-result.md` with the template in that README (PLT-R398D). The bundle ID contains
`.inputmethod.`; the icon is original pixel art from `SpikeIMK/Tools/make-icon.py` (CLR-R7).

<!-- include: SpikeIMK/Sources/main.swift -->
```swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Spike S1 (PLT-R398D): does an InputMethodKit input source still receive key events in Terminal and iTerm2
// while Secure Keyboard Entry is on, and can it still commit text there? This bundle counts key-down events and
// shows the counts and the OS secure-input state in its input menu. Only when "Commit test" is ticked in that
// menu does it replace a typed ";" with "✓" through the IMK client. It never records which keys were pressed,
// never creates an event tap and never posts CGEvents (PLT-R207). Instructions for Pa: SpikeIMK/README.md.

import AppKit
import Carbon
import InputMethodKit
import RealtimeSupport

/// Counters only: no key values are stored anywhere (PLT-R901 spirit, even for a spike).
enum SpikeCounters {
    static let keyDowns = Atomic<Int>(0)
    static let keyDownsWhileSecureInput = Atomic<Int>(0)
    static let commits = Atomic<Int>(0)
    static let commitsWhileSecureInput = Atomic<Int>(0)
    static let commitTestEnabled = Atomic<Bool>(false)

    static func reset() {
        keyDowns.store(0, ordering: .relaxed)
        keyDownsWhileSecureInput.store(0, ordering: .relaxed)
        commits.store(0, ordering: .relaxed)
        commitsWhileSecureInput.store(0, ordering: .relaxed)
    }
}

/// Builds the input menu and handles its one action, on the main actor.
@MainActor
final class SpikeMenu: NSObject {
    static let shared = SpikeMenu()

    /// English only: a spike for Pa, never shipped.
    func build() -> NSMenu {
        let menu = NSMenu()
        let secure = IsSecureEventInputEnabled() ? "on" : "off"
        for title in [
            "Key-downs received: \(SpikeCounters.keyDowns.load(ordering: .relaxed))",
            "Received while secure input on: \(SpikeCounters.keyDownsWhileSecureInput.load(ordering: .relaxed))",
            "Commits (\";\" -> \"✓\"): \(SpikeCounters.commits.load(ordering: .relaxed))",
            "Commits while secure input on: \(SpikeCounters.commitsWhileSecureInput.load(ordering: .relaxed))",
            "Secure input now: \(secure)",
        ] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let commitTest = NSMenuItem(
            title: "Commit test: replace \";\" with \"✓\"", action: #selector(toggleCommitTest(_:)), keyEquivalent: "")
        commitTest.state = SpikeCounters.commitTestEnabled.load(ordering: .relaxed) ? .on : .off
        commitTest.target = self
        menu.addItem(commitTest)
        let reset = NSMenuItem(title: "Reset counters", action: #selector(resetCounters(_:)), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        return menu
    }

    @objc func resetCounters(_ sender: Any?) { SpikeCounters.reset() }

    @objc func toggleCommitTest(_ sender: Any?) {
        let enabled = SpikeCounters.commitTestEnabled.load(ordering: .relaxed)
        SpikeCounters.commitTestEnabled.store(!enabled, ordering: .relaxed)
    }
}

/// Carries a menu built on the main actor back to InputMethodKit's (main-thread) caller.
private struct MenuBox: @unchecked Sendable {
    let menu: NSMenu
}

@objc(SpikeInputController)
final class SpikeInputController: IMKInputController {
    /// Counts the event and returns false so the key reaches the app unchanged, except for the opt-in commit test.
    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        let secure = IsSecureEventInputEnabled()
        SpikeCounters.keyDowns.wrappingAdd(1, ordering: .relaxed)
        if secure { SpikeCounters.keyDownsWhileSecureInput.wrappingAdd(1, ordering: .relaxed) }
        guard SpikeCounters.commitTestEnabled.load(ordering: .relaxed), event.characters == ";",
            let client = sender as? any IMKTextInput
        else { return false }
        client.insertText("✓", replacementRange: NSRange(location: NSNotFound, length: 0))
        SpikeCounters.commits.wrappingAdd(1, ordering: .relaxed)
        if secure { SpikeCounters.commitsWhileSecureInput.wrappingAdd(1, ordering: .relaxed) }
        return true
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue)
    }

    /// InputMethodKit calls this on the main thread.
    override func menu() -> NSMenu! {
        MainActor.assumeIsolated { MenuBox(menu: SpikeMenu.shared.build()) }.menu
    }
}

let connectionName = Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String ?? ""
let server = IMKServer(name: connectionName, bundleIdentifier: Bundle.main.bundleIdentifier)
withExtendedLifetime(server) {
    NSApplication.shared.run()
}
```
<!-- /include -->

<!-- include: SpikeIMK/Info.plist -->
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>$(EXECUTABLE_NAME)</string>
	<key>CFBundleIdentifier</key>
	<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$(PRODUCT_NAME)</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$(MARKETING_VERSION)</string>
	<key>CFBundleVersion</key>
	<string>$(CURRENT_PROJECT_VERSION)</string>
	<key>LSMinimumSystemVersion</key>
	<string>$(MACOSX_DEPLOYMENT_TARGET)</string>
	<key>LSBackgroundOnly</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>CFBundleDisplayName</key>
	<string>$(PRODUCT_NAME)</string>
	<key>TISInputSourceID</key>
	<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
	<key>tsInputMethodIconFileKey</key>
	<string>SpikeIMK.tiff</string>
	<key>InputMethodConnectionName</key>
	<string>$(PRODUCT_BUNDLE_IDENTIFIER)_Connection</string>
	<key>InputMethodServerControllerClass</key>
	<string>SpikeInputController</string>
	<key>TISIntendedLanguage</key>
	<string>vi</string>
	<key>tsInputMethodCharacterRepertoireKey</key>
	<array>
		<string>Latn</string>
	</array>
</dict>
</plist>
```
<!-- /include -->

## 16. Cross-cutting gates for every workstream

- `unimplemented()` may not remain in any code path reachable from a Release build; the release scripts grep
  for it (open issue for the CI track).
- New `@unchecked Sendable` or `nonisolated(unsafe)` outside `RealtimeSupport` needs a comment explaining the
  confinement and a reviewer's sign-off.
- Hot-path code (`InputHost/Pipeline`, `InputHost/Tap`, producer side of `Injection/Queue`) may not call any
  API listed as forbidden in PLT-R305; an instrumented debug build asserts it (section 3 acceptance).
- Security-sensitive changes (event handling, diagnostics, import parsers, updater configuration) carry the
  QA-R59 checklist in their PR description.

## 17. Review findings: decisions (2026-11-13)

An independent review of this design produced 19 findings (4 high, 7 medium, 8 low). Each was checked against
the spec before acting. All are applied, three of them in a modified form; the modified parts are listed under
"Rejected review findings".

| # | Severity | Finding (short) | Decision and where |
|---|---|---|---|
| 1 | high | "In flight" ended at `CGEventPost`, letting a physical key queued at the WindowServer overtake the synthetic events | Applied: in flight until the echo or a 200 ms timeout, tap-side settlement, `InFlightPolicy.untilPosted` fallback, `SimulatedWindowServer` lagging mode in the property suite ([0311](../decisions/0311-in-flight-until-echo.md), section 9, `Injection/Queue.swift`) |
| 2 | high | Three wave-1 workstreams needed fakes owned by others | Applied and extended: the skeleton implements the shared fakes and every cross-workstream seam (tap/worker state, diagnostics sinks, `CallbackWatchdog`) ([0313](../decisions/0313-testability-seams.md), section 13, workstreams.md) |
| 3 | high | Raw `JSONValue` override in the report could carry URLs | Applied in a stricter form: typed `ReportedOverride` without summary, URL prefixes or title patterns ([0312](../decisions/0312-report-override-projection.md), section 6) |
| 4 | high | Host services pinned `MachClock`/`DispatchQueue`, so fake-clock tests could not run | Applied: `any MonotonicClock`, `TimerScheduler` with `DispatchTimerScheduler` and `ManualScheduler` (ADR 0313, sections 5 and 10) |
| 5 | medium | Fail-open modelled with a `notPermitted` post error that the OS never reports; "nothing is dropped" stated unconditionally | Applied: `PostError.notPermitted` removed, `FakeEventPoster.silentlyDropping`, conservation only while posting works, counted losses, preflight only after an echo miss ([0308](../decisions/0308-conservation-on-abandoned-edits.md) amendment, ADR 0311, ARCHITECTURE.md 4) |
| 6 | medium | Scroll in the tap mask was optional although PRD-R14 is a MUST | Applied: `TapEventMask.standard` includes scroll; scroll only feeds the recogniser; pipeline test in W1-F1 (section 10.3) |
| 7 | medium | Watchdog recovery on a stuck tap thread was undefined and could break QSBR | Applied: recovery only after the callback returned, `failOpen(callbackStuck)` otherwise, never a second tap; `TapWatchdog` reclaims all cells every 5 s ([0309](../decisions/0309-callback-watchdog-gating.md), [0303](../decisions/0303-snapshot-publication.md) amendments) |
| 8 | medium | Accessibility owned only by W2-F, which could not edit or precede the windows | Applied: PRD-R66/R67 in every UI workstream (rule 8), W2-F moved to wave 2b as an audit with label/hint-only edits (workstreams.md) |
| 9 | medium | W1-F too large | Applied: split into W1-F1 (pipeline) and W1-F2 (tap, watchdogs, `HostLifecycle`); W1-H moved to wave 2a as W2-E1 to keep eight per wave (workstreams.md) |
| 10 | medium | No verification plan for layers 5-7 before the runner exists | Applied: "Interim verification" in workstreams.md and the interim M mapping in traceability.md |
| 11 | medium | Swift 6 path of the non-Sendable pipeline into the tap thread, and of the Sparkle delegate, unspecified | Applied: `TapThread<Handler: TapEventHandler>` builds the handler on the tap thread; Sparkle delegate uses `MainActor.assumeIsolated` (ADR 0313, ARCHITECTURE.md 3) |
| 12 | low | Secure-input generation stuck across on/off/key/on inside one poll | Applied: key evidence ends the episode; the next "on" poll bumps the generation (`SecureInputMonitor` doc, W1-E acceptance) |
| 13 | low | Status line could not express the known-limitation and no-text-focus rows | Applied: `FrontmostAppStatus`, `tapRecentlyReenabled`, actions `.overrideTextFocus(bundle:)` and `.reopenApp` (section 11) |
| 14 | low | `EventTapFactory` leaked `CFMachPort` | Applied: `EventTapHandle` protocol, pure Swift fake (section 10.3) |
| 15 | low | Sparkle picks release-notes language by macOS, not by the app | Applied: one bilingual notes page per release; request to the release scripts track ([0304](../decisions/0304-sparkle-version-pin.md) amendment) |
| 16 | low | `mailto:` cannot attach the JSON report | Applied: `MailDraft` sent with `NSSharingService(.composeEmail)`, `mailto:` only as fallback (section 11, W2-C) |
| 17 | low | No source for the repository URL | Applied: `APP_REPOSITORY_URL` (and `APP_SUPPORT_EMAIL`) in `Config/Brand.xcconfig`, Info.plist and `Brand`; Pa list (traceability.md) |
| 18 | low | Artwork not in the Pa list | Applied: artwork row in "Items only Pa can verify"; placeholders with recorded source and VERIFY |
| 19 | low | Settings folder lost on rename | Applied: `APP_LEGACY_STORAGE_FOLDER_NAMES` and `LegacyStorageMigrator` ([0307](../decisions/0307-settings-file-layout.md) amendment) |

### Rejected review findings

No finding was rejected outright. These parts of the suggested fixes were not adopted:

- **Finding 3, "keep only the host of `urlPrefix` when the user ticked include page address".** Rejected: a host
  is part of a URL and PLT-R1203 forbids URLs in the report without exception. The report keeps only the field
  name in `omittedMatchFields`; the guided test's suggestion (which may carry a host-level prefix the user
  chose) stays a separate artefact the user copies or applies.
- **Finding 1, "the tap alone decrements in-flight in its callback".** Modified: jobs that post nothing (a
  `BoundaryJob`, a dropped `pairedKeyUp`) have no echo, so the worker settles them through its own counter.
  Each counter still has exactly one writer, which is what the suggestion was after.
- **Finding 9, "merge W1-H into W1-C".** Not taken: rules data and the TestHost/harness have different review
  needs and W1-C is already full. W1-H moved to wave 2a instead (W2-E1); the spike S1 part it carried is
  delivered by the skeleton, so Pa can run it now and nothing on the P0 path waits.
