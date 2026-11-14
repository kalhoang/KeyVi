// SPDX-License-Identifier: GPL-3.0-or-later
//
// Production `PermissionProbe` (PLT-R701, PLT-R702, PLT-R720, PLT-R731). Thin wrapper over the system checks. The
// three request/prompt calls show system UI: only onboarding calls them (PLT-R711), and the live Input Monitoring
// check runs only once the tap is known to need that permission (PLT-R702).

import ApplicationServices
import CoreGraphics
import Foundation
import Security

public struct SystemPermissionProbe: PermissionProbe {
    public init() {}

    public func isAccessibilityTrusted() -> Bool { AXIsProcessTrusted() }

    /// PLT-R701: posting is part of the Accessibility grant (WWDC19 session 701). `CGPreflightPostEventAccess()`
    /// keeps its launch-time answer, so after a live grant only `AXIsProcessTrusted()` says yes (ADR 0311 reads
    /// this after an echo miss: a session granted live must not count as revoked).
    public func canPostEvents() -> Bool { AXIsProcessTrusted() || CGPreflightPostEventAccess() }

    public func canListenToEvents() -> Bool { CGPreflightListenEventAccess() }

    /// A listen-only tap for key-down at the session level, released at once: it is created only when Input
    /// Monitoring is granted now, and being passive it never holds a key back, even in the instant it exists.
    public func canListenToEventsNow() -> Bool {
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: mask,
                callback: { _, _, event, _ in Unmanaged.passUnretained(event) }, userInfo: nil)
        else { return false }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        return true
    }

    /// The value of `kAXTrustedCheckOptionPrompt` (a mutable C global that Swift 6 does not allow reading).
    static let trustedCheckOptionPrompt = "AXTrustedCheckOptionPrompt"

    public func promptForAccessibility() {
        _ = AXIsProcessTrustedWithOptions([Self.trustedCheckOptionPrompt: true] as CFDictionary)
    }

    public func requestListenEventAccess() -> Bool { CGRequestListenEventAccess() }
    public func requestPostEventAccess() -> Bool { CGRequestPostEventAccess() }

    /// SHA-256 of this process's designated requirement text; nil for unsigned builds.
    public func signingIdentityDigest() -> String? {
        SigningIdentity.designatedRequirement().map(HostServicesHashing.sha256Hex)
    }
}

enum SigningIdentity {
    static func designatedRequirement() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement else {
            return nil
        }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
        return text as String
    }
}
