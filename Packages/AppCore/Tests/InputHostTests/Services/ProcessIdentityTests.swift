// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PLT-R393: bundle-less processes are keyed by the SHA-256 of their executable path; identity fields.

import AppModel
import Darwin
import Foundation
import Testing

@testable import InputHost

@Suite("Process identity (PLT-R393)")
struct ProcessIdentityTests {
    @Test func bundleIdentifierAndInfoKeys() throws {
        let info = ProcessIdentityFactory.BundleInfo([
            "CFBundleShortVersionString": "27.1", "CFBundleVersion": "4711", "LSApplicationCategoryType": "dev",
        ])
        let identity = try #require(
            ProcessIdentityFactory.make(
                pid: 42, bundleIdentifier: "com.example.Editor", bundleURL: URL(fileURLWithPath: "/Applications/E.app"),
                info: info, executablePath: "/Applications/E.app/Contents/MacOS/E", processName: "E",
                localizedName: "Editor"))
        #expect(identity.bundle == bundle("com.example.Editor"))
        #expect(identity.shortVersion == "27.1")
        #expect(identity.buildVersion == "4711")
        #expect(identity.appCategory == "dev")
        #expect(identity.localizedName == "Editor")
    }

    @Test func noBundleIdentifierUsesTheExecutablePathHash() throws {
        let path = "/usr/local/bin/tool"
        let identity = try #require(
            ProcessIdentityFactory.make(
                pid: 7, bundleIdentifier: nil, bundleURL: nil, info: .init(), executablePath: path, processName: "",
                localizedName: nil))
        #expect(identity.bundle == BundleKey.executable(sha256Hex: HostServicesHashing.sha256Hex(path)))
        #expect(identity.processName == "tool")
        // An identifier that is not a valid key also falls back to the path.
        let odd = ProcessIdentityFactory.make(
            pid: 7, bundleIdentifier: "not valid!", bundleURL: nil, info: .init(), executablePath: path,
            processName: "tool", localizedName: nil)
        #expect(odd?.bundle.isExecutableHash == true)
    }

    @Test func nothingKnownGivesNoIdentity() {
        #expect(
            ProcessIdentityFactory.make(
                pid: 7, bundleIdentifier: nil, bundleURL: nil, info: .init(), executablePath: nil, processName: "x",
                localizedName: nil) == nil)
    }

    @Test func hashes() {
        #expect(
            HostServicesHashing.sha256Hex("abc")
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let hash = HostServicesHashing.stableHash52("identity")
        #expect(hash == HostServicesHashing.stableHash52("identity"))
        #expect(hash != HostServicesHashing.stableHash52("identity2"))
        #expect(hash > 0 && hash < (1 << 52))
        #expect(Int(Double(hash)) == hash)  // survives a store that keeps integers as doubles
    }

    @Test func systemProviderReadsThisProcess() throws {
        let provider = SystemProcessIdentityProvider()
        let pid = getpid()
        #expect(provider.isAlive(pid))
        #expect(!provider.isAlive(0))
        #expect(!provider.isAlive(-1))
        #expect(!provider.isAlive(Int32.max))
        let identity = try #require(provider.identity(of: pid))
        #expect(identity.pid == pid)
        #expect(!identity.processName.isEmpty)
        #expect(provider.identity(of: Int32.max) == nil)
        #expect(SystemProcessIdentityProvider.executablePath(of: pid) != nil)
    }
}
