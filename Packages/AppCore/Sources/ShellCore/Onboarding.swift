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
    private var history: [OnboardingScreen] = []

    public init(inputs: OnboardingInputs) {
        self.init(inputs: inputs, startAt: .welcome)
    }

    /// `startAt: .permission` resumes at screen 2 (PRD-R41). The permission-lost variant always starts there.
    public init(inputs: OnboardingInputs, startAt: OnboardingScreen) {
        permissionOnly = inputs.permissionLostAfterCompletion
        screen = permissionOnly ? .permission : startAt
        permissionGranted = Self.isGranted(inputs.permission)
    }

    /// Screens 5 and 6 are skipped when their condition is false; screen 2 has no "Bỏ qua".
    public mutating func next(inputs: OnboardingInputs) {
        permissionGranted = Self.isGranted(inputs.permission)
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
    public mutating func permissionChanged(_ status: PermissionStatus, inputs: OnboardingInputs) {
        let wasGranted = permissionGranted
        permissionGranted = Self.isGranted(status)
        guard screen == .permission, permissionGranted, !wasGranted, !permissionOnly, !isFinished else { return }
        advance(inputs: inputs)
        advancedByGrant = true
    }

    /// Accessibility trusted and, when macOS demands it, Input Monitoring too (PLT-R701, PLT-R702).
    public static func isGranted(_ status: PermissionStatus) -> Bool { status.health == .ready }

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
