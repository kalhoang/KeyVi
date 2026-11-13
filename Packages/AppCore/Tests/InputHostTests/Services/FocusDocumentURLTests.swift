// SPDX-License-Identifier: LicenseRef-App-Pending
//
// 02-platform.md 5.5: the match context carries the document URL "of the focused web area" only. Browser chrome
// such as the omnibox never gets the tab's URL, so the seeded address-bar rules do not tie with URL rules such
// as Google Sheets (PLT-R521). Runs the focus tracker against the seeded compat/rules.json.

import AppModel
import CompatRules
import Foundation
import Testing

@testable import InputHost
@testable import TestSupport

private typealias F = FocusFixtures

/// The seeded rules as the focus tracker sees them, with Chrome fingerprinted as Chromium.
private func seededRules() throws -> CountingFocusResolver {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Services
        .deletingLastPathComponent()  // InputHostTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // AppCore
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()  // repository root
    let document = try RulesLoader.decode(Data(contentsOf: root.appending(path: "compat/rules.json")))
    let rules = try RuleSet(document: document, overrides: [], optedIn: [])
    return CountingFocusResolver(rules, fingerprints: [F.chrome: .chromium])
}

private let sheetsURL = "https://docs.google.com/spreadsheets/d/1"

@Suite("FocusTracker document URL (02-platform.md 5.5, PLT-R521)", .serialized)
struct FocusDocumentURLTests {
    /// The omnibox is browser chrome, not web content: even if AX reported the tab's URL for it, the context has
    /// no document URL, so the address-bar rule wins with no tie against the Sheets rule.
    @Test func chromeOmniboxOnAGoogleSheetsTabIsTheAddressBarWithNoTie() throws {
        let harness = FocusHarness()
        defer { harness.finish() }
        let rules = try seededRules()
        let omnibox = F.attributes(
            role: "AXTextField", url: sheetsURL, ancestors: ["AXGroup", "AXToolbar", "AXGroup", "AXWindow"])
        harness.ax.focus(pid: F.chromePID, attributes: omnibox, notify: nil)
        harness.start(rules)
        #expect(harness.ax.lastAttributeRequest?.includeDocumentURL == true)
        #expect(rules.resolvedContexts.last?.documentURL == nil)
        #expect(harness.snapshot.decision.rule == RuleID(rawValue: "browser.chromium.addressBar"))
        #expect(harness.tracker.currentDecision()?.tieLoser == nil)
        #expect(harness.health.recent(limit: 16).filter { $0.kind == .ruleTie }.isEmpty)
    }

    @Test func aSheetsCellInsideTheWebAreaMatchesTheSheetsRule() throws {
        let harness = FocusHarness()
        defer { harness.finish() }
        let rules = try seededRules()
        let cell = F.attributes(
            role: "AXTextArea", url: sheetsURL, ancestors: ["AXGroup", "AXGroup", "AXWebArea", "AXScrollArea"])
        harness.ax.focus(pid: F.chromePID, attributes: cell, notify: nil)
        harness.start(rules)
        #expect(rules.resolvedContexts.last?.documentURL == sheetsURL)
        #expect(harness.snapshot.decision.rule == RuleID(rawValue: "web.googleSheets.cellEditor"))
        // The URL is used for matching only and never published (PLT-R383).
        #expect(!String(describing: harness.snapshot).contains("spreadsheets"))
    }

    /// The web area itself can be the focused element (a page without an editable focus).
    @Test func theWebAreaItselfKeepsItsURL() throws {
        let harness = FocusHarness()
        defer { harness.finish() }
        let rules = try seededRules()
        let page = F.attributes(role: "AXWebArea", url: sheetsURL, ancestors: ["AXScrollArea", "AXGroup", "AXWindow"])
        harness.ax.focus(pid: F.chromePID, attributes: page, notify: nil)
        harness.start(rules)
        #expect(rules.resolvedContexts.last?.documentURL == sheetsURL)
    }

    /// The web area may sit more than six levels up; the provider then reports the chain up to it, and only the
    /// first six roles take part in matching (5.2).
    @Test func aDeepWebAreaKeepsTheURLAndMatchingSeesSixAncestors() throws {
        let harness = FocusHarness()
        defer { harness.finish() }
        let rules = try seededRules()
        let deep = Array(repeating: "AXGroup", count: 8) + ["AXWebArea"]
        harness.ax.focus(pid: F.chromePID, attributes: F.attributes(url: sheetsURL, ancestors: deep), notify: nil)
        harness.start(rules)
        #expect(rules.resolvedContexts.last?.documentURL == sheetsURL)
        #expect(rules.resolvedContexts.last?.ancestorRoles.count == 6)
    }
}
