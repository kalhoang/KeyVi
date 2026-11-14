// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R381 amendment of 2026-11-15: when Accessibility answers but names no focused application (685 key downs of
// the product owner's trace of 15/11/2026 went to such an app), the focus tracker takes NSWorkspace's frontmost
// application as a weaker identity. Bundle-level rules, the app's mode and its per-app settings apply; nothing that
// needs the focused element does, and no AX call goes to the frontmost app's element. The system-wide AX focus still
// wins whenever it names an app, and a timed-out read stays app-less (PLT-R340 late focus change). Bundle IDs are
// test fixtures (PLT-R501).

import AppModel
import CompatRules
import Foundation
import RealtimeSupport
import SettingsStore
import Testing

@testable import InputHost
@testable import TestSupport

private typealias F = FocusFixtures

@Suite("FocusTracker frontmost-app fallback (PLT-R381 amendment)", .serialized)
struct FocusFrontmostFallbackTests {
    static let editorRule = "editor.sample"
    static let antigravityPID: Int32 = 700
    static let antigravity = BundleKey(rawValue: "com.google.antigravity")!

    private func rules() -> FakeDecisionResolver {
        F.resolver([F.code: F.decision(Self.editorRule, engine: .electron)])
    }

    /// The seeded compat/rules.json as the focus tracker sees it, with the Antigravity fixture fingerprinted as
    /// Electron (its bundle is not on disk).
    private func seededRules() throws -> CountingFocusResolver {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Services
            .deletingLastPathComponent()  // InputHostTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // AppCore
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // repository root
        let document = try RulesLoader.decode(Data(contentsOf: root.appendingPathComponent("compat/rules.json")))
        let rules = try RuleSet(document: document, overrides: [], optedIn: [])
        return CountingFocusResolver(rules, fingerprints: [Self.antigravity: .electron])
    }

    @Test func rulesResolveForTheFrontmostBundleWhenAXNamesNoApp() throws {
        let harness = FocusHarness()
        defer { harness.finish() }
        let rules = rules()
        harness.ax.clearFocusedApplication()
        harness.processes.setFrontmost(F.codePID)
        harness.start(rules)
        let snapshot = harness.snapshot
        let app = try #require(snapshot.app)
        #expect(app.pid == F.codePID && app.bundle == F.code && app.engine == .electron)
        #expect(app.source == .frontmostApplication)
        #expect(snapshot.decision.rule == RuleID(rawValue: Self.editorRule))
        #expect(harness.tracker.currentDecision()?.rule == RuleID(rawValue: Self.editorRule))
        #expect(rules.resolvedContexts.last?.bundle == F.code)
        // Field facts stay unknown: no element, no field handle, and no AX call to the frontmost app's element.
        #expect(snapshot.fieldHandle == nil && snapshot.field.role == nil)
        #expect(snapshot.field.axAvailability == .available)
        #expect(harness.ax.elementQueryCount(pid: F.codePID) == 0)
        #expect(harness.ax.attributeQueryCount(pid: F.codePID) == 0)
    }

    @Test func accessibilityWinsWhenItNamesAnApp() throws {
        let harness = FocusHarness()
        defer { harness.finish() }
        harness.processes.setFrontmost(F.codePID)
        harness.ax.focus(pid: F.zaloPID, attributes: F.attributes(), notify: nil)
        harness.start(rules())
        let app = try #require(harness.snapshot.app)
        #expect(app.bundle == F.zalo && app.source == .accessibility)
        #expect(harness.snapshot.fieldHandle?.pid == F.zaloPID)
        #expect(harness.snapshot.decision.rule == nil)
        // AX names the frontmost app again: its own identity replaces the fallback, with the field.
        harness.ax.clearFocusedApplication()
        harness.idleRevalidation()
        #expect(harness.snapshot.app?.source == .frontmostApplication)
        harness.ax.focus(pid: F.codePID, attributes: F.attributes(), notify: nil)
        harness.idleRevalidation()
        #expect(harness.snapshot.app?.bundle == F.code && harness.snapshot.app?.source == .accessibility)
        #expect(harness.snapshot.fieldHandle?.pid == F.codePID && harness.snapshot.field.role == "AXTextArea")
    }

