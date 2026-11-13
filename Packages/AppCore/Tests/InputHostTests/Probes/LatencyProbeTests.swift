// SPDX-License-Identifier: GPL-3.0-or-later
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
import Testing

@testable import InputHost
@testable import TestSupport

/// A fake probe window: every delivered keyDown changes the text `delay` later on the shared clock; edit keys
/// change it twice (deletion, then the insertion that shows the composed character) and record a
/// decide-to-posted sample like the worker would. A synchronous window applies the change inside the post (the
/// clock advances); an asynchronous one reports it at a later instant while the driver keeps typing, like a real
/// app whose edit lands after the next burst key was posted.
final class ProbeWindowModel: Sendable {
    let clock = ManualClock()
    let metrics = PlatformMetrics()
    private let driverBox = Mutex<LatencyProbeDriver?>(nil)
    private let editKeys: Set<KeyCode>
    private let passDelayMicroseconds: UInt64
    private let editDelayMicroseconds: UInt64
    private let asynchronous: Bool

    init(editKeys: Set<KeyCode> = [], passDelay: UInt64 = 1_000, editDelay: UInt64 = 3_000, asynchronous: Bool = false)
    {
        self.editKeys = editKeys
        passDelayMicroseconds = passDelay
        editDelayMicroseconds = editDelay
        self.asynchronous = asynchronous
    }

    func attach(_ driver: LatencyProbeDriver) { driverBox.withLock { $0 = driver } }

    func deliver(_ posted: FakeEventPoster.Posted) {
        guard case .synthetic(let event, _) = posted, event.isKeyDown,
            let driver = driverBox.withLock({ $0 })
        else { return }
        let start = clock.now()
        if editKeys.contains(event.keyCode) {
            metrics.probeDecideToPosted.record(nanoseconds: 400_000)
            change(driver, start: start, after: editDelayMicroseconds / 2, kind: .plain)  // deletion
            change(driver, start: start, after: editDelayMicroseconds, kind: .composed)  // the visible result
        } else {
            change(driver, start: start, after: passDelayMicroseconds, kind: .plain)
        }
    }

