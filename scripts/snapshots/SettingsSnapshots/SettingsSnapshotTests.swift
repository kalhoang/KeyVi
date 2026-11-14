// SPDX-License-Identifier: GPL-3.0-or-later
//
// Render-only screenshots of the Settings window (W8-D, Pa's feedback item 6), run by scripts/snapshots/settings.sh.
// Every pane in Vietnamese and English, light and dark, at the window's minimum size and at a larger one, plus the
// Advanced disclosures open. Host safety (the product owner's Mac): the window is built offscreen and drawn with
// `cacheDisplay`; it is never ordered on screen, made key or activated. Nothing starts InputHost or the app
// environment, creates an event tap, requests or checks a permission, or posts an event; the run ends by itself.
// `SETTINGS_SNAPSHOT_BASELINE` builds this file against the sources of an earlier commit (the "before" images).

import AppKit
import AppModel
import CompatRules
import SettingsStore
import ShellCore
import SwiftUI
import TestSupport
import Testing

@MainActor
@Suite(.serialized) struct SettingsSnapshotTests {
    struct Variant {
        var pane: SettingsPaneKind
        var language: InterfaceLanguage
        var dark: Bool
        var sizeName: String
        var size: NSSize
        var advanced = false
        var legacyLayout = false

        var fileName: String {
            var parts = [pane.rawValue, language == .vietnamese ? "vi" : "en", dark ? "dark" : "light", sizeName]
            if advanced { parts.append("advanced") }
            if legacyLayout { parts.append("macos12-layout") }
            return parts.joined(separator: "-") + ".png"
        }
    }

    static let largeSize = NSSize(width: 980, height: 760)

