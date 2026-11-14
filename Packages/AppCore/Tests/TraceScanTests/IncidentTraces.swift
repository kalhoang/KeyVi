// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R904A (ADR 0007): synthetic reproductions, with sample words, of the two incidents of the first dev-recorder
// day (2026-11-14, a native app whose editor is a WKWebView, no compat rule): a key the tap passed never reached the
// field, a few tens of milliseconds before a commit readback of the first recorder (format version 1, no timing
// fields). `both()` is the committed folder Fixtures/incidents (IncidentFixtureTests).

import Foundation
import VietnameseEngine

enum IncidentTraces {
    static let webEditor = "com.example.webeditor"

    /// Incident 1 (22:41:30): "Khúc " was committed; the next word's "c" went down 273 ms later, 27 ms before the old
    /// recorder's commit readback, and never reached the field. KeyVi kept editing as if it had ("cafis", two
    /// Backspaces), and the following words were typed and read back with the field one "c" short.
    static func one() -> TraceBuilder {
        var trace = TraceBuilder()
        trace.launch(bundle: webEditor, rule: nil)
        trace.boundary("focusChanged", job: "focusChanged")
        trace.type("Khucs ")
        trace.advance(153)  // "c" goes down 273 ms after the space
        trace.press("c", event: .key(KeyInput("c")), dropped: true)
        trace.advance(27)
        trace.readbackField(reason: "commit")  // "Khúc ": 27 ms after a key, too soon to compare
        trace.advance(93)
        trace.type("afis")
        trace.backspace()
        trace.backspace()
        trace.advance(180)
        trace.readbackField(reason: "backspaceEdit")
        for word in ["cafi ", "ddi ", "nhes "] {
            trace.type(word)
            trace.advance(180)
            trace.readbackField(reason: "commit")
        }
        return trace
    }

    /// Incident 10 (22:44:03): "c", "o", "i" passed 95, 159 and 229 ms after the space that committed "máy"; the
    /// commit readback started 71 ms after "i", read "máy co", and the field never received the "i".
    static func ten() -> TraceBuilder {
        var trace = TraceBuilder()
        trace.launch(bundle: webEditor, rule: nil)
        trace.boundary("focusChanged", job: "focusChanged")
        typeIncidentTen(into: &trace)
        return trace
    }

    private static func typeIncidentTen(into trace: inout TraceBuilder) {
        trace.type("mays")
        trace.press(" ", event: .key(KeyInput(" ")))
        trace.advance(95)
        trace.press("c", event: .key(KeyInput("c")))
        trace.advance(64)
        trace.press("o", event: .key(KeyInput("o")))
        trace.advance(70)
        trace.press("i", event: .key(KeyInput("i")), dropped: true)
        trace.advance(71)
        trace.readbackField(reason: "commit")  // "máy co", 300 ms after the space
        trace.advance(100)
        trace.type(" c")
        trace.advance(1_000)
        trace.readbackField(reason: "commit")
    }

    /// Incident 1, then incident 10 about two and a half minutes later in the same app, as one trace.
    static func both() -> TraceBuilder {
        var trace = one()
        trace.advance(150_000)
        trace.boundary("focusChanged", job: "focusChanged")
        trace.focus(bundle: webEditor, rule: nil)
        trace.focusNewField()
        typeIncidentTen(into: &trace)
        return trace
    }
}
