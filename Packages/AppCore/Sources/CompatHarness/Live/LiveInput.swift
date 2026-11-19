// SPDX-License-Identifier: GPL-3.0-or-later
//
// Keyboard events and accessibility for the self-hosted runner (13.2). The harness posts from its own HID-state
// event source at the HID tap, without the app's event marker, so the app under test treats the events as
// physical keystrokes (PLT-R321). Runner only.

import AppKit
import AppModel
import ApplicationServices
import CoreGraphics
import Foundation
import TestSupport

/// `CGEventSource` is a CoreFoundation object; it is created once and only read afterwards (Apple documents
/// event creation from any thread), hence the unchecked conformance.
final class CGEventKeySink: KeyEventSink, @unchecked Sendable {
    private let source: CGEventSource

    init() throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else { throw LiveError.eventCreationFailed }
        self.source = source
    }

    func post(_ event: PlannedKeyEvent) throws {
        guard
            let cgEvent = CGEvent(
                keyboardEventSource: source, virtualKey: event.keyCode.rawValue, keyDown: event.phase == .down)
        else { throw LiveError.eventCreationFailed }
        if event.isFlagsChanged { cgEvent.type = .flagsChanged }
        cgEvent.flags = CGEventFlags(rawValue: event.flags)
        cgEvent.post(tap: .cghidEventTap)
    }
}

/// AX helpers shared by readback and setup. Every call has a 1 s messaging timeout.
enum AX {
    static let timeout: Float = 1
    static let maximumDepth = 24
    static let elementWaitNanoseconds: UInt64 = 5_000_000_000

