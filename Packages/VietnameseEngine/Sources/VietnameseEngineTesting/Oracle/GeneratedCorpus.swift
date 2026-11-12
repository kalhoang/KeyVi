// SPDX-License-Identifier: MPL-2.0

public import VietnameseEngine

/// One generated Vietnamese corpus case (ENG-T02, ENG-T03).
public struct GeneratedCase: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case order(CorpusOrder)
        case variant(CorpusVariant)
    }

    public let onset: String
    public let rhyme: String
    public let tone: Tone
    public let method: CorpusMethod
    public let style: ToneStyle
    public let kind: Kind
    /// The keys typed, without the boundary.
    public let keys: String
    /// Display after the last key (an open `uơ` shows as `ươ`, ENG-R531).
    public let expectedDisplay: String
    /// Text committed by a space in Vietnamese context, without the space (ENG-R532).
    public let expectedCommitted: String

    /// Default options with this case's method and style.
    public var configuration: EngineConfiguration {
        EngineConfiguration(inputMethod: method.inputMethod, toneStyle: style)
    }

    /// One key event per typed character.
    public var events: [EngineEvent] { keys.map { .key(KeyInput($0)) } }
}

/// The generated Vietnamese corpus: every Tier A onset-rhyme pair (from the engine's tables), every
/// allowed tone, both methods and both styles, in the orders O1 to O4, plus the ENG-T03 variants.
/// Expected strings come from `SyllableOracle`, never from composition code (ENG-T01).
public enum GeneratedCorpus {
    /// Calls `body` for every O1 to O4 case: each toned syllable contributes 2 methods x 2 styles x
    /// 4 orders (3 for the level tone, which has no O4).
    public static func forEachOrderCase(_ body: (GeneratedCase) throws -> Void) rethrows {
        for pair in SyllableTables.standardPairs {
            let onset = pair.onset.spelling
            let rhyme = pair.rhyme.spelling
            for tone in pair.tones {
                for style in [ToneStyle.traditional, .modern] {
                    let display = SyllableOracle.spell(onset: onset, rhyme: rhyme, tone: tone, style: style, form: .display)
                    let committed = SyllableOracle.spell(onset: onset, rhyme: rhyme, tone: tone, style: style)
                    for method in CorpusMethod.allCases {
                        for order in CorpusOrder.allCases {
                            guard
                                let keys = KeySequenceGenerator.keys(
                                    onset: onset, rhyme: rhyme, tone: tone, method: method, order: order)
                            else { continue }
                            try body(
                                GeneratedCase(
                                    onset: onset, rhyme: rhyme, tone: tone, method: method, style: style,
                                    kind: .order(order), keys: keys, expectedDisplay: display,
                                    expectedCommitted: committed))
                        }
                    }
                }
            }
        }
    }

    /// Calls `body` for every ENG-T03 variant: Titlecase and all caps for every Tier A toned syllable,
    /// and the explicit `uwow` spelling for every one whose rhyme contains `ươ`. Telex O1, traditional
    /// style (the default).
    public static func forEachVariantCase(_ body: (GeneratedCase) throws -> Void) rethrows {
        for pair in SyllableTables.standardPairs {
            let onset = pair.onset.spelling
            let rhyme = pair.rhyme.spelling
            for tone in pair.tones {
                for variant in CorpusVariant.allCases {
                    guard let keys = KeySequenceGenerator.variantKeys(onset: onset, rhyme: rhyme, tone: tone, variant: variant)
                    else { continue }
                    let casing: SyllableOracle.Casing =
                        switch variant {
                        case .titlecase: .titlecase
                        case .uppercase: .uppercase
                        case .explicitUwow: .lowercase
                        }
                    func spell(_ form: SyllableOracle.Form) -> String {
                        SyllableOracle.spell(onset: onset, rhyme: rhyme, tone: tone, style: .traditional, casing: casing, form: form)
                    }
                    try body(
                        GeneratedCase(
                            onset: onset, rhyme: rhyme, tone: tone, method: .telex, style: .traditional,
                            kind: .variant(variant), keys: keys, expectedDisplay: spell(.display),
                            expectedCommitted: spell(.committed)))
                }
            }
        }
    }

    /// Number of O1 to O4 cases and of ENG-T03 variant cases for the current tables.
    public static func counts() -> (orders: Int, variants: Int) {
        var orders = 0
        var variants = 0
        forEachOrderCase { _ in orders += 1 }
        forEachVariantCase { _ in variants += 1 }
        return (orders, variants)
    }
}
