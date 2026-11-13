// SPDX-License-Identifier: GPL-3.0-or-later
//
// System calls behind `SystemSecureInputProbe` (PLT-R395, PLT-R396). Read-only: `IsSecureEventInputEnabled()`
// and one IORegistry property read. Never `EnableSecureEventInput` (PLT-R398).

import Carbon
import Foundation
import IOKit

enum SecureInputSystem {
    static func isEnabled() -> Bool { IsSecureEventInputEnabled() }

    /// `kCGSSessionSecureInputPID` of the console session in the IORegistry root's `IOConsoleUsers`.
    static func holderPID() -> Int32? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        guard
            let value = IORegistryEntryCreateCFProperty(
                root, ConsoleUsersKeys.consoleUsers as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue(),
            let sessions = value as? [[String: Any]]
        else { return nil }
        return SecureInputHolderParser.holderPID(sessions: sessions, userID: getuid())
    }
}

enum ConsoleUsersKeys {
    static let consoleUsers = "IOConsoleUsers"
    static let onConsole = "kCGSSessionOnConsoleKey"
    static let userID = "kCGSSessionUserIDKey"
    static let secureInputPID = "kCGSSessionSecureInputPID"
}

/// Pure selection of the console session entry (unit-tested with dictionaries, traceability PLT-R396 "U parser").
enum SecureInputHolderParser {
    /// Prefers the on-console session of this user, then any on-console session, then this user's session.
    static func holderPID(sessions: [[String: Any]], userID: uid_t) -> Int32? {
        let isOnConsole: ([String: Any]) -> Bool = { ($0[ConsoleUsersKeys.onConsole] as? NSNumber)?.boolValue ?? false }
        let isUser: ([String: Any]) -> Bool = {
            ($0[ConsoleUsersKeys.userID] as? NSNumber)?.uint32Value == UInt32(userID)
        }
        let session =
            sessions.first { isOnConsole($0) && isUser($0) } ?? sessions.first(where: isOnConsole)
            ?? sessions.first(where: isUser)
        guard let pid = (session?[ConsoleUsersKeys.secureInputPID] as? NSNumber)?.int32Value, pid > 0 else {
            return nil
        }
        return pid
    }
}
