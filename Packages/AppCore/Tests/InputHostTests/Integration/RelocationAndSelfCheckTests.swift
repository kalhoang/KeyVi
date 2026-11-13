// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The PLT-R710 move with fakes (nothing is ever moved or relaunched on this Mac) and the QA-R42 / PRD-R52
// first-launch-after-update check. Workstream W2-A.

import AppModel
import Foundation
import SettingsStore
import Synchronization
import TestSupport
import Testing

@testable import InputHost

/// In-memory file operations of the move.
final class FakeRelocationFiles: RelocationFileOperations {
    enum Operation: Equatable {
        case copy(URL, URL)
        case trash(URL)
        case clearQuarantine(URL)
        case createDirectory(URL)
    }

    static let translocated = URL(
        fileURLWithPath: "/private/var/folders/xy/AppTranslocation/ABCD/d/Example.app", isDirectory: true)
    static let downloads = URL(fileURLWithPath: "/Users/someone/Downloads/Example.app", isDirectory: true)
    static let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
    static let destination = applications.appendingPathComponent("Example.app", isDirectory: true)
    static let userApplications = URL(fileURLWithPath: "/Users/someone/Applications", isDirectory: true)

    private let state: Mutex<(existing: Set<URL>, operations: [Operation])>
    let failCopy: Bool
    let failTrash: Bool
    let failCreate: Bool
    let writable: Set<URL>

    /// `existing` always includes /Applications; `writable`: the directories this account may write to.
    init(
        existing: Set<URL>, writable: Set<URL> = [applications], failCopy: Bool = false, failTrash: Bool = false,
        failCreate: Bool = false
    ) {
        state = Mutex((existing.union([Self.applications]), []))
        self.writable = writable
        self.failCopy = failCopy
        self.failTrash = failTrash
        self.failCreate = failCreate
    }

    var operations: [Operation] { state.withLock { $0.operations } }

    struct Failure: Error {}

    func itemExists(at url: URL) -> Bool { state.withLock { $0.existing.contains(url) } }

    func copyItem(at source: URL, to destination: URL) throws {
        if failCopy { throw Failure() }
        state.withLock {
            $0.existing.insert(destination)
            $0.operations.append(.copy(source, destination))
        }
    }

    func moveToTrash(_ url: URL) throws {
        if failTrash { throw Failure() }
        state.withLock {
            $0.existing.remove(url)
            $0.operations.append(.trash(url))
        }
    }

    func isRemovable(_ url: URL) -> Bool { !url.path.contains("AppTranslocation") }

    func isWritableDirectory(_ url: URL) -> Bool { itemExists(at: url) && writable.contains(url) }

    func createDirectory(at url: URL) throws {
        if failCreate { throw Failure() }
        state.withLock {
            $0.existing.insert(url)
            $0.operations.append(.createDirectory(url))
        }
    }

    func clearQuarantine(at url: URL) throws { state.withLock { $0.operations.append(.clearQuarantine(url)) } }

    @MainActor
    static func relocator(_ files: FakeRelocationFiles, _ relauncher: FakeRelauncher) -> AppRelocator {
        AppRelocator(files: files, relauncher: relauncher, applicationsDirectory: applications)
    }
}

@MainActor
final class FakeRelauncher: AppRelauncher {
    var launched: [URL] = []
    var terminated = 0
    var fails = false

    struct Failure: Error {}

    func launch(_ bundleURL: URL) async throws {
        if fails { throw Failure() }
        launched.append(bundleURL)
    }

    func terminate() { terminated += 1 }
}