    /// Output folder (`SNAPSHOT_OUTPUT`, passed by the script as `TEST_RUNNER_SNAPSHOT_OUTPUT`) and label.
    static var output: URL {
        let environment = ProcessInfo.processInfo.environment
        let path = environment["SNAPSHOT_OUTPUT"] ?? FileManager.default.temporaryDirectory.path + "/settings-snapshots"
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static var label: String { ProcessInfo.processInfo.environment["SNAPSHOT_LABEL"] ?? "after" }

    /// `SNAPSHOT_ONLY`: render only the variants whose file name contains this text (quick iterations).
    static var only: String? { ProcessInfo.processInfo.environment["SNAPSHOT_ONLY"].flatMap { $0.isEmpty ? nil : $0 } }

    static func variants() -> [Variant] {
        let sizes = [
            ("min", SettingsWindowController.minimumSize), ("default", SettingsWindowController.defaultSize),
            ("large", largeSize),
        ]
        var result: [Variant] = []
        for pane in SettingsPaneKind.allCases {
            for language in [InterfaceLanguage.vietnamese, .english] {
                for dark in [false, true] {
                    for (name, size) in sizes {
                        result.append(Variant(pane: pane, language: language, dark: dark, sizeName: name, size: size))
                    }
                }
            }
        }
        // The whole content of the longest panes in one image (a window taller than any screen, never shown).
        for pane in [SettingsPaneKind.typing, .aboutSupport] {
            for language in [InterfaceLanguage.vietnamese, .english] {
                let full = NSSize(width: SettingsWindowController.defaultSize.width, height: 1_400)
                result.append(Variant(pane: pane, language: language, dark: false, sizeName: "full", size: full))
            }
        }
        for pane in SettingsPaneKind.allCases where pane.hasAdvancedSection {
            for language in [InterfaceLanguage.vietnamese, .english] {
                result.append(
                    Variant(
                        pane: pane, language: language, dark: false, sizeName: "large", size: largeSize, advanced: true)
                )
            }
        }
        #if !SETTINGS_SNAPSHOT_BASELINE
        for pane in SettingsPaneKind.allCases {
            for language in [InterfaceLanguage.vietnamese, .english] {
                result.append(
                    Variant(
                        pane: pane, language: language, dark: false, sizeName: "min",
                        size: SettingsWindowController.minimumSize, legacyLayout: true))
            }
        }
        #endif
        return result
    }

    @Test func rendersEveryPane() async throws {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)  // no Dock icon, no menu bar, never active
        let folder = Self.output.appendingPathComponent(Self.label, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let matrix = SnapshotFixtures.matrix()
        var manifest: [String] = []
        let selected = Self.variants().filter { variant in Self.only.map(variant.fileName.contains) ?? true }
        for variant in selected {
            let store = try await SnapshotFixtures.store(matrix: matrix)
            do {
                try await render(variant, store: store.store, matrix: matrix, into: folder)
            } catch {
                await SnapshotFixtures.discard(store)
                throw error
            }
            await SnapshotFixtures.discard(store)
            manifest.append(variant.fileName)
        }
        try manifest.joined(separator: "\n").write(
            to: folder.appendingPathComponent("manifest.txt"), atomically: true, encoding: .utf8)
        #expect(!manifest.isEmpty && manifest.count == selected.count)
        #expect(SnapshotFixtures.leftoverStores().isEmpty, "temporary settings stores left behind")
    }

    private func render(
        _ variant: Variant, store: SettingsStore, matrix: MatrixDocument?, into folder: URL
    ) async throws {
        let model = try await makeModel(variant, store: store, matrix: matrix)
        let window = makeWindow(variant, model: model)
        let data = try Self.render(window)
        #expect(data.count > 10_000, "\(variant.fileName) rendered blank")
        try data.write(to: folder.appendingPathComponent(variant.fileName))
        window.contentView = nil
    }

    private func makeModel(
        _ variant: Variant, store: SettingsStore, matrix: MatrixDocument?
    ) async throws -> SettingsWindowModel {
        let bundle = SnapshotFixtures.bundle
        let language = InterfaceLanguageModel(language: variant.language, appBundle: bundle)
        let systemLanguage = variant.language == .vietnamese ? "vi" : "en"
        let panes = try #require(SnapshotFixtures.paneNames(systemLanguage: systemLanguage), "SystemPanes.json")
        let model = SettingsWindowModel(
            commands: SettingsCommands(store: store), language: language, updater: SnapshotUpdater(),
            loginItem: SnapshotLoginItem(status: .enabled), brand: Brand.from(bundle), matrix: matrix, panes: panes,
            inputSources: { [] }, layout: { nil }, disclosures: AdvancedDisclosureMemory(store: InMemoryKeyValueStore())
        )
        _ = await model.commands.apply(.interfaceLanguage(variant.language))
        await model.refresh()
        model.select(variant.pane)
        if variant.advanced { model.setAdvancedExpanded(true, for: variant.pane) }
        return model
    }

    private func makeWindow(_ variant: Variant, model: SettingsWindowModel) -> NSWindow {
        let window = SnapshotWindow(
            contentRect: NSRect(origin: .zero, size: variant.size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: variant.dark ? .darkAqua : .aqua)
        window.title = model.localizer.format(SettingsText.windowTitle, model.brand.displayName)
        #if SETTINGS_SNAPSHOT_BASELINE
        window.contentView = NSHostingView(rootView: SettingsRootView(model: model))
        #else
        let root = SettingsRootView(model: model)
            .environment(\.settingsLayoutStyle, variant.legacyLayout ? .legacy : .automatic)
        window.contentView = NSHostingView(rootView: root)
        SettingsWindowController.configure(window)
        #endif
        window.setContentSize(variant.size)
        return window
    }

    /// Draws the window frame (title bar included) without ever putting the window on screen, at 2x.
    /// Offscreen capture cannot draw the system's vibrancy material, so a list selection (`.selection` material) comes
    /// out black. The snapshot puts the colour the system uses for a selection in an inactive window in its place;
    /// the app itself never does this.
    static func standInSelections(in view: NSView, appearance: NSAppearance) {
        for subview in view.subviews {
            guard let effect = subview as? NSVisualEffectView, effect.material == .selection, !effect.isHidden else {
                standInSelections(in: subview, appearance: appearance)
                continue
            }
            let plain = NSView(frame: effect.frame)
            plain.wantsLayer = true
            plain.layer?.cornerRadius = 5
            appearance.performAsCurrentDrawingAppearance {
                plain.layer?.backgroundColor = NSColor.unemphasizedSelectedContentBackgroundColor.cgColor
            }
            effect.superview?.addSubview(plain, positioned: .below, relativeTo: effect)
            effect.isHidden = true
        }
    }

    static func render(_ window: NSWindow) throws -> Data {
        let frameView = try #require(window.contentView?.superview, "window frame view")
        for _ in 0..<4 {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.12))
        }
        window.displayIfNeeded()
        let bounds = frameView.bounds
        let scale = 2
        let representation = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(bounds.width) * scale, pixelsHigh: Int(bounds.height) * scale,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0),
            "bitmap")
        representation.size = bounds.size
        standInSelections(in: frameView, appearance: window.effectiveAppearance)
        frameView.cacheDisplay(in: bounds, to: representation)
        return try #require(representation.representation(using: .png, properties: [:]), "PNG data")
    }
}

/// Draws as the active window (accent selection, coloured switches), the way the user sees Settings while using it,
/// without ever becoming key: it is never ordered on screen.
final class SnapshotWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}
