// SPDX-License-Identifier: GPL-3.0-or-later

/// A user setting that is either untouched (`unset`, follows future default changes) or an explicit choice
/// (`set`, preserved forever, even when equal to today's default). PRD-R6, PLT-R1004.
///
/// JSON: `unset` is an absent key; `set(v)` is the key with `v`. For optional values, `set(nil)` is an
/// explicit JSON `null` ("the user chose none"), distinct from absence.
public enum Setting<Value: Sendable & Hashable & Codable>: Sendable, Hashable {
    case unset
    case set(Value)

    public func resolved(default defaultValue: Value) -> Value {
        if case .set(let value) = self { return value }
        return defaultValue
    }

    public var isSet: Bool {
        if case .set = self { return true }
        return false
    }
}
