// SPDX-License-Identifier: GPL-3.0-or-later
//
// KeyVi's view of the text it produced since the last boundary (PLT-R904A scanner), character by character with
// where each character came from, so a readback that disagrees can name the key whose character never reached the
// field (the incidents of 2026-11-14). Unknown once a Backspace reaches past it (the field then holds text the
// scanner did not see typed) until a readback gives the baseline back.

/// Where a character of KeyVi's view came from.
enum CharacterOrigin: Hashable {
    /// A key the tap passed for the app to insert, at its key-down time.
    case passedKey(t: Int64)
    /// KeyVi's edit, at the engine step's time.
    case edit(t: Int64)
    /// A readback's text, after a mismatch or an unknown baseline.
    case field
}

struct BelievedText {
    /// Kept between 128 and 256 characters: readbacks compare 32.
    static let maximumCount = 256
    static let trimmedCount = 128

    private(set) var characters: [Character] = []
    private(set) var origins: [CharacterOrigin] = []
    private(set) var known = true

    var isEmpty: Bool { characters.isEmpty }

    mutating func reset() {
        characters = []
        origins = []
        known = true
    }

    mutating func delete(_ count: Int) {
        guard count > 0 else { return }
        if characters.count >= count {
            characters.removeLast(count)
            origins.removeLast(count)
        } else {
            characters = []
            origins = []
            known = false
        }
    }

    mutating func append(_ addition: String, origin: CharacterOrigin) {
        for character in addition {
            characters.append(character)
            origins.append(origin)
        }
        guard characters.count > Self.maximumCount else { return }
        characters = Array(characters.suffix(Self.trimmedCount))
        origins = Array(origins.suffix(Self.trimmedCount))
    }

    /// The field's text becomes KeyVi's view: the same divergence is not reported again, and an unknown view is
    /// known again.
    mutating func rebaseline(_ field: [Character]) {
        characters = field
        origins = Array(repeating: .field, count: field.count)
        known = true
    }
}
