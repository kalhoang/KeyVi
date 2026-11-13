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


