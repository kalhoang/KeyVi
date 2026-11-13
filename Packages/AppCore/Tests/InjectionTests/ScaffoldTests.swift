// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Injection

@Suite struct InjectionScaffoldTests {
    @Test func moduleLinks() { #expect(Bool(true)) }
}
