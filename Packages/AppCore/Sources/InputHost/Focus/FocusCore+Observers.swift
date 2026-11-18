// SPDX-License-Identifier: GPL-3.0-or-later
//
// AXObservers on the focus owner and on overlay apps (PLT-R380). Their run-loop sources live on the ax thread;
// callbacks hop back through `FocusNotificationSink`.

import AppModel
import Diagnostics

struct ObservedApplication {
    var observation: any AXObservation
    var kinds: Set<AXNotificationKind>
    var bundle: BundleKey?
    var overlay: Bool
    /// Installed by a best-effort attempt without the focused-element changes it asked for (an app still half up,
    /// PLT-R380 amendment of 19/11/2026): it keeps what the app took, but does not count as the app's observer, so
    /// attempts go on until a complete one replaces it.
    var partial: Bool
}

extension FocusCore {
    static let baseNotifications: Set<AXNotificationKind> = [
        .focusedElementChanged, .focusedWindowChanged, .applicationActivated,
    ]

    /// Title changes are observed only for bundles with a `titlePattern` rule (PLT-R380).
    func notifications(for bundle: BundleKey?) -> Set<AXNotificationKind> {
        guard let bundle, rules?.titlePatternBundles.contains(bundle) == true else { return Self.baseNotifications }
        return Self.baseNotifications.union([.titleChanged])
    }

    /// Re-scans running overlay apps when asked (start, rules change, revalidation), then makes the observer set
    /// equal to overlays plus the current owner.
    func syncObservers(scanOverlays: Bool) {
        if scanOverlays, let rules {
            let overlays = services.processes.runningApplications().filter { rules.overlayBundles.contains($0.bundle) }
            overlayPIDs = Dictionary(overlays.map { ($0.pid, $0.bundle) }, uniquingKeysWith: { first, _ in first })
        }
        reconcileObservers(ownerPID: current?.pid, ownerBundle: current?.identity?.bundle)
    }

    func observeOwner(pid: Int32?, bundle: BundleKey?) {
        reconcileObservers(ownerPID: pid, ownerBundle: bundle)
    }

    private func reconcileObservers(ownerPID: Int32?, ownerBundle: BundleKey?) {
        var wanted: [Int32: (bundle: BundleKey?, overlay: Bool)] = overlayPIDs.mapValues { ($0, true) }
        if let ownerPID, wanted[ownerPID] == nil { wanted[ownerPID] = (ownerBundle, false) }
        for (pid, entry) in observed {
            guard let want = wanted[pid], notifications(for: want.bundle) == entry.kinds else {
                removeObserver(pid)
                continue
            }
            observed[pid]?.overlay = want.overlay
        }
        for (pid, want) in wanted where !observerInPlace(pid) {
            // A partial observer's own chain is still asking.
            guard observed[pid] == nil || deferred.retryTimers[pid] == nil else { continue }
            addObserver(pid: pid, bundle: want.bundle, overlay: want.overlay, attempt: 0)
        }
    }

    /// `pid` has an observer that reports focused-element changes, or the best one the app can give.
    func observerInPlace(_ pid: Int32) -> Bool {
        observed[pid].map { !$0.partial } ?? false
    }

    /// The observation `pid` should have now: the focus owner's or an overlay app's; nil when neither.
    func wantedObservation(of pid: Int32) -> (bundle: BundleKey?, overlay: Bool)? {
        if let bundle = overlayPIDs[pid] { return (bundle, true) }
        guard pid == current?.pid else { return nil }
        return (current?.identity?.bundle, false)
    }

    /// True when an observer was installed. A refusal (an app still launching answers kAXErrorCannotComplete) is
    /// retried after a delay (`FocusCore+Settle.swift`); `attempt` counts the retries so far. An observer this
    /// installs replaces a partial one.
    @discardableResult
    func addObserver(pid: Int32, bundle: BundleKey?, overlay: Bool, attempt: Int) -> Bool {
        let kinds = notifications(for: bundle)
        let sink = self.sink
        let handler: @Sendable (AXNotificationKind) -> Void = { [weak sink] kind in
            sink?.axNotification(pid: pid, kind: kind)
        }
        // From the end of the scheduled attempts on, an app without an observer keeps what it takes (one name
        // refused for good must not cost the others); a partial observer is replaced only by a complete one.
        let bestEffort = attempt >= FocusSettle.observerRetryDelays.count && observed[pid] == nil
        let mode: AXObservationMode = bestEffort ? .bestEffort : .complete
        guard let observation = services.ax.observe(pid: pid, notifications: kinds, mode: mode, handler: handler)
        else {
            noteObserverAttempt(pid: pid, attempt: attempt, result: .refused)
            scheduleObserverRetry(pid: pid, attempt: attempt)
            return false
        }
        if attempt > 0 {  // a first attempt that installs is every app switch: nothing to report
            noteObserverAttempt(pid: pid, attempt: attempt, result: bestEffort ? .installedBestEffort : .installed)
        }
        let partial =
            bestEffort && kinds.contains(.focusedElementChanged)
            && !observation.notifications.contains(.focusedElementChanged)
        removeObserver(pid)
        services.thread.addSource(observation.runLoopSource)
        observed[pid] = ObservedApplication(
            observation: observation, kinds: kinds, bundle: bundle, overlay: overlay, partial: partial)
        if partial { scheduleObserverRetry(pid: pid, attempt: attempt) } else { cancelObserverRetry(pid: pid) }
        return true
    }

    /// One content-free record per reported observer attempt: the pid, the attempt and a result code (PLT-R380,
    /// PLT-R901). Logged on the ax thread; the logger hands it to the utility queue. An install is always reported;
    /// a call that was refused or skipped only within the scheduled attempts or as the chain's last attempt, so an
    /// app that never accepts writes a few lines per chain, not one every 2 s.
    func noteObserverAttempt(pid: Int32, attempt: Int, result: ObserverAttemptResult) {
        let installed = result == .installed || result == .installedBestEffort
        let reported =
            installed || attempt <= FocusSettle.observerRetryDelays.count
            || FocusSettle.observerRetryDelay(after: attempt) == nil
        guard reported else { return }
        services.logger?.log(.focus(.observerAttempt(pid: pid, attempt: attempt, result: result)), level: .info)
    }

    func removeObserver(_ pid: Int32) {
        guard let entry = observed.removeValue(forKey: pid) else { return }
        services.thread.removeSource(entry.observation.runLoopSource)
        entry.observation.invalidate()
    }
}
