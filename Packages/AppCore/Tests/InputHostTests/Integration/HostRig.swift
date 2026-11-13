// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The whole input host under fakes (QA-R1 layer 4, ADR 0313): `InputHostController` with the real tap thread
// (fake handle, no WindowServer), the real pipeline and engine, the real focus tracker on its ax thread, the
// real monitors on a manual scheduler, and the real inject worker driven step by step. Keys are delivered
// through the tap callback bridge on the tap thread; posted events come back as echoes the same way and land
// in a simulated text field. Workstream W2-A.

import AppModel
import CompatRules
import Diagnostics
import Foundation
import Injection
import RealtimeSupport
import SettingsStore
import Synchronization
import TestSupport
import Testing
import VietnameseEngine

@testable import InputHost

/// Returns one fixed table for any layout data (unit tests that do not exercise UCKeyTranslate).
struct FixedLayoutBuilder: LayoutTableBuilding {
    var table: LayoutTable = PipelineFixtures.qwertyTable()
    func build(from data: KeyboardLayoutData, keyboardType: UInt32) throws -> LayoutTable { table }
}

/// Where the current tap lives, so the poster's sink (inject thread or test thread) can echo into it.
final class TapRoute: Sendable {
    private let route = Mutex<(handle: FakeEventTapHandle, userInfo: UInt)?>(nil)

    func set(_ handle: FakeEventTapHandle?, userInfo: UInt) {
        route.withLock { $0 = handle.map { ($0, userInfo) } }
    }

    var current: (handle: FakeEventTapHandle, userInfo: UInt)? { route.withLock { $0 } }
}

/// Delivers posted events back through the tap (echo) and into the field, in posting order.
final class EchoLoop: Sendable {
    let route = TapRoute()
    let field: SimulatedTextField
    let layout: Mutex<LayoutTable>
    private let echoes = Atomic<Int>(0)

    init(field: SimulatedTextField, layout: LayoutTable) {
        self.field = field
        self.layout = Mutex(layout)
    }

    var echoCount: Int { echoes.load(ordering: .relaxed) }

    func echo(_ posted: FakeEventPoster.Posted) {
        guard let (handle, userInfo) = route.current else { return }
        let event = PipelineHarnessEvents.event(posted, at: MachClock().now())
        let field = self.field
        let table = layout.withLock { $0 }
        _ = HostRig.deliverOnTap(event, handle: handle, userInfo: userInfo) { verdict in
            guard verdict == .pass else { return }
            switch posted {
            case .synthetic(let synthetic, _): field.apply(synthetic, layout: table)
            case .replay(let record, _): field.apply(record, layout: table)
            }
        }
        echoes.wrappingAdd(1, ordering: .relaxed)
    }
}

/// `PipelineHarness`'s conversion of posted events into tap events (it is internal to TestSupport).
enum PipelineHarnessEvents {
    static func event(_ posted: FakeEventPoster.Posted, at time: MonotonicInstant) -> RawKeyEvent {
        switch posted {
        case .synthetic(let synthetic, let userData):
            RawKeyEvent(
                kind: synthetic.isKeyDown ? .keyDown : .keyUp, keyCode: synthetic.keyCode, flags: synthetic.flags,
                autorepeat: false, keyboardType: PipelineFixtures.keyboardType, unicode: synthetic.unicode,
                userData: userData, receivedAt: time)
        case .replay(let record, let userData):
            RawKeyEvent(
                kind: record.kind == .keyUp ? .keyUp : (record.kind == .flagsChanged ? .flagsChanged : .keyDown),
                keyCode: record.keyCode, flags: record.flags, autorepeat: record.autorepeat,
                keyboardType: record.keyboardType, unicode: record.unicode, userData: userData, receivedAt: time)
        }
    }

    static func record(_ event: RawKeyEvent) -> KeyEventRecord {
        let kind: KeyEventRecord.Kind =
            switch event.kind {
            case .keyUp: .keyUp
            case .flagsChanged: .flagsChanged
            default: .keyDown
            }
        return KeyEventRecord(
            kind: kind, keyCode: event.keyCode, flags: event.flags, autorepeat: event.autorepeat,
            keyboardType: event.keyboardType, unicode: event.unicode, receivedAt: event.receivedAt, isProbe: false)
    }
}

/// Lets a test pretend that a removed tap thread has not left its run loop yet (ADR 0309).
final class TapExitGate: Sendable {
    private let held = Mutex(false)
    var isHeld: Bool {
        get { held.withLock { $0 } }
        set { held.withLock { $0 = newValue } }
    }
}

/// The production tap thread whose `waitUntilExited` answers false while the gate is held.
final class GatedTapThread: TapControlStarting {
    let base: any TapControlStarting
    let gate: TapExitGate

    init(base: any TapControlStarting, gate: TapExitGate) {
        self.base = base
        self.gate = gate
    }

