// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R371, PLT-R372: classification by type, ASCII capability and language; IDs kept as valid metadata.

import AppModel
import Testing

@testable import InputHost

private func raw(
    _ id: String = "test.source", type: RawInputSourceType, ascii: Bool = true, languages: [String] = ["en"]
) -> RawInputSource {
    RawInputSource(id: id, type: type, asciiCapable: ascii, languages: languages, localizedName: "Name")
}

@Suite("Input source classification (PLT-R371, PLT-R372)")
struct InputSourceClassifierTests {
    @Test func onlyAsciiCapableLayoutsAreTransformed() {
        #expect(InputSourceClassifier.info(from: raw(type: .keyboardLayout)).kind == .asciiLayout)
        #expect(InputSourceClassifier.info(from: raw(type: .keyboardLayout, ascii: false)).kind == .nonASCIILayout)
        #expect(InputSourceClassifier.info(from: raw(type: .inputMethod)).kind == .inputMethod)
        #expect(InputSourceClassifier.info(from: raw(type: .inputMode, languages: ["ja"])).kind == .inputMode)
        #expect(InputSourceClassifier.info(from: raw(type: .other)).kind == .inputMethod)
    }

    @Test func vietnameseTransformerByLanguageAndKindNotByID() {
        let telex = raw("vendor.vi.telex", type: .inputMode, languages: ["vi"])
        #expect(InputSourceClassifier.info(from: telex).isBuiltInVietnamese)
        #expect(InputSourceClassifier.info(from: raw(type: .inputMethod, languages: ["vi-VN"])).isBuiltInVietnamese)
        #expect(
            InputSourceClassifier.info(from: raw(type: .keyboardLayout, ascii: false, languages: ["vi"]))
                .isBuiltInVietnamese)
        // An ASCII layout that lists Vietnamese, or a source whose primary language is not Vietnamese, is fine.
        #expect(!InputSourceClassifier.info(from: raw(type: .keyboardLayout, languages: ["vi"])).isBuiltInVietnamese)
        #expect(!InputSourceClassifier.info(from: raw(type: .inputMode, languages: ["en", "vi"])).isBuiltInVietnamese)
        #expect(!InputSourceClassifier.info(from: raw(type: .inputMode, languages: [])).isBuiltInVietnamese)
    }

    @Test func idsAreSanitisedIntoValidIdentifiers() {
        #expect(InputSourceClassifier.sanitizedID("com.apple.keylayout.ABC").rawValue == "com.apple.keylayout.ABC")
        #expect(
            InputSourceClassifier.sanitizedID("org.example.keylayout.My Layout!").rawValue
                == "org.example.keylayout.My_Layout_")
        #expect(InputSourceClassifier.sanitizedID("").rawValue == "unknown")
        #expect(InputSourceClassifier.sanitizedID(String(repeating: "x", count: 400)).rawValue.count == 255)
        #expect(InputSourceClassifier.sanitizedID("sha256:abc").rawValue == "sha256_abc")
    }

    @Test func infoCarriesNameAndLanguages() {
        let info = InputSourceClassifier.info(from: raw("a.b", type: .keyboardLayout, languages: ["de", "en"]))
        #expect(info.id == sourceID("a.b"))
        #expect(info.localizedName == "Name")
        #expect(info.languages == ["de", "en"])
    }
}
