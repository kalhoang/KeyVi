// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R902: dynamic strings enter logs only as a salted hash or a drop marker.

import Testing

@testable import Diagnostics

@Suite struct RedactionTests {
    private let salt = RedactionSalt(bytes: Array(0..<32))

    /// Known answers computed independently with Python's `hmac` module (HMAC-SHA-256, first 8 bytes).
    @Test func hashedMatchesIndependentHMACSHA256() {
        #expect(Redacted.hashed("hello", salt: salt).description == "h:53c40272a70c15ca")
        #expect(Redacted.hashed("đá canary", salt: salt).description == "h:0bd97a5ec30c129e")
    }

    @Test func hashIsStablePerSaltAndNeverContainsTheValue() {
        let value = "Tiếng Việt có dấu"
        let first = Redacted.hashed(value, salt: salt)
        #expect(first == Redacted.hashed(value[...], salt: salt))
        #expect(first != Redacted.hashed(value, salt: RedactionSalt(bytes: Array(repeating: 7, count: 32))))
        #expect(!first.description.contains("Tiếng"))
        #expect(first.description.count == 18)
        #expect(first.description.hasPrefix("h:"))
        #expect(Redacted.dropped.description == "<dropped>")
    }

    @Test func randomSaltsAreThirtyTwoFreshBytes() {
        let first = RedactionSalt.random()
        let second = RedactionSalt.random()
        #expect(first.bytes.count == 32)
        #expect(first != second)
    }

    @Test func saltOfTheWrongSizeTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = RedactionSalt(bytes: [1, 2, 3])
        }
    }
}

@Suite struct MetadataTextTests {
    @Test func tokensAcceptOnlyMetadataShapes() {
        #expect(MetadataText.token("156.0.8078.80") == "156.0.8078.80")
        #expect(MetadataText.token("org.example.App") == "org.example.App")
        #expect(MetadataText.token("2.1.0+build:7_rc-1") == "2.1.0+build:7_rc-1")
        #expect(MetadataText.token("two words") == nil)
        #expect(MetadataText.token("đá") == nil)
        #expect(MetadataText.token("") == nil)
        #expect(MetadataText.token(String(repeating: "a", count: 65)) == nil)
        #expect(MetadataText.logToken("Xin chào") == "<dropped>")
    }

    @Test func singleLineRemovesEveryLineBreakAndLeadingFence() {
        #expect(MetadataText.singleLine("a\nb\rc\u{2028}d\u{2029}e\u{0B}f\u{85}g") == "a b c d e f g")
        #expect(MetadataText.singleLine("```text") == "text")
        #expect(MetadataText.singleLine("  ~~~ x  ") == "x")
        #expect(MetadataText.singleLine(String(repeating: "x", count: 300)).count == 200)
        #expect(MetadataText.singleLine("AXTextField") == "AXTextField")
    }
}
