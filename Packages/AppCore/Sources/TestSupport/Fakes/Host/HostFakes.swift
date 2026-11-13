// SPDX-License-Identifier: GPL-3.0-or-later
//
// Host-service fakes (W1-E). Pure Swift state behind a lock; no AX, TIS, IORegistry or TCC access. Observer
// callbacks run synchronously on the caller's thread, outside the fake's lock.

public import AppModel
import ApplicationServices
public import CompatRules
public import Foundation
public import Injection
public import InputHost
import RealtimeSupport

public final class FakeAXProvider: AXProvider, Sendable {
    private struct Observer {
        var id: UInt64
        var pid: Int32
        var notifications: Set<AXNotificationKind>
        var handler: @Sendable (AXNotificationKind) -> Void
    }

    private struct State {
        var focusedPID: Int32?
        var attributes: [Int32: FocusAttributes] = [:]
        var elements: [Int32: UInt16] = [:]
        var timingOut: Set<Int32> = []
        var unavailable: Set<Int32> = []
        var observers: [Observer] = []
        var nextObserverID: UInt64 = 1
        var manualRequests: [Int32] = []
        var elementQueries: [Int32: Int] = [:]
        var lastRequest: AXAttributeRequest?
    }

    private let state = Mutex(State())

    public init() {}

    /// Sets the focused app/element; posts the given notification to observers. `element` names the focused
    /// element within the app: the same number is the same `AXUIElement` (CFEqual), another number another one,
    /// so tests can move focus between fields of one app or keep it on one field while its attributes change.
    public func focus(pid: Int32, attributes: FocusAttributes, notify: AXNotificationKind?, element: UInt16 = 0) {
        state.withLock {
            $0.focusedPID = pid
            $0.attributes[pid] = attributes
            $0.elements[pid] = element
        }
        if let notify { post(notify, from: pid) }
    }

    /// The focused application has no focused element.
    public func focusWithoutElement(pid: Int32, notify: AXNotificationKind?) {
        state.withLock {
            $0.focusedPID = pid
            $0.attributes[pid] = nil
        }
        if let notify { post(notify, from: pid) }
    }

    /// Delivers `kind` to the observers registered for `pid` (only if they asked for it).
    public func post(_ kind: AXNotificationKind, from pid: Int32) {
        let handlers = state.withLock { state in
            state.observers.filter { $0.pid == pid && $0.notifications.contains(kind) }.map(\.handler)
        }
        for handler in handlers { handler(kind) }
    }

    public func setTimingOut(pid: Int32, _ timingOut: Bool) {
        state.withLock {
            if timingOut { $0.timingOut.insert(pid) } else { $0.timingOut.remove(pid) }
        }
    }

    public func setUnavailable(pid: Int32, _ unavailable: Bool) {
        state.withLock {
            if unavailable { $0.unavailable.insert(pid) } else { $0.unavailable.remove(pid) }
        }
    }

    public func focusedApplication() -> AXCallResult<Int32?> { .success(state.withLock { $0.focusedPID }) }

    public func focusedElement(pid: Int32) -> AXCallResult<AXFocusedElement?> {
        let (timingOut, unavailable, hasElement, element) = state.withLock { state in
            state.elementQueries[pid, default: 0] += 1
            return (
                state.timingOut.contains(pid), state.unavailable.contains(pid), state.attributes[pid] != nil,
                state.elements[pid] ?? 0
            )
        }
        if timingOut { return .timedOut }
        if unavailable { return .unavailable }
        guard hasElement else { return .success(nil) }
        return .success(AXFocusedElement(pid: pid, element: Self.elementReference(pid: pid, element: element)))
    }

    /// Fixture limits that keep every synthetic reference distinct and inside `Int32`.
    static let maximumFakePID: Int32 = 99_999
    static let maximumFakeElement: UInt16 = 20_000

    /// An application element is a local reference: creating it sends no AX message. Element 0 is the app's
    /// own reference; other elements use unused pids above 1,000,000, one per (pid, element) with the full pid.
    static func elementReference(pid: Int32, element: UInt16) -> AXElementReference {
        precondition((0...maximumFakePID).contains(pid), "fake pids stay below 100,000")
        precondition(element <= maximumFakeElement, "fake element numbers stay at or below 20,000")
        let reference = element == 0 ? pid : 1_000_000 + Int32(element) * (maximumFakePID + 1) + pid
        return AXElementReference(AXUIElementCreateApplication(reference))
    }

