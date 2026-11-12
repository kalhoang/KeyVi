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
  clock, `InlineUTF16`, threads), `AppModel` (identifiers, vocabulary, hotkey JSON, versions, `JSONValue`,
  `LocalFileSystem`) and the common fakes (`InMemoryFileSystem`, `ManualClock`, `FixedWallClock`,
  `InMemoryKeyValueStore`). Wave-1 workstreams need these at the same time, so they are not left to one of
  them.
- **Isolation legend** used in the tables: `tap` / `inject` / `ax` = confined to that dedicated thread;
  `main` = `@MainActor`; `utility` = the utility serial queue (the `SettingsStore` actor's executor);
  `any` = `Sendable`, safe from every thread; `tap-safe` = may be called inside the tap callback
  (no locks, no allocation, no syscalls that block).
- Conventions: SPDX header `LicenseRef-App-Pending` on every non-engine file; requirement IDs in comments
  where they drive non-obvious behaviour; no bundle-ID literals in code (PLT-R501; reverse-DNS constants that
  are not bundle IDs go in a file named `ReverseDNSConstants.swift`, which the lint allowlists); no string
  interpolation in log calls (PLT-R902).

## 1. Module dependencies and isolation summary

| Module | Depends on | Main isolation | Notes |
|---|---|---|---|
| AppModel | Foundation | any | Values only |
| RealtimeSupport | Synchronization, Dispatch, Foundation | any / tap-safe | The only place with `@unchecked Sendable` lock-free code |
| Diagnostics | AppModel, RealtimeSupport | any; `TapLogRing.push`, histogram `record`, `CaptureController.isRecording` are tap-safe | |
| SettingsStore | AppModel | utility (actor) | |
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
| `EventTapFactory` (InputHost) | `CGEventTapFactory`: `CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest:, callback:, userInfo:)`; `CGEvent.tapEnable(tap:enable:)`, `CGEvent.tapIsEnabled(tap:)`; run-loop source via `CFMachPortCreateRunLoopSource` | tap (create, run), any (enable) | `FakeEventTapFactory` |
| `EventPoster` (Injection) | `CGEventPoster`: `CGEventSource(stateID: .privateState)`, `localEventsSuppressionInterval = 0`, `CGEvent(keyboardEventSource:virtualKey:keyDown:)`, explicit `flags`, `keyboardSetUnicodeString` (`CGEventKeyboardSetUnicodeString`), `setIntegerValueField(.eventSourceUserData, …)` (`kCGEventSourceUserData`), `setIntegerValueField(.keyboardEventAutorepeat / .keyboardEventKeyboardType, …)`, `post(tap: .cgSessionEventTap)` | inject | `FakeEventPoster` |
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
| `WallClock` (AppModel) | `SystemWallClock` (`Date()`) | any | `FixedWallClock` |
| `FileSystem` (AppModel) | `LocalFileSystem`: FileManager + POSIX `open(O_EXCL)`, `write`, `fsync`, `rename`, `chmod`; `URLResourceValues.isExcludedFromBackup` | utility | `InMemoryFileSystem` |
| `KeyValueStore` (SettingsStore) | `UserDefaults` of the bundle ID | utility | `InMemoryKeyValueStore` |
| `LoginItemService` (ShellCore) | `SMAppServiceLoginItem`: `SMAppService.mainApp.status`, `register()`, `unregister()`, `SMAppService.openSystemSettingsLoginItems()` | main | test double |
| `UpdaterControlling` (ShellCore) | `UpdaterController` (App) over `SPUStandardUpdaterController` | main | test double |
| `KeyboardDriver`, `ScenarioReadback` (TestSupport) | `compat-harness`: its own `CGEventSource` posting physical-like events with timing profiles; readback through AX, `safaridriver`/`chromedriver`, terminal capture or a human prompt | self-hosted runner | n/a |

## 4. AppModel: shared vocabulary

Owned files: `Packages/AppCore/Sources/AppModel/**` (frozen in wave 1; changes through the integrator).
Isolation: any. Raw values of the enums are JSON spellings in settings and rules files, so renaming one needs a
migration.

<!-- include: Packages/AppCore/Sources/AppModel/Identifiers.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
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
// SPDX-License-Identifier: LicenseRef-App-Pending
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
// SPDX-License-Identifier: LicenseRef-App-Pending
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
// SPDX-License-Identifier: LicenseRef-App-Pending
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
        }
    }
}

public enum FailOpenReason: String, Sendable, Hashable, Codable {
    case permissionRevoked, postingBroken, tapUnavailable, watchdog
}

public enum PauseCode: String, Sendable, Hashable, Codable {
    case secureInput, nonLatinInputSource, builtInVietnameseSource, passThroughRule, secureField,
        sessionInactive, userDisabled, noTextFocus
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
// SPDX-License-Identifier: LicenseRef-App-Pending

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
// SPDX-License-Identifier: LicenseRef-App-Pending

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
// SPDX-License-Identifier: LicenseRef-App-Pending

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

Owned files: `Packages/AppCore/Sources/RealtimeSupport/**` (workstream W1-A hardens and benchmarks; the
skeleton implementation is complete and passes Thread Sanitizer). Why the snapshot cell is shaped this way:
[0303](../decisions/0303-snapshot-publication.md).

<!-- include: Packages/AppCore/Sources/RealtimeSupport/SnapshotCell.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
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

internal import Synchronization

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
// SPDX-License-Identifier: LicenseRef-App-Pending

internal import Synchronization

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
// SPDX-License-Identifier: LicenseRef-App-Pending

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
// SPDX-License-Identifier: LicenseRef-App-Pending

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
        // Absolute deadline in mach ticks (PLT-R409).
        let ticks = deadline.nanoseconds.multipliedFullWidth(by: denominator)
        let (quotient, _) = numerator.dividingFullWidth(ticks)
        mach_wait_until(quotient)
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/RealtimeSupport/InlineUTF16.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending

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
            for index in 0..<buffer.count { target[index] = buffer[index] }
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
// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Dedicated threads (PLT-R203). Swift concurrency cannot express "this state belongs to the ax run-loop
// thread", so confinement is enforced by construction plus debug assertions, in exactly two audited types.

public import Foundation
internal import Synchronization

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

    /// Starts the thread and returns once its run loop is ready.
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
        }
        thread.name = name
        thread.qualityOfService = qualityOfService
        state.withLock { $0.thread = thread }
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

## 6. Diagnostics

Owned files: `Packages/AppCore/Sources/Diagnostics/**`, `Tests/DiagnosticsTests/**`,
`Sources/TestSupport/Fakes/Diagnostics/**` (workstream W1-A). Isolation: any; the tap uses only
`TapLogRing.push`, `Log2Histogram.record`, `AtomicCounter.increment` and `CaptureController.isRecording`.

Rules: the logger accepts only `LogEvent` values (typed metadata, `StaticString`, `Redacted`); the tap never
logs, it writes `TapLogRecord`s; the report type has no field that can hold content; the typing trace is the
only artefact with characters.

### 6.1 The issue block (QA-R44)

`DiagnosticsRenderer.issueBlock` produces exactly this shape. The fence info string is `diagnostics`; the first
line inside is the format header; then one `key: value` per line, ASCII keys, values without newlines, lists
comma-separated. The labeller (CI track) reads `focus.bundle` -> `app:<bundle>`, the major of `macos.version`
-> `macos:<major>`, `arch` -> `arch:arm64|x86_64`, `method` -> `method:telex|vni`. Keys in
`DiagnosticsBlockKey` never change within a format version; new keys may be added; a breaking change bumps the
version.

````text
```diagnostics
diagnostics-format: 1
app.version: 0.1.0
app.build: 12
app.channel: beta
macos.version: 27.1
macos.build: 26B123
arch: arm64
model: Mac15,6
ui.language: vi
method: telex
tone: traditional
englishRestore: true
host.state: readyVietnamese
permissions.accessibility: granted
permissions.postEvent: granted
permissions.listenEvent: granted
tap.enabled: true
tap.timeouts24h: 0
secureInput.enabled: false
secureInput.holder: none
keyboard.layout: com.apple.keylayout.ABC
keyboard.sourceKind: asciiLayout
focus.bundle: com.example.Editor
focus.appVersion: 3.2.1
focus.engine: electron
focus.role: AXTextArea
focus.subrole: none
rule.id: none
rule.source: default
rule.strategy: backspaceReplace
latency.t1.p99Microseconds: 41
latency.t2.p99Microseconds: 1350
health.last24h: flush=1,tapTimeout=0,echoLoss=0
conflicts: none
macros.count: 12
```
````

<!-- include: Packages/AppCore/Sources/Diagnostics/Identity.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending

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
// SPDX-License-Identifier: LicenseRef-App-Pending

internal import AppModel

/// Per-install random salt (32 bytes) for hashed redaction (PLT-R902). Stored in the app's user defaults
/// domain (not in the settings folder) so exports never carry it.
public struct RedactionSalt: Sendable, Hashable {
    public let bytes: [UInt8]
    public init(bytes: [UInt8]) {
        precondition(bytes.count == 32, "salt must be 32 bytes")
        self.bytes = bytes
    }

    /// CSPRNG (`SecRandomCopyBytes`).
    public static func random() -> RedactionSalt { unimplemented() }
}

/// The only way a dynamic string enters a log record (PLT-R902). Either a salted, truncated SHA-256
/// (`h:3fa9c1d2e4b5a697`) or a fixed marker. There is no initializer that keeps the original text.
public struct Redacted: Sendable, Hashable, Codable, CustomStringConvertible {
    public let description: String
    private init(description: String) { self.description = description }

    public static func hashed(_ value: some StringProtocol, salt: RedactionSalt) -> Redacted { unimplemented() }
    public static let dropped = Redacted(description: "<dropped>")
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/Diagnostics/LogEvent.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
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
// SPDX-License-Identifier: LicenseRef-App-Pending

public import AppModel
public import Foundation

/// Metadata-only health event (PLT-R1206).
public struct HealthEvent: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        case tapTimeout, tapDisabledByUserInput, tapReenabled, watchdogTrip, flush, fallbackActivated,
            axCircuitBreakerTrip, echoLoss, postingBroken, permissionTransition, secureInputEpisode,
            ruleLoadError, ruleTie, placeholderResidue, pasteRestoreSkipped, generationDiscard,
            settingsRecovered, settingsNewerSchema, safeModeEntered
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

/// In-memory ring of recent health events (the report shows the last 50, PLT-R1202), mirrored to the log
/// file so events from before a crash remain explainable (PRD-R46). Not used on the tap thread.
public final class HealthEventLog: Sendable {
    public init(capacity: Int = 256) { unimplemented() }
    public func record(_ event: HealthEvent) { unimplemented() }
    public func recent(limit: Int) -> [HealthEvent] { unimplemented() }
    /// Count of events of `kind` within `window` before `now` (PLT-R330 "more than 3 within 10 minutes").
    public func count(of kind: HealthEvent.Kind, within window: TimeInterval, now: Date) -> Int { unimplemented() }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/Diagnostics/Metrics.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Always-on, content-free, lock-free histograms (PLT-R801): fixed memory, log2 buckets, safe on the tap.

public import AppModel

/// 64 log2 buckets of nanoseconds (bucket i counts values in [2^i, 2^(i+1))), one `Atomic<UInt64>` each.
public final class Log2Histogram: Sendable {
    public init() { unimplemented() }
    /// Lock-free, allocation-free; allowed on the tap thread (PLT-R304).
    public func record(nanoseconds: UInt64) { unimplemented() }
    public func snapshot() -> HistogramSnapshot { unimplemented() }
}

public struct HistogramSnapshot: Sendable, Hashable, Codable {
    public var buckets: [UInt64]
    public init(buckets: [UInt64]) { self.buckets = buckets }
    public var count: UInt64 { buckets.reduce(0, +) }
    /// Upper bound (ns) of the bucket containing the given fraction (0.5 = p50, 0.99 = p99).
    public func percentile(_ fraction: Double) -> UInt64? { unimplemented() }
}

/// Monotonic counter safe on every thread.
public final class AtomicCounter: Sendable {
    public init() { unimplemented() }
    public func increment(by amount: UInt64 = 1) { unimplemented() }
    public var value: UInt64 { unimplemented() }
}

/// Platform budget metrics of 02-platform.md 8.1. Probe-tagged events (PLT-R810) go to `probe*` only, so user
/// metrics exclude them.
public final class PlatformMetrics: Sendable {
    public let callbackDuration: Log2Histogram  // T1
    public let decideToPosted: Log2Histogram  // T2
    public let decideToPostedWithAX: Log2Histogram  // T3
    public let echoRoundTrip: Log2Histogram
    public let heldWait: Log2Histogram  // T5
    public let focusRefresh: Log2Histogram  // T6
    public let probeDecideToPosted: Log2Histogram  // T2 for latency-probe events only
    public let flushes: AtomicCounter
    public let tapTimeouts: AtomicCounter
    public let fallbackActivations: AtomicCounter
    public let echoLosses: AtomicCounter
    public let watchdogTrips: AtomicCounter
    /// AX call durations aggregated per bundle (PLT-R801); recorded on the ax and inject threads.
    public let axCallDurations: PerBundleHistograms

    public init() { unimplemented() }
    public func snapshot() -> MetricsSnapshot { unimplemented() }
}

/// Bounded map of bundle -> histogram (at most 64 bundles, least recently used evicted). Uses a lock;
/// never touched by the tap thread.
public final class PerBundleHistograms: Sendable {
    public init(capacity: Int = 64) { unimplemented() }
    public func record(_ bundle: BundleKey, nanoseconds: UInt64) { unimplemented() }
    public func snapshot() -> [BundleKey: HistogramSnapshot] { unimplemented() }
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
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/Diagnostics/TapLog.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
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

/// Single producer (tap), single consumer (utility drain).
public final class TapLogRing: Sendable {
    public init(capacity: Int = 1024) { unimplemented() }
    /// Tap thread. Drops the record (and counts the drop) when full.
    public func push(_ record: TapLogRecord) { unimplemented() }
    /// Utility queue.
    public func drain(_ body: (TapLogRecord) -> Void) { unimplemented() }
    public var droppedCount: UInt64 { unimplemented() }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/Diagnostics/LogStore.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending

public import AppModel
public import Foundation

/// PLT-R903: `~/Library/Logs/<folder>/`, dir 0700, files 0600, JSON lines, 5 files of 1 MB, 14 days.
public struct LogStorePolicy: Sendable, Hashable {
    public var directory: URL
    public var maxFileBytes: Int
    public var maxFiles: Int
    public var retention: TimeInterval

    public init(directory: URL, maxFileBytes: Int = 1_000_000, maxFiles: Int = 5, retention: TimeInterval = 14 * 86_400) {
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
}

/// Production logger: renders `LogEvent` to `LogRecord`, writes JSON lines on the utility queue, mirrors to
/// the unified log through `os.Logger` with default private redaction for dynamic values (PLT-R902).
public final class DiagnosticsLogger: DiagnosticsLogging {
    public init(policy: LogStorePolicy, fileSystem: any FileSystem, clock: any WallClock, subsystem: String) {
        unimplemented()
    }

    public func log(_ event: LogEvent, level: LogLevel) { unimplemented() }
    /// Rotation and 14-day retention; scheduled by the utility queue at launch and every 6 hours.
    public func maintain() { unimplemented() }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/Diagnostics/Report.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
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

