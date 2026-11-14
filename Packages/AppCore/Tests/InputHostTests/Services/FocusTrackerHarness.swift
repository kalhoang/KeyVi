// SPDX-License-Identifier: GPL-3.0-or-later
//
// Shared fixtures for the focus-tracker tests: a real ax RunLoopThread with fake AX, processes and rules, time
// from a ManualClock. Every test waits for the ax thread with `sync()`. Bundle identifiers appear only in test
// fixtures (PLT-R501).

import AppModel
import CompatRules
import Diagnostics
import Foundation
import Injection
import RealtimeSupport
import SettingsStore

@testable import InputHost
@testable import TestSupport

enum FocusFixtures {
    static let terminalPID: Int32 = 100
    static let spotlightPID: Int32 = 200
    static let zaloPID: Int32 = 300
    static let codePID: Int32 = 400
    static let browserPID: Int32 = 500
    static let chromePID: Int32 = 600
    static let terminal = bundle("com.apple.Terminal")
    static let spotlight = bundle("com.apple.Spotlight")
    static let zalo = bundle("com.example.zalo")
    static let code = bundle("com.example.code")
    static let browser = bundle("com.example.browser")
    static let chrome = bundle("com.google.Chrome")

    /// Ancestors of a field that is not web content (no `AXWebArea`); seven, so the 6-level cap shows.
    static let nativeAncestors = ["AXScrollArea", "AXGroup", "AXWindow", "AXApplication", "A5", "A6", "A7"]

    static func attributes(
        role: String? = "AXTextArea", subrole: String? = nil, identifier: String? = nil, title: String? = nil,
        url: String? = nil, ancestors: [String] = nativeAncestors
    ) -> FocusAttributes {
        FocusAttributes(
            role: role, subrole: subrole, identifier: identifier, domClasses: [], editable: nil,
            ancestorRoles: ancestors, documentURL: url, windowTitle: title)
    }

    static func decision(
        _ rule: String?, strategy: InjectionStrategy = .backspaceReplace, axEnable: AXEnableMode = .none,
        tieLoser: String? = nil, defaultMode: FirstSeenMode = .inherit, engine: EngineFingerprint = .native
    ) -> ResolvedDecision {
        var base = FakeDecisionResolver.defaultDecision(engine: engine)
        base.rule = rule.map { RuleID(rawValue: $0)! }
        base.source = rule == nil ? .default : .shipped
        base.strategy = strategy
        base.axEnable = axEnable
        base.tieLoser = tieLoser.map { RuleID(rawValue: $0)! }
        base.defaultMode = defaultMode
        return base
    }

    static func resolver(
        _ decisions: [BundleKey: ResolvedDecision] = [:], overlays: Set<BundleKey> = [spotlight]
    ) -> FakeDecisionResolver {
        FakeDecisionResolver(
            decisions: decisions, fallback: decision(nil), overlayBundles: overlays, titlePatternBundles: [browser],
            fingerprints: [code: .electron, browser: .chromium])
    }

    static let processes = [
        FakeProcessIdentityProvider.process(pid: terminalPID, bundle: terminal.rawValue, name: "Terminal"),
        FakeProcessIdentityProvider.process(pid: spotlightPID, bundle: spotlight.rawValue, name: "Spotlight"),
        FakeProcessIdentityProvider.process(pid: zaloPID, bundle: zalo.rawValue, name: "Zalo"),
        FakeProcessIdentityProvider.process(pid: codePID, bundle: code.rawValue, name: "Code"),
        FakeProcessIdentityProvider.process(pid: browserPID, bundle: browser.rawValue, name: "Browser", build: "9"),
        FakeProcessIdentityProvider.process(pid: chromePID, bundle: chrome.rawValue, name: "Chrome"),
    ]
}

/// Counts fingerprint requests (PLT-R510 cache) and forwards everything else.
final class CountingFocusResolver: FocusDecisionResolving {
    let inner: any FocusDecisionResolving
    private let calls = Mutex<[BundleKey]>([])
    private let contexts = Mutex<[MatchContext]>([])
    private let fingerprintOverrides: [BundleKey: EngineFingerprint]

    init(_ inner: any FocusDecisionResolving, fingerprints: [BundleKey: EngineFingerprint] = [:]) {
        self.inner = inner
        fingerprintOverrides = fingerprints
    }

    func resolve(_ context: MatchContext) -> ResolvedDecision {
        contexts.withLock { $0.append(context) }
        return inner.resolve(context)
    }

