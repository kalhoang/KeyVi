// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Layout and the secure-input holder of the test host window. Labels are fixed English fixture text.

import AppKit
import Carbon

/// Two-column form: a label and a control per row, keyboard order top to bottom.
@MainActor
final class TestHostLayout {
    private let grid = NSGridView(numberOfColumns: 2, rows: 0)
    private(set) var firstField: NSView?

    init() {
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
    }

    func addRow(_ title: String, _ control: NSView) {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        grid.addRow(with: [label, control])
        if firstField == nil { firstField = control }
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
    }

    func contentView() -> NSView {
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
        ])
        return content
    }
}

/// Holds secure event input while its checkbox is on, so PLT-R398B scenarios have a known holder (this app).
/// Released when switched off and when the app quits, so a run never leaves secure input stuck on.
@MainActor
final class SecureInputHolder: NSObject {
    let checkbox = NSButton(checkboxWithTitle: "Hold secure input", target: nil, action: nil)
    private(set) var isHolding = false

    override init() {
        super.init()
        checkbox.target = self
        checkbox.action = #selector(toggle(_:))
        checkbox.setAccessibilityIdentifier("testhost.secureInput.toggle")
        checkbox.setAccessibilityLabel("Hold secure input")
        checkbox.setAccessibilityHelp("While on, this app holds secure event input, as a password prompt does.")
    }

    @objc private func toggle(_ sender: NSButton) { setHolding(sender.state == .on) }

    func setHolding(_ hold: Bool) {
        guard hold != isHolding else { return }
        if hold { EnableSecureEventInput() } else { DisableSecureEventInput() }
        isHolding = hold
        checkbox.state = hold ? .on : .off
    }
}