    public struct KeyboardSection: Sendable, Hashable, Codable {
        public var layout: InputSourceID?
        public var sourceKind: InputSourceKindCode
        public var enabledSources: [InputSourceID]
    }

    public enum InputSourceKindCode: String, Sendable, Hashable, Codable {
        case asciiLayout, nonLatinLayout, inputMethod, builtInVietnamese, unknown
    }

    public struct PermissionsSection: Sendable, Hashable, Codable {
        public var accessibility: PermissionState
        public var postEvent: PermissionState
        public var listenEvent: PermissionState
        public var health: PermissionHealthCode
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
    }

    public struct SecureInputSection: Sendable, Hashable, Codable {
        public var enabled: Bool
        public var likelyHolder: BundleKey?
        public var holderKind: SecureInputHolder.Kind?
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
    }

    public struct RuleSection: Sendable, Hashable, Codable {
        public var rule: RuleID?
        public var source: DecisionSource
        public var specificity: Int
        public var strategy: InjectionStrategy
        public var parameters: JSONValue
        /// The user override for the reported app as rule JSON, so maintainers can promote it (PLT-R541).
        public var userOverride: JSONValue?
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
    }

    public struct AppModeSection: Sendable, Hashable, Codable {
        public var bundle: BundleKey
        public var rule: PerAppRule?
        public var rememberedMode: TypingMode?
    }

    public struct LatencySection: Sendable, Hashable, Codable {
        public var metrics: MetricsSnapshot
        public var probe: LatencyProbeResult?
    }

    public struct UserReportSection: Sendable, Hashable, Codable {
        public var symptom: Symptom
        public var reportedApp: BundleKey?
        public var reproducesInPracticeField: Bool?
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
    }

    public var ranAt: Date
    public var results: [ProfileResult]
}

/// Renders a report for the three outputs of PLT-R1204/PRD-R47.
public enum DiagnosticsRenderer {
    /// Human-readable text in the interface language, shown verbatim before copying (PLT-R1204).
    public static func plainText(_ report: DiagnosticsReport, language: InterfaceLanguage) -> String {
        unimplemented()
    }

    /// QA-R44 block, parsed by the issue labeller (CI track). Exact shape:
    ///
    ///     ```diagnostics
    ///     diagnostics-format: 1
    ///     app.version: 0.1.0
    ///     app.build: 12
    ///     app.channel: beta
    ///     macos.version: 27.1
    ///     macos.build: 26B123
    ///     arch: arm64
    ///     method: telex
    ///     focus.bundle: com.example.App
    ///     ...one `key: value` per line, keys from `DiagnosticsBlockKey`...
    ///     ```
    ///
    /// Values never contain newlines; lists are comma-separated. Keys are ASCII, lower camel case, dotted.
    public static func issueBlock(_ report: DiagnosticsReport) -> String { unimplemented() }

    /// Inverse of `issueBlock` for tests and for the labeller contract: `nil` when no block or an unknown
    /// format version is found.
    public static func parseIssueBlock(_ text: String) -> [String: String]? { unimplemented() }

    /// JSON file attached by "Gửi qua email" / "Lưu tệp..." (PRD-R47).
    public static func json(_ report: DiagnosticsReport) throws -> Data { unimplemented() }
}

/// Keys of the issue block that the labeller relies on (QA-R44 labels `app:<bundle>`, `macos:<major>`,
/// `arch:...`, `method:...`). Other keys may be added within a format version; these may not change.
public enum DiagnosticsBlockKey: String, Sendable, CaseIterable {
    case formatVersion = "diagnostics-format"
    case appVersion = "app.version"
    case appBuild = "app.build"
    case appChannel = "app.channel"
    case macOSVersion = "macos.version"
    case macOSBuild = "macos.build"
    case architecture = "arch"
    case method = "method"
    case focusBundle = "focus.bundle"
    case focusAppVersion = "focus.appVersion"
    case focusEngine = "focus.engine"
    case rule = "rule.id"
    case strategy = "rule.strategy"
    case hostState = "host.state"
    case secureInput = "secureInput.enabled"
    case layout = "keyboard.layout"
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/Diagnostics/Capture.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Time-boxed typing trace (PLT-R905, PRD-R46, D26): the only artefact that ever contains typed characters.

public import AppModel
public import Foundation
public import RealtimeSupport

public enum CaptureLimits {
    public static let defaultDuration: Duration = .seconds(60)
    public static let maximumDuration: Duration = .seconds(180)
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
    public enum Outcome: UInt8, Sendable, BitwiseCopyable { case passed, held, consumedForEdit, consumedAsHotkey, consumedPairedKeyUp }
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

/// Owns capture state. `isRecording` is an atomic flag the tap reads once per callback; records flow through
/// SPSC rings (tap, inject, ax producers) drained by the utility queue into
/// `~/Library/Logs/<folder>/captures/<id>.jsonl` (0600, excluded from backup).
public final class CaptureController: Sendable {
    public init(directory: URL, fileSystem: any FileSystem, wallClock: any WallClock, clock: any MonotonicClock) {
        unimplemented()
    }

    /// Tap-safe (one atomic load).
    public var isRecording: Bool { unimplemented() }
    public var tapRecords: SPSCRing<CaptureRecord> { unimplemented() }
    public var injectRecords: SPSCRing<CaptureRecord> { unimplemented() }
    public var focusRecords: SPSCRing<CaptureRecord> { unimplemented() }

    /// Explicit user action only, after a confirmation that explains what is recorded (PLT-R905).
    public func start(duration: Duration) throws -> CaptureSessionInfo { unimplemented() }
    public func stop() -> CaptureSessionInfo? { unimplemented() }
    public func remaining(now: Date) -> Duration? { unimplemented() }
    /// Readable rendering the user reviews before export (PLT-R905).
    public func render(_ id: CaptureSessionID, language: InterfaceLanguage) throws -> String { unimplemented() }
    /// Writes the export and deletes the capture immediately afterwards.
    public func export(_ id: CaptureSessionID, to destination: URL) throws { unimplemented() }
    public func discard(_ id: CaptureSessionID) { unimplemented() }
    /// Deletes captures older than 24 hours; run at launch and hourly on the utility queue.
    public func purgeExpired(now: Date) { unimplemented() }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/Diagnostics/Signposts.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending

internal import AppModel

/// `os_signpost` intervals around the callback, job execution and AX calls in all builds (PLT-R802); zero cost
/// when not recording. Interval names are static strings.
public struct PlatformSignposts: Sendable {
    public enum Interval: Sendable { case tapCallback, injectionJob, axCall }
    public struct Token: Sendable { let raw: UInt64 }

    public init(subsystem: String) { unimplemented() }
    public func begin(_ interval: Interval) -> Token { unimplemented() }
    public func end(_ interval: Interval, _ token: Token) { unimplemented() }
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
  "englishRestoreLists": { "keepAsTyped": ["tex"], "keepVietnamese": [] },
  "optedInRules": [],
  "onboarding": { "completedVersion": "0.1.0" },
  "futureKeyFromNewerBuild": { "kept": true }
}
```

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
up to 4,000 characters, no shortcut equal to another plus trailing punctuation). The preview counts new,
duplicate and invalid rows; duplicates resolve with "keep mine" or "use imported" (PRD-R70). Importers for
competitor export files (XKey, OpenKey, EVKey, Gõ Nhanh, PHTV, PRD-R69) are added only after their formats are
observed from real exports, never from their source code (CLR-R1, CLR-R5); until then those users use the TSV
or CSV path.

<!-- include: Packages/AppCore/Sources/SettingsStore/Setting.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending

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
// SPDX-License-Identifier: LicenseRef-App-Pending
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
    /// Shipped rules with `requiresUserOptIn: true` that the user enabled (PLT-R460) ("optedInRules").
    public var optedInRules: Set<RuleID> = []
    /// "onboarding" object (PRD-R42).
    public var onboarding = OnboardingState()

    public init() {}

    /// Names of keys that are explicitly set, for the content-free diagnostics report.
    public var explicitlySetKeys: [String] { unimplemented() }
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
        restoreHotkey: nil,  // D8 unset
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
// SPDX-License-Identifier: LicenseRef-App-Pending
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
// SPDX-License-Identifier: LicenseRef-App-Pending

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
    public init(_ migrations: [any DocumentMigration]) { unimplemented() }
    public func migrate(_ object: [String: JSONValue], file: SettingsFile, from: Int, to: Int) throws
        -> [String: JSONValue]
    { unimplemented() }

    /// All migrations shipped by this build (empty while every file is at version 1).
    public static let shipped = MigrationChain([])
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/SettingsStore/SettingsStore.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Settings persistence (PLT-R10xx). An actor whose executor is the utility serial queue, so all reads,
// migrations and debounced atomic writes are serialized there (PLT-R1003, PLT-R203 "utility queue").

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
}

/// User-visible notices (PLT-R1006, PLT-R1007, PLT-R1009), rendered by ShellCore.
public enum StoreNotice: Sendable, Hashable {
    case recoveredFromBackup(SettingsFile, backupDate: Date)
    case corruptFileUsingDefaults(SettingsFile)  // nothing overwritten until the user confirms
    case newerSchemaReadOnly(SettingsFile, schemaVersion: Int)
    case safeMode(recentCrashes: Int)
    case writeFailed(SettingsFile)
}

public enum ResetScope: Sendable, Hashable {
    case all(includeMacros: Bool)  // PRD-R26: macros only with the separate checkbox
    case general, typing, apps  // per pane
}

public actor SettingsStore {
    private let queue: DispatchSerialQueue

    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// - Parameters:
    ///   - queue: the utility serial queue (QoS utility).
    ///   - writtenBy: app version recorded in every file (PLT-R1002).
    ///   - onChange: called on `queue` after each change; InputHost publishes snapshots from it, ShellCore
    ///     hops to the main actor.
    public init(
        location: StorageLocation,
        fileSystem: any FileSystem,
        wallClock: any WallClock,
        writtenBy: String,
        queue: DispatchSerialQueue,
        migrations: MigrationChain = .shipped,
        launchGuard: LaunchGuard,
        onChange: @escaping @Sendable (SettingsState) -> Void
    ) {
        self.queue = queue
        unimplemented()
    }

    /// Loads all four files: migrate (with backups), recover from corruption (PLT-R1006), detect newer
    /// schema (PLT-R1007), honour safe mode (PLT-R1009).
    public func load() -> SettingsState { unimplemented() }

    public var state: SettingsState { unimplemented() }

    /// Applies an explicit change (debounced write, 1 s).
    public func updateSettings(_ change: @Sendable (inout UserSettings) -> Void) { unimplemented() }

    /// Per-app explicit rule from the menu or the Apps pane (PRD-R21). `nil` clears it.
    public func setAppRule(_ rule: PerAppRule?, for bundle: BundleKey) { unimplemented() }

    /// Remembered modes and global mode from InputHost's memory; written with a 5 s debounce (PLT-R392).
    public func recordAppModes(_ document: AppModesDocument) { unimplemented() }

    public func addRuleOverride(_ override: StoredRuleOverride) { unimplemented() }
    public func removeRuleOverride(id: RuleID) { unimplemented() }
    public func replaceMacros(_ macros: [StoredMacro]) { unimplemented() }

    /// PRD-R26. The caller offers an export first.
    public func reset(_ scope: ResetScope) { unimplemented() }

    /// User confirmed using defaults after a corrupt file without backup (PLT-R1006).
    public func confirmDefaults(for file: SettingsFile) { unimplemented() }

    /// Leaves safe mode and resets the launch guard.
    public func exitSafeMode() { unimplemented() }

    /// Writes pending changes immediately (quit, update install).
    public func flush() { unimplemented() }

    // MARK: Export and import (PLT-R1010, PRD-R72)

    public func export(_ options: ExportOptions, now: Date) throws -> Data { unimplemented() }
    /// Validates untrusted data (5 MB cap, schema, no evaluation, PLT-R912) and builds a preview.
    public func previewImport(_ data: Data) throws -> ImportPreview { unimplemented() }
    /// Backs up current files, applies, migrates older schemas, lists skipped fields of newer schemas.
    public func applyImport(_ preview: ImportPreview, choices: ImportChoices) throws { unimplemented() }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/SettingsStore/ExportImport.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
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

    public static func fileName(slug: String, date: Date) -> String { unimplemented() }
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
    public var macroDuplicates: MacroDuplicateResolution
    public init(
        applySettings: Bool = true, applyAppModes: Bool = true, applyRuleOverrides: Bool = true,
        macroDuplicates: MacroDuplicateResolution = .keepMine
    ) {
        self.applySettings = applySettings
        self.applyAppModes = applyAppModes
        self.applyRuleOverrides = applyRuleOverrides
        self.macroDuplicates = macroDuplicates
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/SettingsStore/MacroImport.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
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
    case malformedLine
}

public struct MacroImportRow: Sendable, Hashable {
    public var line: Int
    public var shortcut: String
    public var expansion: String
    public var issue: MacroRowIssue?
}

public enum MacroDuplicateResolution: String, Sendable, Hashable { case keepMine, useImported }

public struct MacroImportPreview: Sendable, Hashable {
    public var new: [StoredMacro]
    public var duplicates: [(existing: StoredMacro, imported: StoredMacro)]
    public var invalid: [MacroImportRow]

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
    /// Sniffs content first (plist header, JSON object, tabs vs commas), then the extension.
    public static func detectFormat(_ data: Data, fileExtension: String?) -> MacroImportFormat? { unimplemented() }
    public static func parse(_ data: Data, format: MacroImportFormat) -> [MacroImportRow] { unimplemented() }
    /// Duplicates are by case-insensitive shortcut (matching is case-insensitive, ENG-R1101).
    public static func preview(_ rows: [MacroImportRow], existing: [StoredMacro]) -> MacroImportPreview {
        unimplemented()
    }

    public static func merge(_ preview: MacroImportPreview, into existing: [StoredMacro],
                             resolution: MacroDuplicateResolution) -> [StoredMacro] { unimplemented() }
}

/// Editor-side validation (PRD-R29). The engine's `MacroTable.init` stays authoritative when the table is
/// built; a test asserts both agree on every fixture.
public enum MacroValidator {
    public static let maxShortcutLength = 32
    public static let maxExpansionLength = 4_000
    public static func issue(shortcut: String, expansion: String, others: [StoredMacro]) -> MacroRowIssue? {
        unimplemented()
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/SettingsStore/LaunchGuard.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending

internal import AppModel
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

    public init(store: any KeyValueStore) { unimplemented() }
    /// Called first thing at launch; returns true when safe mode must be entered.
    public func beginLaunch(now: Double) -> Bool { unimplemented() }
    /// Called 60 s after launch and on clean quit.
    public func markSurvived() { unimplemented() }
    public var recentCrashes: Int { unimplemented() }
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

<!-- include: Packages/AppCore/Sources/CompatRules/Schema.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
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
}

public struct SecureInputHint: Sendable, Hashable, Codable {
    public var bundleId: BundleKey
    /// String Catalog key suffix, for example `terminal.secureKeyboardEntry` (PLT-R397, PLT-R398C).
    public var hintKey: String
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
}

/// Any-of within a field, all-of across fields.
public struct AXMatch: Sendable, Hashable, Codable {
    public var roles: [String]?
    public var subroles: [String]?
    public var identifiers: [String]?
    public var domClasses: [String]?
    public var ancestorRoles: [String]?
    public var editable: Bool?
}

public struct WebMatch: Sendable, Hashable, Codable {
    /// Requires the AX document URL; evaluated in memory, never logged.
    public var urlPrefixes: [String]?
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
}

/// Shipped rules use the 5.4 provenance; user overrides use the PLT-R1205 suggestion shape. Decoded by the
/// presence of `source`.
public enum RuleProvenance: Sendable, Hashable, Codable {
    case shipped(Provenance)
    case userSuggestion(UserProvenance)

    public init(from decoder: any Decoder) throws { unimplemented() }
    public func encode(to encoder: any Encoder) throws { unimplemented() }
}

public struct Provenance: Sendable, Hashable, Codable {
    public var reason: String
    public var evidence: [Evidence]
    public var tested: [TestedEntry]
    public var notes: String?
    public var addedIn: String
    public var reviewBy: String  // ISO date "YYYY-MM-DD"
}

public struct UserProvenance: Sendable, Hashable, Codable {
    public var source: String  // "user-suggestion"
    public var appVersion: String?
    public var macOS: String?
    public var date: String
}

public struct Evidence: Sendable, Hashable, Codable {
    public var type: String  // "scenario", "issue", "report"
    public var ref: String
}

public struct TestedEntry: Sendable, Hashable, Codable {
    public enum Result: String, Sendable, Hashable, Codable { case pass, fail }
    public var app: String
    public var appVersion: String
    public var macOS: String
    public var date: String
    public var result: Result
}

public struct RuleTest: Sendable, Hashable, Codable {
    public enum Automation: String, Sendable, Hashable, Codable { case automated, manual }
    /// Scenario ID (PLT-R530): `compat/scenarios/<scenario>.json` must exist.
    public var scenario: String
    public var automation: Automation
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/CompatRules/Resolution.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
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
}

public struct ResolvedFeatures: Sendable, Hashable, Codable {
    public var autoCapitalize: Bool
    public var macros: Bool
    public var englishRestore: Bool
    public var restoreHotkey: Bool
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
    /// The winning rule as raw JSON, for the diagnostics report of the reported app (PLT-R541).
    public var ruleJSON: JSONValue?
}

/// Compiled, immutable rule set: shipped document plus user overrides plus opted-in IDs.
public struct RuleSet: Sendable {
    public init(document: RulesDocument, overrides: [Rule], optedIn: Set<RuleID>) throws(RulesValidationError) {
        unimplemented()
    }

    public let document: RulesDocument

    /// Specificity per PLT-R520; user overrides outrank shipped rules (PLT-R522); ties resolve to the
    /// lexicographically smaller id (PLT-R521).
    public func resolve(_ context: MatchContext) -> ResolvedDecision { unimplemented() }

    /// Bundles whose AX focus is observed even when not frontmost (`overlay: true`, PLT-R380).
    public var overlayBundles: Set<BundleKey> { unimplemented() }
    /// Bundles with a `titlePattern` rule: only these get title-change observers (PLT-R380).
    public var titlePatternBundles: Set<BundleKey> { unimplemented() }
    public var conflictingInputApps: Set<BundleKey> { unimplemented() }
    public func secureInputHintKey(for bundle: BundleKey) -> String? { unimplemented() }
    /// `bundleGroups["webkitBrowsers"]`, consumed by the fingerprinter (PLT-R510).
    public var webkitBrowsers: Set<BundleKey> { unimplemented() }
    /// Match signature used for duplicate detection (PLT-R521).
    public static func signature(of match: RuleMatch) -> String { unimplemented() }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/CompatRules/Loading.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending

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
    public static func load(contentsOf url: URL) -> RulesLoadResult { unimplemented() }
    public static func decode(_ data: Data) throws(RulesValidationError) -> RulesDocument { unimplemented() }
    /// Decodes rule-overrides.json entries; invalid entries are rejected individually.
    public static func decodeOverrides(_ raw: [JSONValue]) -> (rules: [Rule], rejected: [RejectedOverride]) {
        unimplemented()
    }
}

/// Compiled-in known-good ruleset (PLT-R503): the `defaults` block and engine-only rules. It contains no
/// bundle identifiers, so the bundle-ID literal lint (PLT-R501) stays clean.
public enum EmbeddedRules {
    public static var minimal: RulesDocument { unimplemented() }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/CompatRules/Fingerprint.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
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
    /// True if a file with this name exists anywhere under `Contents` (bounded depth, for example
    /// `libxul.dylib`, `libjvm.dylib`).
    func containsFile(named name: String, in bundle: URL, maxDepth: Int) -> Bool
    func infoDictionary(of bundle: URL) -> [String: JSONValue]?
}

public struct EngineFingerprinter: Sendable {
    public init(inspector: any BundleInspector, webkitBrowsers: Set<BundleKey>) { unimplemented() }

    /// Order: webkitBrowser (rules group) > electron > cef > chromium > gecko > jvm > qt > ios > catalyst >
    /// native.
    public func fingerprint(bundleURL: URL, bundle: BundleKey?) -> EngineFingerprint { unimplemented() }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/CompatRules/Matrix.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
//
// compat/matrix.json: verification status (02-platform.md 13.3, QA-R17), a separate file and schema from the
// behaviour rules. Single source for the Apps pane and the website matrix (PRD-R35, PRD-R38).

public import AppModel
public import Foundation

public struct MatrixDocument: Sendable, Hashable, Codable {
    public var schemaVersion: Int
    public var entries: [MatrixEntry]
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
}

/// User-facing values (PRD-R35).
public enum MatrixStatus: String, Sendable, Hashable, Codable, CaseIterable {
    case works, worksWithNotes, notVerified, knownLimitation
}

public struct LocalizedNote: Sendable, Hashable, Codable {
    public var vi: String
    public var en: String
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
}

public struct MatrixCell: Sendable, Hashable, Codable {
    public enum Result: String, Sendable, Hashable, Codable {
        case pass, fail
        case notApplicable = "n/a"
    }

    public var result: Result
    public var date: String
    public var tester: String
}

public enum MatrixStatusResolver {
    /// Entries not verified for 120 days display as `notVerified` (QA-R19).
    public static func displayStatus(_ entry: MatrixEntry, today: Date) -> MatrixStatus { unimplemented() }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/CompatRules/Lint.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
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
}

public enum LintCode: String, Sendable, Hashable, CaseIterable {
    case schemaInvalid
    case missingProvenance  // PLT-R505
    case missingTest  // PLT-R505
    case noPassingTestedEntry  // 5.4 `tested`: at least one passing entry
    case unknownScenario  // test.scenario has no compat/scenarios file
    case reviewByPassed  // PLT-R506 warning
    case reviewByPassedOver30Days  // PLT-R506 release blocker
    case reviewByMoreThan12Months  // PLT-R506
    case identicalMatchSignature  // PLT-R521
    case placeholderWithoutGateTest  // PLT-R422
    case manualTestWithoutMatrixRow  // PLT-R531
    case tier1MatrixRowOlderThan90Days  // PLT-R531, 13.3 (release mode)
    case matrixRuleUnknown
}

public struct RulesLinter: Sendable {
    public init(
        rules: RulesDocument, matrix: MatrixDocument?, scenarioIDs: Set<String>, today: Date, releaseMode: Bool
    ) { unimplemented() }

    public func run() -> [LintFinding] { unimplemented() }
}
```
<!-- /include -->

## 9. Injection

Owned files: `Packages/AppCore/Sources/Injection/**`, `Tests/InjectionTests/**`,
`Sources/TestSupport/Fakes/Injection/**` (workstream W1-D). Isolation: the worker runs on the dedicated
`inject` thread; `JobQueue.push`, `inFlight`, `nextSequence`, `WorkerFeedback` reads, `EchoTracker.observed`
and `EventMarker.classify` are tap-safe; everything else is worker-only.

Job lifecycle: the tap builds a job (sequence, focus generation, `InjectionPlan` from the focus snapshot,
field handle, counts, insertion, keycodes, trigger copy) and pushes it; the worker pops in FIFO order, discards
stale generations (replaying triggers), checks liveness, minimises the edit, runs the strategy executor in an
`InjectionEnvironment`, posts events with fresh marker sequences, records the last sequence for the echo check,
records the outcome on the 64-entry board and calls `finished`. Strategy fallbacks apply only to detectable
failures (PLT-R410, 4.5).

<!-- include: Packages/AppCore/Sources/Injection/Jobs.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
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
    /// Latency-probe event (PLT-R810): replayed with the probe marker so metrics stay separated.
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
    /// For restores and macros: keycode producing the first inserted character in the current layout, if any.
    public var firstCharacter: KeyCode?
    /// Keycode producing "v" in the current layout (Command+V for `paste`).
    public var paste: KeyCode?

