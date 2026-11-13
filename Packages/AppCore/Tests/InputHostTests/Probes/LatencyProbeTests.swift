// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PLT-R810 latency probe: result math with synthetic timestamps (`ManualClock`), probe-kind marker on every
// posted event (user metrics exclude them), three timing profiles, T2 from the probe histogram of the measured
// run and T4 as measured minus pass-through baseline. Only `FakeEventPoster` is used: no probe code runs against
// the real poster in tests.

import AppModel
import Diagnostics
import Foundation
import Injection
import RealtimeSupport
import Synchronization
import Testing

@testable import InputHost
@testable import TestSupport

/// A fake probe window: every delivered keyDown changes the text `delay` later on the shared clock; edit keys
/// change it twice (deletion then insertion) and record a decide-to-posted sample like the worker would.
final class ProbeWindowModel: Sendable {
    let clock = ManualClock()
    let metrics = PlatformMetrics()
    private let driverBox = Mutex<LatencyProbeDriver?>(nil)
    private let editKeys: Set<KeyCode>
    private let passDelayMicroseconds: UInt64
    private let editDelayMicroseconds: UInt64

    init(editKeys: Set<KeyCode> = [], passDelay: UInt64 = 1_000, editDelay: UInt64 = 3_000) {
        self.editKeys = editKeys
        passDelayMicroseconds = passDelay
        editDelayMicroseconds = editDelay
    }

    func attach(_ driver: LatencyProbeDriver) { driverBox.withLock { $0 = driver } }

    func deliver(_ posted: FakeEventPoster.Posted) {
        guard case .synthetic(let event, _) = posted, event.isKeyDown,
            let driver = driverBox.withLock({ $0 })
        else { return }
        if editKeys.contains(event.keyCode) {
            metrics.probeDecideToPosted.record(nanoseconds: 400_000)
            clock.advance(byMicroseconds: editDelayMicroseconds / 2)
            driver.textChanged(at: clock.now())  // deletion
            clock.advance(byMicroseconds: editDelayMicroseconds / 2)
            driver.textChanged(at: clock.now())  // insertion: the visible result
        } else {
            clock.advance(byMicroseconds: passDelayMicroseconds)
            driver.textChanged(at: clock.now())
        }
    }
}

enum ProbeFixture {
    static let marker = EventMarker(tag: 0xAB_CDEF)

    static func driver(window: ProbeWindowModel) -> (LatencyProbeDriver, FakeEventPoster) {
        let poster = FakeEventPoster { window.deliver($0) }
        let driver = LatencyProbeDriver(poster: poster, marker: marker, clock: window.clock)
        window.attach(driver)
        return (driver, poster)
    }

    static func instant(_ microseconds: UInt64) -> MonotonicInstant {
        MonotonicInstant(nanoseconds: 1_000_000_000 + microseconds * 1_000)
    }
}

@Suite("Latency probe math (PLT-R810)")
struct LatencyProbeMathTests {
    @Test func profilesUseTheSpecifiedSpacing() {
        #expect(LatencyProbeResult.Profile.normal.keyInterval == .milliseconds(120))
        #expect(LatencyProbeResult.Profile.fast.keyInterval == .milliseconds(40))
        #expect(LatencyProbeResult.Profile.burst.keyInterval == .milliseconds(5))
    }

    @Test func eachKeyTakesTheLastChangeBeforeTheNextKey() {
        let posted = [0, 120_000, 240_000].map(ProbeFixture.instant)
        let changes = [1_000, 2_000, 121_500, 400_000, 239_000].map(ProbeFixture.instant)
        let samples = LatencyProbeMath.correlate(posted: posted, changes: changes, settle: .milliseconds(150))
        #expect(samples.map(\.latencyNanoseconds) == [2_000_000, 119_000_000, nil])
        let settled = LatencyProbeMath.correlate(
            posted: posted, changes: changes + [ProbeFixture.instant(250_000)], settle: .milliseconds(150))
        #expect(settled.last?.latencyNanoseconds == 10_000_000)
    }

