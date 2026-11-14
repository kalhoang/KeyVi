// SPDX-License-Identifier: GPL-3.0-or-later
//
// Testable content of the onboarding screens: the try-it checklist (PRD-R40 screen 7), the permission screen's
// instructions in the macOS language (PRD-R40 screen 2, PRD-R64, PLT-R702, PLT-R740) and the move offer copy
// (PLT-R710). The App's SwiftUI views only lay these out.

public import AppModel
internal import Foundation
public import InputHost

/// PRD-R40 screen 7: three items that tick when done. Typed text stays in memory and is never logged (PLT-R901).
public struct TryItChecklist: Sendable, Hashable {
    public enum Item: String, Sendable, Hashable, CaseIterable {
        case typeVietnamese, typeEnglishWords, toggleAndBack
    }

    public private(set) var completed: Set<Item> = []
    private let vietnameseTarget: String
    private let englishTarget: String
    private let startMode: TypingMode
    private var toggledAway = false

    /// Targets come from the catalog (`onboarding.tryIt.target.*`) so no copy is hard-coded.
    public init(vietnameseTarget: String, englishTarget: String, startMode: TypingMode) {
        self.vietnameseTarget = vietnameseTarget.precomposedStringWithCanonicalMapping
        self.englishTarget = englishTarget
        self.startMode = startMode
    }

    public var isComplete: Bool { completed.count == Item.allCases.count }

    public mutating func textChanged(_ text: String) {
        let composed = text.precomposedStringWithCanonicalMapping
        // Case-insensitive but diacritic-sensitive: "tieng viet" must not tick the Vietnamese item.
        if composed.range(of: vietnameseTarget, options: .caseInsensitive) != nil { completed.insert(.typeVietnamese) }
        if composed.range(of: englishTarget, options: .caseInsensitive) != nil { completed.insert(.typeEnglishWords) }
    }

    /// "Press the toggle hotkey once and back": ticks when the mode leaves the starting mode and returns.
    public mutating func modeChanged(to mode: TypingMode) {
        if mode != startMode {
            toggledAway = true
        } else if toggledAway {
            completed.insert(.toggleAndBack)
        }
    }
}

/// Screen 2 text in the interface language with pane names in the macOS language (PRD-R64). One row per needed
/// permission with its live state; the instruction and the primary button name the pane of the first permission
/// still missing and open exactly that pane (Pa, 2026-11-14, feedback item 1; PLT-R701, PLT-R702, PLT-R704).
public struct PermissionScreenContent: Sendable, Hashable {
    public var title: String
    public var body: String
    public var bullets: [String]
    public var rows: [PermissionRowContent]
    /// The permission the primary button opens; nil once every row is granted.
    public var firstMissing: NeededPermission?
    public var instruction: String
    public var openPaneButton: String
    /// PRD-R42 line, shown in the permission-lost variant.
    public var lostNotice: String?
    /// PLT-R740 guidance when the grant went stale (typically after a macOS update).
    public var staleNotice: String?
    /// PLT-R702, PLT-R712: why Input Monitoring is needed, with the relaunch offer for a switch that is on but not
    /// yet effective.
    public var inputMonitoringNotice: String?
    public var relaunchButton: String?
    public var helpLink: String

