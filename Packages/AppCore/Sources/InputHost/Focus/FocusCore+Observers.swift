// SPDX-License-Identifier: LicenseRef-App-Pending
//
// AXObservers on the focus owner and on overlay apps (PLT-R380). Their run-loop sources live on the ax thread;
// callbacks hop back through `FocusNotificationSink`.

import AppModel

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
            addObserver(pid: pid, bundle: want.bundle, overlay: want.overlay)
        }
    }

    private func addObserver(pid: Int32, bundle: BundleKey?, overlay: Bool) {
        let kinds = notifications(for: bundle)
        let sink = self.sink
        let handler: @Sendable (AXNotificationKind) -> Void = { [weak sink] kind in
            sink?.axNotification(pid: pid, kind: kind)
        }
        guard let observation = services.ax.observe(pid: pid, notifications: kinds, handler: handler) else { return }
        services.thread.addSource(observation.runLoopSource)
        observed[pid] = ObservedApplication(observation: observation, kinds: kinds, bundle: bundle, overlay: overlay)
    }

    func removeObserver(_ pid: Int32) {
        guard let entry = observed.removeValue(forKey: pid) else { return }
        services.thread.removeSource(entry.observation.runLoopSource)
        entry.observation.invalidate()
    }
}
