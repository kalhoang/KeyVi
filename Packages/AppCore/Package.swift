// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Platform modules without UI (spec/02-platform.md PLT-R102, docs/decisions/0302-package-and-target-split.md).
// This manifest is FROZEN for wave-1 workstreams (docs/architecture/workstreams.md): a workstream that needs a
// new target or dependency records the request in its report; the integrator changes this file.

import PackageDescription

let strict: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

/// PLT-R904A, ADR 0007: the dev builds' typing recorder is compiled only in the Debug configuration. Release (and
/// the Integration test build) never define it; scripts/verify-release.sh proves the recorder is absent.
let devRecorder: [SwiftSetting] = strict + [.define("DEV_RECORDER", .when(configuration: .debug))]

let package = Package(
    name: "AppCore",
    // PLT-R106: macOS 12 Monterey (Pa's decision 2026-11-13, docs/decisions/0315-minimum-macos-12.md). Newer APIs
    // only behind `#available`; RealtimeSupport provides the locks, atomics and time type used instead.
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "AppModel", targets: ["AppModel"]),
        .library(name: "RealtimeSupport", targets: ["RealtimeSupport"]),
        .library(name: "Diagnostics", targets: ["Diagnostics"]),
        .library(name: "SettingsStore", targets: ["SettingsStore"]),
        .library(name: "CompatRules", targets: ["CompatRules"]),
        .library(name: "Injection", targets: ["Injection"]),
        .library(name: "InputHost", targets: ["InputHost"]),
        .library(name: "ShellCore", targets: ["ShellCore"]),
        .library(name: "TestSupport", targets: ["TestSupport"]),
        .executable(name: "compat-harness", targets: ["CompatHarness"]),
        .executable(name: "compat-lint", targets: ["CompatLint"]),
        .executable(name: "trace-scan", targets: ["TraceScan"]),
    ],
    dependencies: [
        .package(path: "../VietnameseEngine")
    ],
    targets: [
        // Shared vocabulary: value types, JSON value, file-system protocol. Foundation only.
        .target(name: "AppModel", swiftSettings: strict),
        // C11-style atomic operations behind RealtimeSupport's `Atomic` (ADR 0315). Header-only inline functions.
        .target(name: "CRealtimeSupport"),
        // Lock-free primitives for the hot path (PLT-R304, PLT-R388): atomics, mutex, snapshot cell, SPSC ring,
        // signals, clock and time spans.
        .target(name: "RealtimeSupport", dependencies: ["CRealtimeSupport"], swiftSettings: strict),
        // Typed redacting logger, health events, histograms, reports, capture (PLT-R801, PLT-R9xx, PLT-R12xx).
        .target(name: "Diagnostics", dependencies: ["AppModel", "RealtimeSupport"], swiftSettings: devRecorder),
        // Versioned settings documents, migrations, export/import, macro importers (PLT-R10xx, PRD-R32).
        .target(name: "SettingsStore", dependencies: ["AppModel", "RealtimeSupport"], swiftSettings: strict),
        // Rule schema, loader, validator, matcher, fingerprinting, linter (PLT-R5xx).
        .target(name: "CompatRules", dependencies: ["AppModel"], swiftSettings: strict),
        // Serial injection worker, strategies, pasteboard preservation (PLT-R311-R324, PLT-R4xx).
        .target(
            name: "Injection",
            dependencies: ["AppModel", "RealtimeSupport", "Diagnostics"],
            swiftSettings: devRecorder
        ),
        // Event tap thread, decision pipeline, layout tables, input source, focus (AX thread), secure input,
        // per-app memory, hotkeys, permissions (PLT-R2xx, PLT-R3xx, PLT-R7xx).
        .target(
            name: "InputHost",
            dependencies: [
                "AppModel", "RealtimeSupport", "Diagnostics", "SettingsStore", "CompatRules", "Injection",
                .product(name: "VietnameseEngine", package: "VietnameseEngine"),
                .product(name: "VietnameseEngineData", package: "VietnameseEngine"),
            ],
            swiftSettings: devRecorder
        ),
        // UI-free logic of the menu-bar app: view models, localisation lookup, brand, login item (PRD-R*).
        .target(
            name: "ShellCore",
            dependencies: ["AppModel", "Diagnostics", "SettingsStore", "CompatRules", "InputHost", "RealtimeSupport"],
            swiftSettings: devRecorder
        ),
        // Fakes, simulated text field, pipeline harness, conservation ledger, scenario runner (QA-R1 layer 4).
        .target(
            name: "TestSupport",
            dependencies: [
                "AppModel", "RealtimeSupport", "Diagnostics", "SettingsStore", "CompatRules", "Injection",
                "InputHost", "ShellCore",
            ],
            swiftSettings: strict
        ),
        // CI executable for the self-hosted runner: keyboard driver, scenario execution, readback (PLT-R530).
        .executableTarget(name: "CompatHarness", dependencies: ["TestSupport"], swiftSettings: strict),
        // Rules and matrix lint for CI (PLT-R505, PLT-R506, PLT-R521, PLT-R531).
        .executableTarget(name: "CompatLint", dependencies: ["CompatRules"], swiftSettings: strict),
        // PLT-R904A, ADR 0007: offline reader of the dev recorder's trace files (summary, findings, excerpts). Runs on
        // the host against a folder of files; never part of the app. The logic is a library so it is unit-tested.
        .target(
            name: "TraceScanCore",
            dependencies: [
                "Diagnostics",
                .product(name: "VietnameseEngine", package: "VietnameseEngine"),
                .product(name: "VietnameseEngineData", package: "VietnameseEngine"),
            ],
            swiftSettings: strict
        ),
        .executableTarget(name: "TraceScan", dependencies: ["TraceScanCore"], swiftSettings: strict),

        .testTarget(name: "AppModelTests", dependencies: ["AppModel", "TestSupport"], swiftSettings: strict),
        .testTarget(name: "RealtimeSupportTests", dependencies: ["RealtimeSupport"], swiftSettings: strict),
        .testTarget(
            name: "DiagnosticsTests",
            dependencies: ["Diagnostics", "CompatRules", "RealtimeSupport", "TestSupport"],
            exclude: ["Fixtures"],  // golden files read through #filePath
            swiftSettings: devRecorder
        ),
        .testTarget(
            name: "SettingsStoreTests",
            dependencies: [
                "SettingsStore", "RealtimeSupport", "TestSupport",
                .product(name: "VietnameseEngine", package: "VietnameseEngine"),
            ],
            swiftSettings: strict
        ),
        .testTarget(name: "CompatRulesTests", dependencies: ["CompatRules", "TestSupport"], swiftSettings: strict),
        .testTarget(
            name: "InjectionTests", dependencies: ["Injection", "RealtimeSupport", "TestSupport"],
            swiftSettings: devRecorder
        ),
        .testTarget(
            name: "InputHostTests", dependencies: ["InputHost", "RealtimeSupport", "TestSupport"],
            swiftSettings: devRecorder
        ),
        .testTarget(
            name: "ShellCoreTests",
            dependencies: [
                "ShellCore", "InputHost", "SettingsStore", "Diagnostics", "Injection", "RealtimeSupport", "TestSupport",
            ],
            swiftSettings: devRecorder
        ),
        .testTarget(name: "TestSupportTests", dependencies: ["TestSupport", "RealtimeSupport"], swiftSettings: strict),
        .testTarget(
            name: "TraceScanTests",
            dependencies: [
                "TraceScanCore", "Diagnostics", "RealtimeSupport", "AppModel", "TestSupport",
                .product(name: "VietnameseEngine", package: "VietnameseEngine"),
            ],
            exclude: ["Fixtures"],  // synthetic trace files read through #filePath
            swiftSettings: devRecorder
        ),
    ],
    swiftLanguageModes: [.v6]
)
