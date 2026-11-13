// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Skeleton seam tests for the shared fakes (ADR 0313): keep green.
import AppModel
import CompatRules
import CoreGraphics
import Foundation
import Injection
import InputHost
import RealtimeSupport
import Synchronization
import Testing
@testable import TestSupport

private let shift = CGEventFlags.maskShift.rawValue
private let command = CGEventFlags.maskCommand.rawValue

private func key(_ code: UInt16, _ text: String = "", flags: UInt64 = 0) -> SyntheticKeyEvent {
    SyntheticKeyEvent(keyCode: KeyCode(rawValue: code), isKeyDown: true, flags: flags, unicode: InlineUTF16(text)!)
}

private let backspace = key(SimulatedTextField.KeyCodes.delete)

/// Synthetic layout: ANSI A (0x00) types a/A, ANSI V (0x09) types v/V.
private func testLayout() -> LayoutTable {
    var entries = [LayoutEntry](repeating: .none, count: LayoutTable.keyCodeCount * 4)
    entries[0 * 4 + 0] = .character("a")
    entries[0 * 4 + 1] = .character("A")
    entries[9 * 4 + 0] = .character("v")
    entries[9 * 4 + 1] = .character("V")
    return LayoutTable(source: InputSourceID(rawValue: "test.layout")!, keyboardType: 40, entries: entries)
}

@Suite struct SimulatedTextFieldTests {
    /// 4.10 acceptance shape: "nguyen" + s -> 2 backspaces and 2 inserted characters.
    @Test func backspaceReplaceOnCocoaField() {
        let field = SimulatedTextField(text: "nguyen")
        field.apply(backspace)
        field.apply(backspace)
        field.apply(key(0x0E, "ế"))
        field.apply(key(0x2D, "n"))
        #expect(field.text == "nguyến")
        #expect(field.selection == TextRange(location: 6, length: 0))
    }

    @Test func inlineCompletionSelectsSuggestionAndBackspaceRemovesOnlyIt() {
        let field = SimulatedTextField(behaviour: .inlineCompletion(suggestions: ["google.com"]))
        field.apply(key(0x05, "g"))
        #expect(field.text == "google.com")
        #expect(field.selectedText == "oogle.com")
        field.apply(backspace)
        #expect(field.text == "g")  // the classic bug: the backspace hit the suggestion, not the letter
    }

    @Test func selectReplaceWithShiftLeft() {
        let field = SimulatedTextField(text: "ca")
        field.apply(key(SimulatedTextField.KeyCodes.leftArrow, flags: shift))
        #expect(field.selectedText == "a")
        field.apply(key(0x00, "á"))
        #expect(field.text == "cá")
    }

    @Test func dropsFirstEventAfterFocus() {
        let field = SimulatedTextField(behaviour: .dropsFirstEventAfterFocus)
        field.apply(key(0x00, "a"))
        field.apply(key(0x00, "b"))
        #expect(field.text == "b")
        field.click(at: 0)
        field.apply(key(0x00, "c"))
        #expect(field.text == "b")
        #expect(field.droppedEventCount == 2)
    }

    @Test func ignoresUnicodePayloadTypesKeycodeLetter() {
        let field = SimulatedTextField(behaviour: .ignoresUnicodePayload)
        field.apply(key(0x00, "á"), layout: testLayout())
        field.apply(key(0x00, "Á", flags: shift), layout: testLayout())
        #expect(field.text == "aA")
    }

    @Test func terminalReadsInBatchesAndNeverSelects() {
        let field = SimulatedTextField(behaviour: .terminalReadsInBatches(maxEventsPerRead: 2), text: "x")
        field.apply(key(0x00, "a"))
        #expect(field.text == "x")
        #expect(field.pendingReadCount == 1)
        field.apply(key(SimulatedTextField.KeyCodes.leftArrow, flags: shift))
        #expect(field.text == "xa")
        #expect(field.selection.length == 0)
        field.apply(key(0x00, "b"))
        field.flushPendingReads()
        #expect(field.text == "xab")
    }

    @Test func physicalReplayUsesUnicodeThenLayout() {
        let field = SimulatedTextField()
        let layout = testLayout()
        let record = KeyEventRecord(
            kind: .keyDown, keyCode: KeyCode(rawValue: 0), flags: 0, autorepeat: false, keyboardType: 40,
            unicode: .empty, receivedAt: .zero, isProbe: false)
        field.apply(record, layout: layout)
        var withUnicode = record
        withUnicode.unicode = InlineUTF16("q")!
        field.apply(withUnicode, layout: layout)
        var keyUp = record
        keyUp.kind = .keyUp
        field.apply(keyUp, layout: layout)
        #expect(field.text == "aq")
    }

    @Test func commandVPastesFromPasteboard() throws {
        let pasteboard = FakePasteboard()
        _ = try pasteboard.writeTransient("xin chào")
        let field = SimulatedTextField(pasteboardText: { pasteboard.plainText })
        field.apply(key(0x09, "v", flags: command), layout: testLayout())
        #expect(field.text == "xin chào")
    }
}

@Suite struct FakeFocusedFieldAccessTests {
    private let handle = FieldHandle(pid: 1, token: 1, element: nil)

    @Test func readsAreBoundedAndWritesReplaceSelection() {
        let field = SimulatedTextField(text: String(repeating: "a", count: 100))
        let access = FakeFocusedFieldAccess(field: field)
        if case .success(let text) = access.text(handle, in: TextRange(location: 0, length: 100), timeout: .milliseconds(50)) {
            #expect(text.utf16.count == 64)
        } else {
            Issue.record("expected success")
        }
        _ = access.setSelectedRange(handle, to: TextRange(location: 98, length: 2), timeout: .milliseconds(50))
        _ = access.setSelectedText(handle, to: "b", timeout: .milliseconds(50))
        #expect(field.text.hasSuffix("ab"))
        #expect(access.callCount == 3)
    }

