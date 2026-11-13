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
    public static func iconState(state: HostState, mode: TypingMode, ignored: Bool, capturing: Bool)
        -> StatusIconState
    { unimplemented() }
}

/// One status line (PRD-R11 item 1, PRD-R43): message key, arguments and a single concrete action.
public struct StatusLine: Sendable, Hashable {
    public enum Action: Sendable, Hashable {
        case grantPermission, resumeOnboarding, showHolderApp(pid: Int32), secureInputHelp, reportProblem,
            learnMore(URL), none
        /// "paused: no text field detected" (02-platform.md section 6, custom text views): one click writes a
        /// user override with `requireTextFocus: never` for this app (PLT-R540).
        case overrideTextFocus(bundle: BundleKey)
        /// `failOpen(callbackStuck)`: only reopening the app recovers (ADR 0309).
        case reopenApp
    }

    public var key: String  // in the `Status` table
    public var arguments: [String]  // app names, source names, never typed content
    public var action: Action
    public init(key: String, arguments: [String], action: Action) {
        self.key = key
        self.arguments = arguments
        self.action = action
    }

    /// Precedence: host state lines (permission, secure input with holder and hint, fail-open, non-Latin
    /// source, built-in Vietnamese source, no text focus with override action) > tap re-enabled notice >
    /// "App in Known limitation list" for the frontmost app (PRD-R43) > nil.
    public static func forState(
        _ state: HostState, holderHintKey: String?, appName: String, frontmostApp: FrontmostAppStatus?,
        tapRecentlyReenabled: Bool
    ) -> StatusLine? {
        unimplemented()
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