    public init(trigger: KeyCode, firstCharacter: KeyCode? = nil, paste: KeyCode? = nil) {
        self.trigger = trigger
        self.firstCharacter = firstCharacter
        self.paste = paste
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
    /// Re-entry into a committed word: verify before applying when the rule allows (PLT-R342).
    public var verifyBeforeApply: Bool
    /// The word began within 300 ms of a focus change or click (`firstEditDelayUs`, PLT-R408).
    public var wordStartedNearFocusChange: Bool
    public var createdAt: MonotonicInstant
    public var isProbe: Bool

    public init(
        sequence: JobSequence, generation: FocusGeneration, plan: InjectionPlan, field: FieldHandle?,
        kind: EditKind, deleteCount: Int, deleteUTF16Count: Int, replacedText: String?, insertion: String,
        keyCodes: JobKeyCodes, trigger: KeyEventRecord?, verifyBeforeApply: Bool,
        wordStartedNearFocusChange: Bool, createdAt: MonotonicInstant, isProbe: Bool
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
    }
}

public enum BoundaryReason: UInt8, Sendable, Hashable {
    case mouseDown, focusChanged, navigation, commandChord, returnOrTab, escape, modeToggled, inputSourceChanged,
        secureInputChanged, tapReenabled, settingsChanged, ruleChanged, sessionChanged
}

/// Marks a hard boundary in FIFO order so the worker can end paste coalescing windows and first-edit timing
/// (PLT-R340, PLT-R461 step 6).
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
// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Self-generated event marker (PLT-R321). Layout of `kCGEventSourceUserData` (Int64):
//   bits 63...24  per-launch random tag (40 bits, CSPRNG)
//   bit  23       kind: 0 = injected or replayed by the worker, 1 = latency probe / guided test input
//   bits 22...0   sequence number (wraps)
// Physical events are never modified (PLT-R321).

internal import AppModel

public struct EventMarker: Sendable, Hashable {
    public let tag: UInt64

    public init(tag: UInt64) { self.tag = tag & 0xFF_FFFF_FFFF }

    /// `SecRandomCopyBytes`.
    public static func random() -> EventMarker { unimplemented() }

    public func userData(sequence: UInt32, probe: Bool) -> Int64 { unimplemented() }
    /// Tap-safe: integer arithmetic only.
    public func classify(_ userData: Int64) -> MarkerMatch { unimplemented() }
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

<!-- include: Packages/AppCore/Sources/Injection/Services.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
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

public enum PostError: Error, Sendable, Hashable {
    case eventCreationFailed
    /// `CGPreflightPostEventAccess()` false: the worker reports posting broken (PLT-R730).
    case notPermitted
}

/// Production: `CGEventSource(stateID: .privateState)` with `localEventsSuppressionInterval = 0` (PLT-R320),
/// `CGEvent(keyboardEventSource:virtualKey:keyDown:)`, explicit `flags`, `keyboardSetUnicodeString`,
/// `setIntegerValueField(.eventSourceUserData, value:)`, then `post(tap: .cgSessionEventTap)` (PLT-R322).
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
    func selectedRange(_ field: FieldHandle, timeout: Duration) -> AXCallResult<TextRange>
    /// At most 64 UTF-16 units (PLT-R343); longer ranges are clamped by the implementation.
    func text(_ field: FieldHandle, in range: TextRange, timeout: Duration) -> AXCallResult<String>
    func setSelectedRange(_ field: FieldHandle, to range: TextRange, timeout: Duration) -> AXCallResult<Void>
    func setSelectedText(_ field: FieldHandle, to text: String, timeout: Duration) -> AXCallResult<Void>
}

/// `AXUIElement` wrapper. AX references are immutable CF objects that may be used from any thread.
public final class AXElementReference: @unchecked Sendable, Hashable {
    public let element: AXUIElement
    public init(_ element: AXUIElement) { self.element = element }
    public static func == (lhs: AXElementReference, rhs: AXElementReference) -> Bool { CFEqual(lhs.element, rhs.element) }
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
    public var readTimeout: Duration = .milliseconds(100)
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
// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Shared state between the tap (producer) and the worker (consumer). Everything the tap touches here is a
// lock-free push or an atomic load/store (PLT-R304).

public import AppModel
public import RealtimeSupport

/// FIFO of jobs plus the in-flight count of PLT-R311 ("jobs pushed but final event not yet posted").
public final class JobQueue: Sendable {
    /// Capacity above the 256-job liveness ceiling (PLT-R314) so a full ring is never the first symptom.
    public init(capacity: Int = 512, signal: WorkerSignal) { unimplemented() }

    /// Tap: increments `inFlight`, pushes, signals the worker. False when full: the caller passes the event
    /// through and requests a flush.
    public func push(_ job: InjectionJob) -> Bool { unimplemented() }
    /// Tap: one atomic load.
    public var inFlight: Int { unimplemented() }
    /// Tap: next sequence number (single producer, so a plain counter owned by the tap is enough).
    public func nextSequence() -> JobSequence { unimplemented() }

    /// Worker.
    public func pop() -> InjectionJob? { unimplemented() }
    /// Worker: after the final event of a job was posted, or the job was discarded/abandoned.
    public func finished(_ sequence: JobSequence) { unimplemented() }
    public var queuedCount: Int { unimplemented() }
}

public enum JobOutcome: UInt8, Sendable, Hashable {
    case executed, executedWithFallback, abandoned, discardedForGeneration, passedThroughByFallback
}

/// Worker -> tap feedback through atomics.
public final class WorkerFeedback: Sendable {
    public init() { unimplemented() }

    /// Worker increments after a flush or discard; the tap resets the engine when it sees a new value
    /// (PLT-R314 "reset the composition").
    public func requestCompositionReset() { unimplemented() }
    public var compositionResetCount: UInt64 { unimplemented() }

    /// Outcome of recent jobs (64-entry board indexed by sequence) so the tap can decide what to do with the
    /// keyUp of a consumed keyDown whose job already finished (PLT-R313). Nil = unknown or too old.
    public func record(_ outcome: JobOutcome, for sequence: JobSequence) { unimplemented() }
    public func outcome(of sequence: JobSequence) -> JobOutcome? { unimplemented() }

