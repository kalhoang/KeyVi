// SPDX-License-Identifier: GPL-3.0-or-later
//
// Coding of `RuleProvenance`: shipped rules use the 5.4 provenance object, user overrides the PLT-R1205
// suggestion shape. The two are told apart by the presence of `source`; both encode as a flat object.

extension RuleProvenance {
    private enum Discriminator: String, CodingKey {
        case source
    }

    static func decodeTagged(from decoder: any Decoder) throws -> RuleProvenance {
        let container = try decoder.container(keyedBy: Discriminator.self)
        if container.contains(.source) {
            return .userSuggestion(try UserProvenance(from: decoder))
        }
        return .shipped(try Provenance(from: decoder))
    }

    func encodeTagged(to encoder: any Encoder) throws {
        switch self {
        case .shipped(let provenance): try provenance.encode(to: encoder)
        case .userSuggestion(let provenance): try provenance.encode(to: encoder)
        }
    }
}

extension UserProvenance {
    /// The only `source` value of a user override's provenance (PLT-R1205).
    static let suggestionSource = "user-suggestion"
}
