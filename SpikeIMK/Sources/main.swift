// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Spike S1 (PLT-R398D): does an InputMethodKit input source still receive key events in Terminal and iTerm2
// while Secure Keyboard Entry is on, and can it still commit text there? This bundle counts key-down events and
// shows the counts and the OS secure-input state in its input menu. Only when "Commit test" is ticked in that
// menu does it replace a typed ";" with "✓" through the IMK client. It never records which keys were pressed,
// never creates an event tap and never posts CGEvents (PLT-R207). Instructions for Pa: SpikeIMK/README.md.

import AppKit
import Carbon
import InputMethodKit
import Synchronization

/// Counters only: no key values are stored anywhere (PLT-R901 spirit, even for a spike).
enum SpikeCounters {
    static let keyDowns = Atomic<Int>(0)
    static let keyDownsWhileSecureInput = Atomic<Int>(0)
    static let commits = Atomic<Int>(0)
    static let commitsWhileSecureInput = Atomic<Int>(0)
    static let commitTestEnabled = Atomic<Bool>(false)

    static func reset() {
        keyDowns.store(0, ordering: .relaxed)
        keyDownsWhileSecureInput.store(0, ordering: .relaxed)
        commits.store(0, ordering: .relaxed)
        commitsWhileSecureInput.store(0, ordering: .relaxed)
    }
}

/// Builds the input menu and handles its one action, on the main actor.
@MainActor
final class SpikeMenu: NSObject {
    static let shared = SpikeMenu()

    /// English only: a spike for Pa, never shipped.
    func build() -> NSMenu {
        let menu = NSMenu()
        let secure = IsSecureEventInputEnabled() ? "on" : "off"
        for title in [
            "Key-downs received: \(SpikeCounters.keyDowns.load(ordering: .relaxed))",
            "Received while secure input on: \(SpikeCounters.keyDownsWhileSecureInput.load(ordering: .relaxed))",
            "Commits (\";\" -> \"✓\"): \(SpikeCounters.commits.load(ordering: .relaxed))",
            "Commits while secure input on: \(SpikeCounters.commitsWhileSecureInput.load(ordering: .relaxed))",
            "Secure input now: \(secure)",
        ] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let commitTest = NSMenuItem(
            title: "Commit test: replace \";\" with \"✓\"", action: #selector(toggleCommitTest(_:)), keyEquivalent: "")
        commitTest.state = SpikeCounters.commitTestEnabled.load(ordering: .relaxed) ? .on : .off
        commitTest.target = self
        menu.addItem(commitTest)
        let reset = NSMenuItem(title: "Reset counters", action: #selector(resetCounters(_:)), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        return menu
    }

    @objc func resetCounters(_ sender: Any?) { SpikeCounters.reset() }

    @objc func toggleCommitTest(_ sender: Any?) {
        let enabled = SpikeCounters.commitTestEnabled.load(ordering: .relaxed)
        SpikeCounters.commitTestEnabled.store(!enabled, ordering: .relaxed)
    }
}

/// Carries a menu built on the main actor back to InputMethodKit's (main-thread) caller.
private struct MenuBox: @unchecked Sendable {
    let menu: NSMenu
}

@objc(SpikeInputController)
final class SpikeInputController: IMKInputController {
    /// Counts the event and returns false so the key reaches the app unchanged, except for the opt-in commit test.
    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        let secure = IsSecureEventInputEnabled()
        SpikeCounters.keyDowns.wrappingAdd(1, ordering: .relaxed)
        if secure { SpikeCounters.keyDownsWhileSecureInput.wrappingAdd(1, ordering: .relaxed) }
        guard SpikeCounters.commitTestEnabled.load(ordering: .relaxed), event.characters == ";",
            let client = sender as? any IMKTextInput
        else { return false }
        client.insertText("✓", replacementRange: NSRange(location: NSNotFound, length: 0))
        SpikeCounters.commits.wrappingAdd(1, ordering: .relaxed)
        if secure { SpikeCounters.commitsWhileSecureInput.wrappingAdd(1, ordering: .relaxed) }
        return true
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue)
    }

    /// InputMethodKit calls this on the main thread.
    override func menu() -> NSMenu! {
        MainActor.assumeIsolated { MenuBox(menu: SpikeMenu.shared.build()) }.menu
    }
}

let connectionName = Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String ?? ""
let server = IMKServer(name: connectionName, bundleIdentifier: Bundle.main.bundleIdentifier)
withExtendedLifetime(server) {
    NSApplication.shared.run()
}
