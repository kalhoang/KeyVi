// SPDX-License-Identifier: GPL-3.0-or-later
//
// The dev recorder's indicator on the menu bar icon (PLT-R904A, ADR 0007): a small persistent dot in the top left
// corner while the recorder records, a ring around it for about 1 s after a marker. Drawn over the catalog image at
// draw time with semantic colours (PRD-R67: no fixed hue), so the glyph keeps its light, dark and high-contrast
// variants and the dot is a shape in the label colour with a halo in the menu bar's background colour, distinct
// from the glyph's own mode dot. The VoiceOver label says it too (`DevRecorderText.badgeLabel`). Debug
// configuration only.

#if DEV_RECORDER
import AppKit

@MainActor
enum DevRecorderBadge {
    static let dotDiameter: CGFloat = 6
    static let ringDiameter: CGFloat = 10

    /// `base` with the recording dot, and the ring while `flashing`.
    static func image(over base: NSImage, flashing: Bool) -> NSImage {
        let image = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            let center = NSPoint(x: rect.minX + ringDiameter / 2, y: rect.maxY - ringDiameter / 2)
            if flashing {
                let ring = NSBezierPath(ovalIn: square(center: center, diameter: ringDiameter - 1))
                ring.lineWidth = 1.5
                NSColor.labelColor.setStroke()
                ring.stroke()
            }
            let dot = NSBezierPath(ovalIn: square(center: center, diameter: dotDiameter))
            dot.lineWidth = 1.5
            NSColor.windowBackgroundColor.setStroke()
            dot.stroke()
            NSColor.labelColor.setFill()
            dot.fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func square(center: NSPoint, diameter: CGFloat) -> NSRect {
        NSRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
    }
}
#endif
