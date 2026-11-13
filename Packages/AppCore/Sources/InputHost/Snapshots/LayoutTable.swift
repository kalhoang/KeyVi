// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Layout translation table (PLT-R360, PLT-R361). Built off the hot path from the layout's `uchr` data with
// `UCKeyTranslate`; looked up on the tap by array index.

public import AppModel

/// Modifier states covered by the table. Option and Command/Control states are classified, not translated
/// (PLT-R350).
public enum LayoutModifierState: Int, Sendable, Hashable, CaseIterable {
    case none = 0
    case shift
    case capsLock
    case shiftCapsLock
}

public enum LayoutEntry: Sendable, Hashable {
    case character(Character)
    /// `UCKeyTranslate` returned no character and a non-zero dead-key state (PLT-R354).
    case deadKey
    case none
}

public struct LayoutTable: Sendable {
    public static let keyCodeCount = 128

    public let source: InputSourceID
    public let keyboardType: UInt32
    private let entries: [LayoutEntry]  // keyCodeCount * 4, index = keyCode * 4 + state
    private let reverse: [Character: KeyCode]

    /// Used by the builder and by tests with synthetic tables.
    public init(source: InputSourceID, keyboardType: UInt32, entries: [LayoutEntry]) {
        precondition(entries.count == Self.keyCodeCount * LayoutModifierState.allCases.count)
        self.source = source
        self.keyboardType = keyboardType
        self.entries = entries
        var reverse: [Character: KeyCode] = [:]
        for code in (0..<Self.keyCodeCount).reversed() {
            for state in [LayoutModifierState.shift, .none] {
                if case .character(let character) = entries[code * 4 + state.rawValue] {
                    reverse[character] = KeyCode(rawValue: UInt16(code))
                }
            }
        }
        self.reverse = reverse
    }

    /// Tap-safe: bounds check plus array read, no allocation.
    @inline(__always)
    public func entry(for keyCode: KeyCode, state: LayoutModifierState) -> LayoutEntry {
        let code = Int(keyCode.rawValue)
        guard code < Self.keyCodeCount else { return .none }
        return entries[code * 4 + state.rawValue]
    }

    /// Keycode producing `character` without modifiers or with Shift (PLT-R405, PLT-R461 step 3).
    public func keyCode(producing character: Character) -> KeyCode? { reverse[character] }
}