    public func attributes(of element: AXFocusedElement, request: AXAttributeRequest) -> AXCallResult<FocusAttributes> {
        let (timingOut, stored) = state.withLock { state in
            state.lastRequest = request
            return (state.timingOut.contains(element.pid), state.attributes[element.pid])
        }
        if timingOut { return .timedOut }
        guard var attributes = stored else { return .unavailable }
        if !request.includeDocumentURL { attributes.documentURL = nil }
        if !request.includeWindowTitle { attributes.windowTitle = nil }
        return .success(attributes)
    }

    public func observe(
        pid: Int32, notifications: Set<AXNotificationKind>, handler: @escaping @Sendable (AXNotificationKind) -> Void
    ) -> (any AXObservation)? {
        let id = state.withLock { state -> UInt64 in
            defer { state.nextObserverID += 1 }
            state.observers.append(
                Observer(id: state.nextObserverID, pid: pid, notifications: notifications, handler: handler))
            return state.nextObserverID
        }
        return FakeAXObservation { [weak self] in self?.removeObserver(id) }
    }

    public func enableManualAccessibility(pid: Int32) -> Bool {
        state.withLock { $0.manualRequests.append(pid) }
        return true
    }

    public var manualAccessibilityRequests: [Int32] { state.withLock { $0.manualRequests } }
    /// pid -> notifications of every live observer.
    public var observedNotifications: [Int32: Set<AXNotificationKind>] {
        state.withLock { state in
            Dictionary(state.observers.map { ($0.pid, $0.notifications) }, uniquingKeysWith: { $0.union($1) })
        }
    }

    /// Number of `focusedElement` queries per pid (circuit-breaker tests).
    public func elementQueryCount(pid: Int32) -> Int { state.withLock { $0.elementQueries[pid, default: 0] } }
    public var lastAttributeRequest: AXAttributeRequest? { state.withLock { $0.lastRequest } }

    private func removeObserver(_ id: UInt64) { state.withLock { $0.observers.removeAll { $0.id == id } } }
}

/// Observation with an inert run-loop source (never signalled), so adding it to the ax run loop is harmless.
public final class FakeAXObservation: AXObservation, Sendable {
    /// CF run-loop sources may be added and removed from any thread (CFRunLoop is thread-safe).
    private struct Source: @unchecked Sendable { let source: CFRunLoopSource }
    /// Gives the source a unique `info` pointer. Run loops keep sources in a set compared with `CFEqual`, and
    /// two version-0 sources with all-zero contexts are equal: removing one would remove the other (for example
    /// `RunLoopThread`'s keep-alive source, which ends the thread).
    private final class Identity: Sendable {}

    private let identity = Identity()
    private let source: Source
    private let onInvalidate: @Sendable () -> Void
    private let invalidated = Atomic<Bool>(false)

    init(onInvalidate: @escaping @Sendable () -> Void) {
        var context = CFRunLoopSourceContext()
        context.info = Unmanaged.passUnretained(identity).toOpaque()
        source = Source(source: CFRunLoopSourceCreate(nil, 0, &context))
        self.onInvalidate = onInvalidate
    }

    public var runLoopSource: CFRunLoopSource { source.source }
    public var isInvalidated: Bool { invalidated.load(ordering: .sequentiallyConsistent) }

    public func invalidate() {
        guard !invalidated.exchange(true, ordering: .sequentiallyConsistent) else { return }
        onInvalidate()
    }
}

public final class FakeProcessIdentityProvider: ProcessIdentityProvider, Sendable {
    private struct State {
        var processes: [Int32: ProcessIdentity]
        var order: [Int32]
        var dead: Set<Int32> = []
        var identityLookups: [Int32: Int] = [:]
        var runningApplicationScans = 0
    }

    private let state: Mutex<State>

    /// How often `identity(of:)` was asked for `pid` (cost checks, PLT-R382).
    public func identityLookups(of pid: Int32) -> Int { state.withLock { $0.identityLookups[pid] ?? 0 } }
    /// How often `runningApplications()` ran (a full scan in production).
    public var runningApplicationScans: Int { state.withLock { $0.runningApplicationScans } }

