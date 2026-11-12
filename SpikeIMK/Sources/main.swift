// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Spike S1 (PLT-R398D). SKELETON: workstream W1-H completes the counters, the input menu and the README with
// run instructions for Pa. This bundle never creates an event tap and never posts CGEvents (PLT-R207).

import AppKit
import InputMethodKit

@objc(SpikeInputController)
final class SpikeInputController: IMKInputController {
    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        false  // W1-H: count events, note IsSecureEventInputEnabled(), optionally insert a test character.
    }
}

let connectionName = Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String ?? ""
let server = IMKServer(name: connectionName, bundleIdentifier: Bundle.main.bundleIdentifier)
withExtendedLifetime(server) {
    NSApplication.shared.run()
}
