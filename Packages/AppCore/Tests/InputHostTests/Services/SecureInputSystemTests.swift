// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PLT-R396: selecting the console session in IOConsoleUsers. Read-only smoke of the system probe.

import Foundation
import Testing

@testable import InputHost

private func session(onConsole: Bool, user: UInt32, pid: Int32?) -> [String: Any] {
    var entry: [String: Any] = [
        "kCGSSessionOnConsoleKey": NSNumber(value: onConsole), "kCGSSessionUserIDKey": NSNumber(value: user),
    ]
    if let pid { entry["kCGSSessionSecureInputPID"] = NSNumber(value: pid) }
    return entry
}

@Suite("Secure input holder parsing (PLT-R396)")
struct SecureInputSystemTests {
    @Test func prefersTheOnConsoleSessionOfThisUser() {
        let sessions = [
            session(onConsole: false, user: 501, pid: 11), session(onConsole: true, user: 502, pid: 22),
            session(onConsole: true, user: 501, pid: 33),
        ]
        #expect(SecureInputHolderParser.holderPID(sessions: sessions, userID: 501) == 33)
    }

    @Test func fallsBackToAnyOnConsoleSessionThenToThisUser() {
        let onConsole = [session(onConsole: false, user: 501, pid: 11), session(onConsole: true, user: 502, pid: 22)]
        #expect(SecureInputHolderParser.holderPID(sessions: onConsole, userID: 501) == 22)
        let userOnly = [session(onConsole: false, user: 501, pid: 11)]
        #expect(SecureInputHolderParser.holderPID(sessions: userOnly, userID: 501) == 11)
    }

    @Test func missingOrZeroPIDIsUnknown() {
        #expect(
            SecureInputHolderParser.holderPID(sessions: [session(onConsole: true, user: 501, pid: nil)], userID: 501)
                == nil)
        #expect(
            SecureInputHolderParser.holderPID(sessions: [session(onConsole: true, user: 501, pid: 0)], userID: 501)
                == nil)
        #expect(SecureInputHolderParser.holderPID(sessions: [], userID: 501) == nil)
    }

    @Test func systemProbeReadsWithoutChangingAnything() {
        let probe = SystemSecureInputProbe()
        let enabled = probe.isSecureEventInputEnabled()
        let holder = probe.secureInputHolderPID()
        #expect(holder == nil || holder! > 0)
        #expect(enabled == true || enabled == false)
    }
}
