// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R389 on the ax thread: a shortcut, Escape, Return, Tab or a click may move the focus without an app activation
// and without a notification the tracker observes (Spotlight's panel opening and closing, Pa's items 7 and 9 of
// 2026-11-14). The tap's trigger notice makes the tracker read the system-wide focus over the trigger settle window,
// so `launcher.spotlight` applies on every open (first, second, after a relaunch of Spotlight) and stops applying
// once Spotlight closes. Fakes: FakeAXProvider (no notification is posted in these tests), ManualScheduler.

import AppModel
import CompatRules
import Injection
import RealtimeSupport
import Testing

@testable import InputHost
@testable import TestSupport

private let terminalPID = FocusFixtures.terminalPID
private let spotlightPID = FocusFixtures.spotlightPID
private let terminal = FocusFixtures.terminal
private let spotlight = FocusFixtures.spotlight

private func field(_ identifier: String? = nil, role: String = "AXTextField") -> FocusAttributes {
    FocusFixtures.attributes(role: role, identifier: identifier)
}

/// `launcher.spotlight` as resolved: overlay, inline completion read through AX, no restore hotkey (PLT-R353).
private func spotlightRules() -> FakeDecisionResolver {
    var decision = FocusFixtures.decision("launcher.spotlight")
    decision.overlay = true
    decision.features.restoreHotkey = false
    decision.params.inlineCompletion = .axSelection
    return FocusFixtures.resolver([spotlight: decision])
}

private extension FocusHarness {
    /// The tap's PLT-R389 notice for a trigger key, drained on the ax thread.
    func trigger() {
        _ = inbox.push(.revalidateFocusAfterTrigger)
        tracker.drainInbox()
        sync()
    }
}

