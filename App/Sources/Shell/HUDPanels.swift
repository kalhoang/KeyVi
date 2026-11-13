// SPDX-License-Identifier: GPL-3.0-or-later
//
// Non-activating HUD panels (ADR 0305): `.nonactivatingPanel`, all Spaces, above full-screen apps, never key.
// The switch HUD (PRD-R12) sits near the bottom centre; the capture HUD (PLT-R905) near the top right. Both
// respect Reduce Motion (PRD-R67) and use system materials and label colours, so they keep contrast in light,
// dark and Increase Contrast modes. Layout and look are placeholders, VERIFY with Pa.

import AppKit
import SwiftUI

@MainActor
enum HUDPanelFactory {
    static let switchSize = NSSize(width: 112, height: 112)
    static let captureSize = NSSize(width: 260, height: 64)
    /// Distance of the switch HUD above the bottom of the visible frame.
    static let bottomOffset: CGFloat = 120
    static let edgeInset: CGFloat = 16
    static let fadeDuration: TimeInterval = 0.15

    static func switchPanel() -> NSPanel {
        let panel = makePanel(size: switchSize)
        panel.ignoresMouseEvents = true  // PRD-R12: never takes focus or clicks
        return panel
    }

    static func capturePanel() -> NSPanel {
        let panel = makePanel(size: captureSize)
        panel.ignoresMouseEvents = false  // the Stop button must be clickable without activating the app
        return panel
    }

    private static func makePanel(size: NSSize) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        return panel
    }

    static func present(_ panel: NSPanel, content: some View) {
        panel.contentView = NSHostingView(rootView: content)
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(
                NSPoint(x: frame.midX - switchSize.width / 2, y: frame.minY + bottomOffset))
        }
        // PRD-R12: appears without animation when Reduce Motion is on; otherwise a short fade in.
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = reduceMotion ? 1 : 0
        panel.orderFrontRegardless()
        guard !reduceMotion else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeDuration
            panel.animator().alphaValue = 1
        }
    }

    /// PRD-R12: "plain fade off". With Reduce Motion it is the only transition; without, it mirrors the fade in.
    static func dismiss(_ panel: NSPanel) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeDuration
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        }
    }

    static func presentCapture(_ panel: NSPanel, content: CaptureHUDView) {
        if let hosting = panel.contentView as? NSHostingView<CaptureHUDView> {
            hosting.rootView = content
        } else {
            panel.contentView = NSHostingView(rootView: content)
        }
        if !panel.isVisible, let screen = NSScreen.main ?? NSScreen.screens.first {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(
                NSPoint(x: frame.maxX - captureSize.width - edgeInset, y: frame.maxY - captureSize.height - edgeInset))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    /// PRD-R66: the HUD's content is announced, not only drawn. Posted from the HUD's own window so VoiceOver
    /// speaks it even though the app has no key window.
    static func announce(_ text: String, from panel: NSPanel) {
        NSAccessibility.post(
            element: panel, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

/// Large V or E on a HUD material. Placeholder look, VERIFY.
struct SwitchHUDView: View {
    let glyph: String
    let label: String

    var body: some View {
        Text(verbatim: glyph)
            .font(.system(size: 56, weight: .bold, design: .rounded))
            .foregroundStyle(.primary)
            .frame(width: HUDPanelFactory.switchSize.width, height: HUDPanelFactory.switchSize.height)
            .modifier(HUDBackground(cornerRadius: 20))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: label))
    }
}

/// Recording indicator with countdown and Stop (PLT-R905). The dot is a shape plus text, never colour alone.
struct CaptureHUDView: View {
    let title: String
    let remaining: String
    let stopTitle: String
    let stopLabel: String
    let stopHint: String
    let stop: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "record.circle")
                .font(.title2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(.headline)
                Text(verbatim: remaining).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(action: stop) { Text(verbatim: stopTitle) }
                .accessibilityLabel(Text(verbatim: stopLabel))
                .accessibilityHint(Text(verbatim: stopHint))
        }
        .padding(.horizontal, 14)
        .frame(width: HUDPanelFactory.captureSize.width, height: HUDPanelFactory.captureSize.height)
        .modifier(HUDBackground(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }
}

/// HUD surface: the system material (which turns opaque with Reduce Transparency) with a hairline outline, and a
/// solid label-colour outline under Increase Contrast so the panel edge stays visible on any background (PRD-R67).
struct HUDBackground: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(.regularMaterial, in: shape)
            .overlay {
                if contrast == .increased {
                    shape.strokeBorder(.primary, lineWidth: 2)
                } else {
                    shape.strokeBorder(.separator)
                }
            }
    }
}
