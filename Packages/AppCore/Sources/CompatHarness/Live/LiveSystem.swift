// SPDX-License-Identifier: GPL-3.0-or-later
//
// Setup actions on the self-hosted runner (PLT-R530): launch apps, open pages, focus fields through AX,
// select input sources (Text Input Sources), toggle TestHost's secure-input holder, start the terminal
// capture shell. They change the machine's state, so they never run on a developer Mac. Runner only.

import AppKit
import AppModel
import ApplicationServices
import Carbon
import Foundation
import RealtimeSupport
import TestSupport

struct LiveSystemActions: SystemActions {
    /// Time a seeded history page gets to load before the next step.
    static let historySettleNanoseconds: UInt64 = 2_000_000_000

    let targets: HarnessTargets
    let sleeper: any HarnessSleeper

    private func applicationURL(_ bundle: BundleKey) throws -> URL {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle.rawValue) else {
            throw LiveError.appNotFound(bundle.rawValue)
        }
        return url
    }

    func launch(_ bundle: BundleKey) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: try applicationURL(bundle), configuration: configuration)
    }

    func open(_ url: String, in bundle: BundleKey) async throws {
        guard let target = URL(string: url) else { throw LiveError.unsupported("URL " + url) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open(
            [target], withApplicationAt: try applicationURL(bundle), configuration: configuration)
    }

    func seedHistory(_ url: String, in bundle: BundleKey) async throws {
        try await open(url, in: bundle)
        try await sleeper.sleep(nanoseconds: Self.historySettleNanoseconds)
    }

    func focusField(identifier: String, in bundle: BundleKey) async throws {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundle.rawValue).first?.activate()
        let element = try await AX.element(identifier, in: bundle, sleeper: sleeper)
        AX.raiseWindow(of: element)
        try AX.set(element, kAXFocusedAttribute, kCFBooleanTrue)
    }

    func selectInputSource(_ source: InputSourceID) async throws {
        let filter = [kTISPropertyInputSourceID as String: source.rawValue] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
            let input = list.first, TISSelectInputSource(input) == noErr
        else { throw LiveError.inputSourceNotFound(source.rawValue) }
    }

    /// TestHost: presses its "Hold secure input" checkbox when its state differs. Apps with a "Secure Keyboard
    /// Entry" item in their app menu (`targets.secureKeyboardEntryApps`: Terminal, iTerm2, PLT-R398C): presses that
    /// item when its check mark differs. Any other app reports `needsHuman` with the reason instead of failing.
    func setSecureInput(_ enabled: Bool, in bundle: BundleKey) async throws {
        if targets.secureKeyboardEntryApps.contains(bundle) {
            return try SecureKeyboardEntryMenu.set(enabled, in: bundle)
        }
        guard bundle == targets.testHostBundleID else {
            throw HumanReadbackRequired(
                reason: "switch secure keyboard entry " + (enabled ? "on" : "off") + " in " + bundle.rawValue
                    + " by hand")
        }
        let toggle = try await AX.element(TestHostControls.secureInputToggle, in: bundle, sleeper: sleeper)
        let isOn = (AX.attribute(toggle, kAXValueAttribute) as? NSNumber)?.boolValue ?? false
        guard isOn != enabled else { return }
        let result = AXUIElementPerformAction(toggle, kAXPressAction as CFString)
        guard result == .success else { throw LiveError.axFailure("press", result.rawValue) }
    }

    /// Presses TestHost's "Reset fields" button through AX when TestHost runs (a fresh launch has empty fields).
    func resetTestHostFields(in bundle: BundleKey) async throws {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundle.rawValue).first != nil else {
            return
        }
        let button = try await AX.element(TestHostControls.resetFields, in: bundle, sleeper: sleeper)
        let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
        guard result == .success else { throw LiveError.axFailure("press", result.rawValue) }
    }

    /// Opens a `.command` wrapper (`zsh -f <script> <capture>`) with the terminal app. VERIFY on the runner that
    /// iTerm2 and Ghostty run `.command` files like Terminal does.
    func startTerminalCapture(in bundle: BundleKey, script: URL, captureFile: URL) async throws {
        let wrapper = script.deletingPathExtension().appendingPathExtension("command")
        let body = "#!/bin/sh\nexec /bin/zsh -f '" + script.path + "' '" + captureFile.path + "'\n"
        try LocalFileSystem().writeAtomically(
            Data(body.utf8), to: wrapper, permissions: FilePermissions(rawValue: 0o700))
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open(
            [wrapper], withApplicationAt: try applicationURL(bundle), configuration: configuration)
    }
}

/// The "Secure Keyboard Entry" item of an app menu (Terminal, iTerm2), reached through AX: the app menu is the
/// menu-bar item after the Apple menu. Item titles are those of an English system (the runner's language, VERIFY);
/// the check mark is `AXMenuItemMarkChar`.
enum SecureKeyboardEntryMenu {
    static let itemTitle = "Secure Keyboard Entry"

    static func set(_ enabled: Bool, in bundle: BundleKey) throws {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundle.rawValue).first?.activate()
        let app = try AX.application(bundle)
        guard let bar = AX.attribute(app, kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() else {
            throw LiveError.elementNotFound("menu bar")
        }
        let menus = AX.attribute(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] ?? []  // type checked
        guard menus.count > 1, let item = find(itemTitle, below: menus[1]) else {
            throw LiveError.elementNotFound(itemTitle)
        }
        let checked = !((AX.attribute(item, kAXMenuItemMarkCharAttribute) as? String) ?? "").isEmpty
        guard checked != enabled else { return }
        let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
        guard result == .success else { throw LiveError.axFailure("press " + itemTitle, result.rawValue) }
    }

    private static func find(_ title: String, below element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        if AX.attribute(element, kAXTitleAttribute) as? String == title { return element }
        guard depth < 3, let children = AX.attribute(element, kAXChildrenAttribute) as? [AXUIElement] else {
            return nil
        }
        return children.lazy.compactMap { find(title, below: $0, depth: depth + 1) }.first
    }
}
