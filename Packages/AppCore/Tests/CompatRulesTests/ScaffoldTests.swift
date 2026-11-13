// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import CompatRules

@Suite struct CompatRulesScaffoldTests {
    @Test func moduleLinks() { #expect(Bool(true)) }
}
