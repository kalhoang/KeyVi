// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PLT-R333, PLT-R381, PLT-R399: workspace notifications (posted only to private centers) and conflicts.

import AppKit
import AppModel
import Foundation
import Testing

@testable import InputHost
@testable import TestSupport

@Suite("Workspace events and conflicts (PLT-R333, PLT-R399)")
@MainActor
struct WorkspaceTests {
    @Test func mapsWorkspaceAndScreenLockNotifications() {
        let workspace = NotificationCenter()
        let distributed = NotificationCenter()
        let events = NSWorkspaceEvents(workspaceCenter: workspace, distributedCenter: distributed)
        var received: [WorkspaceEvent] = []
        let token = events.observe { received.append($0) }
        let application = NSRunningApplication.current  // this process only: other apps are never inspected
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        workspace.post(
            name: NSWorkspace.didActivateApplicationNotification, object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: application])
        workspace.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)  // no app: ignored
        distributed.post(name: ScreenLockNotificationName.locked, object: nil)
        distributed.post(name: ScreenLockNotificationName.unlocked, object: nil)
        #expect(
            received == [
                .willSleep, .didWake, .sessionResignedActive, .sessionBecameActive,
                .applicationActivated(pid: application.processIdentifier), .screenLocked, .screenUnlocked,
            ])
        token.cancel()
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        distributed.post(name: ScreenLockNotificationName.locked, object: nil)
        #expect(received.count == 7)
    }

    @Test func unrelatedNotificationsMapToNothing() {
        #expect(WorkspaceEventMapping.event(for: Notification(name: Notification.Name("test.other"))) == nil)
    }

    @Test func productionInitializerUsesTheSystemCenters() {
        let token = NSWorkspaceEvents().observe { _ in }
        token.cancel()
    }

    @Test func fakeWorkspaceEventsDeliversUntilCancelled() {
        let fake = FakeWorkspaceEvents()
        var received: [WorkspaceEvent] = []
        let token = fake.observe { received.append($0) }
        fake.send(.screenLocked)
        token.cancel()
        fake.send(.screenUnlocked)
        #expect(received == [.screenLocked])
        #expect(fake.observerCount == 0)
    }
}

@Suite("ConflictDetector (PLT-R399)")
struct ConflictDetectorTests {
    private let otherIME = FakeProcessIdentityProvider.process(
        pid: 10, bundle: "com.example.vietime", name: "Other IME")
    private let editor = FakeProcessIdentityProvider.process(pid: 11, bundle: "com.example.editor")
    private let telex = InputSourceInfo(
        id: sourceID("com.apple.inputmethod.VietnameseIM.VietnameseTelex"), kind: .inputMode,
        localizedName: "Vietnamese Telex", languages: ["vi"], isBuiltInVietnamese: true)

    @Test func reportsRunningConflictingAppsAndVietnameseSourcesOnce() {
        var helper = otherIME
        helper.pid = 12
        let result = ConflictDetector.detect(
            running: [editor, otherIME, helper], enabledSources: [.layout("com.apple.keylayout.ABC"), telex, telex],
            conflictingApps: [bundle("com.example.vietime")])
        #expect(
            result == [
                .runningApp(bundle: bundle("com.example.vietime"), name: "Other IME"),
                .builtInVietnameseSource(id: telex.id, name: "Vietnamese Telex"),
            ])
    }

    @Test func fallsBackToTheProcessName() {
        var unnamed = otherIME
        unnamed.localizedName = nil
        let result = ConflictDetector.detect(
            running: [unnamed], enabledSources: [], conflictingApps: [bundle("com.example.vietime")])
        #expect(result == [.runningApp(bundle: bundle("com.example.vietime"), name: "vietime")])
    }

    @Test func nothingToReport() {
        #expect(
            ConflictDetector.detect(
                running: [editor], enabledSources: [.layout("com.apple.keylayout.ABC")], conflictingApps: []
            ).isEmpty)
    }
}
