// SPDX-License-Identifier: GPL-3.0-or-later
//
// Save sheet of the test host (PLT-R389, PLT-R340 late focus change; Pa's T5.5 report of 2026-11-14: Command+S in
// TextEdit, then `dduowngf` typed at once in the save sheet gave "ddường"). File > Save… (Command+S) attaches a
// document-modal sheet to the second window with a name field that holds "Untitled", all of it selected, like a
// save panel's name field: the first key replaces it. Return or Save, Escape or Cancel close the sheet. The name
// field's text is mirrored into the second window (`TestHostField.sheetMirror`) so the runner reads it back after
// the keys. Labels are fixed English fixture text.

import AppKit

@MainActor
final class SaveSheetController: NSObject, NSTextFieldDelegate {
    static let initialName = "Untitled"

    let mirror: MirrorTextField
    private(set) var sheet: NSWindow?
    private let nameField = NSTextField(string: SaveSheetController.initialName)

    /// The owner sets `mirror.onFocusRequest` (an AX focus request on the mirror focuses the second window's text
    /// view, the document Command+S is typed in).
    override init() {
        mirror = MirrorTextField(string: "")
        super.init()
        mirror.isEditable = false
        mirror.isSelectable = true
        mirror.setAccessibilityIdentifier(TestHostField.sheetMirror.rawValue)
        mirror.setAccessibilityLabel("Save sheet name (mirror)")
        mirror.setAccessibilityHelp(
            "Shows the save sheet's name field; focusing it focuses the second window's text view.")
        nameField.delegate = self
        nameField.setAccessibilityIdentifier(TestHostField.sheetName.rawValue)
        nameField.setAccessibilityLabel("Save as")
        nameField.setAccessibilityHelp("Name of the document to save.")
    }

    /// Attaches the sheet to `window` (a second Command+S while it is up does nothing), name selected.
    func show(on window: NSWindow) {
        guard sheet == nil else { return }
        let sheet = makeSheet()
        self.sheet = sheet
        nameField.stringValue = Self.initialName
        mirror.stringValue = Self.initialName
        window.beginSheet(sheet) { [weak self] _ in self?.sheet = nil }
        sheet.makeFirstResponder(nameField)
        nameField.currentEditor()?.selectAll(nil)
    }

    /// Reset fields: closes the sheet and clears the mirror.
    func reset() {
        close()
        mirror.stringValue = ""
    }

    private func close() {
        guard let sheet else { return }
        sheet.sheetParent?.endSheet(sheet)
        self.sheet = nil
    }

    func controlTextDidChange(_ notification: Notification) { mirror.stringValue = nameField.stringValue }

    @objc private func save(_ sender: Any?) { close() }
    @objc private func cancel(_ sender: Any?) { close() }

    private func makeSheet() -> NSWindow {
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 120), styleMask: [.titled], backing: .buffered,
            defer: false)
        let label = NSTextField(labelWithString: "Save As:")
        let saveButton = NSButton(title: "Save", target: self, action: #selector(save(_:)))
        saveButton.keyEquivalent = "\r"
        saveButton.setAccessibilityHelp("Closes the sheet.")
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.setAccessibilityHelp("Closes the sheet.")
        let row = NSStackView(views: [label, nameField])
        let buttons = NSStackView(views: [cancelButton, saveButton])
        let column = NSStackView(views: [row, buttons])
        column.orientation = .vertical
        column.alignment = .trailing
        column.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        sheet.contentView = column
        sheet.initialFirstResponder = nameField
        return sheet
    }
}
