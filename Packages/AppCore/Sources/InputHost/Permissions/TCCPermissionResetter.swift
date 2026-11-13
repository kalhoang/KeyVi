// SPDX-License-Identifier: LicenseRef-App-Pending
//
// "Đặt lại quyền" (PLT-R740, PLT-R741): `/usr/bin/tccutil reset Accessibility <own bundle ID>`, user-initiated
// only. The command is built only for the app's own bundle identifier, never without one, never with sudo.

public import Foundation

public enum PermissionResetError: Error, Sendable, Hashable {
    /// Empty or not a reverse-DNS bundle identifier: refusing protects every other app's grant (PLT-R741).
    case invalidBundleIdentifier
    case notOwnBundleIdentifier
    case commandFailed(status: Int32)
}

/// An external command (executable plus arguments, no shell).
public struct CommandInvocation: Sendable, Hashable {
    public var executable: URL
    public var arguments: [String]
    public init(executable: URL, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

public protocol CommandRunning: Sendable {
    /// Runs the command to completion and returns its exit status.
    func run(_ invocation: CommandInvocation) throws -> Int32
}

/// `Process` without a shell, so arguments are never interpreted.
public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(_ invocation: CommandInvocation) throws -> Int32 {
        let process = Process()
        process.executableURL = invocation.executable
        process.arguments = invocation.arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

public struct TCCPermissionResetter: PermissionResetting {
    public static let tccutil = URL(fileURLWithPath: "/usr/bin/tccutil")
    /// TCC service name of the Accessibility pane (PLT-R740 VERIFY on macOS 27 after the pane rename).
    public static let accessibilityService = "Accessibility"

    private let ownBundleIdentifier: String
    private let runner: any CommandRunning

    /// `ownBundleIdentifier` comes from the running bundle (`Bundle.main`), never from user input.
    public init(ownBundleIdentifier: String, runner: any CommandRunning = ProcessCommandRunner()) {
        self.ownBundleIdentifier = ownBundleIdentifier
        self.runner = runner
    }

    /// The exact command for `bundleIdentifier`; throws instead of ever building the unscoped form.
    public static func resetCommand(bundleIdentifier: String) throws(PermissionResetError) -> CommandInvocation {
        guard isScopedBundleIdentifier(bundleIdentifier) else { throw .invalidBundleIdentifier }
        return CommandInvocation(executable: tccutil, arguments: ["reset", accessibilityService, bundleIdentifier])
    }

    public func resetAccessibility(bundleIdentifier: String) throws {
        let command = try Self.resetCommand(bundleIdentifier: bundleIdentifier)
        guard bundleIdentifier == ownBundleIdentifier else { throw PermissionResetError.notOwnBundleIdentifier }
        let status = try runner.run(command)
        guard status == 0 else { throw PermissionResetError.commandFailed(status: status) }
    }

    /// Reverse-DNS: at least two non-empty dot-separated segments of letters, digits, `-` and `_`.
    static func isScopedBundleIdentifier(_ identifier: String) -> Bool {
        guard (3...255).contains(identifier.utf8.count) else { return false }
        let segments = identifier.split(separator: ".", omittingEmptySubsequences: false)
        return segments.count >= 2
            && segments.allSatisfy { segment in
                !segment.isEmpty
                    && segment.unicodeScalars.allSatisfy { scalar in
                        scalar.isASCII
                            && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_")
                    }
            }
    }
}
