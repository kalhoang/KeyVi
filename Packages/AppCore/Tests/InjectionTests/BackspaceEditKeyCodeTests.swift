// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R405 for Backspace-triggered edits (PLT-R352, ENG-R712): the insertion of an edit that answers a
// Backspace never rides on the Delete keycode. Chromium (Electron chat apps) derives the DOM `code` and, for a
// non-ASCII character, the legacy `keyCode` from the virtual keycode, so a Unicode event posted on `kVK_Delete`
// reaches a web editor that acts on `keyCode` 8 as one more Backspace: the edit then deletes instead of
// inserting, and one physical Backspace takes the whole word (Pa, 2026-11-14, item 3).

import AppModel
import RealtimeSupport
import TestSupport
import Testing

@testable import Injection

/// A field that acts on the keycode first, like an editor listening to `keydown.code` / `keyCode`: a keyDown on
/// `kVK_Delete` deletes one character whatever its Unicode string; any other keyDown types its string.
private final class KeyCodeFirstField: @unchecked Sendable {
    private let lock = Mutex([Character]())

    init(text: String) { lock.withLock { $0 = Array(text) } }

    var text: String { lock.withLock { String($0) } }

    func apply(_ posted: FakeEventPoster.Posted) {
        guard case .synthetic(let event, _) = posted, event.isKeyDown else { return }
        lock.withLock { characters in
            if event.keyCode == .delete || event.keyCode == .forwardDelete {
                if !characters.isEmpty { characters.removeLast() }
            } else {
                characters.append(contentsOf: event.unicode.string)
            }
        }
    }
}

@Suite struct BackspaceEditKeyCodeTests {
    private static func environment(field: KeyCodeFirstField) -> (FakeInjectionEnvironment, FakeEventPoster) {
        let poster = FakeEventPoster { field.apply($0) }
        let simulated = SimulatedTextField(text: field.text)
        let environment = FakeInjectionEnvironment(
            poster: poster, clock: ManualClock(), fieldAccess: FakeFocusedFieldAccess(field: simulated),
            pasteboard: FakePasteboard())
        return (environment, poster)
    }

    /// W240 after a Backspace: traditional `hoàn` + Backspace gives `hòa`, an edit (delete `oàn`, insert `òa`).
    private static func relocationJob(kind: EditKind, firstCharacter: KeyCode?) -> EditJob {
        let backspace = KeyEventRecord(
            kind: .keyDown, keyCode: .delete, flags: 0, autorepeat: false, keyboardType: 40, unicode: .empty,
            receivedAt: Fixture.start, isProbe: false)
        return Fixture.job(
            deleteCount: 3, replaced: "hoàn", insertion: "òa", kind: kind, trigger: backspace,
            keyCodes: JobKeyCodes(trigger: .delete, firstCharacter: firstCharacter, paste: KeyCode(rawValue: 0x09)))
    }

    @Test(arguments: [EditKind.backspaceRecompose, .reentry])
    func aBackspaceEditNeverInsertsOnTheDeleteKeycodePLTR405(kind: EditKind) {
        let field = KeyCodeFirstField(text: "chào hoàn")
        let (environment, poster) = Self.environment(field: field)
        let job = Self.relocationJob(kind: kind, firstCharacter: KeyCode(rawValue: 0x00))
        _ = StrategyCatalog.executor(for: .backspaceReplace).execute(job, in: environment)
        let insertions = poster.posted.compactMap(\.synthetic).filter { $0.isKeyDown && $0.unicode.count > 0 }
        #expect(insertions.map(\.unicode.string) == ["ò", "a"])
        #expect(insertions.allSatisfy { $0.keyCode == KeyCode(rawValue: 0x00) })
        // One Backspace took exactly one character: the word before it and the space survive.
        #expect(field.text == "chào hòa")
    }

    /// Without a layout key for any character of the edit, the insertion still avoids both deletion keys.
    @Test func withoutALayoutKeyTheInsertionUsesALetterPositionPLTR405() {
        let field = KeyCodeFirstField(text: "chào hoàn")
        let (environment, poster) = Self.environment(field: field)
        let job = Self.relocationJob(kind: .backspaceRecompose, firstCharacter: nil)
        _ = StrategyCatalog.executor(for: .backspaceReplace).execute(job, in: environment)
        let insertions = poster.posted.compactMap(\.synthetic).filter { $0.isKeyDown && $0.unicode.count > 0 }
        #expect(!insertions.isEmpty)
        #expect(insertions.allSatisfy { $0.keyCode != .delete && $0.keyCode != .forwardDelete })
        #expect(field.text == "chào hòa")
    }

    /// The deletions themselves stay plain Backspaces without a Unicode string (PLT-R407).
    @Test func theDeletionsStayPlainBackspacesPLTR407() {
        let field = KeyCodeFirstField(text: "hoàn")
        let (environment, poster) = Self.environment(field: field)
        _ = StrategyCatalog.executor(for: .backspaceReplace).execute(
            Self.relocationJob(kind: .backspaceRecompose, firstCharacter: KeyCode(rawValue: 0x00)), in: environment)
        let deletions = poster.posted.compactMap(\.synthetic).filter { $0.isKeyDown && $0.keyCode == .delete }
        #expect(deletions.count == 3)
        #expect(deletions.allSatisfy { $0.unicode.count == 0 && $0.flags == 0 })
    }
}