    /// Set by the echo watchdog; read by the tap at callback entry to fail open within the same callback
    /// (PLT-R730).
    public func markPostingBroken() { unimplemented() }
    public var isPostingBroken: Bool { unimplemented() }
}

/// Echo liveness (PLT-R323): the worker records the sequence of each job's last event, the tap records the
/// highest sequence it saw come back.
public final class EchoTracker: Sendable {
    public init(timeout: Duration = .milliseconds(200), missesForBroken: Int = 3) { unimplemented() }
    /// Worker, after posting a job's final event.
    public func expect(_ sequence: UInt32, postedAt: MonotonicInstant) { unimplemented() }
    /// Tap, on a marked event (PLT-R310 step 2).
    public func observed(_ sequence: UInt32, at: MonotonicInstant) { unimplemented() }
    /// Worker or utility: true once three consecutive jobs saw no echo within the timeout.
    public func isBroken(now: MonotonicInstant) -> Bool { unimplemented() }
}

/// Current focus generation, written by the ax thread on every publication, read by the worker to discard
/// stale edits (PLT-R316).
public final class CurrentFocusGeneration: Sendable {
    public init() { unimplemented() }
    public func store(_ generation: FocusGeneration) { unimplemented() }
    public func load() -> FocusGeneration { unimplemented() }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/Injection/Worker.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The serial injection worker on the dedicated `inject` thread (PLT-R203, PLT-R311-R317, section 4).

internal import AppModel
public import Diagnostics
public import RealtimeSupport

public struct WorkerConfiguration: Sendable, Hashable {
    /// Oldest held event may wait this long before a flush (PLT-R314, VERIFY tuning).
    public var livenessCeiling: Duration = .milliseconds(150)
    /// Ceiling while a macro job runs (PLT-R480).
    public var macroLivenessCeiling: Duration = .seconds(1)
    /// Queue length that forces a flush (PLT-R314).
    public var maxQueuedJobs: Int = 256
    /// Jobs longer than this are split (if `allowSplit`) or use the fallback (PLT-R408).
    public var maxJobDuration: Duration = .milliseconds(150)
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

    public init(
        poster: any EventPoster, fieldAccess: any FocusedFieldAccess, pasteboard: any PasteboardAccess,
        clock: any MonotonicClock, metrics: PlatformMetrics, health: HealthEventLog,
        logger: any DiagnosticsLogging, capture: CaptureController?
    ) {
        self.poster = poster
        self.fieldAccess = fieldAccess
        self.pasteboard = pasteboard
        self.clock = clock
        self.metrics = metrics
        self.health = health
        self.logger = logger
        self.capture = capture
    }
}

/// Reasons the host asks the worker to flush outside the normal liveness check.
public enum FlushReason: UInt8, Sendable, Hashable {
    case tapDisabled  // PLT-R330 step 3
    case failOpen  // PLT-R730
    case queueFull
}

public final class InjectionWorker: Sendable {
    public init(
        queue: JobQueue, signal: WorkerSignal, feedback: WorkerFeedback, echo: EchoTracker, marker: EventMarker,
        focusGeneration: CurrentFocusGeneration, services: InjectionServices,
        configuration: WorkerConfiguration = WorkerConfiguration()
    ) { unimplemented() }

    /// Spawns the `inject` thread (QoS user-interactive). The loop drains jobs, executes them FIFO, sleeps
    /// only on its own signal with absolute deadlines (pacing, liveness, echo), and never waits on the main or
    /// tap thread (PLT-R315).
    public func start() { unimplemented() }
    public func stop() { unimplemented() }

    /// Asynchronous request (atomic flag + signal): abandon unstarted edit jobs (replaying their triggers),
    /// replay every held event in order, request a composition reset, record a `flush` health event.
    public func requestFlush(_ reason: FlushReason) { unimplemented() }

    /// Deterministic mode for tests and the pipeline harness: runs the loop body on the caller's thread until
    /// the queue is empty and no deadline is pending, using the injected (fake) clock.
    public func runUntilIdle() { unimplemented() }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/Injection/Strategies.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
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

public enum FallbackReason: UInt8, Sendable, Hashable {
    case axUnavailable, axTimedOut, axWriteFailed, readbackMismatch, pasteboardUnsafe, postingFailed, jobTooLong
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
    public static func executor(for strategy: InjectionStrategy) -> any StrategyExecutor { unimplemented() }
}

/// PLT-R402: trims the common grapheme prefix of the replaced text and the insertion. With unknown replaced
/// text, the edit is returned unchanged (the engine's edits are already minimal, ENG-R611).
public enum EditMinimizer {
    public static func minimize(deleteCount: Int, replaced: String?, insertion: String)
        -> (deleteCount: Int, insertion: String)
    { unimplemented() }
}

/// PLT-R404/PLT-R480: one grapheme per event by default; up to `maxUTF16` units per event when allowed;
/// never splits a grapheme cluster.
public enum UnicodeChunker {
    public static func chunks(of text: String, maxUTF16: Int, oneGraphemePerEvent: Bool) -> [InlineUTF16] {
        unimplemented()
    }
}

/// Full clipboard preservation for `paste` (PLT-R461): snapshot every item and type (abort on file promises,
/// unmaterialisable lazy data, > 10 MB or > 100 ms), write the transient item, paste, restore after
/// `restoreDelayMs` only if `changeCount` is unchanged, coalesce consecutive pastes within the window.
public final class PasteboardPreserver {
    public init(pasteboard: any PasteboardAccess, limits: PasteboardLimits = PasteboardLimits()) { unimplemented() }
    /// Step 1-2. Throws when the clipboard cannot be fully preserved: never destroy what cannot be restored.
    public func beginPaste(_ text: String) throws(PasteboardError) { unimplemented() }
    /// Steps 4-6, driven by the worker's deadlines.
    public func restoreIfDue(now: MonotonicInstant, restoreDelay: Duration) -> RestoreResult { unimplemented() }

    public enum RestoreResult: Sendable, Hashable { case notDue, restored, skippedUserCopied, nothingPending }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/Injection/System/SystemInjectionServices.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Production implementations of the injection services. They need granted permissions and are exercised by
// the self-hosted integration suite (13.2), never by hosted CI or on the maintainer's everyday Mac.

internal import AppModel

/// CoreGraphics poster (PLT-R320-R322, PLT-R324).
public final class CGEventPoster: EventPoster {
    public init() { unimplemented() }
    public func post(_ event: SyntheticKeyEvent, userData: Int64) throws(PostError) { unimplemented() }
    public func replay(_ record: KeyEventRecord, userData: Int64) throws(PostError) { unimplemented() }
}

/// Bounded AX field access (PLT-R343).
public final class AXFocusedFieldAccess: FocusedFieldAccess {
    public init() { unimplemented() }
    public func selectedRange(_ field: FieldHandle, timeout: Duration) -> AXCallResult<TextRange> { unimplemented() }
    public func text(_ field: FieldHandle, in range: TextRange, timeout: Duration) -> AXCallResult<String> {
        unimplemented()
    }
    public func setSelectedRange(_ field: FieldHandle, to range: TextRange, timeout: Duration) -> AXCallResult<Void> {
        unimplemented()
    }
    public func setSelectedText(_ field: FieldHandle, to text: String, timeout: Duration) -> AXCallResult<Void> {
        unimplemented()
    }
}

/// AppKit pasteboard (PLT-R461). `pasteboardName` nil = general pasteboard.
public final class NSPasteboardAccess: PasteboardAccess {
    public init(pasteboardName: String?) { unimplemented() }
    public var changeCount: Int { unimplemented() }
    public func snapshot(limits: PasteboardLimits) throws(PasteboardError) -> PasteboardSnapshot { unimplemented() }
    public func writeTransient(_ text: String) throws(PasteboardError) -> Int { unimplemented() }
    public func restore(_ snapshot: PasteboardSnapshot) throws(PasteboardError) { unimplemented() }
}
```
<!-- /include -->

## 10. InputHost

Owned files (two wave-1 workstreams, disjoint directories):

| Directory under `Sources/InputHost/` | Owner | Tests |
|---|---|---|
| `Snapshots/`, `Engine/`, `Pipeline/`, `Tap/`, `Lifecycle/` | W1-F (pipeline) | `Tests/InputHostTests/Pipeline/`, `Sources/TestSupport/Pipeline/` |
| `Hotkeys/`, `InputSource/`, `SecureInput/`, `Focus/`, `Memory/`, `Permissions/`, `Workspace/` | W1-E (host services) | `Tests/InputHostTests/Services/`, `Sources/TestSupport/Fakes/Host/` |
| `Probes/` | W2-C (diagnostics UI) | `Tests/InputHostTests/Probes/` |

`Snapshots/` is a frozen contract between W1-E (producers) and W1-F (consumer).

### 10.1 Pipeline and per-key state (tap thread)

`KeyPipeline<Factory, Clock>` holds, confined to the tap thread: the current `CompositionEngine`, the engine
variant and settings generation it was built for, the `HotkeyRecognizer`, a fixed-size table of consumed
keyDowns awaiting their keyUp (keycode -> job sequence), the last seen worker reset counter, the tap's own
toggle override (sequence, bundle, mode), the secure-input "resumed" generation and the idle timestamp for
PLT-R382. Steps of PLT-R310 are in ARCHITECTURE.md section 4.

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

### 10.3 Per-app memory and the toggle race

`AppModeMemory` lives on the ax thread. When the user toggles with the hotkey, the tap flips the mode at once
and pushes `modeToggled(sequence, bundle, mode)` to both the ax and the main outbox. The ax thread drains its
inbox before resolving any focus change, applies the toggle to memory (PRD-R20) and stamps every published
`FocusSnapshot` with `appliedToggleSequence`. The tap's effective mode is its own override when
`override.sequence > snapshot.appliedToggleSequence` and the bundle matches, otherwise `snapshot.mode`. A
focus change resolved concurrently with a toggle therefore never flips the mode back (PLT-R391, PRD-R19).

<!-- include: Packages/AppCore/Sources/InputHost/Snapshots/Snapshots.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
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

    public init(
        plan: InjectionPlan, variant: EngineVariant, requireTextFocus: RequireTextFocus, verifyReentry: VerifyReentry,
        restoreHotkeyEnabled: Bool, rule: RuleID?, source: DecisionSource, specificity: Int
    ) {
        self.plan = plan
        self.variant = variant
        self.requireTextFocus = requireTextFocus
        self.verifyReentry = verifyReentry
        self.restoreHotkeyEnabled = restoreHotkeyEnabled
        self.rule = rule
        self.source = source
        self.specificity = specificity
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

/// Published by the utility queue's secure-input poller (PLT-R395). `generation` changes only on
/// transitions, so the tap's "resumed by key" evidence (PLT-R398B) stays valid while the OS flag is stuck.
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

    public init(generation: UInt64, phase: Phase, userDisabled: Bool, recorderActive: Bool, globalMode: TypingMode) {
        self.generation = generation
        self.phase = phase
        self.userDisabled = userDisabled
        self.recorderActive = recorderActive
        self.globalMode = globalMode
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
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/InputHost/Snapshots/LayoutTable.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Layout translation table (PLT-R360, PLT-R361). Built off the hot path from the layout's `uchr` data with
// `UCKeyTranslate`; looked up on the tap by array index.

public import AppModel

/// Modifier states covered by the table. Option and Command/Control states are classified, not translated
/// (PLT-R350).
public enum LayoutModifierState: Int, Sendable, Hashable, CaseIterable {
    case none = 0, shift, capsLock, shiftCapsLock
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
// SPDX-License-Identifier: LicenseRef-App-Pending
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

public struct VietnameseCompositionEngineFactory: CompositionEngineFactory {
    public init() {}
    public func makeEngine(for variant: EngineVariant, settings: TapSettingsSnapshot) -> VietnameseCompositionEngine {
        VietnameseCompositionEngine(engine: settings.engines.engine(for: variant))
    }
}

/// Eight prebuilt engines: appContext x englishRestore x macros (ENG-R850, `features`, ENG-R1107).
public struct EngineCatalog: Sendable {
    public init(engines: [EngineVariant: VietnameseEngine.Engine]) { unimplemented() }
    public func engine(for variant: EngineVariant) -> VietnameseEngine.Engine { unimplemented() }
}

public enum MacroTableBuildIssue: Sendable, Hashable {
    case rejected(macroID: String, reason: MacroTable.ValidationError)
}

/// Pure mapping from settings to engine values. Runs on the utility queue when settings change.
public enum EngineBridge {
    /// D1, D2, D4, D5, D6 plus the variant.
    public static func configuration(for settings: EffectiveSettings, variant: EngineVariant) -> EngineConfiguration {
        unimplemented()
    }

    /// Enabled macros only; invalid entries are skipped and reported (the editor prevents them, PRD-R29).
    public static func macroTable(from macros: [StoredMacro]) -> (MacroTable, [MacroTableBuildIssue]) {
        unimplemented()
    }

    /// Loads bundled lexicons once (ENG-R1231: at most 50 ms) and attaches user lists and macros.
    public static func resources(
        settings: EffectiveSettings, macros: MacroTable, bundledLoader: () throws -> Resources
    ) rethrows -> Resources { unimplemented() }

    public static func catalog(settings: EffectiveSettings, resources: Resources) -> EngineCatalog { unimplemented() }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/InputHost/Pipeline/Events.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending

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
    case learning(LearningSignal)  // ENG-R861, memory only
    case postingBroken
    case keyboardTypeSeen(UInt32)
}

/// Tap -> ax notices.
public enum AXNotice: Sendable {
    case modeToggled(sequence: UInt64, bundle: BundleKey?, mode: TypingMode)
    case revalidateFocus  // PLT-R382
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
// SPDX-License-Identifier: LicenseRef-App-Pending
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

    public init(
        snapshots: TapSnapshots, queue: JobQueue, feedback: WorkerFeedback, echo: EchoTracker, marker: EventMarker,
        outbox: TapOutbox, metrics: PlatformMetrics, tapLog: TapLogRing, capture: CaptureController?,
        watchdog: CallbackWatchdog
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
    }
}

/// Per-callback watchdog state (PLT-R306): `enteredAt` written at entry, cleared at exit; the utility watchdog
/// disables the tap if one callback runs longer than 250 ms.
public final class CallbackWatchdog: Sendable {
    public static let callbackLimit: Duration = .milliseconds(250)
    public init(activitySignal: WakeSignal) { unimplemented() }
    @inline(__always) public func enter(at now: MonotonicInstant) { unimplemented() }
    @inline(__always) public func exit() { unimplemented() }
    /// Utility queue.
    public func runningCallbackDuration(now: MonotonicInstant) -> UInt64? { unimplemented() }
}

/// Tap-thread pipeline. Generic over the engine factory and the clock, so production code
/// (`KeyPipeline<VietnameseCompositionEngineFactory, MachClock>`) has no existential calls on the hot path and
/// tests drive it with a scripted engine and a manual clock.
public final class KeyPipeline<Factory: CompositionEngineFactory, Clock: MonotonicClock> {
    public init(context: PipelineContext, factory: Factory, clock: Clock) { unimplemented() }

    /// The whole of PLT-R310 for one event. Brackets itself with `ReaderEpoch.enter()/exit()` and
    /// `CallbackWatchdog.enter/exit`.
    public func handle(_ event: RawKeyEvent) -> TapVerdict { unimplemented() }

    /// Outcome of the last physical keyboard event (nil for echoes, mouse and tap-disabled events). Read by
    /// the conservation ledger in tests and by the capture.
    public var lastOutcome: EventOutcome? { unimplemented() }
}

/// Classification of step 7 (pure, tap-safe).
public enum KeyClassifier {
    public static func classify(_ event: RawKeyEvent, table: LayoutTable?) -> KeyClass { unimplemented() }
}

/// Host state per key (2.1), the same pure function the main thread uses for the menu icon.
public enum HostStateResolver {
    /// Precedence: noPermission / failOpen / starting > sessionInactive > userDisabled > secureInput (unless
    /// resumed by key evidence for this generation) > secureField > nonLatinInputSource >
    /// builtInVietnameseSource > passThroughRule > noTextFocus > ready(mode).
    public static func resolve(
        lifecycle: LifecycleSnapshot, secureInput: SecureInputSnapshot, secureResumedGeneration: UInt64?,
        inputSource: InputSourceSnapshot, focus: FocusSnapshot, effectiveMode: TypingMode
    ) -> HostState { unimplemented() }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/InputHost/Tap/TapThread.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The `tap` thread (PLT-R203, PLT-R301-R303): one active session-level, head-insert event tap whose run-loop
// source is the only source on its run loop.

internal import AppModel
public import CoreGraphics
public import Dispatch

/// Event mask of PLT-R301 (`keyDown`, `keyUp`, `flagsChanged`, `leftMouseDown`, `rightMouseDown`,
/// `otherMouseDown`, optionally `scrollWheel`).
public struct TapEventMask: Sendable, Hashable {
    public var includeScrollWheel: Bool
    public init(includeScrollWheel: Bool) { self.includeScrollWheel = includeScrollWheel }
    public var cgMask: CGEventMask { unimplemented() }
}

/// Creates the event tap. Production: `CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
/// options: .defaultTap, eventsOfInterest: mask.cgMask, callback: callback, userInfo: userInfo)`.
/// Returns nil when the OS refuses (no permission): the host enters `failOpen(tapUnavailable)` (PLT-R332).
public protocol EventTapFactory: Sendable {
    func makeTap(mask: TapEventMask, callback: CGEventTapCallBack, userInfo: UnsafeMutableRawPointer?) -> CFMachPort?
}

public struct CGEventTapFactory: EventTapFactory {
    public init() {}
    public func makeTap(mask: TapEventMask, callback: CGEventTapCallBack, userInfo: UnsafeMutableRawPointer?)
        -> CFMachPort?
    { unimplemented() }
}

/// Owns the tap thread and the tap's mach port. The C callback converts the `CGEvent` into a `RawKeyEvent`,
/// calls `KeyPipeline.handle`, and returns `Unmanaged.passUnretained(event)` or nil.
public final class TapThread: Sendable {
    /// `handler` is called on the tap thread only.
    public init(factory: any EventTapFactory, mask: TapEventMask, handler: @escaping @Sendable (RawKeyEvent) -> TapVerdict) {
        unimplemented()
    }

