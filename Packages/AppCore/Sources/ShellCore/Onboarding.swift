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
