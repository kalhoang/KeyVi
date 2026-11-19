// SPDX-License-Identifier: GPL-3.0-or-later
//
// 03-product.md D8, PRD-R18, PLT-R353 (decision of the product owner, 13/11/2026, Q14): Escape restores the last
// word by default. Where a compatibility rule switches the binding off (`features.restoreHotkey: false`), Escape
// passes through untouched and nothing is consumed: the rule decision is resolved on the ax thread and published
// in the focus snapshot, so the tap only reads one boolean (PLT-R304, PLT-R305, PLT-R523).

import AppModel
import CompatRules
import Foundation
import Injection
import RealtimeSupport
import SettingsStore
import TestSupport
import Testing

@testable import InputHost

@Suite("Restore hotkey default and rule exclusions (D8, PLT-R353)")
struct RestoreHotkeyDefaultTests {
    static let escape = HotkeyBinding.key(KeyCode(rawValue: Key.escape))

    private func publish(_ change: (inout UserSettings) -> Void = { _ in }) -> TapSettingsSnapshot {
        let cell = SnapshotCell(InputHostController.placeholderSettings, epoch: ReaderEpoch())
        let publisher = TapSettingsPublisher(cell: cell, logger: RecordingLogger(), loadBundled: { .empty })
        var user = UserSettings()
        change(&user)
        return publisher.publish(SettingsState(user: user, macros: [])).snapshot
    }

    /// Users who never set the key get Escape; an explicit "none" stays none; a recorded key stays.
    @Test func publishedBindingFollowsTheMigrationRule_D8() {
        #expect(publish().restoreHotkey == Self.escape)
        #expect(publish { $0.restoreHotkey = .set(nil) }.restoreHotkey == nil)
        let f5 = HotkeyBinding.key(KeyCode(rawValue: Key.f5))
        #expect(publish { $0.restoreHotkey = .set(f5) }.restoreHotkey == f5)
    }

    /// The default binding restores in an ordinary text field (ENG-R701).
    @Test func defaultEscapeRestoresInOrdinaryFields() throws {
        let fixture = PipelineFixture(settings: PipelineFixtures.settings(restore: Self.escape))
        fixture.typeKeys([Key.a, Key.a])
        fixture.completeJobs()
        #expect(fixture.keyDown(Key.escape) == .swallow)
        #expect(try #require(fixture.popJobs().first?.edit).kind == .restore)
    }

    /// Rule says no: Escape keyDown and keyUp pass untouched, the engine never sees a restore toggle, no job is
    /// queued, and the passed Escape is the usual hard boundary (PLT-R340).
    @Test func suppressedEscapePassesUntouchedAndConsumesNothing() {
        let fixture = PipelineFixture(
            settings: PipelineFixtures.settings(restore: Self.escape),
            focus: PipelineFixtures.focus(decision: PipelineFixtures.decision(restoreHotkeyEnabled: false)))
        fixture.typeKeys([Key.a, Key.a])
        fixture.completeJobs()
        #expect(fixture.keyDown(Key.escape) == .pass)
        #expect(fixture.lastOutcome != .consumedAsHotkey && fixture.lastOutcome != .consumedForEdit)
        #expect(fixture.keyUp(Key.escape) == .pass)
        #expect(fixture.lastOutcome != .consumedPairedKeyUp)
        #expect(fixture.popJobs().allSatisfy { $0.edit == nil })
        #expect(!fixture.log.feeds.contains(.restoreToggle))
        #expect(fixture.log.resets == [.shortcut])
        // A second press behaves the same way.
        #expect(fixture.keyDown(Key.escape) == .pass)
        #expect(fixture.keyUp(Key.escape) == .pass)
    }

    /// End to end from the shipped data: a terminal, an IDE, a code editor and a remote client resolve to a
    /// decision whose tap view switches the binding off, and an ordinary editor keeps it.
    @Test(arguments: [
        ("com.apple.Terminal", EngineFingerprint.native, false),
        ("com.jetbrains.intellij", .jvm, false),
        ("com.microsoft.VSCode", .electron, false),
        ("com.apple.dt.Xcode", .native, false),
        ("tv.parsec.www", .native, false),
        ("com.apple.TextEdit", .native, true),
        ("com.apple.Spotlight", .native, false),
    ])
    func shippedRulesReachTheTapDecision(bundle: String, engine: EngineFingerprint, enabled: Bool) throws {
        try expectTapDecision(bundle: bundle, engine: engine, domClasses: [], enabled: enabled)
    }

    /// The integrated terminal of a VS Code family editor resolves to its own, more specific rule
    /// (`editor.vscode.integratedTerminal`), which must switch the binding off as well.
    @Test(arguments: ["com.microsoft.VSCode", "com.vscodium", "com.todesktop.230313mzl4w4u92"])
    func vscodeIntegratedTerminalSwitchesTheBindingOff(bundle: String) throws {
        try expectTapDecision(bundle: bundle, engine: .electron, domClasses: ["xterm-helper-textarea"], enabled: false)
    }

    private func expectTapDecision(bundle: String, engine: EngineFingerprint, domClasses: [String], enabled: Bool)
        throws
    {
        let loaded = HostRig.shippedRules
        #expect(!loaded.usedEmbeddedDefaults)
        let rules = try RuleSet(document: loaded.document, overrides: [], optedIn: [])
        var context = MatchContext(
            bundle: BundleKey(rawValue: bundle), appVersion: nil, macOS: LooseVersion("27.1")!, engine: engine)
        context.domClasses = domClasses
        let decision = HostDecisionMapping.map(rules.resolve(context), engine: engine, optedIntoPaste: false)
        #expect(decision.restoreHotkeyEnabled == enabled)
        // ENG-R1119: the same feature selects the engine variant, so no word is corrected where the key is off.
        #expect(decision.variant.restoreHotkey == enabled)
    }
}
