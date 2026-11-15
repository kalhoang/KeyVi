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

/// Where the focus owner's identity came from (PLT-R381 and its amendment of 2026-11-15).
public enum FocusedAppSource: String, Sendable, Hashable, Codable {
    /// The system-wide AX focused application: authoritative, with the focused element.
    case accessibility
    /// NSWorkspace's frontmost application, taken because AX answered but named no focused application. A weaker
    /// identity: bundle-level rules, the app's mode and its per-app settings apply; the snapshot has no element, so
    /// no rule that needs an AX role, subrole or other field fact matches.
    case frontmostApplication
}

/// The focus owner (PLT-R381): the system-wide AX focused application, which can be a non-activating panel, or the
/// frontmost application when AX names none (`source`).
public struct FocusedApp: Sendable, Hashable {
    public var pid: Int32
    public var bundle: BundleKey
    public var appVersion: LooseVersion?
    public var engine: EngineFingerprint
    public var source: FocusedAppSource
    public init(
        pid: Int32, bundle: BundleKey, appVersion: LooseVersion?, engine: EngineFingerprint,
        source: FocusedAppSource = .accessibility
    ) {
        self.pid = pid
        self.bundle = bundle
        self.appVersion = appVersion
        self.engine = engine
        self.source = source
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
    /// The rule allows revising the previous word (`features.lookaheadRevision`, PLT-R357); the engine gets it
    /// ANDed with the user's D29 (ENG-R829).
    public var lookaheadRevision: Bool
    public init(appContext: EngineContextKind, englishRestore: Bool, macros: Bool, lookaheadRevision: Bool = true) {
        self.appContext = appContext
        self.englishRestore = englishRestore
        self.macros = macros
        self.lookaheadRevision = lookaheadRevision
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
