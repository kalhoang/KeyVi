// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R380, PLT-R391: the focus tracker keeps up with apps whose AX focus settles after the notification, and with
// apps that cannot take an observer yet. Both were seen in the macOS 27 VM (docs/runbooks/integration-suite.md
// section 10.5): WebKit posted AXFocusedUIElementChanged for a page's textarea while the app's focused element still
// read nil, and a freshly launched app answered AXObserverAddNotification with kAXErrorCannotComplete for about
// 400 ms, so no notification of that app ever arrived. Deferred work runs from a ManualScheduler on the
// harness's ManualClock and hops to the real ax thread.

import AppModel
import Injection
import RealtimeSupport
import Testing

@testable import InputHost
@testable import TestSupport

private let terminalPID = FocusFixtures.terminalPID
private let zaloPID = FocusFixtures.zaloPID
private let zalo = FocusFixtures.zalo

private func field(_ role: String = "AXTextArea", identifier: String? = nil) -> FocusAttributes {
    FocusFixtures.attributes(role: role, identifier: identifier)
}

@Suite("Focus settle re-reads and observer retries (PLT-R380, PLT-R391)", .serialized)
struct FocusSettleTests {
    // MARK: Settle re-reads after a notification

    @Test func aFocusThatSettlesAfterTheNotificationIsPublishedByTheSettleReRead() {
        let harness = FocusHarness(scheduled: true)
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: field(identifier: "input"), notify: nil, element: 1)
        harness.start()
        // The page posts the notification while the app's focused element still reads nil...
        harness.ax.focusWithoutElement(pid: terminalPID, notify: .focusedElementChanged)
        harness.sync()
        #expect(harness.snapshot.fieldHandle == nil)
        // ...and the textarea becomes readable a moment later, without a second notification.
        harness.ax.focus(pid: terminalPID, attributes: field(identifier: "textarea"), notify: nil, element: 2)
        harness.advance(by: FocusSettle.delays[0])
        #expect(harness.snapshot.field.identifier == "textarea")
        #expect(harness.snapshot.fieldHandle != nil)
    }

    @Test func settleReReadsOfAnUnchangedFocusPublishNothing() {
        let harness = FocusHarness(scheduled: true)
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: field(), notify: nil, element: 1)
        harness.start()
        harness.ax.focus(
            pid: terminalPID, attributes: field(identifier: "b"), notify: .focusedElementChanged, element: 2)
        harness.sync()
        let generation = harness.snapshot.generation
        let refreshes = harness.metrics.focusRefresh.snapshot().count
        harness.advance(by: FocusSettle.window)
        #expect(harness.snapshot.generation == generation)
        #expect(harness.metrics.focusRefresh.snapshot().count == refreshes)
        #expect(harness.scheduler.pendingCount == 0)
    }

    @Test func everySettleDelayReReadsUntilTheWindowEnds() {
        let harness = FocusHarness(scheduled: true)
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: field(), notify: nil, element: 1)
        harness.start()
        harness.ax.focusWithoutElement(pid: terminalPID, notify: .focusedElementChanged)
        harness.sync()
        let queries = harness.ax.elementQueryCount(pid: terminalPID)
        harness.advance(by: FocusSettle.window)
        #expect(harness.ax.elementQueryCount(pid: terminalPID) == queries + FocusSettle.delays.count)
        // The last delay is the window: a focus that settles later waits for the next notification or key.
        harness.ax.focus(pid: terminalPID, attributes: field(identifier: "late"), notify: nil, element: 3)
        harness.advance(by: .seconds(5))
        #expect(harness.snapshot.field.identifier != "late")
    }

    @Test func aNewNotificationRestartsTheSettleWindow() {
        let harness = FocusHarness(scheduled: true)
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: field(), notify: nil, element: 1)
        harness.start()
        harness.ax.focusWithoutElement(pid: terminalPID, notify: .focusedElementChanged)
        harness.sync()
        harness.advance(by: FocusSettle.delays[0])
        harness.ax.focusWithoutElement(pid: terminalPID, notify: .focusedWindowChanged)
        harness.sync()
        let queries = harness.ax.elementQueryCount(pid: terminalPID)
        harness.advance(by: FocusSettle.window)
        // Only the second chain reads: the first one's remaining ticks are stale.
        #expect(harness.ax.elementQueryCount(pid: terminalPID) == queries + FocusSettle.delays.count)
    }

    @Test func activationRevalidationAlsoSettles() {
        let harness = FocusHarness(scheduled: true)
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: field(), notify: nil)
        harness.start()
        harness.ax.focusWithoutElement(pid: zaloPID, notify: nil)
        harness.tracker.revalidate()
        harness.sync()
        #expect(harness.snapshot.app?.bundle == zalo)
        #expect(harness.snapshot.fieldHandle == nil)
        harness.ax.focus(pid: zaloPID, attributes: field(identifier: "composer"), notify: nil, element: 4)
        harness.advance(by: FocusSettle.delays[1])
        #expect(harness.snapshot.field.identifier == "composer")
    }

    @Test func aTimedOutSettleReReadKeepsTheSnapshot() {
        let harness = FocusHarness(scheduled: true)
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: field(identifier: "a"), notify: nil, element: 1)
        harness.start()
        harness.ax.focus(
            pid: terminalPID, attributes: field(identifier: "b"), notify: .focusedElementChanged, element: 2)
        harness.sync()
        let generation = harness.snapshot.generation
        harness.ax.setTimingOut(pid: terminalPID, true)
        harness.advance(by: FocusSettle.delays[0])
        // Like the idle revalidation (PLT-R382): a timeout teaches nothing, the word in progress is kept.
        #expect(harness.snapshot.generation == generation)
        #expect(harness.snapshot.field.axAvailability == .available)
    }

    /// PLT-R384: one focus change of a timing-out app costs one breaker count, as before the settle window
    /// existed. A notification read that timed out opens no window, so two changes within 10 s do not trip.
    @Test func aTimedOutNotificationReadOpensNoSettleWindow() {
        let harness = FocusHarness(scheduled: true)
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: field(identifier: "a"), notify: nil, element: 1)
        harness.start()
        harness.ax.setTimingOut(pid: terminalPID, true)
        let queries = harness.ax.elementQueryCount(pid: terminalPID)
        for _ in 0..<2 {
            harness.advance(by: .seconds(1))
            harness.ax.post(.focusedElementChanged, from: terminalPID)
            harness.sync()
            harness.advance(by: FocusSettle.window)
        }
        #expect(harness.ax.elementQueryCount(pid: terminalPID) == queries + 2)
        #expect(harness.health.recent(limit: 10).filter { $0.kind == .axCircuitBreakerTrip }.isEmpty)
        #expect(harness.scheduler.pendingCount == 0)
    }

    @Test func aSettlePublicationTellsTheHost() {
        let harness = FocusHarness(scheduled: true)
        defer { harness.finish() }
        let publications = Recorder<Bool>()
        harness.tracker.setDeferredPublicationObserver { publications.append(true) }
        harness.ax.focus(pid: terminalPID, attributes: field(), notify: nil, element: 1)
        harness.start()
        harness.ax.focusWithoutElement(pid: terminalPID, notify: .focusedElementChanged)
        harness.sync()
        harness.ax.focus(pid: terminalPID, attributes: field(identifier: "settled"), notify: nil, element: 2)
        harness.advance(by: FocusSettle.window)
        // One publication (the change), not one per re-read.
        #expect(publications.values.count == 1)
    }

    @Test func deferredTimersAreOneShotWithTenPercentLeewayPLTR803() {
        let harness = FocusHarness(scheduled: true)
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: field(), notify: nil)
        harness.start()
        harness.ax.refuseObservers(pid: zaloPID, times: 100)
        harness.activate(zaloPID)
        harness.advance(by: .seconds(30))
        let requests = harness.timers.requests
        #expect(requests.count == FocusSettle.delays.count + FocusSettle.observerRetryDelays.count)
        for request in requests {
            #expect(!request.repeating)
            #expect(request.leeway.nanoseconds * 10 >= request.delay.nanoseconds)
        }
        // Nothing keeps firing once the focus is still (PLT-R803 steady state).
        #expect(harness.scheduler.pendingCount == 0)
    }

    @Test func withoutASchedulerNothingIsDeferred() {
        let harness = FocusHarness()
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: field(), notify: nil)
        harness.start()
        harness.ax.focusWithoutElement(pid: terminalPID, notify: .focusedElementChanged)
        harness.sync()
        harness.ax.focus(pid: terminalPID, attributes: field(identifier: "settled"), notify: nil, element: 2)
        harness.sync()
        #expect(harness.snapshot.fieldHandle == nil)
    }

    // MARK: Observer retries

    @Test func anObserverRefusedRightAfterLaunchIsRetriedUntilItRegisters() {
        let harness = FocusHarness(scheduled: true)
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: field(), notify: nil)
        harness.start()
        harness.ax.refuseObservers(pid: zaloPID, times: 2)
        harness.activate(zaloPID, field(identifier: "first"))
        #expect(harness.snapshot.app?.bundle == zalo)
        #expect(harness.ax.observedNotifications[zaloPID] == nil)
        harness.advance(by: FocusSettle.observerRetryDelays[0])
        #expect(harness.ax.observedNotifications[zaloPID] == nil)
        harness.advance(by: FocusSettle.observerRetryDelays[1])
        #expect(harness.ax.observedNotifications[zaloPID] == FocusCore.baseNotifications)
        #expect(harness.ax.observeAttempts(pid: zaloPID) == 3)
        // From now on the app's own notifications drive the snapshot.
        harness.ax.focus(
            pid: zaloPID, attributes: field(identifier: "second"), notify: .focusedElementChanged, element: 5)
        harness.sync()
        #expect(harness.snapshot.field.identifier == "second")
    }

    /// PLT-R380: an app that refuses one of the base notifications for good still gets an observer for the others
    /// once the retries are used up, so its window and activation changes keep arriving.
    @Test func theLastAttemptKeepsWhatAnAppThatRefusesOneNotificationForGoodAccepts() {
        let harness = FocusHarness(scheduled: true)
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: field(), notify: nil)
        harness.start()
        harness.ax.refuseNotification(pid: zaloPID, .focusedWindowChanged)
        harness.activate(zaloPID, field(identifier: "first"))
        #expect(harness.ax.observedNotifications[zaloPID] == nil)
        harness.advance(by: .seconds(30))
        var accepted = FocusCore.baseNotifications
        accepted.remove(.focusedWindowChanged)
        #expect(harness.ax.observedNotifications[zaloPID] == accepted)
        #expect(harness.ax.observeAttempts(pid: zaloPID) == FocusSettle.observerRetryDelays.count + 1)
        #expect(harness.scheduler.pendingCount == 0)
        harness.ax.focus(
            pid: zaloPID, attributes: field(identifier: "second"), notify: .focusedElementChanged, element: 5)
        harness.sync()
        #expect(harness.snapshot.field.identifier == "second")
    }

    @Test func aRetryThatRegistersReadsTheFocusItMissed() {
        // The retry falls between the first two settle re-reads, so only the retry can see the move.
        let firstSettle = FocusSettle.delays[0]
        let retry = FocusSettle.observerRetryDelays[0]
        #expect(firstSettle < retry && retry < FocusSettle.delays[1])
        let harness = FocusHarness(scheduled: true)
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: field(), notify: nil)
        harness.start()
        harness.ax.refuseObservers(pid: zaloPID, times: 1)
        harness.activate(zaloPID, field(identifier: "launch"))
        harness.advance(by: firstSettle)
        // While unobserved the app moved its focus; nobody was told.
        harness.ax.focus(
            pid: zaloPID, attributes: field(identifier: "moved"), notify: .focusedElementChanged, element: 6)
        harness.sync()
        #expect(harness.snapshot.field.identifier == "launch")
        harness.advance(by: retry - firstSettle)
        #expect(harness.snapshot.field.identifier == "moved")
    }

    @Test func retriesStopAfterTheLastDelay() {
        let harness = FocusHarness(scheduled: true)
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: field(), notify: nil)
        harness.start()
        harness.ax.refuseObservers(pid: zaloPID, times: 100)
        harness.activate(zaloPID)
        harness.advance(by: .seconds(30))
        #expect(harness.ax.observeAttempts(pid: zaloPID) == 1 + FocusSettle.observerRetryDelays.count)
        #expect(harness.ax.observedNotifications[zaloPID] == nil)
        #expect(harness.scheduler.pendingCount == 0)
    }

    @Test func retriesStopWhenTheAppIsNoLongerTheOwner() {
        let harness = FocusHarness(scheduled: true)
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: field(), notify: nil)
        harness.start()
        harness.ax.refuseObservers(pid: zaloPID, times: 100)
        harness.activate(zaloPID)
        harness.activate(terminalPID)
        let attempts = harness.ax.observeAttempts(pid: zaloPID)
        harness.advance(by: .seconds(30))
        #expect(harness.ax.observeAttempts(pid: zaloPID) == attempts)
        #expect(harness.scheduler.pendingCount == 0)
        #expect(Set(harness.ax.observedNotifications.keys) == [terminalPID, FocusFixtures.spotlightPID])
    }

    @Test func aRefusedObserverWithoutASchedulerIsTriedAgainOnTheNextActivation() {
        let harness = FocusHarness()
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: field(), notify: nil)
        harness.start()
        harness.ax.refuseObservers(pid: zaloPID, times: 1)
        harness.activate(zaloPID)
        #expect(harness.ax.observedNotifications[zaloPID] == nil)
        harness.activate(zaloPID)
        #expect(harness.ax.observedNotifications[zaloPID] == FocusCore.baseNotifications)
        #expect(harness.snapshot.app?.bundle == zalo)
    }
}
