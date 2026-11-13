// SPDX-License-Identifier: LicenseRef-App-Pending
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
    let clock: any MonotonicClock

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
        _ = try await NSWorkspace.shared.open([target], withApplicationAt: try applicationURL(bundle), configuration: configuration)
    }

    func seedHistory(_ url: String, in bundle: BundleKey) async throws {
        try await open(url, in: bundle)
        clock.sleep(until: MonotonicInstant(nanoseconds: clock.now().nanoseconds &+ Self.historySettleNanoseconds))
    }

    func focusField(identifier: String, in bundle: BundleKey) async throws {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundle.rawValue).first?.activate()
        try AX.set(try AX.element(identifier, in: bundle), kAXFocusedAttribute, kCFBooleanTrue)
    }

    func selectInputSource(_ source: InputSourceID) async throws {
        let filter = [kTISPropertyInputSourceID as String: source.rawValue] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
            let input = list.first, TISSelectInputSource(input) == noErr
        else { throw LiveError.inputSourceNotFound(source.rawValue) }
    }

    /// TestHost: presses its "Hold secure input" checkbox when its state differs. Other apps (iTerm2's and
    /// Terminal's "Secure Keyboard Entry", PLT-R398C) are left to W2-E2 and reported as unsupported.
    func setSecureInput(_ enabled: Bool, in bundle: BundleKey) async throws {
        guard bundle == targets.testHostBundleID else { throw LiveError.unsupported("secure input toggle in " + bundle.rawValue) }
        let toggle = try AX.element(TestHostControls.secureInputToggle, in: bundle)
        let isOn = (AX.attribute(toggle, kAXValueAttribute) as? NSNumber)?.boolValue ?? false
        guard isOn != enabled else { return }
        let result = AXUIElementPerformAction(toggle, kAXPressAction as CFString)
        guard result == .success else { throw LiveError.axFailure("press", result.rawValue) }
    }

    /// Opens a `.command` wrapper (`zsh -f <script> <capture>`) with the terminal app. VERIFY on the runner that
    /// iTerm2 and Ghostty run `.command` files like Terminal does.
    func startTerminalCapture(in bundle: BundleKey, script: URL, captureFile: URL) async throws {
        let wrapper = script.deletingPathExtension().appendingPathExtension("command")
        let body = "#!/bin/sh\nexec /bin/zsh -f '" + script.path + "' '" + captureFile.path + "'\n"
        try LocalFileSystem().writeAtomically(Data(body.utf8), to: wrapper, permissions: FilePermissions(rawValue: 0o700))
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open([wrapper], withApplicationAt: try applicationURL(bundle), configuration: configuration)
    }
}
