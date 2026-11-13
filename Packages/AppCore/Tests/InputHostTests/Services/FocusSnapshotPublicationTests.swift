// SPDX-License-Identifier: GPL-3.0-or-later
//
// How the ax thread publishes `FocusSnapshot` for the tap (contracts.md 10.4, W1-F1 requests): the field token
// is stable for one element across republications and new on every element change, an idle revalidation that
// learns nothing does not bump the generation (PLT-R382, PLT-R316), and tap toggles apply in arrival order.

import AppModel
import CompatRules
import Diagnostics
import Foundation
import Injection
import RealtimeSupport
import SettingsStore
import Testing

@testable import InputHost
@testable import TestSupport

private typealias F = FocusFixtures

@Suite("FocusSnapshot publication (contracts.md 10.4)", .serialized)
struct FocusSnapshotPublicationTests {
    // MARK: Field token

    @Test func tokenIsStableAcrossAToggleRepublication() throws {
        let harness = FocusHarness()
        defer { harness.finish() }
        harness.ax.focus(pid: F.terminalPID, attributes: F.attributes(), notify: nil)
        harness.start()
        let before = harness.snapshot
        let token = try #require(before.fieldHandle?.token)
        harness.toggle(4, F.terminal, .english)
        #expect(harness.snapshot.mode == .english)
        #expect(harness.snapshot.fieldHandle?.token == token)
        #expect(harness.snapshot.generation == before.generation)
        harness.tracker.setMode(.vietnamese)  // menu toggle (D16)
        harness.sync()
        #expect(harness.snapshot.fieldHandle?.token == token)
    }

    /// A rule change re-resolves the same element: a new generation (the decision is a hard boundary), but the
    /// same token and focus time, so the tap does not count it as a focus change.
    @Test func tokenIsStableAcrossARuleReResolution() throws {
        let harness = FocusHarness()
        defer { harness.finish() }
        harness.ax.focus(pid: F.terminalPID, attributes: F.attributes(), notify: nil)
        harness.start()
        let before = harness.snapshot
        let token = try #require(before.fieldHandle?.token)
        harness.clock.advance(byMicroseconds: 5_000_000)
        harness.tracker.update(rules: F.resolver([F.terminal: F.decision("terminal.pass", strategy: .passThrough)]))
        harness.sync()
        #expect(harness.snapshot.generation == before.generation.next)
        #expect(harness.snapshot.decision.rule == RuleID(rawValue: "terminal.pass"))
        #expect(harness.snapshot.fieldHandle?.token == token)
        #expect(harness.snapshot.changedAt == before.changedAt)
        var settings = DefaultSettings.v1
        settings.firstSeenAppMode = .en
        harness.tracker.update(settings: settings, appModes: harness.documents.last ?? AppModesDocument())
        harness.sync()
        #expect(harness.snapshot.fieldHandle?.token == token)
    }

    /// The same element whose attributes change (a field turning secure, a role update) keeps its token.
    @Test func tokenIsStableWhenTheSameElementChangesAttributes() throws {
        let harness = FocusHarness()
        defer { harness.finish() }
        harness.ax.focus(pid: F.zaloPID, attributes: F.attributes(), notify: nil)
        harness.start()
        let token = try #require(harness.snapshot.fieldHandle?.token)
        let generation = harness.snapshot.generation
        harness.ax.focus(
            pid: F.zaloPID, attributes: F.attributes(role: "AXTextField", subrole: "AXSecureTextField"),
            notify: .focusedElementChanged)
        harness.sync()
        #expect(harness.snapshot.pause == .secureField)
        #expect(harness.snapshot.generation == generation.next)
        #expect(harness.snapshot.fieldHandle?.token == token)
    }

