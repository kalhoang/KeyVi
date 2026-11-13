// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Full clipboard preservation (PLT-R461) against `FakePasteboard` and against a uniquely named `NSPasteboard`
// (named pasteboards never show an access alert; the general pasteboard is never touched by tests).

import AppKit
import AppModel
import Foundation
import RealtimeSupport
import TestSupport
import Testing

@testable import Injection

private let plain = "public.utf8-plain-text"
private let twoItems = [
    PasteboardItemData(
        types: [plain, "public.rtf"], data: [plain: Data("xin chào".utf8), "public.rtf": Data([0x7B, 0x5C, 0x72, 0x74])]),
    PasteboardItemData(
        types: ["public.png", "public.file-url"],
        data: ["public.png": Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF]), "public.file-url": Data("file:///tmp/a".utf8)]),
]

private func ms(_ value: UInt64) -> MonotonicInstant {
    MonotonicInstant(nanoseconds: Fixture.start.nanoseconds + value * 1_000_000)
}

@Suite struct PasteboardPreserverFakeTests {
    /// Multi-item, multi-type snapshot is byte-identical after 100 paste jobs, each restored before the next.
    @Test func byteIdenticalAfter100PastesPLTR461() throws {
        let pasteboard = FakePasteboard(items: twoItems)
        let preserver = PasteboardPreserver(pasteboard: pasteboard)
        for index in 0..<100 {
            try preserver.beginPaste("đoạn \(index)")
            let transient = try #require(pasteboard.items.first)
            #expect(pasteboard.items.count == 1)
            #expect(Set(transient.types) == Set([plain] + PasteboardTypeName.markers))
            #expect(pasteboard.plainText == "đoạn \(index)")
            let base = UInt64(index) * 1_000
            #expect(preserver.restoreIfDue(now: ms(base), restoreDelay: .milliseconds(400)) == .notDue)
            #expect(preserver.restoreIfDue(now: ms(base + 400), restoreDelay: .milliseconds(400)) == .restored)
        }
        #expect(pasteboard.items == twoItems)
    }

    /// Step 6: pastes inside the window coalesce: one snapshot, one restore after the last paste.
    @Test func consecutivePastesCoalesce() throws {
        let pasteboard = FakePasteboard(items: twoItems)
        let preserver = PasteboardPreserver(pasteboard: pasteboard)
        for index in 0..<100 {
            try preserver.beginPaste("\(index)")
            preserver.arm(at: ms(UInt64(index) * 100))
            #expect(preserver.restoreIfDue(now: ms(UInt64(index) * 100 + 99), restoreDelay: .milliseconds(400)) == .notDue)
        }
        #expect(pasteboard.transientWriteCount == 100)
        #expect(preserver.deadline(restoreDelay: .milliseconds(400)) == ms(9_900 + 400))
        #expect(preserver.restoreIfDue(now: ms(10_300), restoreDelay: .milliseconds(400)) == .restored)
        #expect(pasteboard.items == twoItems)
        #expect(preserver.restoreIfDue(now: ms(20_000), restoreDelay: .milliseconds(400)) == .nothingPending)
    }

    /// Step 5: `changeCount` guard skips the restore after a user copy.
    @Test func userCopySkipsTheRestore() throws {
        let pasteboard = FakePasteboard(items: twoItems)
        let preserver = PasteboardPreserver(pasteboard: pasteboard)
        try preserver.beginPaste("ă")
        let copied = PasteboardItemData(types: [plain], data: [plain: Data("mới".utf8)])
        pasteboard.userCopies(copied)
        #expect(preserver.restoreIfDue(now: ms(0), restoreDelay: .zero) == .skippedUserCopied)
        #expect(pasteboard.items == [copied])
    }

    @Test func userCopyInsideTheWindowIsPreservedByTheNextPaste() throws {
        let pasteboard = FakePasteboard(items: twoItems)
        let preserver = PasteboardPreserver(pasteboard: pasteboard)
        try preserver.beginPaste("a")
        let copied = PasteboardItemData(types: [plain], data: [plain: Data("mới".utf8)])
        pasteboard.userCopies(copied)
        try preserver.beginPaste("b")
        #expect(preserver.takeSkippedRestores() == 1)
        #expect(preserver.restoreIfDue(now: ms(0), restoreDelay: .zero) == .restored)
        #expect(pasteboard.items == [copied])
    }

    @Test func writeFailureRestoresAndThrows() {
        let pasteboard = FakePasteboard(items: twoItems)
        pasteboard.set(.writeFails, true)
        let preserver = PasteboardPreserver(pasteboard: pasteboard)
        #expect(throws: PasteboardError.writeFailed) { try preserver.beginPaste("x") }
        #expect(!preserver.hasPendingRestore)
        #expect(pasteboard.items == twoItems)
    }

    @Test func failedRestoreIsReportedAsSkipped() throws {
        let pasteboard = FakePasteboard(items: twoItems)
        let preserver = PasteboardPreserver(pasteboard: pasteboard)
        try preserver.beginPaste("x")
        pasteboard.set(.writeFails, true)
        #expect(preserver.restoreIfDue(now: ms(0), restoreDelay: .zero) == .skippedUserCopied)
    }

    @Test func nothingPendingAndRestoreNow() throws {
        let pasteboard = FakePasteboard(items: twoItems)
        let preserver = PasteboardPreserver(pasteboard: pasteboard)
        #expect(preserver.restoreIfDue(now: ms(0), restoreDelay: .zero) == .nothingPending)
        try preserver.beginPaste("x")
        preserver.restoreNow()
        #expect(pasteboard.items == twoItems)
        #expect(!preserver.hasPendingRestore)
    }
}

