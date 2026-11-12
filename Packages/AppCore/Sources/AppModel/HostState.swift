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
