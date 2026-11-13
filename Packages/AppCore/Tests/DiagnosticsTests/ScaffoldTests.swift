// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Diagnostics

@Suite struct DiagnosticsScaffoldTests {
    @Test func moduleLinks() { #expect(Bool(true)) }
}