@Suite(.serialized) struct NSPasteboardAccessTests {
    private func withUniquePasteboard(_ body: (String, NSPasteboard) throws -> Void) rethrows {
        let name = "injection-tests-\(UUID().uuidString)"
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(name))
        defer { pasteboard.releaseGlobally() }
        try body(name, pasteboard)
    }

    private func write(_ items: [PasteboardItemData], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.writeObjects(
            items.map { saved in
                let item = NSPasteboardItem()
                for type in saved.types { item.setData(saved.data[type] ?? Data(), forType: .init(type)) }
                return item
            })
    }

    private var generousLimits: PasteboardLimits {
        var limits = PasteboardLimits()
        limits.readTimeout = .seconds(5)  // shared CI machines; the 100 ms rule is tested with FakePasteboard
        return limits
    }

    /// The acceptance run against a real pasteboard: byte-identical after 100 paste jobs, marker types present.
    @Test func byteIdenticalAfter100PastesOnANamedPasteboardPLTR461() throws {
        try withUniquePasteboard { name, pasteboard in
            write(twoItems, to: pasteboard)
            let access = NSPasteboardAccess(pasteboardName: name)
            let before = try access.snapshot(limits: generousLimits)
            #expect(before.items.count == 2)
            let preserver = PasteboardPreserver(pasteboard: access, limits: generousLimits)
            for index in 0..<100 {
                try preserver.beginPaste("đoạn \(index)")
                if index == 0 {
                    let types = Set(pasteboard.pasteboardItems?.first?.types.map(\.rawValue) ?? [])
                    #expect(types.isSuperset(of: [plain] + PasteboardTypeName.markers))
                    #expect(pasteboard.string(forType: .string) == "đoạn 0")
                }
                #expect(preserver.restoreIfDue(now: ms(0), restoreDelay: .zero) == .restored)
            }
            let after = try access.snapshot(limits: generousLimits)
            #expect(after.items.map(\.data) == before.items.map(\.data))
            for (old, new) in zip(before.items, after.items) { #expect(Set(old.types) == Set(new.types)) }
        }
    }

    @Test func userCopySkipsTheRestoreOnANamedPasteboard() throws {
        try withUniquePasteboard { name, pasteboard in
            write(twoItems, to: pasteboard)
            let access = NSPasteboardAccess(pasteboardName: name)
            let preserver = PasteboardPreserver(pasteboard: access, limits: generousLimits)
            try preserver.beginPaste("x")
            pasteboard.clearContents()
            pasteboard.setString("user", forType: .string)
            #expect(preserver.restoreIfDue(now: ms(0), restoreDelay: .zero) == .skippedUserCopied)
            #expect(pasteboard.string(forType: .string) == "user")
        }
    }

    @Test func limitsAbortTheSnapshot() {
        withUniquePasteboard { name, pasteboard in
            write(twoItems, to: pasteboard)
            let access = NSPasteboardAccess(pasteboardName: name)
            var tiny = generousLimits
            tiny.maxTotalBytes = 4
            #expect(throws: PasteboardError.tooLarge) { try access.snapshot(limits: tiny) }
            var instant = PasteboardLimits()
            instant.readTimeout = .zero
            #expect(throws: PasteboardError.timedOut) { try access.snapshot(limits: instant) }
        }
    }

    @Test func filePromisesAreRecognised() {
        #expect(PasteboardIO.isFilePromise(kPasteboardTypeFileURLPromise as String))
        #expect(!PasteboardIO.isFilePromise(plain))
        withUniquePasteboard { name, pasteboard in
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setData(Data("x".utf8), forType: .init(kPasteboardTypeFilePromiseContent as String))
            pasteboard.writeObjects([item])
            let access = NSPasteboardAccess(pasteboardName: name)
            #expect(throws: PasteboardError.filePromise) { try access.snapshot(limits: generousLimits) }
        }
    }

    /// Owner-provided lazy data that cannot be materialised aborts; system-derived conversions do not.
    @Test func unmaterialisableLazyDataAborts() {
        #expect(PasteboardIO.isRederivable("public.utf16-external-plain-text", from: [plain]))
        #expect(!PasteboardIO.isRederivable("public.utf16-external-plain-text", from: ["public.png"]))
        #expect(!PasteboardIO.isRederivable("public.tiff", from: [plain]))
        withUniquePasteboard { name, pasteboard in
            let provider = SilentProvider()
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setData(Data("x".utf8), forType: .string)
            item.setDataProvider(provider, forTypes: [.tiff])
            pasteboard.writeObjects([item])
            let access = NSPasteboardAccess(pasteboardName: name)
            #expect(throws: PasteboardError.lazyDataUnavailable) { try access.snapshot(limits: generousLimits) }
            withExtendedLifetime(provider) {}
        }
    }

    @Test func emptyPasteboardRoundTrips() throws {
        try withUniquePasteboard { name, pasteboard in
            pasteboard.clearContents()
            let access = NSPasteboardAccess(pasteboardName: name)
            let snapshot = try access.snapshot(limits: generousLimits)
            #expect(snapshot.items.isEmpty)
            let changeCount = try access.writeTransient("t")
            #expect(changeCount == access.changeCount)
            try access.restore(snapshot)
            #expect((pasteboard.pasteboardItems ?? []).isEmpty)
        }
    }
}

/// A lazy data provider that never provides anything (an owner app that is gone or failing).
private final class SilentProvider: NSObject, NSPasteboardItemDataProvider {
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {}
}
