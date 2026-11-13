// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The diagnostics drivers that post their own events (PLT-R1205 guided test, PLT-R810 latency probe). They
// share this launch's event marker with the tap, so the pipeline recognises their events as probe events: kept
// out of the user's metrics (PLT-R810) and passed unchanged by the guided test's pass-through. Workstream W2-H.

internal import Injection

extension InputHostController {
    /// PLT-R1205 step 3: types the canary with each candidate strategy. The caller brackets every run with
    /// `setDiagnosticsPassThrough(true)` and `(false)`; the key codes come from the current layout (PLT-R405).
    public func makeGuidedTestRunner() -> GuidedTestRunner {
        GuidedTestRunner(
            poster: dependencies.poster, fieldAccess: dependencies.fieldAccess, marker: channels.marker,
            clock: tapClock, layout: channels.snapshots.inputSource.load().table)
    }

    /// PLT-R810: the latency probe's driver, timed on the clock the tap stamps events with.
    public func makeLatencyProbeDriver() -> LatencyProbeDriver {
        LatencyProbeDriver(poster: dependencies.poster, marker: channels.marker, clock: tapClock)
    }
}
