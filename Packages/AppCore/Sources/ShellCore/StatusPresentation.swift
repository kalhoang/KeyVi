// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Menu-bar icon states (PRD-R10), menu model (PRD-R11) and status lines (PRD-R43). Pure functions of host
// state, testable without AppKit.

public import AppModel
public import CompatRules
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

    private static func pausedIcon(_ reason: PauseReason, mode: TypingMode) -> StatusIconState {
        switch reason {
        case .secureInput, .secureField:
            return mode == .vietnamese ? .secureInputVietnamese : .secureInputEnglish
        case .passThroughRule:
            return .ignoredApp
        case .nonLatinInputSource, .builtInVietnameseSource, .sessionInactive, .userDisabled, .noTextFocus:
            return .paused
        }
    }

    /// VoiceOver label key for the status item (PLT-R211: the label is truthful about the reason). PRD-R10
    /// labels are used where they fit; the dimmed and slashed glyphs, which cover several states, get a
    /// reason-specific label otherwise.
    public static func accessibilityLabelKey(icon: StatusIconState, state: HostState) -> String {
        switch (icon, state) {
        case (.paused, .starting):
            return MenuText.iconStarting.rawValue
        case (.paused, .paused(.noTextFocus)):
            return MenuText.iconPausedNoTextFocus.rawValue
        case (.paused, .paused(.sessionInactive)), (.paused, .paused(.userDisabled)):
            return MenuText.iconPausedOther.rawValue
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
    /// source, built-in Vietnamese source, no text focus with override action) > tap re-enabled notice >
    /// "App in Known limitation list" for the frontmost app (PRD-R43) > nil.
    /// `onboardingCompleted == false` turns the permission action into "resume onboarding at screen 2"
    /// (PRD-R41).
    public static func forState(
        _ state: HostState, holderHintKey: String?, appName: String, frontmostApp: FrontmostAppStatus?,
        tapRecentlyReenabled: Bool, onboardingCompleted: Bool = true
    ) -> StatusLine? {
        let context = StatusLineBuilder(
            appName: appName, holderHintKey: holderHintKey, frontmostApp: frontmostApp,
            onboardingCompleted: onboardingCompleted)
        if let line = context.hostLine(for: state) { return line }
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
