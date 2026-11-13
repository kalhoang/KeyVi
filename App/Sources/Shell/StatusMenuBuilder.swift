// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Maps ShellCore's `MenuEntry` list (PRD-R11) to `NSMenuItem`s. Copy comes from the Menu and Status tables in
// the selected language (ADR 0310); every item carries a VoiceOver hint (PRD-R66).

import AppKit
import AppModel
import ShellCore

/// Payloads for `representedObject` (Objective-C objects).
final class RuleChoice: NSObject {
    let rule: PerAppRule
    let bundle: BundleKey
    init(rule: PerAppRule, bundle: BundleKey) {
        self.rule = rule
        self.bundle = bundle
    }
}

final class BundleChoice: NSObject {
    let bundle: BundleKey
    init(bundle: BundleKey) { self.bundle = bundle }
}

final class StatusActionBox: NSObject {
    let action: StatusLine.Action
    init(action: StatusLine.Action) { self.action = action }
}

@MainActor
struct StatusMenuBuilder {
    let localizer: Localizer
    let target: StatusItemController

    /// Right tab stop for the hotkey shown next to the VI/EN items (PRD-R11 item 2).
    private static let hotkeyTabLocation: CGFloat = 220

    func item(for entry: MenuEntry, model: MenuModel) -> NSMenuItem {
        let item: NSMenuItem
        switch entry {
        case .separator: return .separator()
        case .status(let line): item = statusItem(line)
        case .statusAction(let line): item = statusActionItem(line)
        case .mode(let mode, let isSelected, let hotkey): item = modeItem(mode, isSelected: isSelected, hotkey: hotkey)
        case .method(let method, let isSelected):
            item = action(entry, #selector(StatusItemController.selectMethod(_:)), state: isSelected)
            item.representedObject = method.rawValue
        case .perApp(let app): item = perAppItem(app)
        case .macros: item = action(entry, #selector(StatusItemController.openMacros(_:)))
        case .settings: item = action(entry, #selector(StatusItemController.openSettings(_:)))
        case .reportProblem: item = action(entry, #selector(StatusItemController.reportProblem(_:)))
        case .checkForUpdates(let enabled):
            item = action(entry, #selector(StatusItemController.checkForUpdates(_:)))
            item.isEnabled = enabled
        case .donate:
            item = action(entry, #selector(StatusItemController.openSupport(_:)), argument: model.appName)
        case .quit:
            item = NSMenuItem(
                title: localizer.format(MenuText.quit, model.appName),
                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
            item.target = NSApp
        }
        if let key = entry.commandKeyEquivalent {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = .command
        }
        if let hint = entry.accessibilityHintKey {
            let text = entry == .quit ? localizer.format(hint, model.appName) : localizer.string(hint)
            item.setAccessibilityHelp(text)
        }
        return item
    }

    // MARK: - Entries

    /// PRD-R11 item 1: the sentence (one line per sentence) and, in smaller type, the hint (PLT-R397, PLT-R206).
    private func statusItem(_ line: StatusLine) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let message = line.message(localizer)
        let text = NSMutableAttributedString(
            string: StatusLine.sentences(message).joined(separator: "\n"),
            attributes: [.font: NSFont.menuFont(ofSize: 0)])
        if let hint = line.hint(localizer) {
            text.append(
                NSAttributedString(
                    string: "\n" + StatusLine.sentences(hint).joined(separator: "\n"),
                    attributes: [
                        .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ]))
        }
        item.attributedTitle = text
        item.title = message
        item.setAccessibilityLabel([message, line.hint(localizer)].compactMap { $0 }.joined(separator: " "))
        if line.action != .none { attach(line.action, to: item) }
        return item
    }

    private func statusActionItem(_ line: StatusLine) -> NSMenuItem {
        let item = NSMenuItem(title: line.actionLabel(localizer) ?? "", action: nil, keyEquivalent: "")
        item.indentationLevel = 1
        attach(line.action, to: item)
        return item
    }

    private func attach(_ action: StatusLine.Action, to item: NSMenuItem) {
        item.action = #selector(StatusItemController.performStatusAction(_:))
        item.target = target
        item.representedObject = StatusActionBox(action: action)
    }

    private func modeItem(_ mode: TypingMode, isSelected: Bool, hotkey: String) -> NSMenuItem {
        let entry = MenuEntry.mode(mode, isSelected: isSelected, hotkey: hotkey)
        let item = action(entry, #selector(StatusItemController.selectMode(_:)), state: isSelected)
        item.representedObject = mode.rawValue
        guard !hotkey.isEmpty else { return item }
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: Self.hotkeyTabLocation)]
        let title = NSMutableAttributedString(
            string: item.title, attributes: [.font: NSFont.menuFont(ofSize: 0), .paragraphStyle: style])
        title.append(
            NSAttributedString(
                string: "\t" + hotkey,
                attributes: [
                    .font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: style,
                ]))
        item.attributedTitle = title
        return item
    }

    /// PRD-R11 item 4: "Với <App>" with the four rules, then "Báo lỗi với ứng dụng này...".
    private func perAppItem(_ app: MenuModel.FrontmostAppMenu) -> NSMenuItem {
        let item = NSMenuItem(title: localizer.format(MenuText.perAppTitle, app.displayName), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for rule in PerAppRule.allCases {
            let ruleItem = NSMenuItem(
                title: localizer.string(rule.menuTitleKey), action: #selector(StatusItemController.selectRule(_:)),
                keyEquivalent: "")
            ruleItem.target = target
            ruleItem.state = rule == app.rule ? .on : .off
            ruleItem.representedObject = RuleChoice(rule: rule, bundle: app.bundle)
            ruleItem.setAccessibilityHelp(localizer.string(MenuText.ruleHint))
            submenu.addItem(ruleItem)
        }
        submenu.addItem(.separator())
        let report = NSMenuItem(
            title: localizer.string(MenuText.perAppReport), action: #selector(StatusItemController.reportForApp(_:)),
            keyEquivalent: "")
        report.target = target
        report.representedObject = BundleChoice(bundle: app.bundle)
        report.setAccessibilityHelp(localizer.string(MenuText.perAppReportHint))
        submenu.addItem(report)
        item.submenu = submenu
        return item
    }

    private func action(_ entry: MenuEntry, _ selector: Selector, state: Bool = false, argument: String? = nil)
        -> NSMenuItem
    {
        let title = entry.titleKey.map { key in argument.map { localizer.format(key, $0) } ?? localizer.string(key) }
        let item = NSMenuItem(title: title ?? "", action: selector, keyEquivalent: "")
        item.target = target
        item.state = state ? .on : .off
        return item
    }
}
