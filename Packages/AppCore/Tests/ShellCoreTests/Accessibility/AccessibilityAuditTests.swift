// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Accessibility audit (W2-F, PRD-R10, PRD-R12, PRD-R63, PRD-R66, PRD-R67, PLT-R211). Two kinds of checks:
// - model level: the status item's VoiceOver label is truthful for every host state, every menu entry has a hint,
//   the switch HUD announces "Tiếng Việt" / "Tiếng Anh";
// - source level, over every UI folder of the App target: each SwiftUI control carries a label and a hint, each
//   AppKit alert button a hint, each animation sits next to a Reduce Motion check, no hue is hard-coded (state is
//   never colour alone), plain-style buttons draw their own focus ring, and every titled window follows a
//   language change. The source checks are heuristics on purpose; docs/runbooks/accessibility-audit.md lists what
//   Pa verifies with VoiceOver, Increase Contrast and Reduce Motion.

import AppModel
import Foundation
import Testing

@testable import ShellCore

@Suite struct StatusAccessibilityTests {
    let bundle: TemporaryAppBundle
    let vi: Localizer
    let en: Localizer

    init() throws {
        bundle = try TemporaryAppBundle(catalogs: [.menu, .status])
        vi = Localizer(language: .vietnamese, appBundle: bundle.bundle)
        en = Localizer(language: .english, appBundle: bundle.bundle)
    }

    func label(_ state: HostState, mode: TypingMode = .vietnamese, ignored: Bool = false, capturing: Bool = false)
        -> String
    {
        let icon = StatusPresentation.iconState(state: state, mode: mode, ignored: ignored, capturing: capturing)
        return StatusPresentation.accessibilityLabelKey(icon: icon, state: state)
    }

    @Test func everyHostStateHasAStatusItemLabelInBothLanguages() {
        // PRD-R10, PRD-R66: the menu bar icon announces its state in every combination.
        for state in AllHostStates.all {
            for mode in TypingMode.allCases {
                for ignored in [false, true] {
                    for capturing in [false, true] {
                        let key = label(state, mode: mode, ignored: ignored, capturing: capturing)
                        #expect(vi.contains(key, table: .menu), "\(state) \(mode): \(key)")
                        #expect(en.string(key, table: .menu) != key, "\(state): \(key) has no English")
                    }
                }
            }
        }
    }

    @Test func everyPauseReasonIsSaidInPlainWords() {
        // PLT-R211: the icon and the menu say why typing is paused. A reason without a status line must have its
        // own label; reasons that share the generic "another input source" label always have a status line.
        let genericPause = MenuText.iconPaused.rawValue
        for reason in AllHostStates.pauseReasons {
            let state = HostState.paused(reason)
            let key = label(state)
            let line = StatusLine.forState(
                state, holderHintKey: nil, appName: "App", frontmostApp: nil, tapRecentlyReenabled: false)
            if line == nil {
                #expect(key != genericPause || reason == .nonLatinInputSource(name: "Kotoeri"), "\(reason)")
            }
            #expect(vi.string(key, table: .menu) != vi.string(MenuText.iconStarting), "\(reason)")
        }
        let reasonOnly: [PauseReason] = [.userDisabled, .sessionInactive, .diagnosticsTest, .noTextFocus]
        let labels = reasonOnly.map { vi.string(label(.paused($0)), table: .menu) }
        #expect(Set(labels).count == reasonOnly.count, "each of these reasons has its own label")
        #expect(labels.allSatisfy { $0.hasPrefix("Tạm dừng: ") })
    }