    /// `inputMonitoringSeen`: the Input Monitoring row was needed earlier on this screen (`OnboardingFlow`), so it
    /// stays, as granted, once the need cleared.
    public init(
        localizer: Localizer, appName: String, panes: SystemPaneNames, status: PermissionStatus, permissionLost: Bool,
        inputMonitoringSeen: Bool = false
    ) {
        title = localizer.format(OnboardingText.permissionTitle, appName)
        body = localizer.format(OnboardingText.permissionBody, appName, panes.privacySecurity)
        bullets = [
            localizer.format(OnboardingText.permissionBulletKeysOnly, appName),
            localizer.string(OnboardingText.permissionBulletPasswords),
            localizer.string(OnboardingText.permissionBulletLocal),
        ]
        let needs = PermissionNeed.needs(status, inputMonitoringSeen: inputMonitoringSeen)
        rows = needs.map { PermissionRowContent($0, localizer: localizer, panes: panes) }
        firstMissing = needs.first { !$0.granted }?.permission
        let target = (firstMissing ?? .accessibility).paneName(panes)
        instruction = localizer.format(
            OnboardingText.permissionInstruction, panes.systemSettings, panes.privacySecurity, target, appName)
        openPaneButton = localizer.format(OnboardingText.permissionOpenPane, target)
        lostNotice = permissionLost ? localizer.format(OnboardingText.permissionLost, appName) : nil
        staleNotice = status.health == .stale ? localizer.format(OnboardingText.permissionStale, appName) : nil
        let needsInputMonitoring = needs.contains { $0.permission == .inputMonitoring && !$0.granted }
        inputMonitoringNotice =
            needsInputMonitoring
            ? localizer.format(OnboardingText.permissionInputMonitoring, panes.inputMonitoring, appName) : nil
        relaunchButton = needsInputMonitoring ? localizer.format(OnboardingText.permissionRelaunch, appName) : nil
        helpLink = localizer.format(OnboardingText.permissionHelpLink, appName)
    }
}

/// "Không thấy <App> trong danh sách?" sheet: remove and re-add, or reset only this app's entry (PLT-R740).
/// Never suggests `sudo` or a reset without a bundle ID (PLT-R741).
public struct PermissionHelpContent: Sendable, Hashable {
    public var title: String
    public var steps: [String]
    public var resetIntro: String
    public var resetButton: String
    public var confirmTitle: String
    public var confirmBody: String
    public var confirmButton: String
    /// PLT-R206: the built-in Vietnamese input source is the honest fallback without permission.
    public var fallback: String
    /// PLT-R740, PRD-R43: the reset did not run; the steps above (remove and add again) are the way on.
    public var resetFailed: String

    public init(localizer: Localizer, appName: String, panes: SystemPaneNames) {
        title = localizer.format(OnboardingText.helpTitle, appName)
        steps = [
            localizer.format(
                OnboardingText.helpStep1, panes.systemSettings, panes.privacySecurity, panes.accessibility),
            localizer.format(OnboardingText.helpStep2, appName),
            localizer.format(OnboardingText.helpStep3, appName),
        ]
        resetIntro = localizer.format(OnboardingText.helpResetIntro, appName)
        resetButton = localizer.string(OnboardingText.helpReset)
        confirmTitle = localizer.format(OnboardingText.helpConfirmTitle, appName)
        confirmBody = localizer.format(OnboardingText.helpConfirmBody, appName)
        confirmButton = localizer.string(OnboardingText.helpConfirm)
        fallback = localizer.string(OnboardingText.helpFallback)
        resetFailed = localizer.format(OnboardingText.helpResetFailed, appName)
    }
}

/// "Đặt lại quyền" after the user confirmed (PLT-R740): runs the reset scoped to the app's own bundle ID. A
/// failure (missing tool, refused bundle ID, non-zero exit, for example a renamed TCC service on a newer macOS)
/// is returned, never swallowed, so the sheet can say so (PRD-R43).
public enum PermissionReset {
    public enum Outcome: Sendable, Hashable { case reset, failed }

    public static func run(_ resetter: any PermissionResetting, bundleIdentifier: String) -> Outcome {
        do {
            try resetter.resetAccessibility(bundleIdentifier: bundleIdentifier)
            return .reset
        } catch {
            return .failed
        }
    }
}

/// PLT-R710 move offer, shown before any permission request when `AppLocationCheck` says `mustMove`.
public struct MoveOfferContent: Sendable, Hashable {
    public var title: String
    public var body: String
    public var confirm: String
    public var quit: String

    public init(localizer: Localizer, appName: String, reason: AppLocationCheck.Reason) {
        title = localizer.format(OnboardingText.moveTitle, appName)
        let key: OnboardingText =
            switch reason {
            case .translocated: .moveBodyTranslocated
            case .readOnlyVolume: .moveBodyReadOnlyVolume
            case .outsideApplications: .moveBodyOutsideApplications
            }
        body = localizer.format(key, appName)
        confirm = localizer.string(OnboardingText.moveConfirm)
        quit = localizer.string(OnboardingText.moveQuit)
    }
}