@Suite("Move to Applications and relaunch (PLT-R710)")
@MainActor
struct AppRelocationTests {
    @Test func translocatedCopyIsCopiedUnquarantinedAndLaunched() async {
        let files = FakeRelocationFiles(existing: [])
        let relauncher = FakeRelauncher()
        let result = await FakeRelocationFiles.relocator(files, relauncher).relocate(FakeRelocationFiles.translocated)
        #expect(result == .success(FakeRelocationFiles.destination))
        #expect(
            files.operations == [
                .copy(FakeRelocationFiles.translocated, FakeRelocationFiles.destination),
                .clearQuarantine(FakeRelocationFiles.destination),
            ], "a translocated original stays where it is")
        #expect(relauncher.launched == [FakeRelocationFiles.destination])
    }

    @Test func anOlderCopyGoesToTheTrashAndAWritableOriginalToo() async {
        let files = FakeRelocationFiles(existing: [FakeRelocationFiles.destination, FakeRelocationFiles.downloads])
        let relauncher = FakeRelauncher()
        let result = await FakeRelocationFiles.relocator(files, relauncher).relocate(FakeRelocationFiles.downloads)
        #expect(result == .success(FakeRelocationFiles.destination))
        #expect(files.operations.first == .trash(FakeRelocationFiles.destination))
        #expect(files.operations.last == .trash(FakeRelocationFiles.downloads), "never deleted, only trashed")
    }

    @Test func failuresLaunchNothing() async {
        let relauncher = FakeRelauncher()
        let copy = await FakeRelocationFiles.relocator(FakeRelocationFiles(existing: [], failCopy: true), relauncher)
            .relocate(FakeRelocationFiles.downloads)
        #expect(copy == .failure(.copyFailed))
        let replace = await FakeRelocationFiles.relocator(
            FakeRelocationFiles(existing: [FakeRelocationFiles.destination], failTrash: true), relauncher
        ).relocate(FakeRelocationFiles.downloads)
        #expect(replace == .failure(.replaceFailed))
        #expect(relauncher.launched.isEmpty)
        relauncher.fails = true
        let files = FakeRelocationFiles(existing: [FakeRelocationFiles.downloads])
        let launch = await FakeRelocationFiles.relocator(files, relauncher).relocate(FakeRelocationFiles.downloads)
        #expect(launch == .failure(.launchFailed))
        #expect(files.itemExists(at: FakeRelocationFiles.downloads), "the original stays when the copy did not start")
    }

    /// PLT-R710 accepts ~/Applications too: a standard account cannot write /Applications.
    @Test func aStandardAccountMovesIntoItsOwnApplicationsFolder_PLT_R710() async {
        let admin = FakeRelocationFiles(existing: [])
        #expect(
            AppRelocator.applicationsDirectory(
                system: FakeRelocationFiles.applications, user: FakeRelocationFiles.userApplications, files: admin)
                == FakeRelocationFiles.applications)

        let standard = FakeRelocationFiles(existing: [], writable: [])
        let directory = AppRelocator.applicationsDirectory(
            system: FakeRelocationFiles.applications, user: FakeRelocationFiles.userApplications, files: standard)
        #expect(directory == FakeRelocationFiles.userApplications)
        let relauncher = FakeRelauncher()
        let relocator = AppRelocator(files: standard, relauncher: relauncher, applicationsDirectory: directory)
        let target = FakeRelocationFiles.userApplications.appendingPathComponent("Example.app", isDirectory: true)
        let result = await relocator.relocate(FakeRelocationFiles.translocated)
        #expect(result == .success(target))
        #expect(
            standard.operations == [
                .createDirectory(FakeRelocationFiles.userApplications), .copy(FakeRelocationFiles.translocated, target),
                .clearQuarantine(target),
            ], "the missing folder is created first")
        #expect(relauncher.launched == [target])
    }

    @Test func aFolderThatCannotBeCreatedFailsTheMove_PLT_R710() async {
        let files = FakeRelocationFiles(existing: [], writable: [], failCreate: true)
        let relauncher = FakeRelauncher()
        let relocator = AppRelocator(
            files: files, relauncher: relauncher, applicationsDirectory: FakeRelocationFiles.userApplications)
        #expect(await relocator.relocate(FakeRelocationFiles.downloads) == .failure(.copyFailed))
        #expect(relauncher.launched.isEmpty)
    }

    @Test func theGateProceedsDeclinesOrReportsAFailedMove() async {
        let relauncher = FakeRelauncher()
        let relocator = FakeRelocationFiles.relocator(FakeRelocationFiles(existing: []), relauncher)
        var offers = 0
        let ok = LocationGate<Int>(
            verdict: { .ok },
            offer: { _ in
                offers += 1
                return true
            }, reportFailure: { _ in }, relocator: relocator,
            bundleURL: FakeRelocationFiles.downloads)
        #expect(await ok.resolve() == .proceed)
        #expect(offers == 0)
        let declined = LocationGate<Int>(
            verdict: { .mustMove(1) }, offer: { _ in false }, reportFailure: { _ in }, relocator: relocator,
            bundleURL: FakeRelocationFiles.downloads)
        #expect(await declined.resolve() == .quit)
        var reported: [RelocationError] = []
        let failing = LocationGate<Int>(
            verdict: { .mustMove(2) }, offer: { _ in true }, reportFailure: { reported.append($0) },
            relocator: FakeRelocationFiles.relocator(FakeRelocationFiles(existing: [], failCopy: true), relauncher),
            bundleURL: FakeRelocationFiles.downloads)
        #expect(await failing.resolve() == .quit)
        #expect(reported == [.copyFailed])
    }
}