    @Test func everyMenuEntryHasAHintThatExists() throws {
        // PRD-R66: every menu item carries a VoiceOver hint (the separator is not an item).
        let line = StatusLine.forState(
            .noPermission, holderHintKey: nil, appName: "App", frontmostApp: nil, tapRecentlyReenabled: false)
        let bundle = try #require(BundleKey(rawValue: "com.example.Editor"))
        let model = MenuModel(
            statusLine: line, mode: .vietnamese, toggleHotkeyDisplay: "⌃⇧", method: .telex,
            frontmostApp: MenuModel.FrontmostAppMenu(bundle: bundle, displayName: "Editor", rule: .remember),
            appName: "App", updateCheckEnabled: true)
        #expect(model.entries.count > 10)
        for entry in model.entries where entry != .separator {
            let hint = try #require(entry.accessibilityHintKey, "\(entry) has no hint")
            let key: String = hint.rawValue
            #expect(vi.contains(key, table: .menu), "\(key)")
        }
        for key in [MenuText.ruleHint, .perAppReportHint, .statusItemHint] {
            #expect(vi.contains(key.rawValue, table: .menu))
        }
    }

    @Test func switchHUDAnnouncesTheModeInWords() {
        // PRD-R66: "Tiếng Việt" / "Tiếng Anh", not only the drawn V or E (PRD-R12).
        #expect(vi.string(MenuText.hudVietnameseAnnouncement) == "Tiếng Việt")
        #expect(vi.string(MenuText.hudEnglishAnnouncement) == "Tiếng Anh")
        #expect(en.string(MenuText.hudVietnameseAnnouncement) == "Vietnamese")
        #expect(en.string(MenuText.hudEnglishAnnouncement) == "English")
        #expect(vi.string(MenuText.hudVietnameseGlyph) == "V" && vi.string(MenuText.hudEnglishGlyph) == "E")
    }

    @MainActor
    @Test func switchHUDIsShownOnlyForManualToggles() {
        // PRD-R12: never for automatic per-app switches; D14 off hides it.
        #expect(SwitchIndicator.shouldShow(manual: true, indicatorEnabled: true))
        #expect(!SwitchIndicator.shouldShow(manual: false, indicatorEnabled: true))
        #expect(!SwitchIndicator.shouldShow(manual: true, indicatorEnabled: false))
        #expect(SwitchIndicator.displayDuration == .milliseconds(600))
    }
}