    static func application(_ bundle: BundleKey) throws -> AXUIElement {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle.rawValue).first else {
            throw LiveError.appNotRunning(bundle.rawValue)
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    /// One attribute read with its `AXError` code, for a walk that reports why it missed.
    static func read<Value>(_ element: AXUIElement, _ name: String, as type: Value.Type) -> AXAttributeRead<Value> {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return AXAttributeRead(value: value as? Value, code: result.rawValue)
    }

    /// Depth-first search for `AXIdentifier == identifier` below `root`, with the first container read that failed
    /// (`AXIdentifierLookup`: a miss names it, PLT-R530).
    static func find(_ identifier: String, in root: AXUIElement) -> AXIdentifierLookup.Outcome<AXUIElement> {
        AXIdentifierLookup.find(
            identifier, in: root, maximumDepth: maximumDepth,
            identifierOf: { read($0, kAXIdentifierAttribute, as: String.self) },
            childrenOf: { read($0, kAXChildrenAttribute, as: [AXUIElement].self) })
    }

    static func element(_ identifier: String?, in bundle: BundleKey) throws -> AXUIElement {
        let app = try application(bundle)
        if let identifier {
            let lookup = find(identifier, in: app)
            guard let found = lookup.found else { throw LiveError.elementNotFound(identifier, lookup.firstFailure) }
            return found
        }
        guard let focused = attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { throw LiveError.elementNotFound("focused element") }
        return focused as! AXUIElement  // type ID checked on the line above
    }

    /// Lookup by identifier, retried for up to `elementWaitNanoseconds` while the app starts or builds its window:
    /// `launch` returns once the process runs, before its controls exist (the first VM run failed `setSecureInput`
    /// right after TestHost's launch, integration-suite.md section 10).
    /// A lookup that misses for the whole wait names the failed container read of its last walk, if any.
    static func element(_ identifier: String, in bundle: BundleKey, sleeper: any HarnessSleeper) async throws
        -> AXUIElement
    {
        var failure: AXIdentifierLookup.Failure?
        let found = try await HarnessPolling.firstValue(timeoutNanoseconds: elementWaitNanoseconds, sleeper: sleeper) {
            () -> AXUIElement? in
            guard let app = try? application(bundle) else { return nil }
            let lookup = find(identifier, in: app)
            failure = lookup.firstFailure
            return lookup.found
        }
        guard let found else { throw LiveError.elementNotFound(identifier, failure) }
        return found
    }

    /// Brings the element's window to the front and makes it the main window, so the keys go there: a field of a
    /// window behind takes AX focus without its window becoming key (the first VM runs typed the second window's
    /// scenarios into TestHost's main window). Best effort: an app without AX windows keeps its own order.
    static func raiseWindow(of element: AXUIElement) {
        guard let window = attribute(element, kAXWindowAttribute), CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return }
        let axWindow = window as! AXUIElement  // type ID checked on the line above
        _ = AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    /// Frontmost app and the system-wide focused element (role, subrole, identifier, its window's identifier, its
    /// selection and character count), never a value and never a window title: titles are content (ARCHITECTURE.md,
    /// PLT-R901), and the report is written to the evidence directory whichever app the scenario targets.
    static func focusReport() -> [String] {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, timeout)
        var lines = ["frontmost: " + (NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")]
        if let app = attribute(systemWide, kAXFocusedApplicationAttribute),
            CFGetTypeID(app) == AXUIElementGetTypeID()
        {
            var pid: pid_t = 0
            AXUIElementGetPid(app as! AXUIElement, &pid)  // type ID checked above
            lines.append(
                "focused application: " + (NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "?"))
        }
        guard let focused = attribute(systemWide, kAXFocusedUIElementAttribute),
            CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return lines + ["focused element: none"] }
        let element = focused as! AXUIElement  // type ID checked above
        for (label, name) in [
            ("role", kAXRoleAttribute), ("subrole", kAXSubroleAttribute), ("identifier", kAXIdentifierAttribute),
        ] {
            lines.append("focused " + label + ": " + (attribute(element, name) as? String ?? "none"))
        }
        if let window = attribute(element, kAXWindowAttribute), CFGetTypeID(window) == AXUIElementGetTypeID() {
            lines.append(
                "focused window identifier: "
                    + (attribute(window as! AXUIElement, kAXIdentifierAttribute) as? String ?? "none"))
        }
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        lines.append("focused value settable: " + String(settable.boolValue))
        let characters = attribute(element, kAXNumberOfCharactersAttribute) as? Int
        return lines + AXReadbackText.focusReportLines(selection: selection(of: element), characters: characters)
    }

    /// Whether the app's focused element takes text (its value is settable): a web mirror hands focus to the page
    /// a moment after the AX focus request.
    static func focusedElementIsEditable(in bundle: BundleKey) -> Bool {
        guard let app = try? application(bundle), let focused = attribute(app, kAXFocusedUIElementAttribute),
            CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return false }
        var settable: DarwinBoolean = false
        let result = AXUIElementIsAttributeSettable(focused as! AXUIElement, kAXValueAttribute as CFString, &settable)
        return result == .success && settable.boolValue
    }

    /// `kAXSelectedTextRangeAttribute` in UTF-16 units; nil when the element has none.
    static func selection(of element: AXUIElement) -> AXReadbackText.Selection? {
        guard let raw = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range) else { return nil }  // type ID checked above
        return AXReadbackText.Selection(location: range.location, length: range.length)
    }

    static func set(_ element: AXUIElement, _ name: String, _ value: CFTypeRef) throws {
        let result = AXUIElementSetAttributeValue(element, name as CFString, value)
        guard result == .success else { throw LiveError.axFailure("set " + name, result.rawValue) }
    }
}

/// The whole value and the selection, nothing stripped: whether a selected completion counts is the scenario's
/// declaration, applied by `ReadbackRouter` (PLT-R530).
struct LiveAXFieldReader: AXFieldReader {
    func field(identifier: String?, in bundle: BundleKey) async throws -> AXFieldState {
        let element = try AX.element(identifier, in: bundle)
        let value = AX.attribute(element, kAXValueAttribute) as? String ?? ""
        return AXFieldState(value: value, selection: AX.selection(of: element))
    }
}
