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
        // The log keeps the scheduled attempts and the chain's last one, not every slow attempt (PLT-R901 volume).
        let logged = harness.observerAttempts(pid: zaloPID)
        #expect(logged.count == 1 + FocusSettle.observerRetryDelays.count + 1)
        #expect(logged.last?.attempt == FocusSettle.observerRetryDelays.count + FocusSettle.observerSlowRetryLimit)
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
        #expect(harness.observerAttempts(pid: zaloPID).last?.result == .installedBestEffort)
        #expect(harness.scheduler.pendingCount == 0)
        harness.ax.focus(
            pid: zaloPID, attributes: field(identifier: "second"), notify: .focusedElementChanged, element: 5)
        harness.sync()
        #expect(harness.snapshot.field.identifier == "second")
    }

    /// An app still half up when a best-effort attempt lands (the control run's probe of 18/11: focused-element
    /// changes refused with kAXErrorCannotComplete while the other names were accepted) keeps what it accepted, and
    /// the chain goes on with complete attempts until an observer that reports focused-element changes replaces it
    /// (PLT-R380 amendment of 19/11/2026).
    @Test func aBestEffortObserverWithoutFocusChangesIsReplacedByALaterAttemptPLTR380() {
        let harness = FocusHarness(scheduled: true)
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: field(), notify: nil)
        harness.start()
        harness.ax.refuseObservers(pid: zaloPID, times: 1 + FocusSettle.observerRetryDelays.count)
        harness.ax.refuseNotification(pid: zaloPID, .focusedElementChanged)
        harness.activate(zaloPID, field(identifier: "first"))
        harness.advance(by: .seconds(9))  // the first slow attempt (about 8.3 s) finds the app half up
        #expect(harness.ax.observedNotifications[zaloPID] == [.applicationActivated, .focusedWindowChanged])
        #expect(harness.observerAttempts(pid: zaloPID).last?.result == .installedBestEffort)
        #expect(harness.scheduler.pendingCount == 1)  // the chain goes on
        harness.ax.acceptNotification(pid: zaloPID, .focusedElementChanged)
        harness.advance(by: FocusSettle.observerSlowRetryDelay)
        #expect(harness.ax.observedNotifications[zaloPID] == FocusCore.baseNotifications)
        #expect(harness.observerAttempts(pid: zaloPID).last?.result == .installed)
        #expect(harness.scheduler.pendingCount == 0)
        harness.ax.focus(
            pid: zaloPID, attributes: field(identifier: "second"), notify: .focusedElementChanged, element: 5)
        harness.sync()
        #expect(harness.snapshot.field.identifier == "second")
    }

    /// The chain's last attempt may also find the app half up: once the chain is over, a publication of the owner's
    /// focus asks again, because an observer without focused-element changes does not count as one (PLT-R380).
    @Test func aPublicationReplacesAnObserverWithoutFocusChangesPLTR380() {
        let harness = FocusHarness(scheduled: true)
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: field(), notify: nil)
        harness.start()
        let chain = 1 + FocusSettle.observerRetryDelays.count + FocusSettle.observerSlowRetryLimit
        harness.ax.refuseObservers(pid: zaloPID, times: chain - 1)
        harness.ax.refuseNotification(pid: zaloPID, .focusedElementChanged)
        harness.activate(zaloPID, field(identifier: "first"))
        harness.advance(by: .seconds(120))
        #expect(harness.ax.observedNotifications[zaloPID] == [.applicationActivated, .focusedWindowChanged])
        #expect(harness.scheduler.pendingCount == 0)
        harness.ax.acceptNotification(pid: zaloPID, .focusedElementChanged)
        harness.ax.focus(pid: zaloPID, attributes: field(identifier: "moved"), notify: nil, element: 7)
        harness.idleRevalidation()
        #expect(harness.snapshot.field.identifier == "moved")
        #expect(harness.ax.observedNotifications[zaloPID] == FocusCore.baseNotifications)
        harness.ax.focus(
            pid: zaloPID, attributes: field(identifier: "second"), notify: .focusedElementChanged, element: 8)
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

    /// The observer sync of an activation (or a wake) asks too while the owner holds only a partial observer.
    @Test func anActivationReplacesAnObserverWithoutFocusChangesPLTR380() {
        let harness = FocusHarness(scheduled: true)
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: field(), notify: nil)
        harness.start()
        let chain = 1 + FocusSettle.observerRetryDelays.count + FocusSettle.observerSlowRetryLimit
        harness.ax.refuseObservers(pid: zaloPID, times: chain - 1)
        harness.ax.refuseNotification(pid: zaloPID, .focusedElementChanged)
        harness.activate(zaloPID, field(identifier: "first"))
        harness.advance(by: .seconds(120))
        let attempts = harness.ax.observeAttempts(pid: zaloPID)
        harness.activate(zaloPID, field(identifier: "first"))  // still refused: the partial observer stays
        #expect(harness.ax.observeAttempts(pid: zaloPID) == attempts + 1)
        #expect(harness.ax.observedNotifications[zaloPID] == [.applicationActivated, .focusedWindowChanged])
        harness.advance(by: .seconds(120))  // the new chain ends, still refused
        harness.ax.acceptNotification(pid: zaloPID, .focusedElementChanged)
        harness.activate(zaloPID, field(identifier: "first"))
        #expect(harness.ax.observedNotifications[zaloPID] == FocusCore.baseNotifications)
    }

    /// An app that refuses another name for good (here focused-window changes) and still refused focused-element
    /// changes when the attempt at the end of the 3,200 ms wait landed gets a partial observer. An attempt that takes
    /// every name or none can never replace it, so while a partial observer is in place the attempts are best effort
    /// too, and the first result with focused-element changes replaces it (PLT-R380).
    @Test func aPartialObserverOfAnAppThatRefusesAnotherNameForGoodIsReplacedPLTR380() {
        let harness = FocusHarness(scheduled: true)
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: field(), notify: nil)
        harness.start()
        harness.ax.refuseNotification(pid: zaloPID, .focusedWindowChanged)  // for good
        harness.ax.refuseNotification(pid: zaloPID, .focusedElementChanged)  // while it launches
        harness.activate(zaloPID, field(identifier: "first"))
        harness.advance(by: .seconds(7))  // the best-effort attempt (about 6.3 s) finds the app half up
        #expect(harness.ax.observedNotifications[zaloPID] == [.applicationActivated])
        #expect(harness.scheduler.pendingCount == 1)
        harness.ax.acceptNotification(pid: zaloPID, .focusedElementChanged)
        harness.advance(by: FocusSettle.observerSlowRetryDelay)
        #expect(harness.ax.observedNotifications[zaloPID] == [.applicationActivated, .focusedElementChanged])
        #expect(harness.ax.observerIDs(pid: zaloPID).count == 1)
        #expect(harness.observerAttempts(pid: zaloPID).last?.result == .installedBestEffort)
        #expect(harness.scheduler.pendingCount == 0)
        harness.ax.focus(
            pid: zaloPID, attributes: field(identifier: "second"), notify: .focusedElementChanged, element: 5)
        harness.sync()
        #expect(harness.snapshot.field.identifier == "second")
    }

    /// A best-effort attempt that brings no focused-element changes is no better than the partial observer in
    /// place: it is dropped, and the partial observer stays registered as it is, never removed and added again
    /// (PLT-R380).
    @Test func anAttemptNoBetterThanThePartialObserverLeavesItUntouchedPLTR380() {
        let harness = FocusHarness(scheduled: true)
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: field(), notify: nil)
        harness.start()
        harness.ax.refuseNotification(pid: zaloPID, .focusedElementChanged)
        harness.activate(zaloPID, field(identifier: "first"))
        harness.advance(by: .seconds(7))
        let partial = harness.ax.observerIDs(pid: zaloPID)
        #expect(partial.count == 1)
        harness.advance(by: .seconds(120))  // the chain's later attempts get the same names
        harness.ax.focus(pid: zaloPID, attributes: field(identifier: "moved"), notify: nil, element: 7)
        harness.idleRevalidation()  // a publication asks again: a new chain
        harness.advance(by: .seconds(120))
        #expect(harness.ax.observerIDs(pid: zaloPID) == partial)
        #expect(harness.ax.observedNotifications[zaloPID] == [.applicationActivated, .focusedWindowChanged])
        // The partial observer still delivers what it has.
        harness.ax.focus(
            pid: zaloPID, attributes: field(identifier: "window"), notify: .focusedWindowChanged, element: 8)
        harness.sync()
        #expect(harness.snapshot.field.identifier == "window")
    }

    /// An app that refuses focused-element changes for good keeps its partial observer. Once a chain is over, a
    /// publication of its focus asks again at most once until the app is activated again (it becomes the focus
    /// owner, or an activation or a wake syncs the observers), so staying in the app costs a bounded number of
    /// calls instead of a new chain for every publication (PLT-R380).
    @Test func publicationsAskAnAppThatRefusesFocusChangesForGoodOncePerActivationPLTR380() {
        let harness = FocusHarness(scheduled: true)
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: field(), notify: nil)
        harness.start()
        let chain = 1 + FocusSettle.observerRetryDelays.count + FocusSettle.observerSlowRetryLimit
        harness.ax.refuseNotification(pid: zaloPID, .focusedElementChanged)
        harness.activate(zaloPID, field(identifier: "first"))
        harness.advance(by: .seconds(120))  // the activation's chain ends with the partial observer
        #expect(harness.ax.observeAttempts(pid: zaloPID) == chain)
        var element: UInt16 = 10
        func publish() {
            element += 1
            harness.ax.focus(pid: zaloPID, attributes: field(identifier: "f\(element)"), notify: nil, element: element)
            harness.idleRevalidation()
            #expect(harness.snapshot.field.identifier == "f\(element)")
            harness.advance(by: .seconds(120))
        }
        for _ in 0..<5 { publish() }
        // The first publication started one more chain; the others asked nothing.
        #expect(harness.ax.observeAttempts(pid: zaloPID) == 2 * chain)
        #expect(harness.scheduler.pendingCount == 0)
        // An activation lets the observer sync and then one publication ask again.
        harness.activate(zaloPID, field(identifier: "first"))
        harness.advance(by: .seconds(120))
        for _ in 0..<3 { publish() }
        #expect(harness.ax.observeAttempts(pid: zaloPID) == 4 * chain)
        #expect(harness.scheduler.pendingCount == 0)
        #expect(harness.ax.observedNotifications[zaloPID] == [.applicationActivated, .focusedWindowChanged])
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

    /// Every scheduled attempt keeps the chain when it finds the app not wanted, the one after the 3,200 ms wait
    /// included; the first slow attempt then ends it, since slow attempts run only while the app is wanted (PLT-R380).
    @Test func theLastScheduledAttemptKeepsTheChainWhenTheAppIsNotWantedPLTR380() {
        let harness = FocusHarness(scheduled: true)
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: field(), notify: nil)
        harness.start()
        harness.ax.refuseObservers(pid: zaloPID, times: 1_000)
        harness.activate(zaloPID)
        harness.advance(by: .milliseconds(3_200))  // attempts 1 to 5 refused, attempt 6 pending
        harness.activate(terminalPID)
        harness.advance(by: .milliseconds(3_200))  // attempt 6 finds the app not wanted
        #expect(harness.observerAttempts(pid: zaloPID).last?.result == .notWanted)
        #expect(harness.scheduler.pendingCount == 1)
        harness.advance(by: FocusSettle.observerSlowRetryDelay)
        #expect(harness.scheduler.pendingCount == 0)
    }

    /// PLT-R380, PLT-R901: the scheduled attempts (a first one only when refused), the last attempt of a chain and
    /// every install after a refusal leave one log record each with the pid, the attempt and a result code, so an
    /// integration run shows how an app's observer was installed.
    @Test func observerAttemptsAreLoggedButAFirstInstallPLTR380() {
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
