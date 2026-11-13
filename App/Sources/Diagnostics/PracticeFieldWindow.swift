// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PRD-R49 practice field: a local text field to check whether a problem is app-specific. Its text lives only in
// the view and is never saved or reported.

import AppKit
import ShellCore
import SwiftUI

@MainActor
final class PracticeFieldWindowController: NSWindowController {
    required init?(coder: NSCoder) { nil }

    init(language: InterfaceLanguageModel) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 220), styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("PracticeField")
        window.contentViewController = NSHostingController(rootView: PracticeFieldView(language: language))
        window.center()
        super.init(window: window)
        WindowTitles.follow(language, window: window) { $0.string(DiagnosticsText.practiceTitle) }
    }
}

struct PracticeFieldView: View {
    let language: InterfaceLanguageModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let localizer = language.localizer
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: localizer.string(DiagnosticsText.practiceInstructions))
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.title3)
                .frame(minHeight: 90)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                .focused($focused)
                .diagnosticsControl(.practiceField, localizer)
        }
        .padding(20)
        .respectsReduceMotion()
        .onAppear { focused = true }
    }
}
