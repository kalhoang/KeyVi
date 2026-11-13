// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PLT-R740, PLT-R741: "Đặt lại quyền" builds tccutil only with the app's own bundle ID. Never executed here.

import Foundation
import Testing

@testable import InputHost
@testable import TestSupport

private let ownID = "vn.example.input"

@Suite("TCC permission reset (PLT-R740, PLT-R741)")
struct PermissionResetTests {
    @Test func commandIsScopedToTheOwnBundleIdentifier() throws {
        let runner = RecordingCommandRunner()
        try TCCPermissionResetter(ownBundleIdentifier: ownID, runner: runner).resetAccessibility(
            bundleIdentifier: ownID)
        #expect(
            runner.recorded == [
                CommandInvocation(
                    executable: URL(fileURLWithPath: "/usr/bin/tccutil"), arguments: ["reset", "Accessibility", ownID])
            ])
    }

    @Test(arguments: ["", "Accessibility", "*", "com.", ".com", "vn..x", "a b.c", "vn.example.input;rm", "sudo"])
    func unscopedIdentifiersAreRefused(identifier: String) {
        #expect(throws: PermissionResetError.invalidBundleIdentifier) {
            try TCCPermissionResetter.resetCommand(bundleIdentifier: identifier)
        }
        let runner = RecordingCommandRunner()
        #expect(throws: PermissionResetError.invalidBundleIdentifier) {
            try TCCPermissionResetter(ownBundleIdentifier: identifier, runner: runner)
                .resetAccessibility(bundleIdentifier: identifier)
        }
        #expect(runner.recorded.isEmpty)
    }

    @Test func anotherAppsIdentifierIsRefused() {
        let runner = RecordingCommandRunner()
        #expect(throws: PermissionResetError.notOwnBundleIdentifier) {
            try TCCPermissionResetter(ownBundleIdentifier: ownID, runner: runner)
                .resetAccessibility(bundleIdentifier: "com.example.other")
        }
        #expect(runner.recorded.isEmpty)
    }

    @Test func failureStatusIsReported() {
        let runner = RecordingCommandRunner(exitStatus: 1)
        #expect(throws: PermissionResetError.commandFailed(status: 1)) {
            try TCCPermissionResetter(ownBundleIdentifier: ownID, runner: runner).resetAccessibility(
                bundleIdentifier: ownID)
        }
    }

    @Test func processRunnerRunsWithoutAShell() throws {
        let runner = ProcessCommandRunner()
        #expect(
            try runner.run(CommandInvocation(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])) == 0)
        #expect(
            try runner.run(CommandInvocation(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: ["x"])) == 1
        )
    }

    @Test func systemProbeDigestReadsOnlyThisProcessSignature() {
        // SecCodeCopySelf on the test runner: read-only; nil for an unsigned runner.
        let digest = SystemPermissionProbe().signingIdentityDigest()
        #expect(digest == nil || digest!.count == 64)
        #expect(SystemPermissionProbe.trustedCheckOptionPrompt == "AXTrustedCheckOptionPrompt")
    }
}
