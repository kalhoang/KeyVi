// SPDX-License-Identifier: GPL-3.0-or-later
//
// Bounded AX calls for injection (PLT-R342, PLT-R343, PLT-R423, 4.5). Never reads `AXValue`: only the selected range,
// the character count, a parameterized range read of at most 64 UTF-16 units, and selection writes. Every call first
// sets the messaging timeout on the element.

internal import AppModel
internal import ApplicationServices
internal import Foundation
internal import RealtimeSupport

enum AXFieldCalls {
    static func selectedRange(_ element: AXUIElement?, timeout: TimeSpan) -> AXCallResult<Injection.TextRange> {
        guard let element else { return .unavailable }
        prepare(element, timeout: timeout)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value)
        guard error == .success else { return map(error) }
        guard let range = cfRange(from: value) else { return .unavailable }
        return .success(Injection.TextRange(location: range.location, length: range.length))
    }

    /// PLT-R423: the selected range and `kAXNumberOfCharactersAttribute` in one message to the app, so both describe
    /// the same moment and the read costs one round trip, as the `axSelection` read does.
    static func caret(_ element: AXUIElement?, timeout: TimeSpan) -> AXCallResult<FieldCaret> {
        guard let element else { return .unavailable }
        prepare(element, timeout: timeout)
        let attributes = [kAXSelectedTextRangeAttribute, kAXNumberOfCharactersAttribute] as CFArray
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(
            element, attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        guard error == .success else { return map(error) }
        return caret(from: values as? [AnyObject])
    }

    /// Decodes the two values of `caret`. Without the stop-on-error option a failed attribute arrives as an `AXValue`
    /// of type `.axError` in its slot; it is mapped like the error of a single read.
    static func caret(from values: [AnyObject]?) -> AXCallResult<FieldCaret> {
        guard let values, values.count == 2 else { return .unavailable }
        if let error = axError(in: values[0]) ?? axError(in: values[1]) { return map(error) }
        guard let range = cfRange(from: values[0]), let count = (values[1] as? NSNumber)?.intValue else {
            return .unavailable
        }
        return .success(
            FieldCaret(
                selection: Injection.TextRange(location: range.location, length: range.length), characterCount: count))
    }

    static func text(_ element: AXUIElement?, in range: Injection.TextRange, timeout: TimeSpan) -> AXCallResult<String>
    {
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

    static func setSelectedRange(_ element: AXUIElement?, to range: Injection.TextRange, timeout: TimeSpan)
        -> AXCallResult<Void>
    {
        guard let element else { return .unavailable }
        prepare(element, timeout: timeout)
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return .unavailable }
        return result(AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value))
    }

    static func setSelectedText(_ element: AXUIElement?, to text: String, timeout: TimeSpan) -> AXCallResult<Void> {
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

    private static func prepare(_ element: AXUIElement, timeout: TimeSpan) {
        AXUIElementSetMessagingTimeout(element, Float(Double(InjectionTiming.nanoseconds(timeout)) / 1e9))
    }

    private static func axError(in value: AnyObject) -> AXError? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        var error = AXError.success
        guard AXValueGetType(axValue) == .axError, AXValueGetValue(axValue, .axError, &error) else { return nil }
        return error == .success ? nil : error
    }

    private static func cfRange(from value: CFTypeRef?) -> CFRange? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetType(axValue) == .cfRange, AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }
}
