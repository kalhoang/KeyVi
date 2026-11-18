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
        harness.ax.refuseObservers(pid: zaloPID, times: 1_000)
        harness.activate(zaloPID)
        harness.advance(by: .seconds(120))
        let requests = harness.timers.requests
        #expect(
            requests.count
                == FocusSettle.delays.count + FocusSettle.observerRetryDelays.count
                + FocusSettle.observerSlowRetryLimit)
        for request in requests {
            #expect(!request.repeating)
            #expect(request.leeway.nanoseconds * 10 >= request.delay.nanoseconds)
        }
        // The slow observer retries keep to the shortest steady-state period PLT-R803 allows.
        let scheduled = FocusSettle.observerRetryDelays.max() ?? .zero
        #expect(requests.filter { $0.delay > scheduled }.allSatisfy { $0.delay >= .seconds(2) })
        // Nothing keeps firing once the focus is still and the retries are used up (PLT-R803 steady state).
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

    /// PLT-R380 amendment of 19/11/2026: the slow retries end after `observerSlowRetryLimit` attempts, so an app
    /// that never takes an observer costs a bounded number of calls per chain and no timer afterwards.
    @Test func retriesAreBoundedPLTR380() {
        let harness = FocusHarness(scheduled: true)
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: field(), notify: nil)
        harness.start()
        harness.ax.refuseObservers(pid: zaloPID, times: 1_000)
        harness.activate(zaloPID)
        harness.advance(by: .seconds(300))
        #expect(
            harness.ax.observeAttempts(pid: zaloPID)
                == 1 + FocusSettle.observerRetryDelays.count + FocusSettle.observerSlowRetryLimit)
        #expect(harness.ax.observedNotifications[zaloPID] == nil)
        #expect(harness.scheduler.pendingCount == 0)
    }

    /// VM run of 19/11/2026 (control run of `testhost.native.textView`): TestHost refused observers for about
    /// 5 s after its launch on a loaded guest, longer than a slow guest leaves the scheduled attempts, and none of
    /// its focus changes reached the tracker. After the scheduled attempts the owner is asked again every 2 s, and
    /// the observer it finally takes delivers the next notification (PLT-R380 amendment of 19/11/2026).
    @Test func anObserverRefusedLongerThanTheScheduleIsInstalledByASlowRetryPLTR380() {
        let harness = FocusHarness(scheduled: true)
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: field(), notify: nil)
        harness.start()
        let scheduled = 1 + FocusSettle.observerRetryDelays.count
        harness.ax.refuseObservers(pid: zaloPID, times: scheduled + 2)
        harness.activate(zaloPID, field(identifier: "first"))
        harness.advance(by: .seconds(7))  // past the scheduled attempts (about 6.3 s)
        #expect(harness.ax.observedNotifications[zaloPID] == nil)
        harness.advance(by: FocusSettle.observerSlowRetryDelay * 3)
        #expect(harness.ax.observedNotifications[zaloPID] != nil)
        #expect(harness.ax.observeAttempts(pid: zaloPID) == scheduled + 3)
        #expect(harness.scheduler.pendingCount == 0)
        harness.ax.focus(
            pid: zaloPID, attributes: field(identifier: "second"), notify: .focusedElementChanged, element: 5)
        harness.sync()
        #expect(harness.snapshot.field.identifier == "second")
    }

    /// When a whole chain was refused, a publication of the owner's focus (here the PLT-R382 read on the first key
    /// after a pause) tries the observer again, although the owner did not change (PLT-R380 amendment).
    @Test func aPublicationOfAnUnobservedOwnerTriesTheObserverAgainPLTR380() {
        let harness = FocusHarness(scheduled: true)
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: field(), notify: nil)
        harness.start()
        let chain = 1 + FocusSettle.observerRetryDelays.count + FocusSettle.observerSlowRetryLimit
        harness.ax.refuseObservers(pid: zaloPID, times: chain)
        harness.activate(zaloPID, field(identifier: "first"))
        harness.advance(by: .seconds(120))
        #expect(harness.ax.observedNotifications[zaloPID] == nil)
        #expect(harness.scheduler.pendingCount == 0)
        // The app moved its focus and nobody was told; the next key after a pause reads it.
        harness.ax.focus(pid: zaloPID, attributes: field(identifier: "moved"), notify: nil, element: 7)
        harness.idleRevalidation()
        #expect(harness.snapshot.field.identifier == "moved")
        #expect(harness.ax.observedNotifications[zaloPID] == FocusCore.baseNotifications)
        harness.ax.focus(
            pid: zaloPID, attributes: field(identifier: "second"), notify: .focusedElementChanged, element: 8)
        harness.sync()
        #expect(harness.snapshot.field.identifier == "second")
    }

    /// A retry that finds the app momentarily not wanted (another app owns the focus) skips its call but keeps the
    /// chain going through the scheduled attempts, instead of ending it (PLT-R380 amendment).
    @Test func aRetryChainOutlastsAMomentWhenTheAppIsNotTheOwnerPLTR380() {
        let harness = FocusHarness(scheduled: true)
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: field(), notify: nil)
        harness.start()
        harness.ax.refuseObservers(pid: zaloPID, times: 3)
        harness.activate(zaloPID)
        // The activation's observer sync still sees the app as the owner and asks once more before the read.
        harness.activate(terminalPID)
        harness.advance(by: .seconds(1))  // attempts 1 to 3 fall due while the terminal owns the focus
        #expect(harness.ax.observeAttempts(pid: zaloPID) == 2)
        #expect(harness.scheduler.pendingCount == 1)  // the chain's next attempt
        harness.activate(zaloPID)
        harness.advance(by: .seconds(1))
        #expect(harness.ax.observedNotifications[zaloPID] == FocusCore.baseNotifications)
    }

    /// PLT-R380, PLT-R901: each attempt after the first, and a first attempt that is refused, leaves one log record
    /// with the pid, the attempt and a result code, so an integration run shows how an app's observer was installed.
    @Test func everyObserverAttemptButAFirstInstallIsLoggedPLTR380() {
        let harness = FocusHarness(scheduled: true)
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: field(), notify: nil)
        harness.start()
        #expect(harness.observerAttempts(pid: terminalPID).isEmpty)  // installed at once: nothing to say
        harness.ax.refuseObservers(pid: zaloPID, times: 2)
        harness.activate(zaloPID)
        harness.advance(by: .seconds(1))
        let logged = harness.observerAttempts(pid: zaloPID)
        #expect(logged.map(\.attempt) == [0, 1, 2])
        #expect(logged.map(\.result) == [.refused, .refused, .installed])
    }

    /// The skipped attempts are logged with their reason, and an observer a publication finally installs too.
    @Test func skippedAttemptsAndAnInstallAfterAPublicationAreLoggedPLTR380() {
        let harness = FocusHarness(scheduled: true)
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: field(), notify: nil)
        harness.start()
        harness.ax.refuseObservers(pid: zaloPID, times: 1_000)
        harness.activate(zaloPID)
        harness.activate(terminalPID)
        harness.advance(by: .seconds(1))
        #expect(harness.observerAttempts(pid: zaloPID).contains { $0.result == .notWanted })
        harness.activate(zaloPID)
        harness.advance(by: .seconds(120))
        #expect(harness.observerAttempts(pid: zaloPID).last?.result == .refused)
        harness.ax.refuseObservers(pid: zaloPID, times: 0)  // the app accepts from now on
        harness.ax.focus(pid: zaloPID, attributes: field(identifier: "moved"), notify: nil, element: 7)
        harness.idleRevalidation()
        #expect(harness.observerAttempts(pid: zaloPID).last?.result == .installed)
    }

    /// PLT-R384: no observer call goes to an app whose breaker is open; the chain's attempts pass it by.
    @Test func retriesSkipAnAppWhoseBreakerIsOpenPLTR384() {
        let harness = FocusHarness(scheduled: true)
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: field(), notify: nil)
        harness.start()
        harness.ax.refuseObservers(pid: zaloPID, times: 1_000)
        harness.activate(zaloPID, field(identifier: "first"))
        harness.ax.setTimingOut(pid: zaloPID, true)
        for _ in 0..<3 { harness.idleRevalidation() }  // three timeouts within 10 s open the breaker
        #expect(harness.health.recent(limit: 10).contains { $0.kind == .axCircuitBreakerTrip })
        let attempts = harness.ax.observeAttempts(pid: zaloPID)
        harness.advance(by: .seconds(50))  // within the 60 s cool-down
        #expect(harness.ax.observeAttempts(pid: zaloPID) == attempts)
        #expect(harness.observerAttempts(pid: zaloPID).last?.result == .breakerOpen)
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