    /// Creates the tap on a new thread (QoS user-interactive) and runs its CFRunLoop. False if creation failed.
    public func start() -> Bool { unimplemented() }
    /// `CGEventTapEnable`; callable from any thread (watchdog and fail-open use it, PLT-R306, PLT-R730).
    public func setEnabled(_ enabled: Bool) { unimplemented() }
    /// `CGEventTapIsEnabled` (PLT-R331).
    public var isEnabled: Bool { unimplemented() }
    /// Disables, removes the source, invalidates the port and lets the thread exit (PLT-R730).
    public func stop() { unimplemented() }
}

/// PLT-R306 and PLT-R331 on the utility queue. The 250 ms callback check runs only while keys are flowing
/// (armed by the tap's activity `WakeSignal`, disarmed after 2 s idle), so idle wakeups stay at zero
/// (PLT-R803); the tap-enabled check runs every 5 s with leeway and on wake, session activation and
/// permission change.
public final class TapWatchdog: Sendable {
    public init(
        tap: TapThread, callbacks: CallbackWatchdog, queue: DispatchQueue, onTrip: @escaping @Sendable (TapTrip) -> Void
    ) { unimplemented() }

    public func start() { unimplemented() }
    public func stop() { unimplemented() }
    /// Called on wake, session activation, permission change (PLT-R331).
    public func checkNow() { unimplemented() }

    public enum TapTrip: Sendable, Hashable {
        case callbackOverLimit(microseconds: UInt64)  // -> failOpen(watchdog), retry after 2 s
        case unexpectedlyDisabled  // -> PLT-R330 procedure
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/InputHost/Lifecycle/InputHostController.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Lifecycle owner of the input host (2.1). Main actor: it starts and stops threads, applies settings, runs the
// state machine and tells the shell what to show. It never sits on the per-keystroke path.

public import AppModel
public import CompatRules
public import Diagnostics
public import Foundation
public import Injection
public import RealtimeSupport
public import SettingsStore

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
    public var clock: MachClock
    public var wallClock: any WallClock
    public var metrics: PlatformMetrics
    public var health: HealthEventLog
    public var logger: any DiagnosticsLogging
    public var tapLog: TapLogRing
    public var capture: CaptureController?
    /// Serial utility queue shared with SettingsStore and Diagnostics (PLT-R203).
    public var utilityQueue: DispatchSerialQueue

    public init(
        tapFactory: any EventTapFactory, poster: any EventPoster, fieldAccess: any FocusedFieldAccess,
        pasteboard: any PasteboardAccess, ax: any AXProvider, processes: any ProcessIdentityProvider,
        bundleInspector: any BundleInspector, inputSources: any InputSourceProvider,
        layoutBuilder: any LayoutTableBuilding, secureInput: any SecureInputProbe, permissions: any PermissionProbe,
        workspace: any WorkspaceEvents, keyValueStore: any KeyValueStore, clock: MachClock, wallClock: any WallClock,
        metrics: PlatformMetrics, health: HealthEventLog, logger: any DiagnosticsLogging, tapLog: TapLogRing,
        capture: CaptureController?, utilityQueue: DispatchSerialQueue
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
        self.wallClock = wallClock
        self.metrics = metrics
        self.health = health
        self.logger = logger
        self.tapLog = tapLog
        self.capture = capture
        self.utilityQueue = utilityQueue
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
    /// ENG-R861 learning signal seen twice: proposed for the user list (open decision 8).
    case learningProposal(LearningProposal)
}

public struct LearningProposal: Sendable, Hashable {
    public enum List: Sendable, Hashable { case keepAsTyped, keepVietnamese }
    public var list: List
    public var rawKeys: String  // content: shown to the user in Settings, never logged
}

@MainActor
public final class InputHostController {
    public init(dependencies: InputHostDependencies, settingsStore: SettingsStore) { unimplemented() }

    public private(set) var state: HostState {
        get { unimplemented() }
        set { unimplemented() }
    }

    public var onEvent: (@MainActor (HostEvent) -> Void)? {
        get { unimplemented() }
        set { unimplemented() }
    }

    /// Ready after launch within 300 ms target / 1 s gate when permissions are granted (S1).
    public func start(rules: RulesLoadResult, settings: SettingsState) { unimplemented() }
    public func stop() { unimplemented() }

    /// Rebuilds engines and snapshots (utility queue) and re-resolves focus (ax) (PLT-R1008, PRD-R27).
    public func apply(settings: SettingsState) { unimplemented() }

    /// Menu radio or click-to-toggle (D16). Hard boundary; updates per-app memory (PRD-R20).
    public func setMode(_ mode: TypingMode, manual: Bool) { unimplemented() }

    /// Status for the menu "Với <App>" submenu and diagnostics.
    public func currentFocus() -> FocusSnapshot { unimplemented() }

    /// Immediate secure-input poll when the menu opens (PLT-R395).
    public func refreshSecureInput() -> SecureInputSnapshot { unimplemented() }

    /// Immediate permission check on menu open, wake and session activation (PLT-R721).
    public func refreshPermissions() -> PermissionStatus { unimplemented() }

    /// The settings window's recorder is capturing keys: suspend hotkeys (PRD-R15).
    public func setRecorderActive(_ active: Bool) { unimplemented() }

    /// Data for the diagnostics report (PLT-R1202), metadata only.
    public func reportContext() -> HostReportContext { unimplemented() }
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
// SPDX-License-Identifier: LicenseRef-App-Pending
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
public struct HotkeyRecognizer: Sendable {
    public static let maximumTapDuration: Duration = .milliseconds(500)
    public init(toggle: HotkeyBinding, restore: HotkeyBinding?) { unimplemented() }
    public mutating func handle(_ input: HotkeyInput) -> HotkeyResult { unimplemented() }
}

public enum RecorderState: Sendable, Hashable {
    case idle
    case recording(held: ModifierKeys, key: KeyCode?)
    case finished(HotkeyBinding, conflict: SystemShortcutConflict?)
    case rejected(RecorderRejection)
}

public enum RecorderRejection: String, Sendable, Hashable {
    case unsupportedModifierTap  // modifier-only chord outside the PRD-R15 list
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

/// Captures a binding in any press order and finishes when every key is released (PRD-R15).
public struct HotkeyRecorder: Sendable {
    public init(role: HotkeyRole) { unimplemented() }
    public mutating func handle(_ input: HotkeyInput) -> RecorderState { unimplemented() }
    public static func conflict(for binding: HotkeyBinding) -> SystemShortcutConflict? { unimplemented() }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/InputHost/InputSource/InputSources.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
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

public struct UCKeyTranslateLayoutBuilder: LayoutTableBuilding {
    public init() {}
    public func build(from data: KeyboardLayoutData, keyboardType: UInt32) throws -> LayoutTable { unimplemented() }
}

/// Main thread: on every source change builds (or reuses) the table, classifies the source (PLT-R371,
/// PLT-R372), applies the PLT-R373 binding and publishes an `InputSourceSnapshot`; signals a hard boundary.
@MainActor
public final class InputSourceMonitor {
    public init(provider: any InputSourceProvider, builder: any LayoutTableBuilding,
                publish: @escaping @Sendable (InputSourceSnapshot) -> Void) { unimplemented() }
    public func start() { unimplemented() }
    public func stop() { unimplemented() }
    public func apply(binding: LayoutBindingConfiguration) { unimplemented() }
    /// The tap saw a keyboard type without a table (ISO/ANSI/JIS): build one.
    public func keyboardTypeSeen(_ keyboardType: UInt32) { unimplemented() }
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
// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Secure Event Input (PLT-R395-R398C, P0-1). Only two pause signals exist: the OS secure-input state and an
// `AXSecureTextField` focus (PLT-R398A). No heuristics.

public import AppModel
public import Foundation

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
    public func isSecureEventInputEnabled() -> Bool { unimplemented() }
    public func secureInputHolderPID() -> Int32? { unimplemented() }
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

/// Production: `NSRunningApplication(processIdentifier:)`, `proc_pidpath`, `proc_name`, `Bundle(url:)`.
public protocol ProcessIdentityProvider: Sendable {
    func identity(of pid: Int32) -> ProcessIdentity?
    func isAlive(_ pid: Int32) -> Bool  // kill(pid, 0) != ESRCH
    func runningApplications() -> [ProcessIdentity]
}

/// Utility queue: polls every 2 s with 10 % leeway and on demand (menu open), publishes a
/// `SecureInputSnapshot` whose generation changes only on transitions, names the likely holder with the
/// data-driven hint key (PLT-R396, PLT-R397).
public final class SecureInputMonitor: Sendable {
    public static let pollInterval: Duration = .seconds(2)

    public init(
        probe: any SecureInputProbe, processes: any ProcessIdentityProvider,
        hintKey: @escaping @Sendable (BundleKey) -> String?, queue: DispatchQueue,
        publish: @escaping @Sendable (SecureInputSnapshot) -> Void
    ) { unimplemented() }

    public func start() { unimplemented() }
    public func stop() { unimplemented() }
    /// Synchronous poll (menu open, PLT-R395).
    public func pollNow() -> SecureInputSnapshot { unimplemented() }
    /// The tap processed a key while paused for secure input (PLT-R398B): keep the state "resumed" for this
    /// generation and record the episode end.
    public func keyEvidence(generation: UInt64) { unimplemented() }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/InputHost/Focus/Focus.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
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
    public var ancestorRoles: [String]  // up to 6 parents (5.2)
    public var documentURL: String?  // transient
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
public protocol AXProvider: Sendable {
    func systemWideFocus() -> AXCallResult<AXFocusedElement?>
    func attributes(of element: AXFocusedElement, request: AXAttributeRequest) -> AXCallResult<FocusAttributes>
    /// Observer whose run-loop source the caller adds to the ax run loop. The handler runs on the ax thread.
    func observe(
        pid: Int32, notifications: Set<AXNotificationKind>,
        handler: @escaping @Sendable (AXNotificationKind) -> Void
    ) -> (any AXObservation)?
    /// `AXManualAccessibility = true` when a rule says `axEnable: manual`; the caller records it (PLT-R385).
    func enableManualAccessibility(pid: Int32) -> Bool
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

/// PLT-R384: 3 timeouts within 10 s for one pid stop AX queries to that pid for 60 s.
public struct AXCircuitBreaker: Sendable {
    public init(threshold: Int = 3, window: Duration = .seconds(10), cooldown: Duration = .seconds(60)) { unimplemented() }
    public mutating func recordTimeout(pid: Int32, at: MonotonicInstant) -> Bool { unimplemented() }
    public func isOpen(pid: Int32, at: MonotonicInstant) -> Bool { unimplemented() }
}

/// The focus tracker. Owns AXObservers on the focused app and on `overlay` apps (PLT-R380), treats the
/// system-wide AX focus as authoritative (PLT-R381), resolves rules and per-app mode, and publishes a
/// `FocusSnapshot` plus the current generation before the next key is processed (PLT-R391).
public final class FocusTracker: Sendable {
    public init(
        thread: RunLoopThread, ax: any AXProvider, processes: any ProcessIdentityProvider,
        output: SnapshotCell<FocusSnapshot>, generation: CurrentFocusGeneration, inbox: SPSCRing<AXNotice>,
        metrics: PlatformMetrics, health: HealthEventLog, clock: MachClock, macOSVersion: LooseVersion
    ) { unimplemented() }

    public func start(rules: any FocusDecisionResolving, memory: AppModeMemory) { unimplemented() }
    public func stop() { unimplemented() }
    /// Hop to the ax thread; re-resolve the current focus (rules or overrides changed, PLT-R540 acceptance).
    public func update(rules: any FocusDecisionResolving) { unimplemented() }
    public func update(settings: EffectiveSettings, appModes: AppModesDocument) { unimplemented() }
    /// NSWorkspace activation, wake, idle-key flag (PLT-R381, PLT-R382): revalidate system-wide focus.
    public func revalidate() { unimplemented() }
    /// Drains `inbox` (tap toggles first, then revalidation) on the ax thread; wired to the AX wake signal.
    public func drainInbox() { unimplemented() }
}

/// Conversion done once per focus change (rule decision -> tap decision), PLT-R386 `byEngine` resolution.
public enum HostDecisionMapper {
    public static func map(_ decision: ResolvedDecision, engine: EngineFingerprint, optedIntoPaste: Bool) -> HostDecision {
        unimplemented()
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/InputHost/Memory/AppModeMemory.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
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
}

public struct AppModeMemory: Sendable, Hashable {
    public init(document: AppModesDocument, rememberPerApp: Bool, firstSeen: FirstSeenMode) { unimplemented() }

    /// PRD-R21: ignore > always English > always Vietnamese > remembered > rule `defaultMode` / D13 > global.
    public func resolve(bundle: BundleKey?, ruleDefault: FirstSeenMode) -> ModeResolution { unimplemented() }

    /// Manual toggle while `bundle` is the focus owner (PRD-R20). Updates the global mode too.
    public mutating func recordToggle(bundle: BundleKey?, mode: TypingMode) { unimplemented() }

