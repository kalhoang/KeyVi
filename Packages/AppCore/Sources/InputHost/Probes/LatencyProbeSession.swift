// SPDX-License-Identifier: LicenseRef-App-Pending
//
// "Run typing latency test" (PLT-R810): for each timing profile a pass-through baseline run and a measured run
// with edits, combined into a `LatencyProbeResult` for the diagnostics report.

public import AppModel
public import Diagnostics
internal import Foundation
internal import RealtimeSupport

/// Keys typed by the probe. The baseline keys pass through the engine unchanged (consonants that are neither
/// Telex nor VNI modifiers); the measured keys alternate a vowel, a tone key that turns it into "ạ" (an edit)
/// and a space. Only the tone keys are measured (`measuredIndices`), the other keys keep the field realistic.
public struct LatencyProbeScript: Sendable, Hashable {
    public var baseline: [KeyCode]
    public var measured: [KeyCode]
    public var measuredIndices: [Int]

    public init(baseline: [KeyCode], measured: [KeyCode], measuredIndices: [Int]) {
        self.baseline = baseline
        self.measured = measured
        self.measuredIndices = measuredIndices
    }

    static let baselineCharacters: [Character] = Array("bcghklmnpqtv")
    static let repetitions = 12

    /// Script for the current layout and method; nil when the layout cannot produce one of the keys (the
    /// window then explains that the test needs a Latin layout).
    public static func standard(layout: LayoutTable, method: TypingMethod) -> LatencyProbeScript? {
        // "a" + tone key + space: Telex "j" and VNI "5" make "ạ"; "aj" is no English word, so English restore
        // never undoes the edit.
        let tone: Character = method == .telex ? "j" : "5"
        var baseline: [KeyCode] = []
        for character in baselineCharacters {
            guard let code = layout.keyCode(producing: character) else { return nil }
            baseline.append(code)
        }
        guard let vowel = layout.keyCode(producing: "a"), let toneKey = layout.keyCode(producing: tone),
            let space = layout.keyCode(producing: " ")
        else { return nil }
        let measured = Array(repeating: [vowel, toneKey, space], count: repetitions).flatMap { $0 }
        let indices = (0..<repetitions).map { $0 * 3 + 1 }
        return LatencyProbeScript(baseline: baseline, measured: measured, measuredIndices: indices)
    }
}

/// Runs the profiles one after another. The probe window must have focus and the host must be in Vietnamese
/// mode for the measured run to produce edits.
public final class LatencyProbeSession: Sendable {
    private let driver: LatencyProbeDriver
    private let metrics: PlatformMetrics
    private let wallClock: any WallClock

    public init(driver: LatencyProbeDriver, metrics: PlatformMetrics, wallClock: any WallClock) {
        self.driver = driver
        self.metrics = metrics
        self.wallClock = wallClock
    }

    /// `progress` is called before each profile starts (the window shows which one runs).
    public func run(
        script: LatencyProbeScript, profiles: [LatencyProbeResult.Profile] = LatencyProbeResult.Profile.allCases,
        progress: @Sendable (LatencyProbeResult.Profile) -> Void = { _ in }
    ) async -> LatencyProbeResult {
        var results: [LatencyProbeResult.ProfileResult] = []
        for profile in profiles {
            progress(profile)
            let baseline = await driver.run(profile: profile, keys: script.baseline)
            let before = metrics.probeDecideToPosted.snapshot()
            let all = await driver.run(profile: profile, keys: script.measured)
            let decideToPosted = LatencyProbeMath.difference(metrics.probeDecideToPosted.snapshot(), before)
            let measured = script.measuredIndices.compactMap { all.indices.contains($0) ? all[$0] : nil }
            results.append(
                driver.result(
                    profile: profile, baseline: baseline, measured: measured, decideToPosted: decideToPosted))
        }
        return LatencyProbeResult(ranAt: wallClock.now(), results: results)
    }
}