    @Test func everyElementChangeMintsANewToken() throws {
        let harness = FocusHarness()
        defer { harness.finish() }
        harness.ax.focus(pid: F.zaloPID, attributes: F.attributes(), notify: nil)
        harness.start()
        var tokens = [try #require(harness.snapshot.fieldHandle?.token)]
        // Another field of the same app with identical attributes, then back, then another app.
        for element: UInt16 in [1, 0, 2] {
            harness.ax.focus(
                pid: F.zaloPID, attributes: F.attributes(), notify: .focusedElementChanged, element: element)
            harness.sync()
            tokens.append(try #require(harness.snapshot.fieldHandle?.token))
        }
        harness.activate(F.terminalPID)
        tokens.append(try #require(harness.snapshot.fieldHandle?.token))
        #expect(Set(tokens).count == tokens.count)
        #expect(harness.snapshot.generation == FocusGeneration(rawValue: 5))
        // Leaving the field for no element and coming back is two element changes.
        harness.ax.focusWithoutElement(pid: F.terminalPID, notify: .focusedElementChanged)
        harness.sync()
        #expect(harness.snapshot.fieldHandle == nil)
        harness.ax.focus(pid: F.terminalPID, attributes: F.attributes(), notify: .focusedElementChanged)
        harness.sync()
        #expect(harness.snapshot.fieldHandle.map { !tokens.contains($0.token) } == true)
    }

    // MARK: Idle revalidation (PLT-R382)

    @Test func idleRevalidationThatFindsNothingChangedKeepsTheGenerationPLTR382() throws {
        let harness = FocusHarness()
        defer { harness.finish() }
        let rules = CountingFocusResolver(F.resolver())
        harness.ax.focus(pid: F.terminalPID, attributes: F.attributes(), notify: nil)
        harness.start(rules)
        let before = harness.snapshot
        for _ in 0..<5 {
            harness.clock.advance(byMicroseconds: 600_000)
            harness.idleRevalidation()
        }
        #expect(harness.generation.load() == before.generation)
        #expect(harness.snapshot.generation == before.generation)
        #expect(harness.snapshot.fieldHandle == before.fieldHandle)
        #expect(harness.snapshot.changedAt == before.changedAt)
        #expect(rules.resolvedContexts.count == 1)
    }

    /// A transient context change that resolves to the same decision (a window title for a titlePattern
    /// bundle) re-resolves but publishes no new generation.
    @Test func idleRevalidationWithTheSameDecisionKeepsTheGeneration() {
        let harness = FocusHarness()
        defer { harness.finish() }
        harness.ax.focus(pid: F.browserPID, attributes: F.attributes(title: "One"), notify: nil)
        harness.start()
        let before = harness.snapshot
        harness.ax.focus(pid: F.browserPID, attributes: F.attributes(title: "Two"), notify: nil)
        harness.idleRevalidation()
        #expect(harness.snapshot.generation == before.generation)
        #expect(harness.snapshot.fieldHandle == before.fieldHandle)
    }

    /// PLT-R382, PLT-R316: an AX timeout during an idle revalidation teaches nothing about the focus, so the
    /// snapshot stays (a generation bump would reset the word and discard in-flight edits). Once the breaker
    /// opens the snapshot says `timedOut` (PLT-R384).
    @Test func idleRevalidationTimeoutKeepsTheSnapshotUntilTheBreakerOpensPLTR384() {
        let harness = FocusHarness()
        defer { harness.finish() }
        harness.ax.focus(pid: F.terminalPID, attributes: F.attributes(), notify: nil)
        harness.start()
        let before = harness.snapshot
        harness.ax.setTimingOut(pid: F.terminalPID, true)
        for _ in 0..<2 {
            harness.clock.advance(byMicroseconds: 1_000_000)
            harness.idleRevalidation()
        }
        #expect(harness.generation.load() == before.generation)
        #expect(harness.snapshot.field.axAvailability == .available)
        #expect(harness.snapshot.fieldHandle == before.fieldHandle)
        harness.clock.advance(byMicroseconds: 1_000_000)
        harness.idleRevalidation()  // third timeout in 10 s: the breaker opens
        #expect(harness.snapshot.field.axAvailability == .timedOut)
        #expect(harness.generation.load() == before.generation.next)
    }

    /// A timeout outside the idle path (a focus notification) still publishes: focus may have moved.
    @Test func notificationTimeoutStillPublishes() {
        let harness = FocusHarness()
        defer { harness.finish() }
        harness.ax.focus(pid: F.terminalPID, attributes: F.attributes(), notify: nil)
        harness.start()
        harness.ax.setTimingOut(pid: F.terminalPID, true)
        harness.ax.post(.focusedElementChanged, from: F.terminalPID)
        harness.sync()
        #expect(harness.snapshot.field.axAvailability == .timedOut)
        #expect(harness.snapshot.fieldHandle == nil)
    }

    // MARK: Tap toggles in arrival order

    /// Two pipelines (before and after a tap recreation) can send the same sequence: both notices apply, in the
    /// order they arrived (W1-F1 request; only the tap's override orders by sequence).
    @Test func togglesWithTheSameSequenceApplyInArrivalOrder() throws {
        let harness = FocusHarness()
        defer { harness.finish() }
        harness.ax.focus(pid: F.terminalPID, attributes: F.attributes(), notify: nil)
        harness.start()
        let emitted = harness.documents.count
        _ = harness.inbox.push(.modeToggled(sequence: 5, bundle: F.terminal, mode: .english))
        _ = harness.inbox.push(.modeToggled(sequence: 5, bundle: F.terminal, mode: .vietnamese))
        harness.tracker.drainInbox()
        harness.sync()
        #expect(harness.documents.values.dropFirst(emitted).map(\.globalMode) == [.english, .vietnamese])
        #expect(harness.snapshot.mode == .vietnamese)
        #expect(harness.snapshot.appliedToggleSequence == 5)
        #expect(harness.documents.last?.apps.first == AppModeEntry(bundle: F.terminal, mode: .vietnamese))
    }

    @Test func aLowerSequenceArrivingLaterIsStillApplied() {
        let harness = FocusHarness()
        defer { harness.finish() }
        harness.ax.focus(pid: F.terminalPID, attributes: F.attributes(), notify: nil)
        harness.start()
        harness.toggle(7, F.terminal, .english)
        harness.toggle(3, F.terminal, .vietnamese)
        #expect(harness.snapshot.mode == .vietnamese)
        #expect(harness.snapshot.appliedToggleSequence == 7)  // the highest applied, for the tap's override
        _ = harness.inbox.push(.modeToggled(sequence: 9, bundle: F.terminal, mode: .english))
        _ = harness.inbox.push(.modeToggled(sequence: 8, bundle: F.terminal, mode: .vietnamese))
        harness.tracker.drainInbox()
        harness.sync()
        #expect(harness.snapshot.mode == .vietnamese)
        #expect(harness.snapshot.appliedToggleSequence == 9)
        #expect(harness.documents.last?.globalMode == .vietnamese)
    }
}
