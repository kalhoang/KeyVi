// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Production `AXProvider` (PLT-R380-R385, PLT-R343). Thin wrapper, called only on the ax thread. Every element
// gets the 100 ms messaging timeout; reads are bounded attributes, never a field's full `AXValue`. It never sets
// `AXEnhancedUserInterface` and sets `AXManualAccessibility` only when asked (PLT-R385).

import ApplicationServices
import CoreFoundation
public import Injection

public final class SystemAXProvider: AXProvider {
    /// PLT-R384, seconds.
    public static let messagingTimeout: Float = 0.1
    public static let maximumAncestors = 6

    private let systemWide: AXElementReference

    public init() {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        systemWide = AXElementReference(element)
    }

    public func focusedApplication() -> AXCallResult<Int32?> {
        AXRead.element(systemWide.element, kAXFocusedApplicationAttribute).flatMap { application in
            guard let application else { return .success(nil) }
            var pid: pid_t = 0
            let error = AXUIElementGetPid(application, &pid)
            return error == .success ? .success(pid) : AXRead.failure(error)
        }
    }

    public func focusedElement(pid: Int32) -> AXCallResult<AXFocusedElement?> {
        AXRead.element(AXRead.application(pid), kAXFocusedUIElementAttribute).flatMap { element in
            .success(element.map { AXFocusedElement(pid: pid, element: AXElementReference($0)) })
        }
    }

    public func attributes(of element: AXFocusedElement, request: AXAttributeRequest) -> AXCallResult<FocusAttributes> {
        AXAttributeReader(element: element.element.element).read(request: request)
    }

    public func observe(
        pid: Int32, notifications: Set<AXNotificationKind>, handler: @escaping @Sendable (AXNotificationKind) -> Void
    ) -> (any AXObservation)? {
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, name, refcon in
            guard let refcon else { return }
            Unmanaged<AXObserverHandlerBox>.fromOpaque(refcon).takeUnretainedValue().deliver(name as String)
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let observer = created else { return nil }
        let application = AXRead.application(pid)
        let box = AXObserverHandlerBox(handler: handler)
        let refcon = Unmanaged.passUnretained(box).toOpaque()
        let names = notifications.map(AXNotificationNames.name(for:)).filter { name in
            AXObserverAddNotification(observer, application, name as CFString, refcon) == .success
        }
        guard !names.isEmpty else { return nil }
        return SystemAXObservation(
            objects: AXObserverObjects(observer: observer, application: application), names: names, box: box)
    }

    public func enableManualAccessibility(pid: Int32) -> Bool {
        AXUIElementSetAttributeValue(
            AXRead.application(pid), AXNotificationNames.manualAccessibility as CFString, kCFBooleanTrue) == .success
    }
}

enum AXNotificationNames {
    /// Electron/Chromium opt-in attribute (PLT-R385, VERIFY for Chrome 155+).
    static let manualAccessibility = "AXManualAccessibility"

    static func name(for kind: AXNotificationKind) -> String {
        switch kind {
        case .focusedElementChanged: kAXFocusedUIElementChangedNotification
        case .focusedWindowChanged: kAXFocusedWindowChangedNotification
        case .applicationActivated: kAXApplicationActivatedNotification
        case .titleChanged: kAXTitleChangedNotification
        }
    }

    static func kind(for name: String) -> AXNotificationKind? {
        AXNotificationKind.allCases.first { self.name(for: $0) == name }
    }
}

final class AXObserverHandlerBox: Sendable {
    private let handler: @Sendable (AXNotificationKind) -> Void
    init(handler: @escaping @Sendable (AXNotificationKind) -> Void) { self.handler = handler }
    func deliver(_ name: String) {
        if let kind = AXNotificationNames.kind(for: name) { handler(kind) }
    }
}

/// CF objects of one observer. CF types are reference counted with atomic operations and AX objects may be
/// used from any thread; the observer is created, registered and invalidated on the ax thread only.
struct AXObserverObjects: @unchecked Sendable {
    let observer: AXObserver
    let application: AXUIElement
}

final class SystemAXObservation: AXObservation {
    private let objects: AXObserverObjects
    private let names: [String]
    private let box: AXObserverHandlerBox  // retained for the refcon

    init(objects: AXObserverObjects, names: [String], box: AXObserverHandlerBox) {
        self.objects = objects
        self.names = names
        self.box = box
    }

    var runLoopSource: CFRunLoopSource { AXObserverGetRunLoopSource(objects.observer) }

    func invalidate() {
        for name in names {
            AXObserverRemoveNotification(objects.observer, objects.application, name as CFString)
        }
    }
}

/// The two AX primitives the attribute reader needs; production sends real AX messages, tests inject a table
/// (no Accessibility permission needed).
struct AXReadFunctions {
    var copy: (AXUIElement, String) -> AXRead.Outcome<CFTypeRef>
    /// Whether `kAXValueAttribute` is settable; the value itself is never read (PLT-R343).
    var isValueSettable: (AXUIElement) -> (error: AXError, settable: Bool)

    static var system: AXReadFunctions { AXReadFunctions(copy: AXRead.copy, isValueSettable: AXRead.isValueSettable) }
}

/// Bounded attribute reads of one focused element (5.2, PLT-R383).
struct AXAttributeReader {
    static let identifierAttribute = "AXIdentifier"
    static let domClassListAttribute = "AXDOMClassList"
    static let webAreaRole = "AXWebArea"

    let element: AXUIElement
    var functions = AXReadFunctions.system