    private func change(
        _ driver: LatencyProbeDriver, start: MonotonicInstant, after microseconds: UInt64, kind: LatencyProbeChange
    ) {
        let instant = start.advanced(byMicroseconds: microseconds)
        if !asynchronous { clock.sleep(until: instant) }
        driver.textChanged(at: instant, kind: kind)
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

    @Test func changesAreMatchedToKeysInOrder() {
        // FIFO: the second key's change arrives after the third key was posted and still belongs to it.
        func key(_ microseconds: UInt64, delivered: Bool = true) -> LatencyProbePostedKey {
            LatencyProbePostedKey(instant: ProbeFixture.instant(microseconds), delivered: delivered)
        }
        let keys = [key(5_000), key(10_000), key(15_000), key(20_000, delivered: false), key(25_000)]
        let changes = [1_000, 7_000, 16_000, 18_000].map(ProbeFixture.instant)  // 1,000: left over, skipped
        let samples = LatencyProbeMath.correlate(keys, changes: changes)
        #expect(samples.map(\.latencyNanoseconds) == [2_000_000, 6_000_000, 3_000_000, nil, nil])
        #expect(samples.map(\.posted) == keys.map(\.instant))
    }

    @Test func changeKindFollowsTheComposedCharacter() {
        #expect(LatencyProbeChange(text: "bc a\u{1EA1}") == .composed)
        #expect(LatencyProbeChange(text: "a\u{0323}") == .composed)  // canonically equivalent
        #expect(LatencyProbeChange(text: "\u{1EA1} ") == .plain)
        #expect(LatencyProbeChange(text: "") == .plain)
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

    /// W3-A: the probe's own histogram has gate-aligned sub-buckets, so T2 is the 10 us bucket's upper end, not
    /// the log2 bucket's; the difference keeps only the run's samples in both layers.
    @Test func t2UsesTheSubBucketsOfTheProbeHistogram() {
        let histogram = Log2Histogram(subBuckets: true)
        histogram.record(nanoseconds: 2_000_000)  // before the run: must not count
        let before = histogram.snapshot()
        for _ in 0..<9 { histogram.record(nanoseconds: 400_000) }  // sub-bucket (390 us, 400 us]
        histogram.record(nanoseconds: 2_999_999)  // (2.95 ms, 3 ms]
        let run = LatencyProbeMath.difference(histogram.snapshot(), before)
        #expect(run.count == 10 && run.subBuckets?.counts.reduce(0, +) == 10)
        let result = LatencyProbeMath.result(profile: .normal, baseline: [], measured: [], decideToPosted: run)
        #expect(result.decideToPostedP50Microseconds == 400)
        #expect(result.decideToPostedP99Microseconds == 3_000)
        let mismatched = LatencyProbeMath.difference(run, Log2Histogram().snapshot())
        #expect(mismatched.subBuckets == nil && mismatched.count == 10)
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

    @Test(arguments: [LatencyProbeResult.Profile.fast, .burst])
    func editsSlowerThanTheKeyIntervalKeepEverySample(profile: LatencyProbeResult.Profile) async {
        // PLT-R810: an edit that lands 45 ms after its key (after the next key in both profiles) is still
        // credited to the tone key with its insertion time, not to the space that follows.
        let tone = KeyCode(rawValue: 0x26)
        let window = ProbeWindowModel(editKeys: [tone], passDelay: 2_000, editDelay: 45_000, asynchronous: true)
        let (driver, _) = ProbeFixture.driver(window: window)
        let word = [KeyCode(rawValue: 0x00), tone, KeyCode(rawValue: 0x31)]
        let keys = Array(repeating: word, count: 12).flatMap { $0 }
        let edits = (0..<12).map { $0 * 3 + 1 }
        let samples = await driver.run(profile: profile, keys: keys, edits: edits)
        #expect(samples.count == 12)
        #expect(samples.allSatisfy { $0.latencyNanoseconds == 45_000_000 })
        let baseline = await driver.run(profile: profile, keys: [KeyCode(rawValue: 0x0B), KeyCode(rawValue: 0x08)])
        #expect(baseline.map(\.latencyNanoseconds) == [2_000_000, 2_000_000])
    }

    @Test func aStopEndsPostingAtOnce() async {
        let window = ProbeWindowModel()
        let (driver, poster) = ProbeFixture.driver(window: window)
        let remaining = Mutex(2)
        let samples = await driver.run(profile: .normal, keys: Array(repeating: KeyCode(rawValue: 0x0B), count: 6)) {
            remaining.withLock { count in
                defer { count -= 1 }
                return count > 0
            }
        }
        #expect(samples.count == 2)
        #expect(poster.posted.count == 4)  // two keys, keyDown and keyUp each
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
        #expect(telex.baseline.count == 13)
        // The measured run starts at a word boundary: the baseline ends with the space key.
        #expect(telex.baseline.last == InjectionTestLayouts.keyCode(for: " "))
        #expect(telex.measured[2] == InjectionTestLayouts.keyCode(for: " "))
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
        let result = try #require(
            await session.run(script: script) { profile in started.withLock { $0.append(profile) } })
        #expect(started.withLock { $0 } == LatencyProbeResult.Profile.allCases)
        #expect(result.ranAt == wallClock.now())
        #expect(result.results.map(\.profile) == LatencyProbeResult.Profile.allCases)
        for profile in result.results {
            #expect(profile.samples == 12)
            #expect(profile.endToEndDeltaP50Microseconds == 2_000)  // 3 ms edit minus 1 ms pass-through
            #expect(profile.decideToPostedP99Microseconds == 400)  // only the run's own 400 µs samples
        }
        let eventsPerProfile = 2 * (script.baseline.count + script.measured.count)
        #expect(poster.posted.count == 3 * eventsPerProfile)
    }

    @Test func aStopAfterTheFirstProfileYieldsNoResult() async throws {
        let layout = InjectionTestLayouts.qwerty()
        let script = try #require(LatencyProbeScript.standard(layout: layout, method: .telex))
        let window = ProbeWindowModel(editKeys: [InjectionTestLayouts.keyCode(for: "j")])
        let (driver, poster) = ProbeFixture.driver(window: window)
        let session = LatencyProbeSession(driver: driver, metrics: window.metrics, wallClock: FixedWallClock())
        let started = Mutex<[LatencyProbeResult.Profile]>([])
        let keepGoing = Atomic<Bool>(true)
        let result = await session.run(
            script: script,
            progress: { profile in
                started.withLock { $0.append(profile) }
                if profile == .fast { keepGoing.store(false, ordering: .relaxed) }
            },
            shouldContinue: { keepGoing.load(ordering: .relaxed) })
        #expect(result == nil)
        #expect(started.withLock { $0 } == [.normal, .fast])
        // Only the normal profile typed; the stop during "fast" prevented every further key.
        #expect(poster.posted.count == 2 * (script.baseline.count + script.measured.count))
    }
}
