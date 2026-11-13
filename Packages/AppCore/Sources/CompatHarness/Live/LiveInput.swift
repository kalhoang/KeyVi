// SPDX-License-Identifier: LicenseRef-App-Pending
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
        guard let cgEvent = CGEvent(keyboardEventSource: source, virtualKey: event.keyCode.rawValue, keyDown: event.phase == .down)
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

    /// Depth-first search for `AXIdentifier == identifier` below `root`.
    static func find(_ identifier: String, in root: AXUIElement, depth: Int = 0) -> AXUIElement? {
        if attribute(root, kAXIdentifierAttribute) as? String == identifier { return root }
        guard depth < maximumDepth, let children = attribute(root, kAXChildrenAttribute) as? [AXUIElement] else {
            return nil
        }
        for child in children {
            if let found = find(identifier, in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    static func element(_ identifier: String?, in bundle: BundleKey) throws -> AXUIElement {
        let app = try application(bundle)
        if let identifier {
            guard let found = find(identifier, in: app) else { throw LiveError.elementNotFound(identifier) }
            return found
        }
        guard let focused = attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { throw LiveError.elementNotFound("focused element") }
        return focused as! AXUIElement  // type ID checked on the line above
    }

    static func set(_ element: AXUIElement, _ name: String, _ value: CFTypeRef) throws {
        let result = AXUIElementSetAttributeValue(element, name as CFString, value)
        guard result == .success else { throw LiveError.axFailure("set " + name, result.rawValue) }
    }
}

struct LiveAXFieldReader: AXFieldReader {
    func text(identifier: String?, in bundle: BundleKey) async throws -> String {
        let element = try AX.element(identifier, in: bundle)
        return AX.attribute(element, kAXValueAttribute) as? String ?? ""
    }
}
