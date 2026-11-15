// SPDX-License-Identifier: GPL-3.0-or-later
//
// Retest of 15/11/2026, items 7 and 9 (PLT-R389, PLT-R353, PLT-R420): on macOS 27.2 Command+Space opens the search
// field of the Siri app (`com.apple.campo`), not of `com.apple.Spotlight`. The dev trace showed that field with no
// rule (`rule -`), so edits ran without the `axSelection` handling ("vieêệt", "teẽext") and Escape restored the
// word ("vieệeejt"). The other focus tests use fake resolvers, which is why the missing bundle went unnoticed:
// these resolve the shipped compat/rules.json, follow the published decision into the tap and check that Escape
// passes there. Bundle IDs are test fixtures checked against compat/rules.json (PLT-R501).

import AppModel
import CompatRules
import Foundation
import Injection
import RealtimeSupport
import TestSupport
import Testing

@testable import InputHost

private typealias F = FocusFixtures

@Suite("Spotlight with the shipped rules (retest of 15/11/2026, items 7 and 9)", .serialized)
struct FocusSpotlightSeededRulesTests {
    static let sirifiedSpotlightPID: Int32 = 210
    static let sirifiedSpotlight = BundleKey(rawValue: "com.apple.campo")!
    static let escape = HotkeyBinding.key(KeyCode(rawValue: Key.escape))

    struct Panel: Sendable, CustomTestStringConvertible {
        let pid: Int32
        let bundle: BundleKey
        let name: String
        var testDescription: String { bundle.rawValue }
    }

    static let panels = [
        Panel(pid: sirifiedSpotlightPID, bundle: sirifiedSpotlight, name: "Siri"),
        Panel(pid: F.spotlightPID, bundle: F.spotlight, name: "Spotlight"),
    ]

    /// The shipped compat/rules.json as the focus tracker sees it; the fixtures' bundles are not on disk, so their
    /// engine is given (native, as their Info.plist shows).
    private func seededRules() throws -> CountingFocusResolver {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }  // up to the repository root
        let document = try RulesLoader.decode(Data(contentsOf: root.appendingPathComponent("compat/rules.json")))
        let rules = try RuleSet(document: document, overrides: [], optedIn: [])
        return CountingFocusResolver(
            rules,
            fingerprints: [Self.sirifiedSpotlight: .native, F.spotlight: .native, F.zalo: .native, F.terminal: .native])
    }

    private static func searchField() -> FocusAttributes {
        F.attributes(role: "AXTextField", subrole: "AXSearchField", identifier: "search")
    }

    private func openPanel(_ panel: Panel, harness: FocusHarness) {
        _ = harness.inbox.push(.revalidateFocusAfterTrigger)  // Command+Space (PLT-R389)
        harness.tracker.drainInbox()
        harness.sync()
        harness.advance(by: .milliseconds(66))  // the trace: the field had the focus 66 ms after the shortcut
        harness.ax.focus(pid: panel.pid, attributes: Self.searchField(), notify: nil, element: 20)
        harness.advance(by: FocusSettle.triggerDelays[FocusSettle.triggerDelays.count - 1])
    }

    /// The published decision of the panel's field is `launcher.spotlight`: overlay, inline completion read through
    /// AX, no restore key and no revision (PLT-R353, PLT-R357, T5.8).
    @Test(arguments: panels)
    func theSpotlightRuleAppliesToThePanelsField(_ panel: Panel) throws {
        let harness = FocusHarness(scheduled: true)
        defer { harness.finish() }
        harness.processes.add(
            FakeProcessIdentityProvider.process(pid: panel.pid, bundle: panel.bundle.rawValue, name: panel.name))
        harness.ax.focus(pid: F.zaloPID, attributes: F.attributes(), notify: nil, element: 1)
        harness.start(try seededRules())
        #expect(harness.snapshot.decision.restoreHotkeyEnabled)  // the document's app keeps Escape
        openPanel(panel, harness: harness)
        let snapshot = harness.snapshot
        #expect(snapshot.app?.bundle == panel.bundle)
        #expect(snapshot.decision.rule == RuleID(rawValue: "launcher.spotlight"))
        #expect(snapshot.decision.overlay)
        #expect(!snapshot.decision.restoreHotkeyEnabled)
        #expect(snapshot.decision.plan.parameters.inlineCompletion == .axSelection)
    }

    /// End to end on the tap: with the published decision, a composing edit carries the `axSelection` handling
    /// (the worker removes a selected completion first, PLT-R420), and Escape with an open word passes to the panel
    /// as a boundary, with no restore job (T5.8).
    @Test(arguments: panels)
    func escapePassesToThePanelAndEditsHandleTheCompletion(_ panel: Panel) throws {
        let harness = FocusHarness(scheduled: true)
        defer { harness.finish() }
        harness.processes.add(
            FakeProcessIdentityProvider.process(pid: panel.pid, bundle: panel.bundle.rawValue, name: panel.name))
        harness.ax.focus(pid: F.zaloPID, attributes: F.attributes(), notify: nil, element: 1)
        harness.start(try seededRules())
        openPanel(panel, harness: harness)
        let fixture = PipelineFixture(
            settings: PipelineFixtures.settings(restore: Self.escape), focus: harness.snapshot)
        fixture.press(Key.a)
        fixture.press(Key.a)  // "aa" -> "â": one deletion
        let edit = try #require(fixture.completeJobs().compactMap(\.edit).first)
        #expect(edit.deleteCount == 1 && edit.plan.parameters.inlineCompletion == .axSelection)
        #expect(fixture.keyDown(Key.escape) == .pass)
        #expect(fixture.keyUp(Key.escape) == .pass)
        #expect(fixture.popJobs().allSatisfy { $0.edit == nil })
        #expect(!fixture.log.feeds.contains(.restoreToggle))
    }
}