    func start() -> Bool { base.start() }
    func waitUntilExited(timeout: Duration) -> Bool {
        let exited = base.waitUntilExited(timeout: timeout)
        return exited && !gate.isHeld
    }
    func setEnabled(_ enabled: Bool) { base.setEnabled(enabled) }
    var isEnabled: Bool { base.isEnabled }
    var isRunning: Bool { base.isRunning || gate.isHeld }
    func stop() { base.stop() }
}

@MainActor
final class HostRig {
    static let editorPID: Int32 = 4_242
    static let editorBundle = "com.example.editor"
    static let abc = InputSourceInfo(
        id: InputSourceID(rawValue: "com.apple.keylayout.ABC")!, kind: .asciiLayout, localizedName: "ABC",
        languages: ["en"], isBuiltInVietnamese: false)

    let clock = ManualClock()
    let scheduler: ManualScheduler
    let tapFactory = FakeEventTapFactory()
    let field = SimulatedTextField(behaviour: .cocoa)
    let echoLoop: EchoLoop
    let poster: FakeEventPoster
    let ax = FakeAXProvider()
    let processes: FakeProcessIdentityProvider
    let inputSources: FakeInputSourceProvider
    let secureInput = FakeSecureInputProbe()
    let permissions: FakePermissionProbe
    let workspace = FakeWorkspaceEvents()
    let keyValues = InMemoryKeyValueStore()
    let exitGate = TapExitGate()
    let wallClock = FixedWallClock()
    let metrics = PlatformMetrics()
    let logger = RecordingLogger()
    let health: HealthEventLog
    let tapLog = TapLogRing()
    let utility = DispatchSerialQueue(label: "test.host.utility", qos: .utility)
    let hop = ManualMainHop()
    let store: SettingsStoreHarness
    let controller: InputHostController
    var events: [HostEvent] = []
    private(set) var layout: LayoutTable

    init(
        layout: LayoutTable = PipelineFixtures.qwertyTable(), source: InputSourceInfo = HostRig.abc,
        layoutData: [InputSourceID: KeyboardLayoutData]? = nil, builder: (any LayoutTableBuilding)? = nil,
        permissions: FakePermissionProbe = FakePermissionProbe(), realResources: Bool = false,
        capture: CaptureController? = nil
    ) {
        scheduler = ManualScheduler(clock: clock)
        self.layout = layout
        let loop = EchoLoop(field: field, layout: layout)
        echoLoop = loop
        poster = FakeEventPoster { loop.echo($0) }
        processes = FakeProcessIdentityProvider(processes: [
            FakeProcessIdentityProvider.process(pid: Self.editorPID, bundle: Self.editorBundle)
        ])
        inputSources = FakeInputSourceProvider(
            current: source, layouts: layoutData ?? [source.id: KeyboardLayoutData(source: source.id, uchr: Data())])
        self.permissions = permissions
        health = HealthEventLog(mirror: logger)
        store = SettingsStoreHarness()
        let dependencies = InputHostDependencies(
            tapFactory: tapFactory, poster: poster, fieldAccess: FakeFocusedFieldAccess(field: field),
            pasteboard: FakePasteboard(), ax: ax, processes: processes,
            bundleInspector: FakeBundleInspector(bundles: [:]),
            inputSources: inputSources, layoutBuilder: builder ?? FixedLayoutBuilder(table: layout),
            secureInput: secureInput, permissions: permissions, workspace: workspace, keyValueStore: keyValues,
            clock: clock, scheduler: scheduler, wallClock: wallClock, metrics: metrics, health: health,
            logger: logger, tapLog: tapLog, capture: capture, utilityQueue: utility)
        controller = InputHostController(
            dependencies: dependencies, settingsStore: store.store, hop: hop,
            makeTapThread: Self.gatedThreadMaker(TapSession.productionThreadMaker(factory: tapFactory), exitGate),
            tapClock: MachClock(),
            loadBundled: realResources ? TapSettingsPublisher.bundledLoader : HostRig.emptyResources,
            macOSVersion: LooseVersion("15.0")!, runsWorkerThread: false)
        controller.onEvent = { [weak self] in self?.events.append($0) }
        focusEditor()
    }

    private static func gatedThreadMaker(_ base: @escaping TapThreadMaker, _ gate: TapExitGate) -> TapThreadMaker {
        { context in GatedTapThread(base: base(context), gate: gate) }
    }

    /// The editor's text field has focus (a native, editable AXTextField).
    func focusEditor(notify: Bool = false) {
        ax.focus(
            pid: Self.editorPID,
            attributes: FocusAttributes(
                role: "AXTextField", subrole: nil, identifier: nil, domClasses: [], editable: true, ancestorRoles: [],
                documentURL: nil, windowTitle: nil),
            notify: notify ? .focusedElementChanged : nil)
    }

    // MARK: Launch

