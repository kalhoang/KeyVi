// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Monochrome template glyphs for every `StatusIconState` (PRD-R10), drawn in code. Placeholder artwork that is
// original to this repository (CLR-R7 source: this file). VERIFY with Pa or a designer before 1.0; workstream
// W1-G may replace the drawing with designed assets.

import AppKit
import ShellCore

@MainActor
enum StatusGlyph {
    /// Menu bar extra size in points.
    static let size = NSSize(width: 18, height: 18)

    static func image(for state: StatusIconState) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            draw(state, in: rect)
            return true
        }
        image.isTemplate = true
        return image
    }

    private nonisolated static func draw(_ state: StatusIconState, in rect: NSRect) {
        let ink = NSColor.black
        let dimmed = state == .paused
        let frame = NSBezierPath(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), xRadius: 4, yRadius: 4)
        frame.lineWidth = 1.5
        ink.withAlphaComponent(dimmed ? 0.4 : 1).setStroke()
        frame.stroke()

        let letter: String =
            switch state {
            case .english, .ignoredApp, .secureInputEnglish: "E"
            case .vietnamese, .secureInputVietnamese, .paused, .notWorking, .capturing: "V"
            }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: ink.withAlphaComponent(dimmed ? 0.4 : 1),
        ]
        let text = NSAttributedString(string: letter, attributes: attributes)
        let textSize = text.size()
        text.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2))

        ink.setFill()
        ink.setStroke()
        switch state {
        case .ignoredApp:
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - 6, y: rect.minY + 1, width: 5, height: 5)).fill()
        case .secureInputVietnamese, .secureInputEnglish:
            drawLock(in: NSRect(x: rect.maxX - 7, y: rect.maxY - 8, width: 6, height: 7))
        case .notWorking:
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: rect.minX + 2, y: rect.minY + 2))
            slash.line(to: NSPoint(x: rect.maxX - 2, y: rect.maxY - 2))
            slash.lineWidth = 1.75
            slash.stroke()
        case .capturing:
            NSBezierPath(ovalIn: NSRect(x: rect.minX + 1, y: rect.maxY - 6, width: 5, height: 5)).fill()
        case .vietnamese, .english, .paused:
            break
        }
    }

    private nonisolated static func drawLock(in rect: NSRect) {
        NSBezierPath(rect: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.55)).fill()
        let shackle = NSBezierPath()
        shackle.appendArc(
            withCenter: NSPoint(x: rect.midX, y: rect.minY + rect.height * 0.55), radius: rect.width * 0.32,
            startAngle: 0, endAngle: 180)
        shackle.lineWidth = 1.2
        shackle.stroke()
    }
}
