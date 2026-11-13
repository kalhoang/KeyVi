// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Length of time for timeouts, intervals, backoffs and deadlines (docs/decisions/0315-minimum-macos-12.md).
// Replaces `Swift.Duration`, which needs macOS 13 (PLT-R106: the floor is macOS 12). Call sites keep the
// `Duration` spelling of values: `.milliseconds(150)`, `.seconds(2)`, `.zero`, comparisons and arithmetic.
//
// Signed nanoseconds in 64 bits (about 292 years either way). Factories and arithmetic saturate at the bounds
// instead of trapping, so a configuration value can never crash the input method.

public import Dispatch

public struct TimeSpan: Sendable, Hashable, Comparable, BitwiseCopyable, CustomStringConvertible {
    /// Signed length in nanoseconds.
    public var nanoseconds: Int64

    @inlinable public init(nanoseconds: Int64) { self.nanoseconds = nanoseconds }

    public static let zero = TimeSpan(nanoseconds: 0)

    // MARK: Factories

    @inlinable public static func nanoseconds(_ value: some BinaryInteger) -> TimeSpan {
        TimeSpan(nanoseconds: Int64(clamping: value))
    }

    @inlinable public static func microseconds(_ value: some BinaryInteger) -> TimeSpan {
        scaled(value, by: 1_000)
    }

    @inlinable public static func milliseconds(_ value: some BinaryInteger) -> TimeSpan {
        scaled(value, by: 1_000_000)
    }

    @inlinable public static func seconds(_ value: some BinaryInteger) -> TimeSpan {
        scaled(value, by: 1_000_000_000)
    }

    /// Fractional seconds, rounded to the nearest nanosecond; NaN is zero.
    @inlinable public static func seconds(_ value: Double) -> TimeSpan {
        fromNanoseconds(value * 1e9)
    }

    /// Fractional milliseconds, rounded to the nearest nanosecond; NaN is zero.
    @inlinable public static func milliseconds(_ value: Double) -> TimeSpan {
        fromNanoseconds(value * 1e6)
    }

    @inlinable static func scaled(_ value: some BinaryInteger, by factor: Int64) -> TimeSpan {
        let clamped = Int64(clamping: value)
        let (product, overflow) = clamped.multipliedReportingOverflow(by: factor)
        guard !overflow else { return TimeSpan(nanoseconds: (clamped < 0) != (factor < 0) ? .min : .max) }
        return TimeSpan(nanoseconds: product)
    }

    @inlinable static func fromNanoseconds(_ value: Double) -> TimeSpan {
        guard !value.isNaN else { return .zero }
        guard value < 9.223_372_036_854_775e18 else { return TimeSpan(nanoseconds: .max) }
        guard value > -9.223_372_036_854_775e18 else { return TimeSpan(nanoseconds: .min) }
        return TimeSpan(nanoseconds: Int64(value.rounded()))
    }

    // MARK: Conversions

    /// Length in seconds as a floating-point value (for Foundation's `TimeInterval` APIs and display).
    @inlinable public var inSeconds: Double { Double(nanoseconds) / 1e9 }

    /// Nanoseconds clamped to zero and above, for APIs that take an unsigned count (`Task.sleep(nanoseconds:)`,
    /// `DispatchTime(uptimeNanoseconds:)`).
    @inlinable public var unsignedNanoseconds: UInt64 { UInt64(clamping: nanoseconds) }

    /// Nanosecond-precision interval for Dispatch APIs; negative lengths become zero.
    @inlinable public var dispatchInterval: DispatchTimeInterval {
        .nanoseconds(Int(clamping: Swift.max(0, nanoseconds)))
    }

    public var description: String { "\(inSeconds) seconds" }

    // MARK: Arithmetic (saturating)

    @inlinable public static func < (lhs: TimeSpan, rhs: TimeSpan) -> Bool { lhs.nanoseconds < rhs.nanoseconds }

    @inlinable public static func + (lhs: TimeSpan, rhs: TimeSpan) -> TimeSpan {
        let (sum, overflow) = lhs.nanoseconds.addingReportingOverflow(rhs.nanoseconds)
        guard !overflow else { return TimeSpan(nanoseconds: rhs.nanoseconds < 0 ? .min : .max) }
        return TimeSpan(nanoseconds: sum)
    }

    @inlinable public static func - (lhs: TimeSpan, rhs: TimeSpan) -> TimeSpan {
        let (difference, overflow) = lhs.nanoseconds.subtractingReportingOverflow(rhs.nanoseconds)
        guard !overflow else { return TimeSpan(nanoseconds: rhs.nanoseconds < 0 ? .max : .min) }
        return TimeSpan(nanoseconds: difference)
    }

    @inlinable public static func += (lhs: inout TimeSpan, rhs: TimeSpan) { lhs = lhs + rhs }

    @inlinable public static func -= (lhs: inout TimeSpan, rhs: TimeSpan) { lhs = lhs - rhs }

    @inlinable public static prefix func - (span: TimeSpan) -> TimeSpan { .zero - span }

    @inlinable public static func * (lhs: TimeSpan, rhs: some BinaryInteger) -> TimeSpan {
        scaled(lhs.nanoseconds, by: Int64(clamping: rhs))
    }

    @inlinable public static func * (lhs: some BinaryInteger, rhs: TimeSpan) -> TimeSpan { rhs * lhs }

    /// Integer division toward zero; dividing by zero saturates by sign (zero stays zero).
    @inlinable public static func / (lhs: TimeSpan, rhs: some BinaryInteger) -> TimeSpan {
        let divisor = Int64(clamping: rhs)
        guard divisor != 0 else {
            return lhs.nanoseconds == 0 ? .zero : TimeSpan(nanoseconds: lhs.nanoseconds < 0 ? .min : .max)
        }
        let (quotient, overflow) = lhs.nanoseconds.dividedReportingOverflow(by: divisor)
        return overflow ? TimeSpan(nanoseconds: .max) : TimeSpan(nanoseconds: quotient)
    }

    /// Ratio of two lengths.
    @inlinable public static func / (lhs: TimeSpan, rhs: TimeSpan) -> Double {
        Double(lhs.nanoseconds) / Double(rhs.nanoseconds)
    }
}