@Suite("Trigger revalidation (PLT-R389)", .serialized)
struct FocusTriggerSettleTests {
    /// The tap is still holding the trigger key when the notice arrives: no read at once, the reads follow.
    @Test func aTriggerReadsOverItsWindowNotAtOncePLTR389() {
        let harness = FocusHarness(scheduled: true)
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: field("doc"), notify: nil, element: 1)
        harness.start(spotlightRules())
        let queries = harness.ax.elementQueryCount(pid: terminalPID)
        harness.trigger()
        #expect(harness.ax.elementQueryCount(pid: terminalPID) == queries)
        harness.advance(by: FocusSettle.triggerDelays[FocusSettle.triggerDelays.count - 1])
        #expect(harness.ax.elementQueryCount(pid: terminalPID) == queries + FocusSettle.triggerDelays.count)
        #expect(harness.scheduler.pendingCount == 0)
    }

    /// Pa's item 7: Command+Space, Spotlight's field takes the focus 50 ms later, no notification. The next read of
    /// the window publishes Spotlight with its overlay rule before a key typed 80 ms after the shortcut.
    @Test func spotlightOpenedByAShortcutIsPublishedBeforeTheNextKeyPLTR389() {
        let harness = FocusHarness(scheduled: true)
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: field("doc"), notify: nil, element: 1)
        harness.start(spotlightRules())
        harness.trigger()
        harness.advance(by: .milliseconds(50))
        harness.ax.focus(pid: spotlightPID, attributes: field("search"), notify: nil, element: 2)
        harness.advance(by: .milliseconds(30))
        #expect(harness.snapshot.app?.bundle == spotlight)
        #expect(harness.snapshot.decision.overlay)
        #expect(!harness.snapshot.decision.restoreHotkeyEnabled)  // T5.8: Escape is never a restore there
        #expect(harness.snapshot.decision.plan.parameters.inlineCompletion == .axSelection)
    }

    /// Pa's items 7 and 9: open, close with Escape, open again, and open once more after Spotlight was relaunched
    /// (a new pid nobody observes). Every open applies `launcher.spotlight`, every close returns to the app's rules.
    @Test func spotlightAppliesOnEveryOpenAndStopsOnCloseT58() {
        let harness = FocusHarness(scheduled: true)
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: field("doc"), notify: nil, element: 1)
        harness.start(spotlightRules())
        let relaunchedPID: Int32 = 201
        harness.processes.add(
            FakeProcessIdentityProvider.process(pid: relaunchedPID, bundle: spotlight.rawValue, name: "Spotlight"))
        for (round, pid) in [spotlightPID, spotlightPID, relaunchedPID].enumerated() {
            harness.trigger()  // Command+Space
            harness.advance(by: .milliseconds(40))
            harness.ax.focus(pid: pid, attributes: field("search"), notify: nil, element: UInt16(10 + round))
            harness.advance(by: FocusSettle.triggerDelays[FocusSettle.triggerDelays.count - 1])
            #expect(harness.snapshot.app?.pid == pid, "open \(round)")
            #expect(!harness.snapshot.decision.restoreHotkeyEnabled, "open \(round)")
            harness.trigger()  // Escape closes Spotlight: the focus returns to the document, no activation
            harness.advance(by: .milliseconds(30))
            harness.ax.focus(pid: terminalPID, attributes: field("doc"), notify: nil, element: 1)
            harness.advance(by: FocusSettle.triggerDelays[FocusSettle.triggerDelays.count - 1])
            #expect(harness.snapshot.app?.bundle == terminal, "close \(round)")
            #expect(harness.snapshot.decision.restoreHotkeyEnabled, "close \(round)")
            #expect(!harness.snapshot.decision.overlay, "close \(round)")
        }
    }

    /// PLT-R389: while the overlay rule applies, each key's read (`.revalidateFocus`) sees a close that happened
    /// without a trigger the tap could see (Spotlight closing by itself after Return opened a result).
    @Test func theKeyReadInsideAnOverlaySeesTheClosePLTR389() {
        let harness = FocusHarness(scheduled: true)
        defer { harness.finish() }
        harness.ax.focus(pid: spotlightPID, attributes: field("search"), notify: nil, element: 2)
        harness.start(spotlightRules())
        #expect(harness.snapshot.decision.overlay)
        harness.ax.focus(pid: terminalPID, attributes: field("doc"), notify: nil, element: 1)
        harness.idleRevalidation()
        #expect(harness.snapshot.app?.bundle == terminal)
    }

    /// Trigger reads of an unchanged focus publish nothing: a Command+B in the middle of a word keeps the word and
    /// every edit in flight (PLT-R316).
    @Test func triggerReadsOfAnUnchangedFocusPublishNothingPLTR389() {
        let harness = FocusHarness(scheduled: true)
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: field("doc"), notify: nil, element: 1)
        harness.start(spotlightRules())
        let generation = harness.snapshot.generation
        harness.trigger()
        harness.advance(by: .seconds(1))
        #expect(harness.snapshot.generation == generation)
    }

    /// Like the other settle windows (PLT-R384): a timeout teaches nothing and ends the window.
    @Test func aTimedOutTriggerReadEndsTheWindowPLTR384() {
        let harness = FocusHarness(scheduled: true)
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: field("doc"), notify: nil, element: 1)
        harness.start(spotlightRules())
        harness.ax.setTimingOut(pid: terminalPID, true)
        let queries = harness.ax.elementQueryCount(pid: terminalPID)
        harness.trigger()
        harness.advance(by: .seconds(1))
        #expect(harness.ax.elementQueryCount(pid: terminalPID) == queries + 1)
        #expect(harness.scheduler.pendingCount == 0)
    }

    /// A later trigger restarts the window (Command+Space, then Escape at once).
    @Test func aNewTriggerRestartsTheWindowPLTR389() {
        let harness = FocusHarness(scheduled: true)
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: field("doc"), notify: nil, element: 1)
        harness.start(spotlightRules())
        harness.trigger()
        harness.advance(by: FocusSettle.triggerDelays[0])
        harness.trigger()
        let queries = harness.ax.elementQueryCount(pid: terminalPID)
        harness.advance(by: .seconds(1))
        #expect(harness.ax.elementQueryCount(pid: terminalPID) == queries + FocusSettle.triggerDelays.count)
    }

    /// Without a scheduler nothing can be deferred: the trigger reads at once instead of not at all.
    @Test func withoutASchedulerATriggerReadsAtOnce() {
        let harness = FocusHarness(scheduled: false)
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: field("doc"), notify: nil, element: 1)
        harness.start(spotlightRules())
        harness.ax.focus(pid: spotlightPID, attributes: field("search"), notify: nil, element: 2)
        harness.trigger()
        #expect(harness.snapshot.app?.bundle == spotlight)
    }

    /// PLT-R803: every trigger timer has at least 10 % leeway; the window ends at 400 ms like the notification one.
    @Test func triggerTimersHaveLeewayAndTheSameWindowEnd() {
        #expect(FocusSettle.triggerDelays.last == FocusSettle.window)
        #expect(FocusSettle.triggerDelays == FocusSettle.triggerDelays.sorted())
        let harness = FocusHarness(scheduled: true)
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: field("doc"), notify: nil, element: 1)
        harness.start(spotlightRules())
        let before = harness.timers.requests.count
        harness.trigger()
        let requests = Array(harness.timers.requests.dropFirst(before))
        #expect(requests.map(\.delay) == FocusSettle.triggerDelays)
        for request in requests {
            #expect(request.leeway.nanoseconds * 10 >= request.delay.nanoseconds)
        }
    }
}