    @Test func timeoutAndIgnoredWrites() {
        let field = SimulatedTextField(text: "abc")
        let access = FakeFocusedFieldAccess(field: field, behaviour: .timeout)
        if case .timedOut = access.selectedRange(handle, timeout: .milliseconds(50)) {} else { Issue.record("expected timeout") }
        access.setBehaviour(.writesIgnored)
        if case .success = access.setSelectedText(handle, to: "x", timeout: .milliseconds(50)) {} else { Issue.record("expected success") }
        #expect(field.text == "abc")
    }
}

@Suite struct FakePasteboardTests {
    @Test func snapshotRestoreAndMarkers() throws {
        let original = PasteboardItemData(types: ["public.png"], data: ["public.png": Data([1, 2, 3])])
        let pasteboard = FakePasteboard(items: [original])
        let snapshot = try pasteboard.snapshot(limits: PasteboardLimits())
        let afterWrite = try pasteboard.writeTransient("đ")
        #expect(afterWrite == snapshot.changeCount + 1)
        #expect(Set(pasteboard.items[0].types).isSuperset(of: PasteboardTypeName.markers))
        try pasteboard.restore(snapshot)
        #expect(pasteboard.items == [original])
    }

    @Test func conditionsAbortSnapshot() {
        let pasteboard = FakePasteboard(items: [PasteboardItemData(types: ["x"], data: ["x": Data(count: 11)])])
        var limits = PasteboardLimits()
        limits.maxTotalBytes = 10
        #expect(throws: PasteboardError.tooLarge) { try pasteboard.snapshot(limits: limits) }
        pasteboard.set(.filePromise, true)
        #expect(throws: PasteboardError.filePromise) { try pasteboard.snapshot(limits: PasteboardLimits()) }
    }

    @Test func userCopyChangesCount() {
        let pasteboard = FakePasteboard()
        let before = pasteboard.changeCount
        pasteboard.userCopies(PasteboardItemData(types: [], data: [:]))
        #expect(pasteboard.changeCount == before + 1)
    }
}

@Suite struct FakeEventPosterTests {
    @Test func modes() throws {
        let delivered = Mutex<Int>(0)
        let poster = FakeEventPoster(sink: { _ in delivered.withLock { $0 += 1 } })
        try poster.post(key(0x00, "a"), userData: 1)
        poster.setMode(.silentlyDropping)
        try poster.post(key(0x00, "b"), userData: 2)
        poster.setMode(.failingCreation)
        #expect(throws: PostError.eventCreationFailed) { try poster.post(key(0x00, "c"), userData: 3) }
        #expect(poster.posted.map(\.userData) == [1])
        #expect(poster.dropped.map(\.userData) == [2])
        #expect(delivered.withLock { $0 } == 1)
    }
}

@Suite struct ManualSchedulerTests {
    @Test func firesDueTimersInOrder() {
        let clock = ManualClock()
        let scheduler = ManualScheduler(clock: clock)
        let log = Mutex<[String]>([])
        let repeating = scheduler.scheduleRepeating(every: .seconds(2), leeway: .zero) { log.withLock { $0.append("tick") } }
        _ = scheduler.schedule(after: .seconds(3), leeway: .zero) { log.withLock { $0.append("once") } }
        let cancelled = scheduler.schedule(after: .seconds(1), leeway: .zero) { log.withLock { $0.append("never") } }
        cancelled.cancel()
        scheduler.advance(by: .seconds(5))
        #expect(log.withLock { $0 } == ["tick", "once", "tick"])
        #expect(scheduler.repeatingIntervals == [.seconds(2)])
        repeating.cancel()
        #expect(scheduler.pendingCount == 0)
    }
}

@Suite struct FakeEventTapTests {
    @Test func factoryFailsOnDemandAndHandleRecordsCalls() {
        let factory = FakeEventTapFactory(failCreation: true)
        let callback: CGEventTapCallBack = { _, _, event, _ in Unmanaged.passUnretained(event) }
        #expect(factory.makeTap(mask: .standard, callback: callback, userInfo: nil) == nil)
        factory.setFailCreation(false)
        let handle = factory.makeTap(mask: .standard, callback: callback, userInfo: nil)
        #expect(handle != nil)
        handle?.setEnabled(false)
        #expect(handle?.isEnabled == false)
        handle?.invalidate()
        #expect(factory.handles.first?.enableCalls == [false])
        #expect(factory.handles.first?.isInvalidated == true)
    }
}

@Suite struct FakeDecisionResolverTests {
    @Test func resolvesByBundleAndRecordsContexts() throws {
        let terminal = try #require(BundleKey(rawValue: "com.example.terminal"))
        var passThrough = FakeDecisionResolver.defaultDecision(engine: .native)
        passThrough.strategy = .passThrough
        let resolver = FakeDecisionResolver(
            decisions: [terminal: passThrough], fallback: FakeDecisionResolver.defaultDecision(engine: .chromium))
        let context = MatchContext(bundle: terminal, appVersion: nil, macOS: LooseVersion("15.0")!, engine: .native)
        #expect(resolver.resolve(context).strategy == .passThrough)
        #expect(resolver.resolve(MatchContext(bundle: nil, appVersion: nil, macOS: LooseVersion("15.0")!, engine: .chromium)).requireTextFocus == .never)
        #expect(resolver.resolvedContexts.count == 2)
        #expect(FakeDecisionResolver.defaultDecision(engine: .native).requireTextFocus == .whenKnown)
    }
}