    var overlayBundles: Set<BundleKey> { inner.overlayBundles }
    var titlePatternBundles: Set<BundleKey> { inner.titlePatternBundles }

    func fingerprint(bundleURL: URL, bundle: BundleKey) -> EngineFingerprint {
        calls.withLock { $0.append(bundle) }
        return fingerprintOverrides[bundle] ?? inner.fingerprint(bundleURL: bundleURL, bundle: bundle)
    }

    var fingerprintCalls: [BundleKey] { calls.withLock { $0 } }
    var resolvedContexts: [MatchContext] { contexts.withLock { $0 } }
}

final class FocusHarness {
    let thread = RunLoopThread(name: "test.focus.ax", qualityOfService: .userInitiated)
    let ax = FakeAXProvider()
    let processes = FakeProcessIdentityProvider(processes: FocusFixtures.processes)
    let cell: SnapshotCell<FocusSnapshot>
    let generation = CurrentFocusGeneration()
    let inbox = SPSCRing<AXNotice>(capacity: 64)
    let metrics = PlatformMetrics()
    let health = HealthEventLog()
    let clock = ManualClock()
    let documents = Recorder<AppModesDocument>()
    let scheduler: ManualScheduler
    /// Every timer the tracker asked for (PLT-R803 leeway checks).
    let timers: TimerRequestRecorder
    let tracker: FocusTracker

    /// `scheduled`: the tracker gets the ManualScheduler for its settle re-reads and observer retries; otherwise
    /// it defers nothing (the behaviour every other focus test pins).
    init(scheduled: Bool = false) {
        scheduler = ManualScheduler(clock: clock)
        timers = TimerRequestRecorder(base: scheduler)
        thread.start()
        let initial = FocusSnapshot(
            generation: .initial, app: nil, field: .unknown,
            decision: HostDecisionMapper.map(FocusFixtures.decision(nil), engine: .native, optedIntoPaste: false),
            mode: .vietnamese, modeSource: .globalMode, appliedToggleSequence: 0, fieldHandle: nil, changedAt: .zero,
            pause: nil)
        cell = SnapshotCell(initial, epoch: ReaderEpoch())
        tracker = FocusTracker(
            thread: thread, ax: ax, processes: processes, output: cell, generation: generation, inbox: inbox,
            metrics: metrics, health: health, clock: clock, macOSVersion: LooseVersion("27.2")!,
            scheduler: scheduled ? timers : nil)
        let documents = self.documents
        tracker.setMemoryObserver { documents.append($0) }
    }

    func start(
        _ rules: any FocusDecisionResolving = FocusFixtures.resolver(), memory apps: [AppModeEntry] = [],
        global: TypingMode = .vietnamese
    ) {
        let memory = AppModeMemory(
            document: AppModesDocument(globalMode: global, apps: apps), rememberPerApp: true, firstSeen: .inherit)
        tracker.start(rules: rules, memory: memory)
        sync()
    }

    func sync() { tracker.waitUntilIdle() }

    /// Advances virtual time timer by timer, letting the ax thread run what each one queued (a retry may schedule
    /// the next one) before the next deadline.
    func advance(by duration: TimeSpan) {
        let target = clock.now().nanoseconds &+ duration.unsignedNanoseconds
        while let next = scheduler.nextDeadline, next.nanoseconds <= target {
            scheduler.advance(by: .nanoseconds(Int64(next.nanoseconds &- clock.now().nanoseconds)))
            sync()
        }
        scheduler.advance(by: .nanoseconds(Int64(target &- clock.now().nanoseconds)))
        sync()
    }

    /// Focus moves to an app that has no observer: NSWorkspace activation makes the owner revalidate (PLT-R381).
    func activate(_ pid: Int32, _ focus: FocusAttributes = FocusFixtures.attributes()) {
        ax.focus(pid: pid, attributes: focus, notify: nil)
        tracker.revalidate()
        sync()
    }

    /// PLT-R382: the tap's idle-key flag, drained on the ax thread without the overlay rescan.
    func idleRevalidation() {
        _ = inbox.push(.revalidateFocus)
        tracker.drainInbox()
        sync()
    }

    func toggle(_ sequence: UInt64, _ bundle: BundleKey?, _ mode: TypingMode) {
        _ = inbox.push(.modeToggled(sequence: sequence, bundle: bundle, mode: mode))
        tracker.drainInbox()
        sync()
    }

    var snapshot: FocusSnapshot { cell.load() }

    func finish() {
        tracker.stop()
        sync()
        thread.stop()
    }
}
