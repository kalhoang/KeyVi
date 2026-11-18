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
        for (pid, want) in wanted where observed[pid] == nil {
            addObserver(pid: pid, bundle: want.bundle, overlay: want.overlay, attempt: 0)
        }
    }

    /// The observation `pid` should have now: the focus owner's or an overlay app's; nil when neither.
    func wantedObservation(of pid: Int32) -> (bundle: BundleKey?, overlay: Bool)? {
        if let bundle = overlayPIDs[pid] { return (bundle, true) }
        guard pid == current?.pid else { return nil }
        return (current?.identity?.bundle, false)
    }

    /// True when the observer is in place. A refusal (an app still launching answers kAXErrorCannotComplete) is
    /// retried after a delay (`FocusCore+Settle.swift`); `attempt` counts the retries so far.
    @discardableResult
    func addObserver(pid: Int32, bundle: BundleKey?, overlay: Bool, attempt: Int) -> Bool {
        let kinds = notifications(for: bundle)
        let sink = self.sink
        let handler: @Sendable (AXNotificationKind) -> Void = { [weak sink] kind in
            sink?.axNotification(pid: pid, kind: kind)
        }
        // The last retry keeps what the app takes: one name refused for good must not cost the others.
        let mode: AXObservationMode = attempt >= FocusSettle.observerRetryDelays.count ? .bestEffort : .complete
        guard let observation = services.ax.observe(pid: pid, notifications: kinds, mode: mode, handler: handler)
        else {
            noteObserverAttempt(pid: pid, attempt: attempt, result: .refused)
            scheduleObserverRetry(pid: pid, attempt: attempt)
            return false
        }
        if attempt > 0 {  // a first attempt that installs is every app switch: nothing to report
            noteObserverAttempt(
                pid: pid, attempt: attempt, result: mode == .complete ? .installed : .installedBestEffort)
        }
        cancelObserverRetry(pid: pid)
        services.thread.addSource(observation.runLoopSource)
        observed[pid] = ObservedApplication(observation: observation, kinds: kinds, bundle: bundle, overlay: overlay)
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
