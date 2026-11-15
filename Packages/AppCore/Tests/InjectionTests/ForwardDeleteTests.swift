// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R407 (amended 15/11/2026) and PLT-R423: the forward-delete key (kVK_ForwardDelete, 0x75) is posted only by the
// `forwardDelete` completion handling, only with the caret read at the end of the field's text, and always right
// before a deletion step. Checked statically over the Injection sources and exhaustively over every executor,
// completion mode, AX behaviour, caret position and edit shape.

import AppModel
import Foundation
import RealtimeSupport
import TestSupport
import Testing

@testable import Injection

@Suite struct ForwardDeleteTests {
    private static var injectionSources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Injection")
    }

    private static func sources() throws -> [(name: String, text: String)] {
        let files = try #require(
            FileManager.default.enumerator(at: injectionSources, includingPropertiesForKeys: nil)
        )
        .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count >= 10)
        return try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    /// Static: the key code is named once, where `SyntheticKeys.forwardDelete` is built (KeyScript.swift), and only the
    /// completion prefix (KeyStrategies.swift) posts that key.
    @Test func onlyTheCompletionPrefixReferencesTheForwardDeleteKeyPLTR407() throws {
        let keyCode = try Regex(#"KeyCode\.forwardDelete\b|keyCode: \.forwardDelete\b|0x75\b|\b117\b"#)
        let builder = try Regex(#"SyntheticKeys\.forwardDelete\b"#)
        var keyCodeFiles: [String] = []
        var builderFiles: [String] = []
        for (name, text) in try Self.sources() {
            keyCodeFiles += Array(repeating: name, count: text.matches(of: keyCode).count)
            if text.firstMatch(of: builder) != nil { builderFiles.append(name) }
        }
        #expect(keyCodeFiles == ["KeyScript.swift"])
        #expect(builderFiles == ["KeyStrategies.swift"])
    }

    /// Exhaustive: only `forwardDelete` with a readable caret at the end posts Forward Delete, only for an edit that
    /// deletes, and each one is followed by a deletion step (Backspace, or Shift+Left for `selectReplace`).
    @Test func onlyAReadableCaretAtTheEndGetsForwardDeletePLTR423() {
        let behaviours: [FakeFocusedFieldAccess.Behaviour] = [.normal, .timeout, .unavailable, .writesIgnored]
        for strategy in InjectionStrategy.allCases {
            for mode in InlineCompletionMode.allCases {
                for behaviour in behaviours {
                    for caretAtEnd in [true, false] {
                        for deleteCount in 0...3 {
                            for insertion in ["", "á", "ường", String(repeating: "đ", count: 70)] {
                                let edit = Edit(
                                    strategy: strategy, mode: mode, behaviour: behaviour, caretAtEnd: caretAtEnd,
                                    deleteCount: deleteCount, insertion: insertion)
                                check(edit, posted: post(edit))
                            }
                        }
                    }
                }
            }
        }
    }

    private struct Edit {
        var strategy: InjectionStrategy
        var mode: InlineCompletionMode
        var behaviour: FakeFocusedFieldAccess.Behaviour
        var caretAtEnd: Bool
        var deleteCount: Int
        var insertion: String

        var expectsForwardDelete: Bool {
            mode == .forwardDelete && caretAtEnd && deleteCount > 0 && behaviour != .timeout
                && behaviour != .unavailable && (strategy == .backspaceReplace || strategy == .selectReplace)
        }
    }

    private func check(_ edit: Edit, posted: [SyntheticKeyEvent]) {
        let downs = posted.filter(\.isKeyDown)
        let label = "\(edit.strategy) \(edit.mode) \(edit.behaviour) end \(edit.caretAtEnd) delete \(edit.deleteCount)"
        let forwardDeletes = downs.indices.filter { downs[$0].keyCode == .forwardDelete }
        guard edit.expectsForwardDelete else {
            #expect(forwardDeletes.isEmpty, "\(label)")
            return
        }
        let expectedCount = edit.strategy == .backspaceReplace ? edit.deleteCount : 1
        #expect(forwardDeletes.count == expectedCount, "\(label)")
        for index in forwardDeletes {
            let next = index + 1 < downs.count ? downs[index + 1].keyCode : nil
            #expect(next == .delete || next == .leftArrow, "\(label)")
            #expect(downs[index].flags == 0 && downs[index].unicode.count == 0, "\(label)")
        }
    }

    private func post(_ edit: Edit) -> [SyntheticKeyEvent] {
        let field = SimulatedTextField(behaviour: .inlineCompletion(suggestions: ["abcdef"]), text: "abc")
        if !edit.caretAtEnd { field.click(at: 1) }
        let poster = InjectionFieldWiring.poster(for: field, layout: InjectionTestLayouts.qwerty())
        let environment = FakeInjectionEnvironment(
            poster: poster, clock: ManualClock(),
            fieldAccess: FakeFocusedFieldAccess(field: field, behaviour: edit.behaviour),
            pasteboard: FakePasteboard())
        let parameters = Fixture.parameters {
            $0.inlineCompletion = edit.mode
            $0.pasteOptedIn = true
            $0.allowMultiCharEvents = true
        }
        let job = Fixture.job(
            deleteCount: edit.deleteCount, insertion: edit.insertion,
            plan: Fixture.plan(edit.strategy, parameters: parameters))
        _ = StrategyCatalog.executor(for: edit.strategy).execute(job, in: environment)
        return poster.posted.compactMap(\.synthetic)
    }
}
