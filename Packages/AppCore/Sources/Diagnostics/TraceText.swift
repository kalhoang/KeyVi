// SPDX-License-Identifier: GPL-3.0-or-later
//
// The typing trace's text helpers (PLT-R905 `CaptureRendering`), public so tools that render traces offline (the
// dev recorder's scanner, PLT-R904A) print keys, modifiers and characters exactly as the review window does.

public enum TraceText {
    /// `+12.345 s` from microseconds.
    public static func seconds(_ microseconds: UInt64) -> String { CaptureRendering.seconds(microseconds) }

    /// `0x2f`.
    public static func hex(_ keyCode: UInt16) -> String { CaptureRendering.hex(keyCode) }

    /// `shift+cmd`, `-` when no modifier is held (CGEventFlags device-independent bits).
    public static func modifiers(_ flags: UInt64) -> String { CaptureRendering.modifiers(flags) }

    /// Control characters and separators as `U+XXXX`, everything else unchanged.
    public static func visible(_ text: String) -> String { CaptureRendering.visible(text) }
}