    public init(processes: [ProcessIdentity]) {
        state = Mutex(
            State(
                processes: Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { _, last in last }),
                order: processes.map(\.pid)))
    }

    public func identity(of pid: Int32) -> ProcessIdentity? {
        state.withLock { state in
            state.identityLookups[pid, default: 0] += 1
            return state.dead.contains(pid) ? nil : state.processes[pid]
        }
    }

    public func isAlive(_ pid: Int32) -> Bool { state.withLock { $0.processes[pid] != nil && !$0.dead.contains(pid) } }

    public func runningApplications() -> [ProcessIdentity] {
        state.withLock { state in
            state.runningApplicationScans += 1
            return state.order.filter { !state.dead.contains($0) }.compactMap { state.processes[$0] }
        }
    }

    public func add(_ process: ProcessIdentity) {
        state.withLock {
            if $0.processes[process.pid] == nil { $0.order.append(process.pid) }
            $0.processes[process.pid] = process
            $0.dead.remove(process.pid)
        }
    }

    /// The process exits: `isAlive` is false and its identity is gone.
    public func terminate(pid: Int32) { _ = state.withLock { $0.dead.insert(pid) } }

    /// A plausible identity for tests (`bundleURL` under /Applications, process name from the bundle's last part).
    public static func process(
        pid: Int32, bundle: String, name: String? = nil, version: String? = "1.0", build: String? = "1"
    ) -> ProcessIdentity {
        let key = BundleKey(rawValue: bundle)!
        let processName = bundle.split(separator: ".").last.map(String.init) ?? bundle
        return ProcessIdentity(
            pid: pid, bundle: key, bundleURL: URL(fileURLWithPath: "/Applications/\(processName).app"),
            shortVersion: version, buildVersion: build, appCategory: nil, localizedName: name ?? processName,
            processName: processName)
    }
}

public final class FakeSecureInputProbe: SecureInputProbe, Sendable {
    private struct State {
        var enabled = false
        var holderPID: Int32?
        var polls = 0
    }

    private let state = Mutex(State())

    public init() {}

    public func set(enabled: Bool, holderPID: Int32?) {
        state.withLock {
            $0.enabled = enabled
            $0.holderPID = holderPID
        }
    }

    public func isSecureEventInputEnabled() -> Bool {
        state.withLock {
            $0.polls += 1
            return $0.enabled
        }
    }

    public func secureInputHolderPID() -> Int32? { state.withLock { $0.holderPID } }
    /// Number of `isSecureEventInputEnabled` calls (polls).
    public var pollCount: Int { state.withLock { $0.polls } }
}

public final class FakePermissionProbe: PermissionProbe, Sendable {
    private struct State {
        var trusted: Bool
        var post: Bool
        var listen: Bool
        var digest: String? = "fake-signing-identity"
        var accessibilityPrompts = 0
        var listenRequests = 0
        var postRequests = 0
    }

    private let state: Mutex<State>

    public init(trusted: Bool = true, post: Bool = true, listen: Bool = true) {
        state = Mutex(State(trusted: trusted, post: post, listen: listen))
    }

    public func set(trusted: Bool, post: Bool, listen: Bool) {
        state.withLock {
            $0.trusted = trusted
            $0.post = post
            $0.listen = listen
        }
    }

    /// Simulates another signing identity (a different build) or an unsigned build (`nil`).
    public func setSigningIdentityDigest(_ digest: String?) { state.withLock { $0.digest = digest } }

    public func isAccessibilityTrusted() -> Bool { state.withLock { $0.trusted } }
    public func canPostEvents() -> Bool { state.withLock { $0.post } }
    public func canListenToEvents() -> Bool { state.withLock { $0.listen } }
    public func promptForAccessibility() { state.withLock { $0.accessibilityPrompts += 1 } }
    public func requestListenEventAccess() -> Bool {
        state.withLock {
            $0.listenRequests += 1
            return $0.listen
        }
    }

    public func requestPostEventAccess() -> Bool {
        state.withLock {
            $0.postRequests += 1
            return $0.post
        }
    }

    public func signingIdentityDigest() -> String? { state.withLock { $0.digest } }

    public var accessibilityPromptCount: Int { state.withLock { $0.accessibilityPrompts } }
    public var listenRequestCount: Int { state.withLock { $0.listenRequests } }
    public var postRequestCount: Int { state.withLock { $0.postRequests } }
}

@MainActor
public final class FakeInputSourceProvider: InputSourceProvider {
    private var current: InputSourceInfo
    private var layouts: [InputSourceID: KeyboardLayoutData]
    private var handlers: [UInt64: @MainActor @Sendable () -> Void] = [:]
    private var nextHandlerID: UInt64 = 1
    public var enabled: [InputSourceInfo] = []
    public var keyboardType: UInt32 = 40
    /// Layout data returned for the current source when it is not an ASCII layout (the underlying layout).
    public var underlyingLayout: InputSourceID?

