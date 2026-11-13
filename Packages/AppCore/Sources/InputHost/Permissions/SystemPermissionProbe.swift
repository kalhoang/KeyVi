// SPDX-License-Identifier: GPL-3.0-or-later
//
// Production `PermissionProbe` (PLT-R701, PLT-R702, PLT-R720). Thin wrapper over the system checks. The three
// request/prompt calls show system UI: only onboarding calls them, after the user asked (PLT-R711).

import ApplicationServices
import CoreGraphics
import Foundation
import Security

public struct SystemPermissionProbe: PermissionProbe {
    public init() {}

    public func isAccessibilityTrusted() -> Bool { AXIsProcessTrusted() }
    public func canPostEvents() -> Bool { CGPreflightPostEventAccess() }
    public func canListenToEvents() -> Bool { CGPreflightListenEventAccess() }

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
