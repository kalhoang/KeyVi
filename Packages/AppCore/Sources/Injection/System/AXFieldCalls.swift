// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Bounded AX calls for injection (PLT-R342, PLT-R343, 4.5). Never reads `AXValue`: only the selected range, a
// parameterized range read of at most 64 UTF-16 units, and selection writes. Every call first sets the
// messaging timeout on the element.

internal import AppModel
internal import ApplicationServices
internal import Foundation

enum AXFieldCalls {
    static func selectedRange(_ element: AXUIElement?, timeout: Duration) -> AXCallResult<Injection.TextRange> {
        guard let element else { return .unavailable }
        prepare(element, timeout: timeout)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value)
        guard error == .success else { return map(error) }
        guard let range = cfRange(from: value) else { return .unavailable }
        return .success(Injection.TextRange(location: range.location, length: range.length))
    }

    static func text(_ element: AXUIElement?, in range: Injection.TextRange, timeout: Duration) -> AXCallResult<String> {
        guard let element else { return .unavailable }
        prepare(element, timeout: timeout)
        var bounded = boundedRange(range)
        guard let parameter = AXValueCreate(.cfRange, &bounded) else { return .unavailable }
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value)
        guard error == .success else { return map(error) }
        guard let string = value as? String else { return .unavailable }
        return .success(string)
    }

    static func setSelectedRange(_ element: AXUIElement?, to range: Injection.TextRange, timeout: Duration)
        -> AXCallResult<Void>
    {
        guard let element else { return .unavailable }
        prepare(element, timeout: timeout)
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return .unavailable }
        return result(AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value))
    }

    static func setSelectedText(_ element: AXUIElement?, to text: String, timeout: Duration) -> AXCallResult<Void> {
        guard let element else { return .unavailable }
        prepare(element, timeout: timeout)
        return result(AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString))
    }

    /// PLT-R343: at most 64 UTF-16 units, never a negative location or length.
    static func boundedRange(_ range: Injection.TextRange) -> CFRange {
        CFRange(location: max(0, range.location), length: min(max(0, range.length), InjectionTiming.maximumAXReadUnits))
    }

    /// `kAXErrorCannotComplete` is what a messaging timeout returns; missing elements, attributes or trust mean
    /// the field is not reachable through AX.
    static func map<Value>(_ error: AXError) -> AXCallResult<Value> {
        switch error {
        case .cannotComplete: .timedOut
        case .apiDisabled, .invalidUIElement, .attributeUnsupported, .parameterizedAttributeUnsupported, .noValue,
            .notImplemented:
            .unavailable
        default: .failed(code: error.rawValue)
        }
    }

    private static func result(_ error: AXError) -> AXCallResult<Void> {
        error == .success ? .success(()) : map(error)
    }

    private static func prepare(_ element: AXUIElement, timeout: Duration) {
        AXUIElementSetMessagingTimeout(element, Float(Double(InjectionTiming.nanoseconds(timeout)) / 1e9))
    }

    private static func cfRange(from value: CFTypeRef?) -> CFRange? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetType(axValue) == .cfRange, AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }
}