    /// The integrated-terminal rule needs a DOM class of the focused element; on the fallback only the bundle-level
    /// editor rule can match, and the match context carries no field fact (seeded rules, Antigravity in the
    /// vscodeFamily group).
    @Test func noFieldLevelRuleMatchesOnTheFallback() throws {
        let harness = FocusHarness()
        defer { harness.finish() }
        harness.processes.add(
            FakeProcessIdentityProvider.process(
                pid: Self.antigravityPID, bundle: Self.antigravity.rawValue, name: "Antigravity"))
        let rules = try seededRules()
        let terminal = FocusAttributes(
            role: "AXTextArea", subrole: nil, identifier: "terminal", domClasses: ["xterm-helper-textarea"],
            editable: true, ancestorRoles: F.nativeAncestors, documentURL: nil, windowTitle: nil)
        harness.ax.focus(pid: Self.antigravityPID, attributes: terminal, notify: nil)
        harness.start(rules)
        #expect(harness.snapshot.decision.rule == RuleID(rawValue: "editor.vscode.integratedTerminal"))
        let elementReads = harness.ax.elementQueryCount(pid: Self.antigravityPID)
        let attributeReads = harness.ax.attributeQueryCount(pid: Self.antigravityPID)
        harness.ax.clearFocusedApplication()
        harness.processes.setFrontmost(Self.antigravityPID)
        harness.tracker.revalidate()
        harness.sync()
        #expect(harness.snapshot.app?.bundle == Self.antigravity)
        #expect(harness.snapshot.app?.source == .frontmostApplication)
        #expect(harness.snapshot.decision.rule == RuleID(rawValue: "editor.vscodeFamily"))
        #expect(harness.snapshot.decision.variant.appContext == .code)
        let context = try #require(rules.resolvedContexts.last)
        #expect(context.bundle == Self.antigravity && context.engine == .electron)
        #expect(context.role == nil && context.subrole == nil && context.identifier == nil && context.editable == nil)
        #expect(context.domClasses.isEmpty && context.ancestorRoles.isEmpty)
        #expect(context.documentURL == nil && context.windowTitle == nil)
        #expect(harness.ax.elementQueryCount(pid: Self.antigravityPID) == elementReads)
        #expect(harness.ax.attributeQueryCount(pid: Self.antigravityPID) == attributeReads)
    }

    /// PRD-R21 and PLT-R390: the app's per-app rule and remembered mode are keyed by the frontmost bundle, and a
    /// toggle is remembered for it.
    @Test func perAppModesUseTheFrontmostBundle() throws {
        let harness = FocusHarness()
        defer { harness.finish() }
        harness.ax.clearFocusedApplication()
        harness.processes.setFrontmost(F.codePID)
        harness.start(rules(), memory: [AppModeEntry(bundle: F.code, rule: .alwaysEnglish)])
        #expect(harness.snapshot.mode == .english && harness.snapshot.modeSource == .alwaysEnglish)
        harness.processes.setFrontmost(F.zaloPID)
        harness.idleRevalidation()
        #expect(harness.snapshot.app?.bundle == F.zalo && harness.snapshot.mode == .vietnamese)
        harness.toggle(4, F.zalo, .english)
        let document = try #require(harness.documents.last)
        #expect(document.apps.contains(AppModeEntry(bundle: F.zalo, mode: .english)))
    }

    @Test func anIgnoredFrontmostAppPassesThrough() {
        let harness = FocusHarness()
        defer { harness.finish() }
        harness.ax.clearFocusedApplication()
        harness.processes.setFrontmost(F.codePID)
        harness.start(rules(), memory: [AppModeEntry(bundle: F.code, rule: .ignore)])
        #expect(harness.snapshot.decision.plan.strategy == .passThrough)
        #expect(harness.snapshot.pause?.code == .passThroughRule)
    }

