// SPDX-License-Identifier: GPL-3.0-or-later
//
// `axReplace` (4.5) and `paste` (4.6, PLT-R461) on the simulated field and `FakePasteboard`.

import AppModel
import Foundation
import InputHost
import RealtimeSupport
import TestSupport
import Testing

@testable import Injection

private func environment(
    field: SimulatedTextField, behaviour: FakeFocusedFieldAccess.Behaviour = .normal,
    pasteboard: FakePasteboard = FakePasteboard()
) -> (FakeInjectionEnvironment, FakeEventPoster) {
    let poster = InjectionFieldWiring.poster(for: field, layout: InjectionTestLayouts.qwerty())
    let access = FakeFocusedFieldAccess(field: field, behaviour: behaviour)
    return (
        FakeInjectionEnvironment(poster: poster, clock: ManualClock(), fieldAccess: access, pasteboard: pasteboard),
        poster
    )
}

@Suite struct AXReplaceTests {
    private let executor = StrategyCatalog.executor(for: .axReplace)

    @Test func replacesTheCompositionRangeWithoutKeyEvents() {
        let field = SimulatedTextField(text: "xin chao")
        let (env, poster) = environment(field: field)
        let outcome = executor.execute(Fixture.job(deleteCount: 2, insertion: "ào"), in: env)
        #expect(outcome == .completed(lastEventSequence: 0))
        #expect(field.text == "xin chào")
        #expect(field.selection == Injection.TextRange(location: 8, length: 0))
        #expect(poster.posted.isEmpty)
    }

    @Test func aSelectedSuggestionIsReplacedToo() {
        let field = SimulatedTextField(behaviour: .inlineCompletion(suggestions: ["amazon"]))
        field.apply(InjectionFieldWiring.keyDown("a", receivedAt: Fixture.start), layout: InjectionTestLayouts.qwerty())
        let (env, _) = environment(field: field)
        _ = executor.execute(Fixture.job(deleteCount: 1, insertion: "á"), in: env)
        #expect(field.text == "á")
    }

    @Test func readFailuresFailBeforeAnythingChanges() {
        let field = SimulatedTextField(text: "ab")
        #expect(
            executor.execute(
                Fixture.job(deleteCount: 1, insertion: "x"), in: environment(field: field, behaviour: .timeout).0)
                == .failedBeforePosting(.axTimedOut))
        #expect(
            executor.execute(
                Fixture.job(deleteCount: 1, insertion: "x"), in: environment(field: field, behaviour: .unavailable).0)
                == .failedBeforePosting(.axUnavailable))
        #expect(
            executor.execute(Fixture.job(deleteCount: 1, insertion: "x", field: nil), in: environment(field: field).0)
                == .failedBeforePosting(.axUnavailable))
        #expect(
            executor.execute(Fixture.job(deleteCount: 3, insertion: "x"), in: environment(field: field).0)
                == .failedBeforePosting(.historyMismatch))
        #expect(field.text == "ab")
    }

    /// 4.5: writes may silently do nothing; the mandatory readback catches it.
    @Test func ignoredWritesAreCaughtByTheReadback() {
        let field = SimulatedTextField(text: "ab")
        let outcome = executor.execute(
            Fixture.job(deleteCount: 1, insertion: "x"), in: environment(field: field, behaviour: .writesIgnored).0)
        #expect(outcome == .failedAfterPosting(.readbackMismatch))
    }

    /// 4.5: the selection write applied, the text write did nothing; the composition must not stay selected.
    @Test func ignoredTextWriteRestoresTheCaretBeforeReporting() {
        let field = SimulatedTextField(text: "ab")
        let outcome = executor.execute(
            Fixture.job(deleteCount: 1, insertion: "x"),
            in: environment(field: field, behaviour: .textWritesIgnored).0)
        #expect(outcome == .failedBeforePosting(.readbackMismatch))
        #expect(field.text == "ab")
        #expect(field.selection == Injection.TextRange(location: 2, length: 0))
    }

    @Test func failedTextWriteRestoresTheCaret() {
        let field = SimulatedTextField(text: "ab")
        let access = ScriptedFieldAccess(field: field, failTextWrite: true, failRestore: false)
        let env = FakeInjectionEnvironment(
            poster: FakeEventPoster(), clock: ManualClock(), fieldAccess: access, pasteboard: FakePasteboard())
        #expect(
            executor.execute(Fixture.job(deleteCount: 1, insertion: "x"), in: env)
                == .failedBeforePosting(.axWriteFailed))
        #expect(field.selection == Injection.TextRange(location: 2, length: 0))
        let stuck = ScriptedFieldAccess(field: field, failTextWrite: true, failRestore: true)
        let stuckEnv = FakeInjectionEnvironment(
            poster: FakeEventPoster(), clock: ManualClock(), fieldAccess: stuck, pasteboard: FakePasteboard())
        #expect(
            executor.execute(Fixture.job(deleteCount: 1, insertion: "x"), in: stuckEnv)
                == .failedAfterPosting(.axWriteFailed))
    }

    @Test func axErrorMapping() {
        #expect(AXReplaceExecutor.reason(AXCallResult<Void>.timedOut, write: true) == .axTimedOut)
        #expect(AXReplaceExecutor.reason(AXCallResult<Void>.failed(code: -25200), write: false) == .axUnavailable)
        #expect(AXReplaceExecutor.reason(AXCallResult<Void>.failed(code: -25200), write: true) == .axWriteFailed)
        #expect(AXReplaceExecutor.reason(AXCallResult<Void>.unavailable, write: true) == .axWriteFailed)
    }
}

/// Field access whose text write (and optionally the caret restore after it) fails.
private final class ScriptedFieldAccess: FocusedFieldAccess, Sendable {
    private let base: FakeFocusedFieldAccess
    private let failTextWrite: Bool
    private let failRestore: Bool
    private let rangeWrites = Atomic<Int>(0)

