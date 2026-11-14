// SPDX-License-Identifier: GPL-3.0-or-later
//
// The dev recorder's items at the top of the status menu (PLT-R904A, ADR 0007): the status line, "Đánh dấu lỗi vừa
// gặp" with its chord, pause or resume, and the log folder, each with a VoiceOver hint (PRD-R66). Copy comes from
// the DevRecorder catalog (ShellCore `DevRecorderMenuEntry`); Debug configuration only.

#if DEV_RECORDER
import AppKit
import InputHost
import ShellCore

@MainActor
enum DevRecorderMenu {
    /// The items, then a separator; the targets are the controller's actions.
    static func items(for controller: DevRecorderController, localizer: Localizer) -> [NSMenuItem] {
        let entries = DevRecorderMenuEntry.entries(
            isStarted: controller.recorder.isStarted, pausedUntil: controller.recorder.pausedUntil)
        return entries.map { item(for: $0, controller: controller, localizer: localizer) } + [.separator()]
    }

    private static func item(
        for entry: DevRecorderMenuEntry, controller: DevRecorderController, localizer: Localizer
    ) -> NSMenuItem {
        let title = entry.title(localizer)
        let item: NSMenuItem
        switch entry {
        case .status:
            item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.setAccessibilityLabel(title)
        case .mark:
            item = NSMenuItem(title: title, action: #selector(DevRecorderController.mark(_:)), keyEquivalent: ";")
            // Shown for the user; the tap consumes the chord in every app before any menu sees it.
            item.keyEquivalentModifierMask = [.control, .option, .command]
        case .pause:
            item = NSMenuItem(title: title, action: #selector(DevRecorderController.pause(_:)), keyEquivalent: "")
        case .resume:
            item = NSMenuItem(title: title, action: #selector(DevRecorderController.resume(_:)), keyEquivalent: "")
        case .openFolder:
            item = NSMenuItem(title: title, action: #selector(DevRecorderController.openFolder(_:)), keyEquivalent: "")
        }
        if item.action != nil { item.target = controller }
        item.setAccessibilityHelp(localizer.string(entry.accessibilityHintKey))
        return item
    }
}
#endif