    @Test func nearestRankPercentiles() {
        let values: [UInt64] = (1...100).map { UInt64($0) }
        #expect(LatencyProbeMath.percentile(values, 0.5) == 50)
        #expect(LatencyProbeMath.percentile(values, 0.99) == 99)
        #expect(LatencyProbeMath.percentile([7], 0.99) == 7)
        #expect(LatencyProbeMath.percentile([], 0.5) == nil)
    }

    @Test func t4IsMeasuredMinusBaselineAndNeverNegative() {
        func samples(_ latencies: [UInt64]) -> [LatencyProbeSample] {
            latencies.map { LatencyProbeSample(posted: ProbeFixture.instant(0), changed: ProbeFixture.instant($0)) }
        }
        let result = LatencyProbeMath.result(
            profile: .fast, baseline: samples([1_000, 1_000, 2_000]), measured: samples([3_000, 3_500, 9_000]),
            decideToPosted: .empty)
        #expect(result.profile == .fast)
        #expect(result.endToEndDeltaP50Microseconds == 2_500)  // 3,500 - 1,000
        #expect(result.endToEndDeltaP99Microseconds == 7_000)  // 9,000 - 2,000
        #expect(result.samples == 3)
        #expect(result.decideToPostedP50Microseconds == 0)
        let faster = LatencyProbeMath.result(
            profile: .normal, baseline: samples([5_000]), measured: samples([1_000]), decideToPosted: .empty)
        #expect(faster.endToEndDeltaP50Microseconds == 0)
        let none = LatencyProbeMath.result(
            profile: .normal, baseline: samples([5_000]),
            measured: [LatencyProbeSample(posted: ProbeFixture.instant(0), changed: nil)], decideToPosted: .empty)
        #expect(none.samples == 0 && none.endToEndDeltaP99Microseconds == 0)
    }

    @Test func t2ComesFromTheRunsOwnHistogramSamples() {
        let histogram = Log2Histogram()
        histogram.record(nanoseconds: 50_000_000)  // before the run: must not count
        let before = histogram.snapshot()
        for _ in 0..<10 { histogram.record(nanoseconds: 400_000) }  // bucket [262 µs, 524 µs)
        let run = LatencyProbeMath.difference(histogram.snapshot(), before)
        #expect(run.count == 10)
        let result = LatencyProbeMath.result(profile: .burst, baseline: [], measured: [], decideToPosted: run)
        #expect(result.decideToPostedP50Microseconds == 524)
        #expect(result.decideToPostedP99Microseconds == 524)
    }

    @Test func durationsConvertToMicroseconds() {
        #expect(LatencyProbeMath.microseconds(.milliseconds(120)) == 120_000)
        #expect(LatencyProbeMath.microseconds(.seconds(2)) == 2_000_000)
        #expect(LatencyProbeMath.microseconds(.zero - .seconds(1)) == 0)
    }
}

@Suite("Latency probe driver (PLT-R810)")
struct LatencyProbeDriverTests {
    @Test(arguments: LatencyProbeResult.Profile.allCases)
    func keysArePacedOnAbsoluteDeadlines(profile: LatencyProbeResult.Profile) async {
        let window = ProbeWindowModel()
        let (driver, poster) = ProbeFixture.driver(window: window)
        let keys = [0x0B, 0x08, 0x05, 0x04].map(KeyCode.init(rawValue:))
        let samples = await driver.run(profile: profile, keys: keys)
        #expect(samples.count == 4)
        let interval = LatencyProbeMath.microseconds(profile.keyInterval) * 1_000
        for index in 1..<samples.count {
            #expect(samples[index].posted.nanoseconds(since: samples[0].posted) == interval * UInt64(index))
        }
        #expect(samples.allSatisfy { $0.latencyNanoseconds == 1_000_000 })
        #expect(poster.posted.count == 8)  // keyDown and keyUp per key
    }