@Suite("First launch after an update (QA-R42, PRD-R52)")
struct UpdateSelfCheckTests {
    @Test func classifiesLaunches() {
        let check = UpdateSelfCheck(store: InMemoryKeyValueStore())
        #expect(check.noteLaunch(version: "0.1.0 (1)") == .firstLaunch)
        #expect(check.noteLaunch(version: "0.1.0 (1)") == .sameVersion)
        #expect(check.noteLaunch(version: "0.1.1 (2)") == .versionChanged)
        #expect(check.noteLaunch(version: "0.1.0 (1)") == .versionChanged, "a downgrade is checked too")
    }

    @Test func fingerprintsAreStableAndNeverZero() {
        #expect(UpdateSelfCheck.fingerprint("1.0 (1)") == UpdateSelfCheck.fingerprint("1.0 (1)"))
        #expect(UpdateSelfCheck.fingerprint("1.0 (1)") != UpdateSelfCheck.fingerprint("1.0 (2)"))
        #expect(UpdateSelfCheck.fingerprint("") != 0)
        #expect(UpdateSelfCheck.fingerprint("x") < 1 << 52)
    }

    @Test func lostOrStalePermissionShowsThePermissionScreen_PRD_R42() {
        #expect(UpdateSelfCheck.verdict(state: .starting, permissions: .ready) == .pending)
        #expect(UpdateSelfCheck.verdict(state: .noPermission, permissions: .noPermission) == .showPermissionScreen)
        #expect(UpdateSelfCheck.verdict(state: .ready(.vietnamese), permissions: .stale) == .showPermissionScreen)
        for reason in [FailOpenReason.permissionRevoked, .tapUnavailable, .postingBroken] {
            #expect(UpdateSelfCheck.verdict(state: .failOpen(reason), permissions: .ready) == .showPermissionScreen)
        }
        #expect(UpdateSelfCheck.verdict(state: .failOpen(.watchdog), permissions: .ready) == .passed)
        #expect(UpdateSelfCheck.verdict(state: .failOpen(.callbackStuck), permissions: .ready) == .passed)
        #expect(UpdateSelfCheck.verdict(state: .ready(.english), permissions: .ready) == .passed)
        #expect(UpdateSelfCheck.verdict(state: .paused(.secureField), permissions: .ready) == .passed)
    }

    @Test func noSettingChangedMeaningInVersionOne_PRD_R52() {
        #expect(
            SettingMeaningChanges.entries.isEmpty,
            "the 24-hour status line and its release-notes link are not wired yet: wire them with the first entry")
    }
}