    /// Loads settings, starts the host and runs every queued hop until the tap is up (or cannot be).
    /// `preloaded`: the store was loaded and changed by the test already (a second load would re-read files the
    /// debounced writes have not reached yet).
    func start(rules: RulesLoadResult = HostRig.shippedRules, preloaded: Bool = false) async {
        let state = preloaded ? await store.store.state : await store.store.load()
        controller.start(rules: rules, settings: state)
        settle()
        routeToCurrentTap()
    }

    /// Lets the ax thread, the utility queue and the main hops finish what is queued.
    func settle() {
        for _ in 0..<8 {
            controller.focusTracker.waitUntilIdle()
            utility.sync {}
            if hop.drain() == 0 && hop.pendingCount == 0 { break }
        }
    }

    func routeToCurrentTap() {
        let handles = tapFactory.handles
        guard let handle = handles.last, let userInfo = tapFactory.userInfoBitPatterns.last else { return }
        echoLoop.route.set(handle.isInvalidated ? nil : handle, userInfo: userInfo)
    }

    nonisolated static let emptyResources: TapSettingsPublisher.BundledResourcesLoader = { .empty }

    nonisolated static var shippedRules: RulesLoadResult {
        RulesLoader.load(contentsOf: repositoryRoot.appendingPathComponent("compat/rules.json"))
    }

    nonisolated static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    // MARK: Typing

    /// Delivers `event` on the tap thread and runs `after(verdict)` there too; nil when no tap is installed.
    nonisolated static func deliverOnTap(
        _ event: RawKeyEvent, handle: FakeEventTapHandle, userInfo: UInt,
        after: @escaping @Sendable (TapVerdict) -> Void = { _ in }
    ) -> TapVerdict? {
        let verdict = Mutex<TapVerdict?>(nil)
        let done = DispatchSemaphore(value: 0)
        let scheduled = handle.performOnTapThread {
            let pointer = UnsafeMutableRawPointer(bitPattern: userInfo)!
            let result = TapCallbackBridge.deliver(event, userInfo: pointer)
            after(result)
            verdict.withLock { $0 = result }
            done.signal()
        }
        guard scheduled, done.wait(timeout: .now() + .seconds(5)) == .success else { return nil }
        return verdict.withLock { $0 }
    }

    /// One physical event through the tap; a passed event reaches the field. Then the worker runs and its
    /// posts echo back before the next key (the WindowServer delivers in order).
    @discardableResult
    func send(_ kind: RawKeyEvent.Kind, keyCode: UInt16, flags: UInt64 = 0) -> TapVerdict? {
        guard let (handle, userInfo) = echoLoop.route.current else { return nil }
        let event = RawKeyEvent(
            kind: kind, keyCode: KeyCode(rawValue: keyCode), flags: flags, autorepeat: false,
            keyboardType: PipelineFixtures.keyboardType, unicode: .empty, userData: 0, receivedAt: MachClock().now())
        let field = self.field
        let table = layout
        let verdict = Self.deliverOnTap(event, handle: handle, userInfo: userInfo) { verdict in
            if verdict == .pass { field.apply(PipelineHarnessEvents.record(event), layout: table) }
        }
        controller.worker.runUntilIdle()
        return verdict
    }

    /// Presses and releases the key that produces `character` on the current layout (Shift when needed).
    @discardableResult
    func type(_ text: String) -> [TapVerdict?] {
        var verdicts: [TapVerdict?] = []
        for character in text {
            guard let (code, flags) = Self.key(producing: character, in: layout) else {
                Issue.record("no key produces \(character) on \(layout.source)")
                continue
            }
            verdicts.append(send(.keyDown, keyCode: code.rawValue, flags: flags))
            send(.keyUp, keyCode: code.rawValue, flags: flags)
        }
        return verdicts
    }

    /// Virtual key codes of the numeric keypad (`kVK_ANSI_Keypad*`); a keypad digit is not a VNI tone key.
    nonisolated static let keypadCodes: ClosedRange<UInt16> = 0x41...0x5C

    /// The key code and modifier flags producing `character` on the main key area: unshifted first, then Shift
    /// (PLT-R360 reverse map; on AZERTY the digits are on the Shift column, PLT-R361).
    nonisolated static func key(producing character: Character, in table: LayoutTable) -> (KeyCode, UInt64)? {
        for (state, flags) in [(LayoutModifierState.none, UInt64(0)), (.shift, EventFlags.shift)] {
            for raw in 0..<UInt16(LayoutTable.keyCodeCount) where !keypadCodes.contains(raw) {
                if table.entry(for: KeyCode(rawValue: raw), state: state) == .character(character) {
                    return (KeyCode(rawValue: raw), flags)
                }
            }
        }
        return nil
    }

    // MARK: Inspection

    var lifecyclePhase: LifecycleSnapshot.Phase { controller.channels.snapshots.lifecycle.load().phase }

    var liveHandles: [FakeEventTapHandle] { tapFactory.handles.filter { !$0.isInvalidated } }

    func stop() {
        controller.stop()
        echoLoop.route.set(nil, userInfo: 0)
    }
}