    @Test func everyEventIsAPhysicalLikeProbeEvent() async {
        // PLT-R810: unmarked for the pipeline's echo logic, tagged as probe so user metrics exclude it.
        let window = ProbeWindowModel()
        let (driver, poster) = ProbeFixture.driver(window: window)
        _ = await driver.run(profile: .burst, keys: [KeyCode(rawValue: 0x0B)])
        for posted in poster.posted {
            guard case .probe = ProbeFixture.marker.classify(posted.userData) else {
                Issue.record("not a probe event")
                continue
            }
            guard case .synthetic(let event, _) = posted else { continue }
            #expect(event.unicode.count == 0 && event.flags == 0)
        }
    }

    @Test func aFailingPosterLeavesSamplesWithoutChanges() async {
        let window = ProbeWindowModel()
        let (driver, poster) = ProbeFixture.driver(window: window)
        poster.setMode(.failingCreation)
        let samples = await driver.run(profile: .burst, keys: [KeyCode(rawValue: 0x0B), KeyCode(rawValue: 0x08)])
        #expect(samples.count == 2 && samples.allSatisfy { $0.changed == nil })
    }

    @Test func changesFromAnEarlierRunAreForgotten() async {
        let window = ProbeWindowModel()
        let (driver, _) = ProbeFixture.driver(window: window)
        driver.textChanged(at: window.clock.now().advanced(byMicroseconds: 10))
        let samples = await driver.run(profile: .normal, keys: [KeyCode(rawValue: 0x0B)])
        #expect(samples.first?.latencyNanoseconds == 1_000_000)
    }
}

@Suite("Latency probe session (PLT-R810)")
struct LatencyProbeSessionTests {
    @Test func standardScriptNeedsTheLayoutKeys() throws {
        let layout = InjectionTestLayouts.qwerty()
        let telex = try #require(LatencyProbeScript.standard(layout: layout, method: .telex))
        #expect(telex.baseline.count == 12)
        #expect(telex.measured.count == 36)
        #expect(telex.measuredIndices.first == 1 && telex.measuredIndices.count == 12)
        #expect(telex.measured[1] == InjectionTestLayouts.keyCode(for: "j"))
        let vni = try #require(LatencyProbeScript.standard(layout: layout, method: .vni))
        #expect(vni.measured[1] == InjectionTestLayouts.keyCode(for: "5"))
        let empty = LayoutTable(
            source: layout.source, keyboardType: 40,
            entries: Array(repeating: .none, count: LayoutTable.keyCodeCount * LayoutModifierState.allCases.count))
        #expect(LatencyProbeScript.standard(layout: empty, method: .telex) == nil)
    }

    @Test func runsEveryProfileWithBaselineAndMeasuredRuns() async throws {
        let layout = InjectionTestLayouts.qwerty()
        let script = try #require(LatencyProbeScript.standard(layout: layout, method: .telex))
        let window = ProbeWindowModel(editKeys: [InjectionTestLayouts.keyCode(for: "j")])
        let (driver, poster) = ProbeFixture.driver(window: window)
        window.metrics.probeDecideToPosted.record(nanoseconds: 90_000_000)  // an earlier run: excluded
        let wallClock = FixedWallClock()
        let session = LatencyProbeSession(driver: driver, metrics: window.metrics, wallClock: wallClock)
        let started = Mutex<[LatencyProbeResult.Profile]>([])
        let result = await session.run(script: script) { profile in started.withLock { $0.append(profile) } }
        #expect(started.withLock { $0 } == LatencyProbeResult.Profile.allCases)
        #expect(result.ranAt == wallClock.now())
        #expect(result.results.map(\.profile) == LatencyProbeResult.Profile.allCases)
        for profile in result.results {
            #expect(profile.samples == 12)
            #expect(profile.endToEndDeltaP50Microseconds == 2_000)  // 3 ms edit minus 1 ms pass-through
            #expect(profile.decideToPostedP99Microseconds == 524)  // only the run's own 400 µs samples
        }
        let eventsPerProfile = 2 * (script.baseline.count + script.measured.count)
        #expect(poster.posted.count == 3 * eventsPerProfile)
    }
}
