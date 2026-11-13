// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Reading the system-wide focus on the ax thread (PLT-R381, PLT-R383, PLT-R384, PLT-R510, 5.2). Every AX call
// is bounded by the provider's 100 ms messaging timeout and skipped while the pid's breaker is open.

import AppModel
import CompatRules
import Diagnostics
import Foundation
import RealtimeSupport

/// Raw facts of one focus read.
struct FocusReading {
    var pid: Int32?
    var identity: ProcessIdentity?
    var engine: EngineFingerprint = .native
    var element: AXFocusedElement?
    var attributes: FocusAttributes?
    var availability: AXAvailability
}

extension FocusCore {
    /// Engines whose focused web area may expose a document URL for `web.urlPrefixes` rules. The protocol does
    /// not say which bundles have URL rules, so the URL is read only for browser engines (VERIFY with rules).
    static let documentURLEngines: Set<EngineFingerprint> = [.chromium, .webkitBrowser, .gecko]

    func readFocus(rules: any FocusDecisionResolving, at instant: MonotonicInstant) -> FocusReading {
        let pid: Int32
        switch services.ax.focusedApplication() {
        case .success(let value?): pid = value
        case .success(nil): return FocusReading(availability: .available)
        case .timedOut: return FocusReading(availability: .timedOut)
        case .unavailable, .failed: return FocusReading(availability: .unavailable)
        }
        let identity = services.processes.identity(of: pid)
        var reading = FocusReading(
            pid: pid, identity: identity, engine: engine(for: identity, rules: rules), availability: .available)
        // PLT-R384: while the breaker is open the snapshot says `timedOut` and rules fall back to bundle and
        // engine level, because the context has no AX fields.
        guard !breaker.isOpen(pid: pid, at: instant) else {
            reading.availability = .timedOut
            return reading
        }
        readElement(into: &reading, rules: rules, at: instant)
        return reading
    }

    private func readElement(
        into reading: inout FocusReading, rules: any FocusDecisionResolving, at instant: MonotonicInstant
    ) {
        guard let pid = reading.pid else { return }
        let bundle = reading.identity?.bundle
        let element: AXFocusedElement
        switch timed(bundle, { services.ax.focusedElement(pid: pid) }) {
        case .success(let value?): element = value
        case .success(nil): return
        case .timedOut: return axTimedOut(pid: pid, bundle: bundle, at: instant, reading: &reading)
        case .unavailable, .failed:
            reading.availability = .unavailable
            return
        }
        reading.element = element
        // Title and URL are requested only when a rule can use them, and only for matching (PLT-R383).
        let request = AXAttributeRequest(
            includeDocumentURL: Self.documentURLEngines.contains(reading.engine),
            includeWindowTitle: bundle.map(rules.titlePatternBundles.contains) ?? false)
        switch timed(bundle, { services.ax.attributes(of: element, request: request) }) {
        case .success(let attributes) where attributes.role == TextFocusGate.applicationRole:
            reading.element = nil  // the application itself: no focused element
        case .success(let attributes): reading.attributes = attributes
        case .timedOut: axTimedOut(pid: pid, bundle: bundle, at: instant, reading: &reading)
        case .unavailable, .failed: reading.availability = .unavailable
        }
    }

    private func axTimedOut(pid: Int32, bundle: BundleKey?, at instant: MonotonicInstant, reading: inout FocusReading) {
        reading.availability = .timedOut
        if breaker.recordTimeout(pid: pid, at: instant) {
            services.health.record(HealthEvent(kind: .axCircuitBreakerTrip, at: Date(), bundle: bundle))
        }
    }

    /// AX call duration per bundle (PLT-R801).
    private func timed<Result>(_ bundle: BundleKey?, _ call: () -> Result) -> Result {
        let start = services.clock.now()
        let result = call()
        if let bundle {
            services.metrics.axCallDurations.record(bundle, nanoseconds: services.clock.now().nanoseconds(since: start))
        }
        return result
    }

    /// PLT-R510: once per (bundle path, `CFBundleVersion`), cached on this thread.
    private func engine(for identity: ProcessIdentity?, rules: any FocusDecisionResolving) -> EngineFingerprint {
        guard let identity, let url = identity.bundleURL else { return .native }
        let key = FingerprintKey(bundlePath: url.path, buildVersion: identity.buildVersion)
        if let cached = fingerprints[key] { return cached }
        let engine = rules.fingerprint(bundleURL: url, bundle: identity.bundle)
        fingerprints[key] = engine
        return engine
    }

    /// 5.2 matcher context. Ancestor roles are capped at 6 levels.
    func matchContext(for reading: FocusReading) -> MatchContext {
        let attributes = reading.attributes
        return MatchContext(
            bundle: reading.identity?.bundle, appVersion: reading.identity?.shortVersion.flatMap { LooseVersion($0) },
            macOS: services.macOSVersion, engine: reading.engine, appCategory: reading.identity?.appCategory,
            role: attributes?.role, subrole: attributes?.subrole, identifier: attributes?.identifier,
            domClasses: attributes?.domClasses ?? [], ancestorRoles: Array((attributes?.ancestorRoles ?? []).prefix(6)),
            editable: attributes?.editable, documentURL: attributes?.documentURL,
            windowTitle: attributes?.windowTitle)
    }
}
