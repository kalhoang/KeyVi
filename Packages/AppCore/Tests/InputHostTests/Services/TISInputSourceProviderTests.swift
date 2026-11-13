// SPDX-License-Identifier: GPL-3.0-or-later
//
// Read-only smoke tests of the TIS wrapper (PLT-R370): reads properties, selects nothing.

import AppModel
import Testing

@testable import InputHost

@Suite("TISInputSourceProvider (read-only)")
@MainActor
struct TISInputSourceProviderTests {
    @Test func readsTheCurrentAndEnabledSources() {
        let provider = TISInputSourceProvider()
        let current = provider.currentSource()
        #expect(!current.id.rawValue.isEmpty)
        let enabled = provider.enabledSources()
        #expect(!enabled.isEmpty)
        #expect(enabled.allSatisfy { !$0.id.rawValue.isEmpty })
        #expect(provider.currentKeyboardType() > 0)
        if current.kind == .asciiLayout { #expect(provider.currentLayoutData() != nil) }
    }

    @Test func readsAnyInstalledLayoutByIDAndNothingForUnknownIDs() {
        let provider = TISInputSourceProvider()
        let abc = provider.layoutData(for: sourceID("com.apple.keylayout.ABC"))
        #expect(abc?.source == sourceID("com.apple.keylayout.ABC"))
        #expect((abc?.uchr.count ?? 0) > 100)
        #expect(provider.layoutData(for: sourceID("test.not.installed.layout")) == nil)
    }

    @Test func observationCanBeCancelled() {
        let token = TISInputSourceProvider().observeChanges {}
        token.cancel()
        token.cancel()
    }
}