    /// Most-recently-used ordering for the Apps pane; LRU eviction at 1,000 remembered entries (PLT-R392).
    public mutating func touch(_ bundle: BundleKey) { unimplemented() }

    public mutating func setRule(_ rule: PerAppRule?, for bundle: BundleKey) { unimplemented() }

    public var globalMode: TypingMode { unimplemented() }
    public func document() -> AppModesDocument { unimplemented() }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/InputHost/Permissions/Permissions.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Permissions (PLT-R701-R741). Probes are cheap system calls made off the tap thread.

public import AppModel
public import Foundation
public import SettingsStore

/// Production (`SystemPermissionProbe`): `AXIsProcessTrusted()`, `CGPreflightPostEventAccess()`,
/// `CGPreflightListenEventAccess()`, `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`,
/// `CGRequestListenEventAccess()`, `CGRequestPostEventAccess()`; the signing identity digest comes from
/// `SecCodeCopySelf` + `SecCodeCopyDesignatedRequirement`.
public protocol PermissionProbe: Sendable {
    func isAccessibilityTrusted() -> Bool
    func canPostEvents() -> Bool
    func canListenToEvents() -> Bool
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
    /// Input Monitoring needed: tap could not be created or receives no keys while Accessibility is granted.
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

/// Utility queue: every 2 s while not ready, every 30 s while ready, immediately on wake, session activation
/// and menu open (PLT-R721). Remembers the identity digest of the last grant (key-value store) for `stale`.
public final class PermissionMonitor: Sendable {
    public init(
        probe: any PermissionProbe, store: any KeyValueStore, queue: DispatchQueue,
        onChange: @escaping @Sendable (PermissionStatus) -> Void
    ) { unimplemented() }
    public func start() { unimplemented() }
    public func stop() { unimplemented() }
    public func checkNow() -> PermissionStatus { unimplemented() }
    /// Onboarding polls every 1 s for at most 5 minutes while visible (PLT-R711).
    public func setFastPolling(_ enabled: Bool) { unimplemented() }
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
// SPDX-License-Identifier: LicenseRef-App-Pending

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
/// `ReverseDNSConstants.swift`, the only file the bundle-ID lint allowlists in this module).
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

public enum ConflictDetector {
    public static func detect(
        running: [ProcessIdentity], enabledSources: [InputSourceInfo], conflictingApps: Set<BundleKey>
    ) -> [ConflictingInput] { unimplemented() }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/InputHost/Probes/Probes.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Diagnostics drivers that type into the user's Mac. They exist for the product owner to run by hand from the
// Diagnostics window; automated tests use fakes only. Wave-2 contract (workstream W2-C).

public import AppModel
public import CompatRules
public import Diagnostics
public import Injection
public import RealtimeSupport

/// PLT-R810: posts physical-like key events tagged with the probe marker (processed by the pipeline as
/// physical, excluded from user metrics) into the probe window's text view with the three timing profiles.
public final class LatencyProbeDriver: Sendable {
    public init(poster: any EventPoster, marker: EventMarker, clock: MachClock) { unimplemented() }
    /// Types `keys` (key codes from the current layout) with `profile` spacing; the probe window reports
    /// text-change times through `textChanged(at:)`.
    public func run(profile: LatencyProbeResult.Profile, keys: [KeyCode]) async -> [MonotonicInstant] { unimplemented() }
    public func textChanged(at instant: MonotonicInstant) { unimplemented() }
    public func result(baseline: [MonotonicInstant], measured: [MonotonicInstant], metrics: PlatformMetrics)
        -> LatencyProbeResult.ProfileResult
    { unimplemented() }
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
}

public final class GuidedTestRunner: Sendable {
    public static func candidates(isNativeApp: Bool) -> [GuidedTestCandidate] { unimplemented() }
    public init(poster: any EventPoster, fieldAccess: any FocusedFieldAccess, marker: EventMarker, clock: MachClock) {
        unimplemented()
    }
    public func run(_ candidate: GuidedTestCandidate, field: FieldHandle?) async -> GuidedTestCandidateResult {
        unimplemented()
    }
    /// Rule suggestion in the 5.4 schema (PLT-R1205 step 4); a URL prefix only if the user ticked it.
    public static func suggestion(
        context: MatchContext, best: GuidedTestCandidate, appVersion: String?, macOS: String, date: String,
        includeURLPrefix: String?
    ) -> Rule { unimplemented() }
}
```
<!-- /include -->

## 11. ShellCore

Owned files: `Packages/AppCore/Sources/ShellCore/**`, `Tests/ShellCoreTests/**` (workstream W1-G).
Isolation: values are any; `InterfaceLanguageModel` and `UpdaterControlling` are main-actor.

### 11.1 Runtime UI-language switch (PRD-R63)

Strings are looked up per **selected** language, not per system language. Xcode compiles each String Catalog
in `App/Resources/Localization/` into `vi.lproj/<Table>.strings` and `en.lproj/<Table>.strings(dict)` (the
skeleton build shows `vi.lproj/Common.strings` and `en.lproj/Common.strings` in the bundle). `Localizer`
opens `Bundle(path: appBundle.path(forResource: language.rawValue, ofType: "lproj"))` and calls
`localizedString(forKey:value:table:)` on that sub-bundle, so `Bundle.main`'s preferred localization (which
follows macOS) is never consulted. Formatting uses `String(format:locale:arguments:)` with the selected
`Locale`, so `.stringsdict` plurals and number formats follow the selected language (PRD-R65). The app name is
always an argument (`"onboarding.welcome.title" = "Chào mừng bạn đến với %@"`). `InterfaceLanguageModel` is
`@Observable`; when settings change D18 it swaps the `Localizer`, SwiftUI views (which render
`Text(verbatim: localizer.string(...))`) re-render, AppKit menus are rebuilt on their next open, the status
item's accessibility label and open window titles are refreshed. Sparkle's own update window follows macOS
localization; its release notes come from the appcast in the selected language (PRD-R51). System pane names
come from `SystemPaneTable` in the macOS language (PRD-R64).

<!-- include: Packages/AppCore/Sources/ShellCore/Brand.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The single runtime source of the product name (CLAUDE.md "Name (temporary)"). Values come from Info.plist
// keys that project.yml fills from Config/Brand.xcconfig; nothing here is hard-coded.

internal import AppModel
public import Foundation

public struct Brand: Sendable, Hashable {
    /// Info.plist keys (project.yml): `CFBundleDisplayName` = $(APP_DISPLAY_NAME),
    /// `AppSlug` = $(APP_SLUG), `AppSiteHost` = $(APP_SITE_HOST).
    public enum InfoKey {
        public static let displayName = "CFBundleDisplayName"
        public static let slug = "AppSlug"
        public static let siteHost = "AppSiteHost"
        public static let supportEmail = "AppSupportEmail"  // VERIFY with Pa (QA-R51)
    }

    public var displayName: String
    public var slug: String
    public var siteHost: String
    public var bundleIdentifier: String
    public var version: String  // CFBundleShortVersionString
    public var build: String  // CFBundleVersion
    public var supportEmail: String?

    public init(
        displayName: String, slug: String, siteHost: String, bundleIdentifier: String, version: String, build: String,
        supportEmail: String?
    ) {
        self.displayName = displayName
        self.slug = slug
        self.siteHost = siteHost
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.build = build
        self.supportEmail = supportEmail
    }

    /// Reads the bundle; traps with a clear message if a key is missing (a build-configuration error).
    public static func from(_ bundle: Bundle) -> Brand { unimplemented() }

    /// Folder name under Application Support and Logs: the display name if it is pure ASCII, else the slug
    /// (PLT-R903). Frozen at the first public release (docs/decisions/0307-settings-file-layout.md).
    public var storageFolderName: String { displayName.allSatisfy(\.isASCII) ? displayName : slug }

    public var siteURL: URL { URL(string: "https://\(siteHost)/")! }
    /// URL scheme that may only open Settings (PLT-R909).
    public var urlScheme: String { slug }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/ShellCore/Localization.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Runtime UI-language switch without restart (PRD-R63, docs/architecture/contracts.md "Localisation").
//
// Strings live in String Catalogs (`App/Resources/Localization/*.xcstrings`, one table per feature area so
// parallel workstreams never edit the same file). Xcode compiles each catalog into `vi.lproj/<Table>.strings`
// and `en.lproj/<Table>.strings(dict)`. Lookup NEVER relies on the process's preferred languages: the
// `Localizer` opens the `.lproj` sub-bundle of the language selected in Settings (D18) and resolves every key
// there, so switching language re-renders immediately and is independent of the macOS language.

public import AppModel
public import Foundation
public import Observation

/// String tables (catalog file names). Owned per workstream (docs/architecture/workstreams.md).
public enum StringTable: String, Sendable, CaseIterable {
    case common = "Common"  // buttons, app-wide words
    case menu = "Menu"  // status item, menu, HUD, VoiceOver labels (PRD-R10, PRD-R11)
    case status = "Status"  // status lines and error states (PRD-R43), secure-input hints (PLT-R397)
    case onboarding = "Onboarding"  // PRD-R40 screens 1-8
    case settings = "Settings"  // five panes (PRD-R24, PRD-R25)
    case macros = "Macros"  // section 8
    case apps = "Apps"  // section 9
    case diagnostics = "Diagnostics"  // PLT-R1201, PLT-R1205, PRD-R47
    case support = "Support"  // About & Support, donation block (PRD-R59)
    case updates = "Updates"  // PRD-R50-R54
}

/// Resolves keys for one language. Immutable; a new instance is created on language change.
public struct Localizer: Sendable {
    public let language: InterfaceLanguage
    public let locale: Locale

    /// `appBundle` contains `vi.lproj` and `en.lproj`.
    public init(language: InterfaceLanguage, appBundle: Bundle) { unimplemented() }

    /// Looks up `key` in `table` of the selected language's lproj; falls back to Vietnamese, then to the key
    /// itself (a missing key is a test failure, never a crash).
    public func string(_ key: String, table: StringTable) -> String { unimplemented() }

    /// Format with arguments (the app name is always an argument, never part of the copy):
    /// `String(format:locale:arguments:)` over the localized format, so `.stringsdict` plural rules apply.
    public func format(_ key: String, table: StringTable, _ arguments: any CVarArg...) -> String { unimplemented() }

    /// PRD-R65: dates, numbers and versions in the selected language.
    public func formatDate(_ date: Date) -> String { unimplemented() }
    public func formatNumber(_ number: Int) -> String { unimplemented() }
}

/// Observable current language for SwiftUI views and AppKit controllers (menus rebuild on open).
@MainActor
@Observable
public final class InterfaceLanguageModel {
    public private(set) var localizer: Localizer
    public init(language: InterfaceLanguage, appBundle: Bundle) { unimplemented() }
    /// Called when settings change; views observing `localizer` re-render (PRD-R63).
    public func select(_ language: InterfaceLanguage) { unimplemented() }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/ShellCore/SystemPanes.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
//
// System Settings pane names and deep links keyed by macOS version and the MACOS language (PLT-R704, PRD-R64),
// loaded from the resource `SystemPanes.json`. UI copy is in the interface language; pane names quoted inside
// it are in the system language so they match what the user sees in System Settings.
//
// SystemPanes.json shape:
// { "schemaVersion": 1,
//   "entries": [ { "macOS": {"min": "15.0", "max": "26.99"},
//                  "names": { "vi": {"systemSettings": "Cài đặt hệ thống", "privacySecurity": "...",
//                                    "accessibility": "Trợ năng", "inputMonitoring": "...", "keyboard": "...",
//                                    "textReplacements": "..."},
//                             "en": {...} },
//                  "deepLinks": { "accessibility": "x-apple.systempreferences:...", ... } } ] }
// Every entry is VERIFY on a real system in that language and version before release.

public import AppModel
public import Foundation

public enum SystemPane: String, Sendable, Hashable, CaseIterable {
    case accessibility, inputMonitoring, keyboard, inputSources, loginItems
}

public struct SystemPaneNames: Sendable, Hashable {
    public var systemSettings: String
    public var privacySecurity: String
    public var accessibility: String  // "Device Control and Data Access" on macOS 27 (PLT-R701)
    public var inputMonitoring: String
    public var keyboard: String
    public var textReplacements: String
}

public struct SystemPaneTable: Sendable {
    public init(resource: Data) throws { unimplemented() }
    /// `systemLanguage` is the macOS primary language (BCP 47); unknown languages fall back to English.
    public func names(macOS: LooseVersion, systemLanguage: String) -> SystemPaneNames { unimplemented() }
    public func deepLink(_ pane: SystemPane, macOS: LooseVersion) -> URL? { unimplemented() }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/ShellCore/StatusPresentation.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Menu-bar icon states (PRD-R10), menu model (PRD-R11) and status lines (PRD-R43). Pure functions of host
// state, testable without AppKit.

public import AppModel
public import Foundation

/// PRD-R10 glyph states; every case has a VoiceOver label key in the `Menu` table.
public enum StatusIconState: String, Sendable, Hashable, CaseIterable {
    case vietnamese  // V in a rounded square
    case english  // E in a rounded square
    case ignoredApp  // E with a small dot
    case secureInputVietnamese  // V with a lock badge
    case secureInputEnglish  // E with a lock badge
    case paused  // dimmed glyph (non-Latin source and other pauses)
    case notWorking  // glyph with a slash (permission missing or tap failed)
    case capturing  // changed icon while a typing trace records (PLT-R905)

    public var accessibilityLabelKey: String { "icon.\(rawValue).accessibilityLabel" }
    public var templateImageName: String { "StatusIcon-\(rawValue)" }
}

public enum StatusPresentation {
    public static func iconState(state: HostState, mode: TypingMode, ignored: Bool, capturing: Bool)
        -> StatusIconState
    { unimplemented() }
}

/// One status line (PRD-R11 item 1, PRD-R43): message key, arguments and a single concrete action.
public struct StatusLine: Sendable, Hashable {
    public enum Action: Sendable, Hashable {
        case grantPermission, resumeOnboarding, showHolderApp(pid: Int32), secureInputHelp, reportProblem,
            learnMore(URL), none
    }

    public var key: String  // in the `Status` table
    public var arguments: [String]  // app names, source names, never typed content
    public var action: Action
    public init(key: String, arguments: [String], action: Action) {
        self.key = key
        self.arguments = arguments
        self.action = action
    }

    public static func forState(_ state: HostState, holderHintKey: String?, appName: String) -> StatusLine? {
        unimplemented()
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
}

public enum HotkeyDisplay {
    /// "⌃⇧" for the Control+Shift tap, "⌥⌘K" for combos, in the selected language for words.
    public static func string(for binding: HotkeyBinding, localizer: Localizer) -> String { unimplemented() }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/ShellCore/Onboarding.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Onboarding flow (PRD-R40-R42, PLT-R710-R712). The state machine is pure; App/ renders the screens.

public import AppModel
public import Foundation
public import InputHost

public enum OnboardingScreen: Int, Sendable, Hashable, CaseIterable {
    case welcome = 1, permission, typingMethod, switching, conflicts, importFrom, tryIt, done
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
}

public struct OnboardingFlow: Sendable, Hashable {
    public private(set) var screen: OnboardingScreen
    public init(inputs: OnboardingInputs) { unimplemented() }
    /// Screens 5 and 6 are skipped when their condition is false; screen 2 has no "Bỏ qua".
    public mutating func next(inputs: OnboardingInputs) { unimplemented() }
    public mutating func back() { unimplemented() }
    public mutating func skip(inputs: OnboardingInputs) { unimplemented() }
    public var canSkip: Bool { screen != .permission }
    /// Permission granted while on screen 2: advance within 1 s (PRD-R40 "Live state").
    public mutating func permissionChanged(_ status: PermissionStatus, inputs: OnboardingInputs) { unimplemented() }
}

/// PLT-R710: the app must run from /Applications or ~/Applications and not be translocated before asking for
/// permissions; otherwise offer to move itself and relaunch.
public enum AppLocationCheck {
    public enum Result: Sendable, Hashable {
        case ok
        case mustMove(reason: Reason)
    }

    public enum Reason: String, Sendable, Hashable { case translocated, readOnlyVolume, outsideApplications }

    public static func evaluate(bundleURL: URL, homeDirectory: URL, isOnReadOnlyVolume: Bool) -> Result {
        unimplemented()
    }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/ShellCore/BugReport.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Bug report sheet logic (PRD-R47-R49, PLT-R1204, PLT-R1205) and report assembly (PLT-R1202).

public import AppModel
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
}

public enum ReportAssembler {
    public static func report(
        identity: AppIdentity, system: SystemInfo, host: HostReportContext, settings: SettingsState,
        metrics: MetricsSnapshot, health: [HealthEvent], probe: LatencyProbeResult?, draft: BugReportDraft?,
        now: Date
    ) -> DiagnosticsReport { unimplemented() }
}

public enum BugReportComposer {
    /// GitHub issue-form URL with the summary in the body (the full block is copied to the clipboard after the
    /// sheet says so, PRD-R48). Repository URL is injected (VERIFY Pa's repository).
    public static func githubIssueURL(repository: URL, draft: BugReportDraft, report: DiagnosticsReport) -> URL {
        unimplemented()
    }

    /// Subject and body for the mail draft; the JSON report is attached by the App (PRD-R47).
    public static func mail(draft: BugReportDraft, report: DiagnosticsReport, localizer: Localizer)
        -> (subject: String, body: String)
    { unimplemented() }
}

/// Collects macOS version and build, architecture, model identifier (sysctl `hw.model`), languages.
public enum SystemInfoReader {
    public static func current(uiLanguage: InterfaceLanguage) -> SystemInfo { unimplemented() }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/ShellCore/AppsPane.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
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
}

/// PRD-R36: "Chế độ tương thích" under Advanced, at most three plain choices plus automatic. Choosing one writes
/// a user override (scope "this app", PLT-R540) and attaches it to the next bug report for that app.
public enum CompatibilityModeChoice: String, Sendable, Hashable, CaseIterable {
    case automatic  // reset to automatic (removes the override)
    case typeSlower  // backspaceReplace with 5 ms pacing
    case selectThenType  // selectReplace
    case pasteText  // paste, requiresUserOptIn, clipboard explanation (PLT-R460, PLT-R462)

    public func overrideRule(for bundle: BundleKey, date: String) -> JSONValue? { unimplemented() }
}

public enum AppsPaneModel {
    /// Most recent first: apps typed in (memory order) plus apps with explicit rules (PRD-R34).
    public static func rows(
        appModes: AppModesDocument, overrides: [StoredRuleOverride], matrix: MatrixDocument?, today: Date
    ) -> [AppsPaneRow] { unimplemented() }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/ShellCore/Services.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending

internal import AppModel
public import Foundation

/// Launch at login (PLT-R205, D17). Production: `SMAppService.mainApp` `status`, `register()`,
/// `unregister()`; `requiresApproval` opens System Settings > Login Items via `SMAppService.openSystemSettingsLoginItems()`.
public protocol LoginItemService: Sendable {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

public enum LoginItemStatus: String, Sendable, Hashable { case enabled, notRegistered, requiresApproval, notFound }

public struct SMAppServiceLoginItem: LoginItemService {
    public init() {}
    public var status: LoginItemStatus { unimplemented() }
    public func register() throws { unimplemented() }
    public func unregister() throws { unimplemented() }
    public func openSystemSettings() { unimplemented() }
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
    public static func route(_ url: URL, scheme: String) -> Route { unimplemented() }
}

/// Donation block (PRD-R59). Account details are placeholders until Pa verifies them; QR images are bundled
/// assets, never fetched.
public struct DonationInfo: Sendable, Hashable {
    public var bankAccountName: String  // VERIFY
    public var vietQRImageName: String  // asset catalog name
    public var momoQRImageName: String
    public var githubSponsorsURL: URL?  // VERIFY
    public static let placeholder = DonationInfo(
        bankAccountName: "VERIFY", vietQRImageName: "DonationVietQR", momoQRImageName: "DonationMoMo",
        githubSponsorsURL: nil)
}
```
<!-- /include -->

## 12. App: AppShell components and the Sparkle wrapper

Owned files: `App/Sources/Shell/**`, `App/Sources/Onboarding/**`, `App/Resources/Localization/{Common,Menu,Status,Onboarding}.xcstrings`,
`App/Resources/Assets.xcassets/**`, `App/Resources/SystemPanes.json` (W1-G); `App/Sources/Composition/**`
(W2-A); `App/Sources/Settings/**` and the `Settings`, `Macros`, `Apps`, `Support` tables (W2-B);
`App/Sources/Diagnostics/**` and the `Diagnostics` table (W2-C); `App/Sources/Updater/**` and the `Updates`
table (W2-D). Isolation: main actor throughout. Framework choice: [0305](../decisions/0305-ui-framework.md).

<!-- include: App/Sources/Composition/AppEnvironment.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Composition root (workstream W2-A). Builds every production service once, wires AppCore modules together
// and owns the window controllers. Main actor only.

import AppKit
import AppModel
import CompatRules
import Diagnostics
import Injection
import InputHost
import SettingsStore
import ShellCore

@MainActor
final class AppEnvironment {
    let brand: Brand
    let language: InterfaceLanguageModel
    let settingsStore: SettingsStore
    let host: InputHostController
    let statusItem: StatusItemController
    let updater: UpdaterController

    /// Launch order (S1 target 300 ms to tap active): LaunchGuard -> AppLocationCheck (move offer before any
    /// permission request, PLT-R710) -> SettingsStore.load -> RulesLoader.load(compat-rules.json) ->
    /// InputHostController.start -> StatusItemController -> onboarding if not completed (PRD-R40, PRD-R42)
    /// -> UpdaterController.start.
    init(bundle: Bundle) { unimplemented() }

    func start() { unimplemented() }
    /// Quit: flush settings (PLT-R1003), stop the host (tap removed), let Sparkle install on quit (D20).
    func terminate() { unimplemented() }
    /// `<slug>://...` opens Settings and nothing else (PLT-R909).
    func handle(url: URL) { unimplemented() }
}
```
<!-- /include -->

<!-- include: App/Sources/Shell/StatusItemController.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Menu-bar status item and menu (PRD-R9-R13), switch HUD (PRD-R12) and capture HUD (PLT-R905).
// Workstream W1-G.

import AppKit
import AppModel
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
    /// `menuModel` is called from `menuNeedsUpdate(_:)` so the menu is rebuilt on every open (PRD-R13).
    init(
        language: InterfaceLanguageModel, actions: any StatusMenuActions, menuModel: @escaping @MainActor () -> MenuModel
    ) { unimplemented() }

    /// Template image `StatusIconState.templateImageName` plus `accessibilityLabel` from the Menu table.
    func show(_ state: StatusIconState) { unimplemented() }
    /// D16: primary click toggles when enabled; the menu then opens on secondary click.
    func setClickToToggle(_ enabled: Bool) { unimplemented() }
    func menuNeedsUpdate(_ menu: NSMenu) { unimplemented() }
}

/// Non-activating panel near the bottom centre showing V or E for 600 ms; respects Reduce Motion; posts an
/// accessibility announcement; never shown for automatic per-app switches (PRD-R12, PRD-R66).
@MainActor
final class SwitchHUDController {
    init(language: InterfaceLanguageModel) { unimplemented() }
    func show(_ mode: TypingMode) { unimplemented() }
}

/// Floating countdown with a Stop button on all Spaces and above full-screen apps while a typing trace
/// records (PLT-R905).
@MainActor
final class CaptureHUDController {
    init(language: InterfaceLanguageModel, stop: @escaping @MainActor () -> Void) { unimplemented() }
    func show(remaining: Duration) { unimplemented() }
    func hide() { unimplemented() }
}
```
<!-- /include -->

<!-- include: App/Sources/Onboarding/OnboardingWindowController.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Onboarding window, 640 x 480 pt, centred, not floating, eight screens driven by ShellCore's OnboardingFlow
// (PRD-R40-R42). Workstream W1-G.

import AppKit
import AppModel
import InputHost
import ShellCore

@MainActor
protocol OnboardingActions: AnyObject {
    func openPermissionPane()  // deep link from SystemPanes.json (PLT-R704)
    func resetPermission()  // PLT-R740, after confirmation
    func relaunch()  // PLT-R712
    func setTypingMethod(_ method: TypingMethod)
    func setOpenAtLogin(_ enabled: Bool)
    func importMacros(from url: URL)
    func complete()
}

@MainActor
final class OnboardingWindowController: NSWindowController {
    required init?(coder: NSCoder) { unimplemented() }

    /// `startAt: .permission` for the "permission lost" variant (PRD-R42) and for resuming (PRD-R41).
    init(
        flow: OnboardingFlow, language: InterfaceLanguageModel, actions: any OnboardingActions,
        inputs: @escaping @MainActor () -> OnboardingInputs
    ) { unimplemented() }

    /// Called by the permission monitor (1 s polling while visible, PLT-R711).
    func permissionChanged(_ status: PermissionStatus) { unimplemented() }
}
```
<!-- /include -->

<!-- include: App/Sources/Settings/SettingsWindowController.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Settings window with at most five panes (PRD-R24-R28), macros editor (PRD-R29-R33) and Apps pane
// (PRD-R34-R38). Workstream W2-B.

import AppKit
import AppModel
import SettingsStore
import ShellCore

enum SettingsPane: String, CaseIterable {
    case general, typing, apps, macros, aboutSupport
}

@MainActor
final class SettingsWindowController: NSWindowController {
    required init?(coder: NSCoder) { unimplemented() }

    init(
        store: SettingsStore, language: InterfaceLanguageModel, updater: any UpdaterControlling,
        loginItem: any LoginItemService
    ) { unimplemented() }

    func show(_ pane: SettingsPane) { unimplemented() }
}
```
<!-- /include -->

<!-- include: App/Sources/Diagnostics/DiagnosticsWindowController.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Diagnostics window (PLT-R1201), "This app misbehaves" flow (PLT-R1205), bug report sheet (PRD-R47-R49),
// typing trace review (PLT-R905) and latency probe window (PLT-R810). Workstream W2-C.

import AppKit
import AppModel
import Diagnostics
import ShellCore

@MainActor
final class DiagnosticsWindowController: NSWindowController {
    required init?(coder: NSCoder) { unimplemented() }

    init(language: InterfaceLanguageModel, report: @escaping @MainActor () -> DiagnosticsReport) { unimplemented() }
    func showReport() { unimplemented() }
    func startMisbehavesFlow(for bundle: BundleKey?) { unimplemented() }
    func startTypingTrace() { unimplemented() }
    func runLatencyProbe() { unimplemented() }
}

@MainActor
final class BugReportController: NSWindowController {
    required init?(coder: NSCoder) { unimplemented() }

    /// Shows the exact redacted text before anything is copied or saved (PLT-R1204, PRD-R48).
    init(draft: BugReportDraft, report: DiagnosticsReport, language: InterfaceLanguageModel) { unimplemented() }
}
```
<!-- /include -->

<!-- include: App/Sources/Updater/UpdaterController.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Thin wrapper around Sparkle 2 (PLT-R1101-R1110, PRD-R50-R55, docs/decisions/0304-sparkle-version-pin.md).
// Workstream W2-D.

import AppKit
import AppModel
import ShellCore
import Sparkle

@MainActor
final class UpdaterController: NSObject, UpdaterControlling {
    /// `idleState` answers "seconds since the last key press, and is secure input on?" for the relaunch policy
    /// (PLT-R1105).
    init(idleState: @escaping @MainActor () -> (secondsSinceLastKey: Double, secureInputOn: Bool)) {
        unimplemented()
    }

    func start() { unimplemented() }

    var canCheckForUpdates: Bool { unimplemented() }
    var automaticallyChecksForUpdates: Bool {
        get { unimplemented() }
        set { unimplemented() }
    }
    var automaticallyDownloadsUpdates: Bool {
        get { unimplemented() }
        set { unimplemented() }
    }
    var channel: UpdateChannelSelection {
        get { unimplemented() }
        set { unimplemented() }
    }
    func checkForUpdates() { unimplemented() }
}

extension UpdaterController: SPUUpdaterDelegate {
    /// `["beta"]` only after the user opted in (PLT-R1101, PRD-R53).
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> { unimplemented() }

    /// Install on quit by default; call `immediateInstallHandler` only after 60 s without a key press and with
    /// secure input off (PLT-R1105).
    nonisolated func updater(
        _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool { unimplemented() }
}
```
<!-- /include -->

## 13. TestSupport and CompatHarness

Owned files: `Sources/TestSupport/Fakes/<Area>/**` per area owner (Diagnostics W1-A, Settings W1-B, Rules
W1-C, Injection W1-D, Host W1-E), `Sources/TestSupport/Pipeline/**` (W1-F), `Sources/TestSupport/Scenario/**`,
`Sources/CompatHarness/**`, `Tests/TestSupportTests/**`, `compat/scenarios/**` (W1-H).
`Sources/TestSupport/Fakes/Common/**` is skeleton-provided and frozen. Isolation: test code; fakes are
`Sendable` so they can stand in for production services on any thread.

`compat-harness` (executable) runs only on the self-hosted runner: `compat-harness run --scenarios
compat/scenarios --profile normal|fast|burst --report out.json`. It posts physical-like events from its own
process, so the app treats them as physical input.

<!-- include: Packages/AppCore/Sources/TestSupport/Fakes/Injection/InjectionFakes.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending

internal import AppModel
public import Injection
internal import RealtimeSupport

/// Records every posted event; optionally forwards it to a sink (simulated field, echo loopback).
public final class FakeEventPoster: EventPoster, Sendable {
    public enum Posted: Sendable, Hashable {
        case synthetic(SyntheticKeyEvent, userData: Int64)
        case replay(KeyEventRecord, userData: Int64)
    }

    public init(sink: (@Sendable (Posted) -> Void)? = nil) { unimplemented() }
    public var posted: [Posted] { unimplemented() }
    /// Makes subsequent posts throw `.notPermitted` (fail-open tests, PLT-R730).
    public func revokePermission() { unimplemented() }
    public func post(_ event: SyntheticKeyEvent, userData: Int64) throws(PostError) { unimplemented() }
    public func replay(_ record: KeyEventRecord, userData: Int64) throws(PostError) { unimplemented() }
}

/// AX field access backed by a `SimulatedTextField`; can time out or be unavailable on demand.
public final class FakeFocusedFieldAccess: FocusedFieldAccess, Sendable {
    public enum Behaviour: Sendable { case normal, timeout, unavailable, writesIgnored }
    public init(field: SimulatedTextField, behaviour: Behaviour = .normal) { unimplemented() }
    public func selectedRange(_ field: FieldHandle, timeout: Duration) -> AXCallResult<TextRange> { unimplemented() }
    public func text(_ field: FieldHandle, in range: TextRange, timeout: Duration) -> AXCallResult<String> {
        unimplemented()
    }
    public func setSelectedRange(_ field: FieldHandle, to range: TextRange, timeout: Duration) -> AXCallResult<Void> {
        unimplemented()
    }
    public func setSelectedText(_ field: FieldHandle, to text: String, timeout: Duration) -> AXCallResult<Void> {
        unimplemented()
    }
}

/// Multi-item, multi-type pasteboard with file promises and lazy data for PLT-R461 tests.
public final class FakePasteboard: PasteboardAccess, Sendable {
    public init(items: [PasteboardItemData] = []) { unimplemented() }
    public var changeCount: Int { unimplemented() }
    public var items: [PasteboardItemData] { unimplemented() }
    /// Simulates the user copying something during the restore window.
    public func userCopies(_ item: PasteboardItemData) { unimplemented() }
    public func snapshot(limits: PasteboardLimits) throws(PasteboardError) -> PasteboardSnapshot { unimplemented() }
    public func writeTransient(_ text: String) throws(PasteboardError) -> Int { unimplemented() }
    public func restore(_ snapshot: PasteboardSnapshot) throws(PasteboardError) { unimplemented() }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/TestSupport/Fakes/Host/HostFakes.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending

public import AppModel
public import CompatRules
public import Foundation
public import InputHost
public import Injection
public import CoreGraphics

public final class FakeAXProvider: AXProvider, Sendable {
    public init() { unimplemented() }
    /// Sets the focused app/element; posts the given notification to observers.
    public func focus(pid: Int32, attributes: FocusAttributes, notify: AXNotificationKind?) { unimplemented() }
    public func setTimingOut(pid: Int32, _ timingOut: Bool) { unimplemented() }
    public func systemWideFocus() -> AXCallResult<AXFocusedElement?> { unimplemented() }
    public func attributes(of element: AXFocusedElement, request: AXAttributeRequest) -> AXCallResult<FocusAttributes> {
        unimplemented()
    }
    public func observe(
        pid: Int32, notifications: Set<AXNotificationKind>, handler: @escaping @Sendable (AXNotificationKind) -> Void
    ) -> (any AXObservation)? { unimplemented() }
    public func enableManualAccessibility(pid: Int32) -> Bool { unimplemented() }
    public var manualAccessibilityRequests: [Int32] { unimplemented() }
}

public final class FakeProcessIdentityProvider: ProcessIdentityProvider, Sendable {
    public init(processes: [ProcessIdentity]) { unimplemented() }
    public func identity(of pid: Int32) -> ProcessIdentity? { unimplemented() }
    public func isAlive(_ pid: Int32) -> Bool { unimplemented() }
    public func runningApplications() -> [ProcessIdentity] { unimplemented() }
}

public final class FakeSecureInputProbe: SecureInputProbe, Sendable {
    public init() { unimplemented() }
    public func set(enabled: Bool, holderPID: Int32?) { unimplemented() }
    public func isSecureEventInputEnabled() -> Bool { unimplemented() }
    public func secureInputHolderPID() -> Int32? { unimplemented() }
}

public final class FakePermissionProbe: PermissionProbe, Sendable {
    public init(trusted: Bool = true, post: Bool = true, listen: Bool = true) { unimplemented() }
    public func set(trusted: Bool, post: Bool, listen: Bool) { unimplemented() }
    public func isAccessibilityTrusted() -> Bool { unimplemented() }
    public func canPostEvents() -> Bool { unimplemented() }
    public func canListenToEvents() -> Bool { unimplemented() }
    public func promptForAccessibility() { unimplemented() }
    public func requestListenEventAccess() -> Bool { unimplemented() }
    public func requestPostEventAccess() -> Bool { unimplemented() }
    public func signingIdentityDigest() -> String? { unimplemented() }
}

@MainActor
public final class FakeInputSourceProvider: InputSourceProvider {
    public init(current: InputSourceInfo, layouts: [InputSourceID: KeyboardLayoutData]) { unimplemented() }
    public func select(_ source: InputSourceInfo) { unimplemented() }
    public func currentSource() -> InputSourceInfo { unimplemented() }
    public func currentLayoutData() -> KeyboardLayoutData? { unimplemented() }
    public func enabledSources() -> [InputSourceInfo] { unimplemented() }
    public func layoutData(for id: InputSourceID) -> KeyboardLayoutData? { unimplemented() }
    public func currentKeyboardType() -> UInt32 { unimplemented() }
    public func observeChanges(_ handler: @escaping @MainActor @Sendable () -> Void) -> any ObservationToken {
        unimplemented()
    }
}

@MainActor
public final class FakeWorkspaceEvents: WorkspaceEvents {
    public init() { unimplemented() }
    public func send(_ event: WorkspaceEvent) { unimplemented() }
    public func observe(_ handler: @escaping @MainActor @Sendable (WorkspaceEvent) -> Void) -> any ObservationToken {
        unimplemented()
    }
}

/// Never creates a real tap; records enable/disable and lets tests invoke the callback path directly.
public final class FakeEventTapFactory: EventTapFactory, Sendable {
    public init(failCreation: Bool = false) { unimplemented() }
    public func makeTap(mask: TapEventMask, callback: CGEventTapCallBack, userInfo: UnsafeMutableRawPointer?)
        -> CFMachPort?
    { unimplemented() }
}

public final class FakeBundleInspector: BundleInspector, Sendable {
    public init(bundles: [URL: FakeBundle]) { unimplemented() }
    public struct FakeBundle: Sendable, Hashable {
        public var frameworks: [String]
        public var helpers: [String]
        public var files: [String]
        public var info: [String: JSONValue]
        public init(frameworks: [String], helpers: [String], files: [String], info: [String: JSONValue]) {
            self.frameworks = frameworks
            self.helpers = helpers
            self.files = files
            self.info = info
        }
    }

    public func frameworkNames(in bundle: URL) -> [String] { unimplemented() }
    public func helperAppNames(in bundle: URL) -> [String] { unimplemented() }
    public func containsFile(named name: String, in bundle: URL, maxDepth: Int) -> Bool { unimplemented() }
    public func infoDictionary(of bundle: URL) -> [String: JSONValue]? { unimplemented() }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/TestSupport/Fakes/Rules/RulesFakes.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending

public import AppModel
public import CompatRules
public import Foundation
public import InputHost

/// Scripted decision resolver so focus tests do not depend on the rules implementation.
public final class FakeDecisionResolver: FocusDecisionResolving, Sendable {
    public init(decisions: [BundleKey: ResolvedDecision], fallback: ResolvedDecision) { unimplemented() }
    public func resolve(_ context: MatchContext) -> ResolvedDecision { unimplemented() }
    public var overlayBundles: Set<BundleKey> { unimplemented() }
    public var titlePatternBundles: Set<BundleKey> { unimplemented() }
    public func fingerprint(bundleURL: URL, bundle: BundleKey) -> EngineFingerprint { unimplemented() }
    /// A default decision equivalent to the 5.4 `defaults` block.
    public static func defaultDecision(engine: EngineFingerprint) -> ResolvedDecision { unimplemented() }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/TestSupport/Pipeline/PipelineSupport.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Pipeline property-test support (13.1): scripted engine, simulated text field, deterministic harness,
// conservation ledger and seeded event generator.

internal import AppModel
public import Injection
public import InputHost
internal import RealtimeSupport
public import VietnameseEngine

/// Scripted engine: maps typed characters to edits with a tiny Telex-like table (aa -> â, s -> acute on the
/// last vowel, w -> ư), enough to exercise deletes and inserts without the real engine.
public struct ScriptedEngine: CompositionEngine {
    public init() { unimplemented() }
    public mutating func handle(_ event: EngineEvent) -> EngineOutput { unimplemented() }
    public var activeDisplay: String { unimplemented() }
}

public struct ScriptedEngineFactory: CompositionEngineFactory {
    public init() {}
    public func makeEngine(for variant: EngineVariant, settings: TapSettingsSnapshot) -> ScriptedEngine { ScriptedEngine() }
}

/// Text field model: caret, selection, inline-completion suggestion, secure flag, per-event processing,
/// optional asynchronous reordering. Applies synthetic and replayed events exactly as a Cocoa field would.
public final class SimulatedTextField: Sendable {
    public enum Behaviour: Sendable, Hashable {
        case cocoa
        case inlineCompletion(suggestions: [String])  // address bar, Spotlight, Sheets
        case dropsFirstEventAfterFocus  // edit-mode transition
        case ignoresUnicodePayload  // remote clients: types keycode letters
        case terminalReadsInBatches(maxEventsPerRead: Int)
    }

    public init(behaviour: Behaviour = .cocoa) { unimplemented() }
    public var text: String { unimplemented() }
    public var selection: TextRange { unimplemented() }
    public func apply(_ event: SyntheticKeyEvent) { unimplemented() }
    public func apply(_ record: KeyEventRecord, layout: LayoutTable) { unimplemented() }
    public func click(at offset: Int) { unimplemented() }
    public func reset() { unimplemented() }
}

/// What happened to each physical event (PLT-R312).
public final class ConservationLedger: Sendable {
    public struct Violation: Sendable, Hashable, CustomStringConvertible {
        public var eventIndex: Int
        public var reason: String
        public var description: String { "event \(eventIndex): \(reason)" }
    }

    public init() { unimplemented() }
    public func physical(_ index: Int, _ event: RawKeyEvent, outcome: EventOutcome?) { unimplemented() }
    public func delivered(_ record: KeyEventRecord, asReplayOf index: Int) { unimplemented() }
    public func passedThrough(_ index: Int) { unimplemented() }
    /// Exactly one outcome per physical keyboard event, replays once and in order, keyUp pairing (PLT-R313).
    public func violations() -> [Violation] { unimplemented() }
}

/// Seeded random interleavings of keys, mouse downs, focus changes, tap-disabled events, secure-input
/// toggles and permission changes (section 3 acceptance: 100,000 sequences).
public struct RandomEventGenerator: Sendable {
    public enum Step: Sendable, Hashable {
        case key(RawKeyEvent)
        case focusChange
        case secureInput(Bool)
        case permission(Bool)
        case advanceMicroseconds(UInt64)
        case workerRuns(maxJobs: Int)
    }

    public init(seed: UInt64) { unimplemented() }
    public mutating func sequence(length: Int) -> [Step] { unimplemented() }
}

/// Wires a `KeyPipeline<ScriptedEngineFactory, ManualClock>` and an `InjectionWorker` in deterministic mode
/// to a `FakeEventPoster` whose events loop back into the pipeline as echoes and into a `SimulatedTextField`.
public final class PipelineHarness {
    public init(field: SimulatedTextField, layout: LayoutTable, clock: ManualClock) { unimplemented() }
    public func run(_ steps: [RandomEventGenerator.Step]) { unimplemented() }
    public var ledger: ConservationLedger { unimplemented() }
    public var field: SimulatedTextField { unimplemented() }
}
```
<!-- /include -->

<!-- include: Packages/AppCore/Sources/TestSupport/Scenario/Scenario.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Compatibility scenario files (PLT-R530): `compat/scenarios/<id>.json`, schema
// compat/schema/scenario.schema.json. Executed by `compat-harness` on the self-hosted runner only.

public import AppModel
public import Foundation

public struct Scenario: Sendable, Hashable, Codable {
    public enum TimingProfile: String, Sendable, Hashable, Codable { case normal, fast, burst }
    public enum Readback: String, Sendable, Hashable, Codable { case ax, webdriver, terminalCapture, human }
    public enum Method: String, Sendable, Hashable, Codable { case telex, vni }

    public struct SetupStep: Sendable, Hashable, Codable {
        public enum Action: String, Sendable, Hashable, Codable {
            case launch, openURL, seedHistory, focusField, selectInputSource, setSecureInput, wait
        }

        public var action: Action
        public var value: String?
    }

    public struct Expectation: Sendable, Hashable, Codable {
        public var text: String?
        public var paused: Bool?
        public var holderBundleId: BundleKey?
        public var firstKeyAfterReleaseComposed: Bool?
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
}

public struct ScenarioRunner: Sendable {
    public init(driver: any KeyboardDriver, readback: any ScenarioReadback) { unimplemented() }
    public func run(_ scenario: Scenario) async -> ScenarioResult { unimplemented() }
    public static func load(directory: URL) throws -> [Scenario] { unimplemented() }
}
```
<!-- /include -->

## 14. TestHost app (QA-R10)

Owned files: `TestHost/**` (W1-H). A normal AppKit app (`TestHost` target, bundle ID `<dev bundle
ID>.testhost`) with one window per field kind; every field exposes its text through AX by accessibility
identifier, web fields mirror their DOM value into a native field. Local test pages under
`TestHost/Resources/Pages/` reproduce inline autocomplete, a first-keystroke edit-mode transition and a
contenteditable composer without network resources (13.2); the same files are served to real browsers on the
self-hosted runner.

<!-- include: TestHost/Sources/TestHostFields.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
//
// QA-R10 contract: each field exposes its current text to the runner through AX (`AXValue` of the element
// with this accessibility identifier). Web fields mirror their DOM value into a hidden native field through a
// WKScriptMessageHandler so AX readback works the same way. Workstream W1-H.

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
}

@MainActor
final class TestHostWindowController: NSWindowController {
    required init?(coder: NSCoder) { fatalError("not used") }

    init() { fatalError("W1-H") }
    func reset(_ field: TestHostField) { fatalError("W1-H") }
    func text(of field: TestHostField) -> String { fatalError("W1-H") }
}
```
<!-- /include -->

## 15. SpikeIMK (spike S1, PLT-R398D)

Owned files: `SpikeIMK/**` (W1-H). Question: does an InputMethodKit input method still receive key events in
iTerm2 and Terminal.app while secure keyboard entry is on (event taps do not, Apple TN2150)? The spike is an
`IMKServer` with one `IMKInputController` subclass that counts `handle(_:client:)` calls with and without
`IsSecureEventInputEnabled()`, inserts a visible test character on a chosen key to prove it can also commit
text, and shows the counters in its input menu (`menu()`); it logs counts only, never characters. It never
creates an event tap or posts CGEvents (PLT-R207). Pa builds it, copies `SpikeIMK.app` to
`~/Library/Input Methods/`, enables it in System Settings > Keyboard > Input Sources, and follows
`SpikeIMK/README.md`; the result is recorded as `docs/decisions/03xx-spike-s1-result.md` (PLT-R398D). The
bundle ID contains `.inputmethod.` (VERIFY whether still required on macOS 27).

<!-- include: SpikeIMK/Sources/main.swift -->
```swift
// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Spike S1 (PLT-R398D). SKELETON: workstream W1-H completes the counters, the input menu and the README with
// run instructions for Pa. This bundle never creates an event tap and never posts CGEvents (PLT-R207).

import AppKit
import InputMethodKit

@objc(SpikeInputController)
final class SpikeInputController: IMKInputController {
    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        false  // W1-H: count events, note IsSecureEventInputEnabled(), optionally insert a test character.
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
<!-- SPDX-License-Identifier: LicenseRef-App-Pending -->
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