    @Test func withoutAFrontmostAppTheSnapshotNamesNoApp() {
        let harness = FocusHarness()
        defer { harness.finish() }
        harness.ax.clearFocusedApplication()
        harness.processes.setFrontmost(nil)
        harness.start(rules())
        #expect(harness.snapshot.app == nil)
        #expect(harness.snapshot.decision.rule == nil)
        #expect(harness.snapshot.field.axAvailability == .available)
    }

    /// A timed-out system-wide read says nothing about the focus: no fallback, so the snapshot stays app-less and
    /// `timedOut`, which the PLT-R340 late focus change treats as an unknown app, not a changed one.
    @Test func aTimedOutSystemWideReadDoesNotFallBack() {
        let harness = FocusHarness()
        defer { harness.finish() }
        harness.processes.setFrontmost(F.codePID)
        harness.ax.setSystemWideTimingOut(true)
        harness.start(rules())
        #expect(harness.snapshot.app == nil)
        #expect(harness.snapshot.field.axAvailability == .timedOut)
    }

    /// Review W14-P finding 1: the same frontmost app, first taken from NSWorkspace, then named by AX without a
    /// focused element. The snapshot must say who named the app (Diagnostics and the dev recorder show it), but a
    /// change of that label alone is no PLT-R340 boundary: same pid, still no field, so the generation stays.
    @Test func axNamingTheFallbackAppRelabelsItWithoutABoundary() throws {
        let harness = FocusHarness()
        defer { harness.finish() }
        harness.ax.clearFocusedApplication()
        harness.processes.setFrontmost(F.codePID)
        harness.start(rules())
        #expect(harness.snapshot.app?.source == .frontmostApplication)
        let generation = harness.snapshot.generation
        harness.ax.focusWithoutElement(pid: F.codePID, notify: nil)
        harness.idleRevalidation()
        let app = try #require(harness.snapshot.app)
        #expect(app.bundle == F.code && app.source == .accessibility)
        #expect(harness.snapshot.generation == generation)
        #expect(harness.snapshot.decision.rule == RuleID(rawValue: Self.editorRule))
    }

    /// The reverse of the finding-1 scenario: AX named the app without an element, then stops naming any app while
    /// the same app stays in front. The label follows, the generation does not move.
    @Test func axDroppingTheAppRelabelsItAsFrontmostWithoutABoundary() throws {
        let harness = FocusHarness()
        defer { harness.finish() }
        harness.processes.setFrontmost(F.codePID)
        harness.ax.focusWithoutElement(pid: F.codePID, notify: nil)
        harness.start(rules())
        #expect(harness.snapshot.app?.source == .accessibility)
        let generation = harness.snapshot.generation
        harness.ax.clearFocusedApplication()
        harness.idleRevalidation()
        let app = try #require(harness.snapshot.app)
        #expect(app.bundle == F.code && app.source == .frontmostApplication)
        #expect(harness.snapshot.generation == generation)
        // Once relabelled, further reads of the same fallback publish nothing more.
        harness.idleRevalidation()
        #expect(harness.snapshot.app?.source == .frontmostApplication)
        #expect(harness.snapshot.generation == generation)
    }

    /// PLT-R382 and T6: an unchanged fallback publishes nothing, and the owner's identity is read once.
    @Test func repeatedReadsOfTheSameFallbackPublishNothing() {
        let harness = FocusHarness()
        defer { harness.finish() }
        harness.ax.clearFocusedApplication()
        harness.processes.setFrontmost(F.codePID)
        harness.start(rules())
        let generation = harness.snapshot.generation
        for _ in 0..<3 { harness.idleRevalidation() }
        #expect(harness.snapshot.generation == generation)
        #expect(harness.processes.identityLookups(of: F.codePID) == 1)
    }
}