    /// PLT-R384: a timeout in any read (role, settable, subrole, identifier, classes, ancestors, window title,
    /// URL) makes the whole read `.timedOut`, so the core counts it for the circuit breaker. Reading stops at
    /// the first timeout, so one refresh spends at most one messaging timeout here.
    func read(request: AXAttributeRequest) -> AXCallResult<FocusAttributes> {
        AXRead.map(functions.copy(element, kAXRoleAttribute)) { $0 as? String }.flatMap { role in
            let settable = functions.isValueSettable(element)
            if settable.error == .cannotComplete { return .timedOut }
            var session = AXReadSession(copy: functions.copy)
            let attributes = session.attributes(
                of: element, role: role, editable: settable.error == .success ? settable.settable : nil,
                request: request)
            return session.timedOut ? .timedOut : .success(attributes)
        }
    }
}

/// Optional attribute reads that remember a timeout and send nothing after it (PLT-R384).
struct AXReadSession {
    let copy: (AXUIElement, String) -> AXRead.Outcome<CFTypeRef>
    private(set) var timedOut = false

    init(copy: @escaping (AXUIElement, String) -> AXRead.Outcome<CFTypeRef>) { self.copy = copy }

    mutating func attributes(
        of element: AXUIElement, role: String?, editable: Bool?, request: AXAttributeRequest
    ) -> FocusAttributes {
        let subrole = string(element, kAXSubroleAttribute)
        let identifier = string(element, AXAttributeReader.identifierAttribute)
        let domClasses = strings(element, AXAttributeReader.domClassListAttribute)
        let ancestors = ancestorChain(of: element)
        let title = request.includeWindowTitle ? windowTitle(of: element) : nil
        let url = request.includeDocumentURL ? documentURL(ancestors: ancestors) : nil
        return FocusAttributes(
            role: role, subrole: subrole, identifier: identifier, domClasses: domClasses, editable: editable,
            ancestorRoles: ancestors.map(\.role), documentURL: url, windowTitle: title)
    }

    private mutating func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        guard !timedOut else { return nil }
        switch copy(element, attribute) {
        case .success(let value): return value
        case .timedOut:
            timedOut = true
            return nil
        case .unavailable, .failed: return nil
        }
    }

    private mutating func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private mutating func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    private mutating func strings(_ element: AXUIElement, _ attribute: String) -> [String] {
        (value(element, attribute) as? [String]) ?? []
    }

    private mutating func ancestorChain(of start: AXUIElement) -> [(element: AXUIElement, role: String)] {
        var chain: [(element: AXUIElement, role: String)] = []
        var cursor = start
        while chain.count < SystemAXProvider.maximumAncestors, let parent = element(cursor, kAXParentAttribute) {
            chain.append((parent, string(parent, kAXRoleAttribute) ?? ""))
            cursor = parent
        }
        return chain
    }

    private mutating func windowTitle(of start: AXUIElement) -> String? {
        guard let window = element(start, kAXWindowAttribute) else { return nil }
        return string(window, kAXTitleAttribute)
    }

    /// The nearest web area's `AXURL`, kept in memory for matching only (PLT-R383).
    private mutating func documentURL(ancestors: [(element: AXUIElement, role: String)]) -> String? {
        guard let webArea = ancestors.first(where: { $0.role == AXAttributeReader.webAreaRole })?.element,
            let value = value(webArea, kAXURLAttribute), CFGetTypeID(value) == CFURLGetTypeID()
        else { return nil }
        return (value as! CFURL as URL).absoluteString
    }
}

/// `AXUIElementCopyAttributeValue` with AXError mapping: no value -> nil, timeout -> `.timedOut` (PLT-R384).
enum AXRead {
    enum Outcome<Value> {
        case success(Value?)
        case timedOut
        case unavailable
        case failed(code: Int32)

        var value: Value?? {
            if case .success(let value) = self { return .some(value) }
            return nil
        }

        func flatMap<Result: Sendable>(_ transform: (Value?) -> AXCallResult<Result>) -> AXCallResult<Result> {
            switch self {
            case .success(let value): transform(value)
            case .timedOut: .timedOut
            case .unavailable: .unavailable
            case .failed(let code): .failed(code: code)
            }
        }
    }

    static func application(_ pid: Int32) -> AXUIElement {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, SystemAXProvider.messagingTimeout)
        return application
    }

    static func copy(_ element: AXUIElement, _ attribute: String) -> Outcome<CFTypeRef> {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        switch error {
        case .success: return .success(value)
        case .noValue, .attributeUnsupported: return .success(nil)
        case .cannotComplete: return .timedOut
        case .apiDisabled, .notImplemented, .invalidUIElement: return .unavailable
        default: return .failed(code: error.rawValue)
        }
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> Outcome<AXUIElement> {
        map(copy(element, attribute)) { value in
            CFGetTypeID(value) == AXUIElementGetTypeID() ? (value as! AXUIElement) : nil
        }
    }

    static func isValueSettable(_ element: AXUIElement) -> (error: AXError, settable: Bool) {
        var settable = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        return (error, settable.boolValue)
    }

    static func failure<Value: Sendable>(_ error: AXError) -> AXCallResult<Value> {
        error == .cannotComplete ? .timedOut : .failed(code: error.rawValue)
    }

    static func map<Value>(_ outcome: Outcome<CFTypeRef>, _ transform: (CFTypeRef) -> Value?) -> Outcome<Value> {
        switch outcome {
        case .success(let value): .success(value.flatMap(transform))
        case .timedOut: .timedOut
        case .unavailable: .unavailable
        case .failed(let code): .failed(code: code)
        }
    }
}