    init(field: SimulatedTextField, failTextWrite: Bool, failRestore: Bool) {
        base = FakeFocusedFieldAccess(field: field)
        self.failTextWrite = failTextWrite
        self.failRestore = failRestore
    }

    func selectedRange(_ field: FieldHandle, timeout: TimeSpan) -> AXCallResult<Injection.TextRange> {
        base.selectedRange(field, timeout: timeout)
    }
    func text(_ field: FieldHandle, in range: Injection.TextRange, timeout: TimeSpan) -> AXCallResult<String> {
        base.text(field, in: range, timeout: timeout)
    }
    func setSelectedRange(_ field: FieldHandle, to range: Injection.TextRange, timeout: TimeSpan) -> AXCallResult<Void>
    {
        let writes = rangeWrites.add(1, ordering: .relaxed).newValue
        if writes > 1, failRestore { return .failed(code: -25200) }
        return base.setSelectedRange(field, to: range, timeout: timeout)
    }
    func setSelectedText(_ field: FieldHandle, to text: String, timeout: TimeSpan) -> AXCallResult<Void> {
        failTextWrite ? .failed(code: -25200) : base.setSelectedText(field, to: text, timeout: timeout)
    }
}

@Suite struct PasteStrategyTests {
    private let executor = StrategyCatalog.executor(for: .paste)
    private let original = [
        PasteboardItemData(
            types: ["public.utf8-plain-text", "public.rtf"],
            data: ["public.utf8-plain-text": Data("copied".utf8), "public.rtf": Data([0x7B, 0x5C, 0x72])])
    ]

    private func pasteJob(deleteCount: Int = 1, insertion: String = "ừ") -> EditJob {
        let parameters = Fixture.parameters {
            $0.pasteOptedIn = true
            $0.restoreDelayMs = 400
        }
        return Fixture.job(
            deleteCount: deleteCount, insertion: insertion, plan: Fixture.plan(.paste, parameters: parameters))
    }

    @Test func deletesThenCommandVAndRestoresInlineWithoutAWorkerPLTR461() {
        let pasteboard = FakePasteboard(items: original)
        let field = SimulatedTextField(text: "u", pasteboardText: { pasteboard.plainText })
        let (env, poster) = environment(field: field, pasteboard: pasteboard)
        #expect(executor.execute(pasteJob(), in: env) != .failedBeforePosting(.pasteboardUnsafe))
        #expect(field.text == "ừ")
        let downs = poster.posted.keyDowns
        #expect(downs.map(\.keyCode) == [.delete, KeyCode(rawValue: 0x09)])
        #expect(downs.last?.flags == SyntheticKeys.commandFlag)
        #expect(env.releaseCount == 1)
        #expect(pasteboard.items == original)
        #expect(env.sleepDeadlines.last == MonotonicInstant(nanoseconds: Fixture.start.nanoseconds + 400_000_000))
    }

    @Test func unsafeClipboardAbortsBeforePostingPLTR461() {
        for condition in [FakePasteboard.Condition.filePromise, .lazyDataUnavailable, .slowRead, .writeFails] {
            let pasteboard = FakePasteboard(items: original)
            pasteboard.set(condition, true)
            let (env, poster) = environment(field: SimulatedTextField(text: "u"), pasteboard: pasteboard)
            #expect(executor.execute(pasteJob(), in: env) == .failedBeforePosting(.pasteboardUnsafe))
            #expect(poster.posted.isEmpty)
            #expect(pasteboard.items == original)
        }
    }

    @Test func moreThanTenMegabytesAborts() {
        let big = [PasteboardItemData(types: ["public.png"], data: ["public.png": Data(count: 10 * 1_024 * 1_024 + 1)])]
        let pasteboard = FakePasteboard(items: big)
        let (env, poster) = environment(field: SimulatedTextField(text: "u"), pasteboard: pasteboard)
        #expect(executor.execute(pasteJob(), in: env) == .failedBeforePosting(.pasteboardUnsafe))
        #expect(poster.posted.isEmpty)
    }

    @Test func missingPasteKeycodeAbortsWithoutTouchingTheClipboard() {
        let pasteboard = FakePasteboard(items: original)
        let (env, _) = environment(field: SimulatedTextField(text: "u"), pasteboard: pasteboard)
        var job = pasteJob()
        job.keyCodes.paste = nil
        #expect(executor.execute(job, in: env) == .failedBeforePosting(.pasteboardUnsafe))
        #expect(pasteboard.transientWriteCount == 0)
    }

    /// PLT-R408, PLT-R461 step 1: a paste too long for its pacing fails before the clipboard is touched.
    @Test func tooLongPasteFailsBeforeTouchingTheClipboardPLTR408() {
        let pasteboard = FakePasteboard(items: original)
        let (env, poster) = environment(field: SimulatedTextField(text: "uuuu"), pasteboard: pasteboard)
        var job = pasteJob(deleteCount: 4)
        job.plan.parameters.interEventDelayUs = 50_000
        #expect(executor.execute(job, in: env) == .failedBeforePosting(.jobTooLong))
        #expect(pasteboard.transientWriteCount == 0)
        #expect(poster.posted.isEmpty)
        #expect(pasteboard.items == original)
    }

    @Test func postingFailureRestoresImmediately() {
        let pasteboard = FakePasteboard(items: original)
        let (env, poster) = environment(field: SimulatedTextField(text: "u"), pasteboard: pasteboard)
        poster.setMode(.failingCreation)
        #expect(executor.execute(pasteJob(), in: env) == .failedBeforePosting(.postingFailed))
        #expect(pasteboard.items == original)
    }
}
