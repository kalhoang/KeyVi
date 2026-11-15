// SPDX-License-Identifier: GPL-3.0-or-later
//
// PRD-R28 (amended 15/11/2026, retest of beta 2): while a window of the app is open (shown or in the Dock) the app is
// a regular app, with a Dock icon, a place in the Command+Tab switcher and a main menu; with no such window it is a
// menu-bar app again (PLT-R201). Panels (the switch HUD, alerts), sheets and floating windows do not count on their
// own. The decision runs on the next main-queue turn after a window closes, so closing one window while another
// opens does not flash the Dock icon.

import Testing

@testable import ShellCore

private func window(
    titled: Bool = true, panel: Bool = false, sheet: Bool = false, normalLevel: Bool = true, visible: Bool = true,
    miniaturized: Bool = false
) -> UserWindowTraits {
    UserWindowTraits(
        isTitled: titled, isPanel: panel, isSheet: sheet, isNormalLevel: normalLevel, isVisible: visible,
        isMiniaturized: miniaturized)
}

@MainActor
private final class FakePolicy: ActivationPolicyApplying {
    var presence: AppPresence = .menuBarOnly
    private(set) var applied: [AppPresence] = []

    func apply(_ presence: AppPresence) {
        applied.append(presence)
        self.presence = presence
    }
}

@MainActor
private final class Rig {
    let policy = FakePolicy()
    var windows: [UserWindowTraits] = []
    var hidden = false
    var turns: [@MainActor () -> Void] = []
    lazy var coordinator = AppPresenceCoordinator(
        policy: policy, windows: { [unowned self] in windows }, isHidden: { [unowned self] in hidden },
        nextTurn: { [unowned self] work in turns.append(work) })

    func runNextTurn() {
        let pending = turns
        turns = []
        for work in pending { work() }
    }
}

@Suite struct AppPresenceRuleTests {
    @Test func noWindowIsMenuBarOnly() {
        #expect(AppPresence.presence(for: []) == .menuBarOnly)
    }

    @Test func aShownOrMinimizedUserWindowMakesARegularApp() {
        #expect(AppPresence.presence(for: [window()]) == .regular)
        #expect(AppPresence.presence(for: [window(visible: false, miniaturized: true)]) == .regular)
    }

    @Test func panelsSheetsFloatingAndClosedWindowsDoNotCount() {
        for traits in [
            window(panel: true), window(sheet: true), window(normalLevel: false), window(titled: false),
            window(visible: false),
        ] {
            #expect(AppPresence.presence(for: [traits]) == .menuBarOnly, "\(traits)")
        }
        #expect(AppPresence.presence(for: [window(panel: true), window()]) == .regular)
    }

    /// The Dock icon reopens the window the user left in the Dock; with none, it opens Settings.
    @Test func reopenOpensSettingsOnlyWhenNoWindowCanComeBack() {
        #expect(AppPresence.reopenOpensSettings(windows: [], hasVisibleWindows: false))
        #expect(!AppPresence.reopenOpensSettings(windows: [window()], hasVisibleWindows: true))
        #expect(
            !AppPresence.reopenOpensSettings(
                windows: [window(visible: false, miniaturized: true)], hasVisibleWindows: false))
        #expect(AppPresence.reopenOpensSettings(windows: [window(visible: false)], hasVisibleWindows: false))
    }
}

@MainActor
@Suite struct AppPresenceCoordinatorTests {
    @Test func presentingAWindowMakesTheAppRegularAtOnce() {
        let rig = Rig()
        rig.windows = [window()]
        rig.coordinator.update()
        #expect(rig.policy.applied == [.regular])
        #expect(rig.turns.isEmpty)
    }

    @Test func closingTheLastWindowReturnsToTheMenuBarOnTheNextTurn() {
        let rig = Rig()
        rig.windows = [window()]
        rig.coordinator.update()
        rig.coordinator.scheduleUpdate()  // willClose: the window is still on screen
        #expect(rig.policy.applied == [.regular])
        rig.windows = [window(visible: false)]
        rig.runNextTurn()
        #expect(rig.policy.applied == [.regular, .menuBarOnly])
    }

    /// Settings, then "Chẩn đoán...", then closing Settings: the Diagnostics window keeps the Dock icon.
    @Test func closingOneWindowWhileAnotherOpensKeepsTheAppRegular() {
        let rig = Rig()
        rig.windows = [window()]
        rig.coordinator.update()
        rig.coordinator.scheduleUpdate()
        rig.windows = [window(visible: false), window()]
        rig.runNextTurn()
        #expect(rig.policy.applied == [.regular])
    }

    @Test func updatesApplyOnlyChangesAndCoalesce() {
        let rig = Rig()
        rig.windows = [window()]
        rig.coordinator.update()
        rig.coordinator.update()
        rig.coordinator.scheduleUpdate()
        rig.coordinator.scheduleUpdate()
        #expect(rig.turns.count == 1)
        rig.runNextTurn()
        #expect(rig.policy.applied == [.regular])
    }

    /// Command+H hides every window: the app stays regular so the Dock icon and Command+Tab bring it back.
    @Test func aHiddenAppKeepsItsPresence() {
        let rig = Rig()
        rig.windows = [window()]
        rig.coordinator.update()
        rig.hidden = true
        rig.windows = [window(visible: false)]
        rig.coordinator.scheduleUpdate()
        rig.runNextTurn()
        rig.coordinator.update()
        #expect(rig.policy.applied == [.regular])
    }
}
