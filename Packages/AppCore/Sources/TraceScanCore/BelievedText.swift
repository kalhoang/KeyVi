// SPDX-License-Identifier: GPL-3.0-or-later
//
// KeyVi's view of the text it produced since the last boundary (PLT-R904A scanner), character by character with
// where each character came from, so a readback that disagrees can name the key whose character never reached the
// field (the incidents of 2026-11-14). Unknown once a Backspace reaches past it (the field then holds text the
// scanner did not see typed) until a readback gives the baseline back. It also keeps the operations since its last
// baseline, so a readback can be explained by one passed key that never arrived even when later edits deleted by
// count around the hole (the held-keyUp drops of 2026-11-15, ADR 0322: "mục" read back as "ục").

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
    /// Operations kept since the baseline; older ones fold into the baseline.
    static let maximumOperations = 512

    enum Operation: Hashable {
        case append([Character], CharacterOrigin)
        case delete(Int)
    }

    private(set) var characters: [Character] = []
    private(set) var origins: [CharacterOrigin] = []
    private(set) var known = true
    private var base: [Character] = []
    private(set) var operations: [Operation] = []

    var isEmpty: Bool { characters.isEmpty }

    mutating func reset() {
        characters = []
        origins = []
        known = true
        rebase()
    }

    mutating func delete(_ count: Int) {
        guard count > 0 else { return }
        if characters.count >= count {
            characters.removeLast(count)
            origins.removeLast(count)
            record(.delete(count))
        } else {
            characters = []
            origins = []
            known = false
            rebase()
        }
    }

    mutating func append(_ addition: String, origin: CharacterOrigin) {
        guard !addition.isEmpty else { return }
        for character in addition {
            characters.append(character)
            origins.append(origin)
        }
        record(.append(Array(addition), origin))
        guard characters.count > Self.maximumCount else { return }
        characters = Array(characters.suffix(Self.trimmedCount))
        origins = Array(origins.suffix(Self.trimmedCount))
        rebase()
    }

    /// The field's text becomes KeyVi's view: the same divergence is not reported again, and an unknown view is
    /// known again.
    mutating func rebaseline(_ field: [Character]) {
        characters = field
        origins = Array(repeating: .field, count: field.count)
        known = true
        rebase()
    }

    /// One passed key's character typed since the baseline (an `append` of one character).
    struct PassedKey: Hashable {
        var operation: Int
        var character: Character
        var t: Int64
    }

    /// The passed keys among the last `limit` operations whose absence alone makes `fits` accept the text, the
    /// later operations (edits deleting by count) applied as recorded.
    func droppedKeyCandidates(limit: Int, fits: ([Character]) -> Bool) -> [PassedKey] {
        operations.indices.suffix(limit).compactMap { index in
            guard case .append(let added, .passedKey(let t)) = operations[index], added.count == 1 else { return nil }
            return fits(text(skipping: index)) ? PassedKey(operation: index, character: added[0], t: t) : nil
        }
    }

    private func text(skipping skipped: Int) -> [Character] {
        var text = base
        for (index, operation) in operations.enumerated() where index != skipped {
            switch operation {
            case .append(let added, _): text.append(contentsOf: added)
            case .delete(let count): text.removeLast(min(count, text.count))
            }
        }
        return text
    }

    private mutating func record(_ operation: Operation) {
        operations.append(operation)
        if operations.count > Self.maximumOperations { rebase() }
    }

    private mutating func rebase() {
        base = characters
        operations = []
    }
}