@Suite struct AccessibilitySourceAuditTests {
    static var control: Regex<(Substring, Substring?)> {
        /\b(Button|TextField|SecureField|Toggle|Picker|Link|Menu|DisclosureGroup|TextEditor|Slider|Stepper)\(|\bButton\s*\{/
    }
    static var labelled: Regex<(Substring, Substring)> {
        /(settingsAccessibility|onboardingAccessibility|diagnosticsControl|accessibilityHint)\(/
    }

    static func indentation(_ line: String) -> Int { line.prefix { $0 == " " }.count }

    static func isComment(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).hasPrefix("//") }

    /// True when the control opened on `lines[start]` carries its own label-and-hint modifier: on the same line
    /// after the control, or on a `.modifier` line at the control's indentation or one level in, with no other
    /// control at that depth or shallower in between. The search stops where the enclosing block closes.
    static func hasOwnAccessibility(_ lines: [String], at start: Int) -> Bool {
        let opening = lines[start]
        if let range = opening.firstMatch(of: control)?.range, opening[range.upperBound...].contains(labelled) {
            return true
        }
        let base = indentation(opening)
        var shallowestControl = Int.max
        for line in lines[(start + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !isComment(line) else { continue }
            let indent = indentation(line)
            if indent < base { return false }
            if trimmed.hasPrefix("."), trimmed.contains(labelled), indent <= base + 4, indent < shallowestControl {
                return true
            }
            if line.contains(control) { shallowestControl = min(shallowestControl, indent) }
            if indent == base, !trimmed.hasPrefix("."), !trimmed.hasPrefix("}"), !trimmed.hasPrefix(")") {
                return false
            }
        }
        return false
    }

    @Test func everySwiftUIControlHasALabelAndAHint() throws {
        // PRD-R66 for every window: onboarding, the five Settings panes and their sheets (recorder, macro editor,
        // imports), Diagnostics and the bug report, HUDs and alerts built with SwiftUI.
        for (path, lines) in try CatalogInventory.uiSources() where lines.contains("import SwiftUI") {
            for (index, line) in lines.enumerated() where line.contains(Self.control) && !Self.isComment(line) {
                let labelled = Self.hasOwnAccessibility(lines, at: index)
                #expect(labelled, "\(path):\(index + 1) has no label and hint: \(line)")
            }
        }
    }

    @Test func scanCatchesAnUnlabelledControlBesideALabelledOne() {
        let lines = [
            "        Button(role: .cancel, action: cancel) {",
            "            Text(verbatim: title)",
            "        }",
            "        Button { go() } label: { Text(verbatim: title) }",
            "            .diagnosticsControl(.copyReport, localizer)",
            "        Toggle(isOn: $on) { Text(verbatim: title) }.accessibilityHint(Text(verbatim: hint))",
        ]
        #expect(!Self.hasOwnAccessibility(lines, at: 0))
        #expect(Self.hasOwnAccessibility(lines, at: 3))
        #expect(Self.hasOwnAccessibility(lines, at: 5))
    }

    @Test func everyAppKitAlertButtonHasAHint() throws {
        // PRD-R66: an NSAlert button is labelled by its title; its hint must be set within the next lines.
        let addButton = /addButton\(withTitle:/
        for (path, lines) in try CatalogInventory.uiSources() {
            for (index, line) in lines.enumerated() where line.contains(addButton) && !Self.isComment(line) {
                let window = lines[index..<min(lines.count, index + 4)].joined(separator: "\n")
                #expect(window.contains("setAccessibilityHelp("), "\(path):\(index + 1) alert button without hint")
            }
        }
    }

    @Test func everyAnimationRespectsReduceMotion() throws {
        // PRD-R67, PRD-R12: a file that animates (explicitly or through a disclosure group) checks Reduce Motion.
        let animation =
            /withAnimation\(|\.animation\(|NSAnimationContext|\.animator\(\)|\.transition\(|repeatForever|symbolEffect\(|DisclosureGroup\(/
        let guardCheck = /accessibilityReduceMotion|accessibilityDisplayShouldReduceMotion|respectsReduceMotion\(\)/
        for (path, lines) in try CatalogInventory.uiSources() {
            let code = lines.filter { !Self.isComment($0) }.joined(separator: "\n")
            guard code.contains(animation) else { continue }
            #expect(code.contains(guardCheck), "\(path) animates without a Reduce Motion check")
        }
    }

    @Test func noHueIsHardCoded() throws {
        // PRD-R67: state is shown with symbols, text and system semantic colours, never a fixed hue alone.
        let hue =
            /Color\.(red|green|orange|yellow|blue|pink|purple|mint|teal|cyan|indigo|brown)\b|\.(foregroundStyle|foregroundColor|tint|fill)\(\.(red|green|orange|yellow|blue|pink|purple)\)|NSColor\.system(Red|Green|Orange|Yellow|Blue|Pink|Purple)/
        for (path, lines) in try CatalogInventory.uiSources() {
            for (index, line) in lines.enumerated() where !Self.isComment(line) {
                #expect(line.firstMatch(of: hue) == nil, "\(path):\(index + 1) hard-codes a hue")
            }
        }
    }

    @Test func plainButtonsDrawTheirOwnFocusRing() throws {
        // PRD-R67: a `.plain` button has no bezel, so it must show keyboard focus itself.
        for (path, lines) in try CatalogInventory.uiSources() {
            for (index, line) in lines.enumerated() where line.contains(".buttonStyle(.plain)") {
                let window = lines[index..<min(lines.count, index + 4)].joined(separator: "\n")
                #expect(window.contains(".focused("), "\(path):\(index + 1) plain button without a focus ring")
            }
        }
    }

    @Test func everyTitledWindowFollowsALanguageChange() throws {
        // PRD-R63: window titles switch with the interface language; SwiftUI content re-renders by itself.
        for (path, lines) in try CatalogInventory.uiSources() {
            let code = lines.joined(separator: "\n")
            guard code.contains("NSWindow(") || (code.contains("NSPanel(") && code.contains(".titled")) else {
                continue
            }
            #expect(
                code.contains("WindowTitles.follow(") || code.contains("observeLanguage()"),
                "\(path) creates a titled window whose title does not follow the language")
        }
    }
}
