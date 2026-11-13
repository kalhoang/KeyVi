// SPDX-License-Identifier: GPL-3.0-or-later
//
// Calendar-day arithmetic for `reviewBy` (PLT-R506), matrix freshness (QA-R19, PLT-R531) and lint dates.
// Pure integer math on the proleptic Gregorian calendar in UTC, so results never depend on the host time zone.

import Foundation

/// A UTC calendar day parsed from a strict `YYYY-MM-DD` string or taken from a `Date`.
struct ISODay: Sendable, Hashable, Comparable {
    /// Days since 1970-01-01.
    let ordinal: Int

    init(ordinal: Int) {
        self.ordinal = ordinal
    }

    /// Strict ISO date: exactly `YYYY-MM-DD` with a valid month and day. `VERIFY` and partial dates return nil.
    init?(_ text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
            parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
            let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
            (1...12).contains(month), (1...Self.daysIn(month: month, year: year)).contains(day)
        else { return nil }
        ordinal = Self.ordinal(year: year, month: month, day: day)
    }

    /// The UTC calendar day containing `date`.
    init(_ date: Date) {
        ordinal = Int((date.timeIntervalSince1970 / Self.secondsPerDay).rounded(.down))
    }

    /// Whole days from `other` to `self` (positive when `self` is later).
    func days(since other: ISODay) -> Int { ordinal - other.ordinal }

    static func < (lhs: ISODay, rhs: ISODay) -> Bool { lhs.ordinal < rhs.ordinal }

    private static let secondsPerDay: Double = 86_400

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: isLeap(year) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    private static func isLeap(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    /// Days from the civil date to 1970-01-01, counting 400-year eras of 146,097 days.
    private static func ordinal(year: Int, month: Int, day: Int) -> Int {
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
