// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Source checks for the "never" rules of the host services (traceability "L"): PLT-R398 (no
// EnableSecureEventInput), PLT-R385 (no AXEnhancedUserInterface), PLT-R343 (no full AXValue read).

import Foundation
import Testing

/// Non-comment lines of every Swift file under `Sources/InputHost`.
private func inputHostCodeLines() throws -> [(file: String, line: String)] {
    let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/InputHost")
    let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
    var lines: [(String, String)] = []
    for case let url as URL in enumerator where url.pathExtension == "swift" {
        let text = try String(contentsOf: url, encoding: .utf8)
        for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
            lines.append((url.lastPathComponent, String(line)))
        }
    }
    return lines
}

@Suite("Host services never-rules (PLT-R343, PLT-R385, PLT-R398)")
struct HostServicesLintTests {
    @Test func sourcesAreScanned() throws {
        #expect(try inputHostCodeLines().contains { $0.file == "SystemAXProvider.swift" })
    }

    @Test func neverEnablesSecureEventInput() throws {
        let offending = try inputHostCodeLines().filter { $0.line.contains("EnableSecureEventInput") }
        #expect(offending.isEmpty, "\(offending)")
    }

    @Test func neverTouchesEnhancedUserInterface() throws {
        let offending = try inputHostCodeLines().filter { $0.line.contains("AXEnhancedUserInterface") }
        #expect(offending.isEmpty, "\(offending)")
    }

    @Test func neverReadsAFullAXValue() throws {
        let offending = try inputHostCodeLines().filter {
            $0.line.contains("kAXValueAttribute") && !$0.line.contains("AXUIElementIsAttributeSettable")
        }
        #expect(offending.isEmpty, "\(offending)")
    }
}
