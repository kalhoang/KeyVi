// SPDX-License-Identifier: GPL-3.0-or-later
//
// Behaviour of the seeded compat/rules.json for the app classes of 02-platform.md 5.6 and section 6, and static
// guarantees about the CompatRules sources (PLT-R501, PLT-R504).

import AppModel
import Foundation
import Testing

@testable import CompatRules

@Suite struct SeededDataTests {
    /// PLT-R398C, PLT-R397: Terminal and iTerm2 carry secure-input hints; iTerm2's covers its automatic mode.
    @Test func secureInputHintsForTerminals() throws {
        let rules = try Build.seededRuleSet()
        #expect(rules.secureInputHintKey(for: bundleKey("com.apple.Terminal")) == "terminal.secureKeyboardEntry")
        #expect(rules.secureInputHintKey(for: bundleKey("com.googlecode.iterm2")) == "iterm2.secureKeyboardEntry")
    }

    /// PLT-R510, PLT-R399: reserved groups and the conflicting-apps list come from data.
    @Test func groupsAndConflictingApps() throws {
        let rules = try Build.seededRuleSet()
        #expect(
            rules.webkitBrowsers == [bundleKey("com.apple.Safari"), bundleKey("com.apple.SafariTechnologyPreview")])
        #expect(!rules.conflictingInputApps.isEmpty)
        #expect(
            rules.document.bundleGroups[ReservedGroup.terminals]?.contains(bundleKey("com.googlecode.iterm2")) == true)
        #expect(
            rules.overlayBundles == [
                bundleKey("com.apple.Spotlight"), bundleKey("com.raycast.macos"),
                bundleKey("com.runningwithcrayons.Alfred"),
            ])
        #expect(rules.titlePatternBundles.isEmpty)
    }

    struct Expectation: Sendable, CustomTestStringConvertible {
        let label: String
        let context: MatchContext
        let rule: String?
        let check: @Sendable (ResolvedDecision) -> Bool
        var testDescription: String { label }
    }

    static let expectations: [Expectation] = [
        .init(
            label: "terminal pacing, no gating, code context",
            context: Build.context(bundle: "com.apple.Terminal", role: "AXTextArea"), rule: "terminal.default"
        ) {
            $0.params.interEventDelayUs == 1_500 && $0.params.postDeleteSettleUs == 4_000
                && $0.requireTextFocus == .never
                && $0.engineContext == .code && !$0.features.restoreHotkey && !$0.features.autoCapitalize
        },
        .init(
            label: "Safari address bar uses axSelection",
            context: Build.context(
                bundle: "com.apple.Safari", engine: .webkitBrowser, role: "AXTextField", ancestorRoles: ["AXToolbar"]),
            rule: "browser.webkit.addressBar"
        ) {
            $0.params.inlineCompletion == .axSelection
        },
        .init(
            label: "Firefox URL bar",
            context: Build.context(
                bundle: "org.mozilla.firefox", engine: .gecko, role: "AXComboBox", ancestorRoles: ["AXToolbar"]),
            rule: "browser.gecko.urlBar"
        ) {
            $0.params.inlineCompletion == .axSelectionThenPlaceholder
        },
        .init(
            label: "Google Sheets in Chrome",
            context: Build.context(
                bundle: "com.google.Chrome", engine: .chromium, role: "AXTextArea",
                url: "https://docs.google.com/spreadsheets/d/1"), rule: "web.googleSheets.cellEditor"
        ) {
            $0.params.inlineCompletion == .axSelection && $0.params.firstEditDelayUs == 8_000 && $0.matchedURL
        },
        // 02-platform.md 5.5: documentURL is the URL "of the focused web area", so the host leaves it nil while
        // the omnibox has focus on a Sheets tab; the address-bar rule then wins with no tie (PLT-R521).
        .init(
            label: "Chrome omnibox on a Google Sheets tab",
            context: Build.context(
                bundle: "com.google.Chrome", engine: .chromium, role: "AXTextField", ancestorRoles: ["AXToolbar"]),
            rule: "browser.chromium.addressBar"
        ) {
            $0.params.inlineCompletion == .axSelectionThenPlaceholder && !$0.matchedURL
        },
        .init(
            label: "Google Sheets in Safari",
            context: Build.context(
                bundle: "com.apple.Safari", engine: .webkitBrowser, url: "https://docs.google.com/spreadsheets/d/1"),
            rule: "web.googleSheets.cellEditor.webkit"
        ) {
            $0.params.inlineCompletion == .axSelection
        },
        .init(
            label: "Telegram Web selects then types",
            context: Build.context(bundle: "com.google.Chrome", engine: .chromium, url: "https://web.telegram.org/k/"),
            rule: "web.telegram.composer"
        ) {
            $0.strategy == .selectReplace
        },
        .init(
            label: "Excel cell editor", context: Build.context(bundle: "com.microsoft.Excel", role: "AXTextArea"),
            rule: "office.excel.cellEditor"
        ) {
            $0.params.inlineCompletion == .axSelection
        },
        .init(
            label: "Excel elsewhere falls back to the Office rule",
            context: Build.context(bundle: "com.microsoft.Excel", role: "AXButton"), rule: "office.microsoft.documents"
        ) {
            $0.requireTextFocus == .whenKnown && $0.strategy == .backspaceReplace
        },
        .init(
            label: "LibreOffice pacing", context: Build.context(bundle: "org.libreoffice.script"),
            rule: "office.libreoffice.pacing"
        ) {
            $0.params.interEventDelayUs == 1_000 && $0.params.postDeleteSettleUs == 2_000
        },
        .init(
            label: "Electron default never enables AX",
            context: Build.context(bundle: "com.tinyspeck.slackmacgap", engine: .electron), rule: "electron.default"
        ) {
            $0.axEnable == AXEnableMode.none && $0.requireTextFocus == .never
        },
        .init(
            label: "VS Code editor code context",
            context: Build.context(bundle: "com.microsoft.VSCode", engine: .electron, role: "AXTextArea"),
            rule: "editor.vscodeFamily"
        ) {
            $0.engineContext == .code
        },
        .init(
            label: "VS Code integrated terminal",
            context: Build.context(
                bundle: "com.microsoft.VSCode", engine: .electron, domClasses: ["xterm-helper-textarea"]),
            rule: "editor.vscode.integratedTerminal"
        ) {
            $0.params.interEventDelayUs == 1_500 && !$0.features.restoreHotkey
        },
        .init(
            label: "other Java apps through the jvm engine",
            context: Build.context(bundle: "com.example.javaapp", engine: .jvm), rule: "jvm.default"
        ) {
            $0.requireTextFocus == .never && $0.engineContext == .code && $0.params.interEventDelayUs == 1_000
                && $0.features.restoreHotkey
        },
        .init(
            label: "JetBrains IDEs: the jvm action without the restore hotkey (PLT-R353)",
            context: Build.context(bundle: "com.jetbrains.intellij", engine: .jvm), rule: "editor.jetbrains"
        ) {
            $0.requireTextFocus == .never && $0.engineContext == .code && $0.params.interEventDelayUs == 1_000
                && !$0.features.restoreHotkey
        },
        .init(
            label: "custom text views never gate", context: Build.context(bundle: "org.gnu.Emacs", role: "AXGroup"),
            rule: "editor.customTextViews"
        ) {
            $0.requireTextFocus == .never
        },
        .init(
            label: "Figma design rule beats Electron",
            context: Build.context(bundle: "com.figma.Desktop", engine: .electron), rule: "design.shortcutHeavy"
        ) {
            $0.defaultMode == .en && $0.requireTextFocus == .whenKnown
        },
        .init(
            label: "remote clients pass through", context: Build.context(bundle: "com.apple.ScreenContinuity"),
            rule: "remote.passThrough"
        ) {
            $0.strategy == .passThrough && $0.fallback.isEmpty && !$0.features.macros
        },
        .init(
            label: "games pass through",
            context: Build.context(bundle: "com.example.game", category: "public.app-category.action-games"),
            rule: "games.passThrough"
        ) {
            $0.strategy == .passThrough && $0.defaultMode == .en
        },
        .init(
            label: "word games are not passed through",
            context: Build.context(bundle: "com.example.words", category: "public.app-category.word-games"), rule: nil
        ) { _ in true },
        .init(
            label: "Spotlight overlay", context: Build.context(bundle: "com.apple.Spotlight", role: "AXTextField"),
            rule: "launcher.spotlight"
        ) {
            $0.overlay && $0.params.inlineCompletion == .axSelection && !$0.features.restoreHotkey
        },
        .init(
            label: "Raycast overlay", context: Build.context(bundle: "com.raycast.macos"),
            rule: "launcher.overlayPanels"
        ) { $0.overlay },
        .init(
            label: "TextEdit uses defaults", context: Build.context(bundle: "com.apple.TextEdit", role: "AXTextArea"),
            rule: nil
        ) {
            $0.source == .default && $0.requireTextFocus == .whenKnown
        },
    ]

    @Test(arguments: expectations)
    func seededRuleApplies(_ expectation: Expectation) throws {
        let decision = try Build.seededRuleSet().resolve(expectation.context)
        #expect(decision.rule == expectation.rule.map(ruleID))
        #expect(decision.tieLoser == nil)
        #expect(expectation.check(decision))
    }

    /// PLT-R407: no shipped key or value can request a forward delete; the strategy enum has no such case.
    @Test func noForwardDeleteAnywhereInTheRules() throws {
        let raw = try String(contentsOf: RepoFiles.rules, encoding: .utf8).lowercased()
        let actions = try Build.seededDocument().rules.map(\.action)
        let encoded = String(decoding: try JSONEncoder().encode(actions), as: UTF8.self).lowercased()
        #expect(!encoded.contains("forward"))
        #expect(!raw.contains("\"forwarddelete\""))
        #expect(InjectionStrategy.allCases.allSatisfy { !$0.rawValue.lowercased().contains("forward") })
    }

    /// PLT-R501: no bundle-ID-shaped string literal in CompatRules sources.
    @Test func compatRulesSourcesContainNoBundleIDLiterals() throws {
        let literal = try NSRegularExpression(
            pattern: "\"" + String(BundleIDShape.lintPattern.dropFirst().dropLast()) + "\"")
        for file in try Self.sourceFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            let lines = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            for line in lines.map(String.init) {
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                #expect(literal.firstMatch(in: line, range: range) == nil, "\(file.lastPathComponent): \(line)")
            }
        }
    }

    /// PLT-R504: rules never come from the network.
    @Test func compatRulesSourcesDoNotFetchRemotely() throws {
        for file in try Self.sourceFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for token in ["URLSession", "URLRequest", "NSURLConnection", "Network."] {
                #expect(!text.contains(token), "\(file.lastPathComponent) uses \(token)")
            }
        }
    }

    private static func sourceFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: RepoFiles.compatRulesSources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
    }
}
