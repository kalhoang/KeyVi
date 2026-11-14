// SPDX-License-Identifier: GPL-3.0-or-later
//
// The dev recorder's field readback reads through its own AX element reference (PLT-R904A observer rule, ADR 0007
// decision 5). AX sets the messaging timeout per element object: if the readback used the `FieldHandle` element the
// inject worker uses, its 50 ms timeout and the worker's 15 ms or 30 ms ones would race on one object from two
// threads, and a worker read that timed out would change KeyVi's behaviour (PLT-R342, PLT-R343). So the readback
// asks the app for its focused element again, gets a new reference with its own timeout, and reads only if that
// element is still the field in the focus snapshot. Debug configuration only.

#if DEV_RECORDER
internal import AppModel
internal import ApplicationServices
internal import Foundation
public import RealtimeSupport

/// Resolves the readback's private reference to the focused field.
public protocol DevReadbackFieldResolver: Sendable {
    /// A handle on a new AX reference to the app's focused element when it is still `field`; `.success(nil)` when
    /// focus moved (or AX handed back the shared reference itself, which must not be retimed).
    func privateHandle(for field: FieldHandle, timeout: TimeSpan) -> AXCallResult<FieldHandle?>
}

/// Production: `AXUIElementCreateApplication(pid)`, then its `kAXFocusedUIElementAttribute`, compared with
/// `CFEqual`. Never sets an attribute (no AXEnhancedUserInterface, no AXManualAccessibility).
public struct AXDevReadbackFieldResolver: DevReadbackFieldResolver {
    public init() {}

    public func privateHandle(for field: FieldHandle, timeout: TimeSpan) -> AXCallResult<FieldHandle?> {
        guard let shared = field.element?.element else { return .unavailable }
        let application = AXUIElementCreateApplication(field.pid)
        AXUIElementSetMessagingTimeout(application, Float(Double(InjectionTiming.nanoseconds(timeout)) / 1e9))
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &value)
        guard error == .success else { return AXFieldCalls.map(error) }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return .unavailable }
        let focused = unsafeDowncast(value, to: AXUIElement.self)
        guard CFEqual(focused, shared), focused !== shared else { return .success(nil) }
        return .success(FieldHandle(pid: field.pid, token: field.token, element: AXElementReference(focused)))
    }
}
#endif