    public init(current: InputSourceInfo, layouts: [InputSourceID: KeyboardLayoutData]) {
        self.current = current
        self.layouts = layouts
    }

    /// Simulates the user selecting `source` and the selection notification.
    public func select(_ source: InputSourceInfo) {
        current = source
        notifyChange()
    }

    /// Delivers a change notification without changing the selection (for example, enabled sources changed).
    public func notifyChange() {
        for handler in handlers.values { handler() }
    }

    public var observerCount: Int { handlers.count }

    public func currentSource() -> InputSourceInfo { current }
    public func currentLayoutData() -> KeyboardLayoutData? { layouts[underlyingLayout ?? current.id] }
    public func enabledSources() -> [InputSourceInfo] { enabled }
    public func layoutData(for id: InputSourceID) -> KeyboardLayoutData? { layouts[id] }
    public func currentKeyboardType() -> UInt32 { keyboardType }
    public func observeChanges(_ handler: @escaping @MainActor @Sendable () -> Void) -> any ObservationToken {
        let id = nextHandlerID
        nextHandlerID += 1
        handlers[id] = handler
        return FakeObservationToken { [weak self] in
            onMainActor { self?.handlers[id] = nil }
        }
    }
}

@MainActor
public final class FakeWorkspaceEvents: WorkspaceEvents {
    private var handlers: [UInt64: @MainActor @Sendable (WorkspaceEvent) -> Void] = [:]
    private var nextID: UInt64 = 1

    public init() {}

    public func send(_ event: WorkspaceEvent) {
        for handler in handlers.values { handler(event) }
    }

    public var observerCount: Int { handlers.count }

    public func observe(_ handler: @escaping @MainActor @Sendable (WorkspaceEvent) -> Void) -> any ObservationToken {
        let id = nextID
        nextID += 1
        handlers[id] = handler
        return FakeObservationToken { [weak self] in
            onMainActor { self?.handlers[id] = nil }
        }
    }
}

/// Runs `body` synchronously when already on the main thread (tests), otherwise hops to the main actor.
private func onMainActor(_ body: @escaping @MainActor @Sendable () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { body() }
    } else {
        Task { @MainActor in body() }
    }
}

/// Calls `onCancel` once.
public final class FakeObservationToken: ObservationToken {
    private let onCancel: @Sendable () -> Void
    private let cancelled = Atomic<Bool>(false)

    public init(onCancel: @escaping @Sendable () -> Void) { self.onCancel = onCancel }

    public var isCancelled: Bool { cancelled.load(ordering: .sequentiallyConsistent) }

    public func cancel() {
        guard !cancelled.exchange(true, ordering: .sequentiallyConsistent) else { return }
        onCancel()
    }
}

public final class FakeBundleInspector: BundleInspector, Sendable {
    private let bundles: [URL: FakeBundle]

    public init(bundles: [URL: FakeBundle]) { self.bundles = bundles }
    public struct FakeBundle: Sendable, Hashable {
        public var frameworks: [String]
        public var helpers: [String]
        /// Paths relative to the bundle, for example `Contents/MacOS/libxul.dylib`.
        public var files: [String]
        public var info: [String: JSONValue]
        public init(frameworks: [String], helpers: [String], files: [String], info: [String: JSONValue]) {
            self.frameworks = frameworks
            self.helpers = helpers
            self.files = files
            self.info = info
        }
    }

    public func frameworkNames(in bundle: URL) -> [String] { bundles[bundle]?.frameworks ?? [] }
    public func helperAppNames(in bundle: URL) -> [String] { bundles[bundle]?.helpers ?? [] }

    /// Same contract as the production inspector (PLT-R510): `directory` is a folder inside a known bundle, and
    /// a file matches when it lies at most `maxDepth` levels below it (1 = directly inside).
    public func containsFile(named name: String, in directory: URL, maxDepth: Int) -> Bool {
        let target = directory.standardizedFileURL.path
        guard
            let (bundleURL, bundle) = bundles.first(where: { url, _ in
                let root = url.standardizedFileURL.path
                return target == root || target.hasPrefix(root + "/")
            })
        else { return false }
        let folder = target.dropFirst(bundleURL.standardizedFileURL.path.count).split(separator: "/")
        return bundle.files.contains { path in
            let components = path.split(separator: "/")
            guard components.last.map(String.init) == name, components.starts(with: folder) else { return false }
            return components.count - folder.count <= maxDepth
        }
    }

    public func infoDictionary(of bundle: URL) -> [String: JSONValue]? { bundles[bundle]?.info }
}
