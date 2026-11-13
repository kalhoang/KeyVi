// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R353, 03-product.md D8 (decision of the product owner, 13/11/2026, Q14): Escape restores the last word by
// default, and compatibility rules switch the binding off (`features.restoreHotkey: false`) in terminals, IDEs and
// code editors, remote desktop clients and games, where Escape has its own meaning. Never per-app code
// (PLT-R501): the bundle IDs below are test fixtures checked against compat/rules.json, whose rule notes record
// the public source of each ID (Homebrew cask metadata, Apple documentation).

import AppModel
import Foundation
import Testing

@testable import CompatRules

@Suite struct RestoreHotkeyExclusionTests {
    struct App: Sendable, CustomTestStringConvertible {
        let bundle: String
        let engine: EngineFingerprint
        let rule: String
        var testDescription: String { bundle }

        init(_ bundle: String, _ engine: EngineFingerprint = .native, rule: String) {
            self.bundle = bundle
            self.engine = engine
            self.rule = rule
        }
    }

    static let terminals: [App] = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "com.github.wez.wezterm",
        "org.alacritty", "net.kovidgoyal.kitty", "dev.warp.Warp-Stable",
    ].map { App($0, rule: "terminal.default") }

    static let vscodeFamily: [App] = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium", "com.todesktop.230313mzl4w4u92",
        "dev.kiro.desktop", "com.trae.app", "com.voideditor.Void",
    ].map { App($0, .electron, rule: "editor.vscodeFamily") }

    static let jetBrains: [App] = [
        "com.jetbrains.intellij", "com.jetbrains.intellij.ce", "com.jetbrains.pycharm", "com.jetbrains.pycharm.ce",
        "com.jetbrains.WebStorm", "com.jetbrains.goland", "com.jetbrains.CLion", "com.jetbrains.rider",
        "com.jetbrains.PhpStorm", "com.jetbrains.rubymine", "com.jetbrains.datagrip", "com.jetbrains.rustrover",
        "com.jetbrains.dataspell", "com.google.android.studio",
    ].map { App($0, .jvm, rule: "editor.jetbrains") }

    static let editors: [App] =
        ["com.sublimetext.4", "org.gnu.Emacs", "org.vim.MacVim", "dev.zed.Zed"].map {
            App($0, rule: "editor.customTextViews")
        }
        + ["com.apple.dt.Xcode", "com.panic.Nova", "com.barebones.bbedit"].map {
            App($0, rule: "editor.nativeCodeEditors")
        }

    static let remoteClients: [App] = [
        "com.microsoft.rdc.macos", "com.p5sys.jump.mac.viewer.web", "com.realvnc.vncviewer",
        "com.realvnc.rvncconnect", "tv.parsec.www", "com.teamviewer.TeamViewer", "com.philandro.anydesk",
        "com.apple.ScreenSharing",
    ].map { App($0, rule: "remote.passThrough") }

    static let excluded = terminals + vscodeFamily + jetBrains + editors + remoteClients

    @Test(arguments: excluded)
    func restoreHotkeyIsOffWhereEscapeHasItsOwnMeaning_PLTR353(_ app: App) throws {
        let decision = try Build.seededRuleSet().resolve(Build.context(bundle: app.bundle, engine: app.engine))
        #expect(decision.rule == ruleID(app.rule))
        #expect(decision.features.restoreHotkey == false)
        #expect(decision.tieLoser == nil)
    }

    /// Code editors and IDEs get the engine's code context (ENG-R850); remote clients pass keys through.
    @Test(arguments: terminals + vscodeFamily + jetBrains + editors)
    func editorsAndTerminalsUseTheCodeContext_ENGR850(_ app: App) throws {
        let decision = try Build.seededRuleSet().resolve(Build.context(bundle: app.bundle, engine: app.engine))
        #expect(decision.engineContext == .code)
        #expect(decision.strategy == .backspaceReplace)
    }

    /// The JetBrains rule keeps the JVM pacing and gating of `jvm.default`: no merging across rules (PLT-R520),
    /// so the bundle rule repeats the engine rule's action.
    @Test func jetBrainsRuleKeepsTheJVMAction() throws {
        let rules = try Build.seededRuleSet()
        let ide = rules.resolve(Build.context(bundle: "com.jetbrains.goland", engine: .jvm))
        let otherJava = rules.resolve(Build.context(bundle: "com.example.javaapp", engine: .jvm))
        #expect(otherJava.rule == ruleID("jvm.default"))
        #expect(otherJava.features.restoreHotkey)
        #expect(ide.params == otherJava.params && ide.requireTextFocus == otherJava.requireTextFocus)
        #expect(ide.engineContext == otherJava.engineContext && ide.fallback == otherJava.fallback)
    }

    /// Games: the category rule switches the binding off, also for a game built on an engine with its own rule.
    @Test(arguments: [EngineFingerprint.native, .jvm, .electron])
    func gamesSwitchTheBindingOff(_ engine: EngineFingerprint) throws {
        let context = Build.context(bundle: "com.example.game", engine: engine, category: "public.app-category.games")
        let decision = try Build.seededRuleSet().resolve(context)
        #expect(decision.rule == ruleID("games.passThrough"))
        #expect(!decision.features.restoreHotkey)
    }

    /// Ordinary text fields keep the default binding (D8: Escape restores the last word there).
    @Test(arguments: [
        ("com.apple.TextEdit", EngineFingerprint.native),
        ("com.apple.Notes", .native),
        ("com.apple.Safari", .webkitBrowser),
        ("com.google.Chrome", .chromium),
        ("com.tinyspeck.slackmacgap", .electron),
        ("com.microsoft.Word", .native),
        ("com.example.javaapp", .jvm),
    ])
    func ordinaryAppsKeepTheBinding(bundle: String, engine: EngineFingerprint) throws {
        let decision = try Build.seededRuleSet().resolve(Build.context(bundle: bundle, engine: engine))
        #expect(decision.features.restoreHotkey)
    }

    /// The VS Code family shares one bundle list between the editor and its integrated terminal, so a fork added
    /// for one rule cannot be missing from the other.
    @Test func vscodeFamilyListIsShared() throws {
        let document = try Build.seededDocument()
        let rules = Dictionary(document.rules.map { ($0.id.rawValue, $0) }) { first, _ in first }
        let editor = try #require(rules["editor.vscodeFamily"])
        let terminal = try #require(rules["editor.vscode.integratedTerminal"])
        #expect(editor.match.bundleGroup == "vscodeFamily" && terminal.match.bundleGroup == "vscodeFamily")
        let members = Set(document.bundleGroups["vscodeFamily"]?.map(\.rawValue) ?? [])
        #expect(members == Set(Self.vscodeFamily.map(\.bundle)))
        let integrated = try Build.seededRuleSet().resolve(
            Build.context(bundle: "com.vscodium", engine: .electron, domClasses: ["xterm-helper-textarea"]))
        #expect(integrated.rule == ruleID("editor.vscode.integratedTerminal"))
    }

    /// Every bundle ID a restore exclusion lists records where it came from in the rule's notes (the task's
    /// public-source requirement; CLR-R5 for data provenance).
    @Test func exclusionRulesNameTheirPublicSources() throws {
        let ids = [
            "terminal.default", "editor.vscodeFamily", "editor.jetbrains", "editor.customTextViews",
            "editor.nativeCodeEditors", "remote.passThrough",
        ]
        let document = try Build.seededDocument()
        for id in ids {
            let rule = try #require(document.rules.first { $0.id.rawValue == id }, "\(id)")
            guard case .shipped(let provenance) = rule.provenance else {
                Issue.record("\(id): no shipped provenance")
                continue
            }
            let notes = provenance.notes ?? ""
            #expect(notes.contains("Homebrew cask") || notes.contains("Apple"), "\(id): no source in notes")
            #expect(rule.action.features?.restoreHotkey == false, "\(id)")
        }
    }
}
