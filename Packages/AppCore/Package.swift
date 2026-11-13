// swift-tools-version: 6.0
// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Platform modules without UI (spec/02-platform.md PLT-R102, docs/decisions/0302-package-and-target-split.md).
// This manifest is FROZEN for wave-1 workstreams (docs/architecture/workstreams.md): a workstream that needs a
// new target or dependency records the request in its report; the integrator changes this file.

import PackageDescription

let strict: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "AppCore",
    // PLT-R106: macOS 15 (Synchronization module). No API newer than macOS 14 outside Synchronization.
    platforms: [.macOS(.v15)],
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
    ],
    dependencies: [
        .package(path: "../VietnameseEngine")
    ],
    targets: [
        // Shared vocabulary: value types, JSON value, file-system protocol. Foundation only.
        .target(name: "AppModel", swiftSettings: strict),
        // Lock-free primitives for the hot path (PLT-R304, PLT-R388): snapshot cell, SPSC ring, signals, clock.
        .target(name: "RealtimeSupport", swiftSettings: strict),
        // Typed redacting logger, health events, histograms, reports, capture (PLT-R801, PLT-R9xx, PLT-R12xx).
        .target(name: "Diagnostics", dependencies: ["AppModel", "RealtimeSupport"], swiftSettings: strict),
        // Versioned settings documents, migrations, export/import, macro importers (PLT-R10xx, PRD-R32).
        .target(name: "SettingsStore", dependencies: ["AppModel"], swiftSettings: strict),
        // Rule schema, loader, validator, matcher, fingerprinting, linter (PLT-R5xx).
        .target(name: "CompatRules", dependencies: ["AppModel"], swiftSettings: strict),
        // Serial injection worker, strategies, pasteboard preservation (PLT-R311-R324, PLT-R4xx).
        .target(
            name: "Injection",
            dependencies: ["AppModel", "RealtimeSupport", "Diagnostics"],
            swiftSettings: strict
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
            swiftSettings: strict
        ),
        // UI-free logic of the menu-bar app: view models, localisation lookup, brand, login item (PRD-R*).
        .target(
            name: "ShellCore",
            dependencies: ["AppModel", "Diagnostics", "SettingsStore", "CompatRules", "InputHost", "RealtimeSupport"],
            swiftSettings: strict
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

        .testTarget(name: "AppModelTests", dependencies: ["AppModel", "TestSupport"], swiftSettings: strict),
        .testTarget(name: "RealtimeSupportTests", dependencies: ["RealtimeSupport"], swiftSettings: strict),
        .testTarget(
            name: "DiagnosticsTests",
            dependencies: ["Diagnostics", "CompatRules", "TestSupport"],
            exclude: ["Fixtures"],  // golden files read through #filePath
            swiftSettings: strict
        ),
        .testTarget(
            name: "SettingsStoreTests",
            dependencies: [
                "SettingsStore", "TestSupport", .product(name: "VietnameseEngine", package: "VietnameseEngine"),
            ],
            swiftSettings: strict
        ),
        .testTarget(name: "CompatRulesTests", dependencies: ["CompatRules", "TestSupport"], swiftSettings: strict),
        .testTarget(name: "InjectionTests", dependencies: ["Injection", "TestSupport"], swiftSettings: strict),
        .testTarget(name: "InputHostTests", dependencies: ["InputHost", "TestSupport"], swiftSettings: strict),
        .testTarget(
            name: "ShellCoreTests",
            dependencies: [
                "ShellCore", "InputHost", "SettingsStore", "Diagnostics", "Injection", "RealtimeSupport", "TestSupport",
            ],
            swiftSettings: strict
        ),
        .testTarget(name: "TestSupportTests", dependencies: ["TestSupport"], swiftSettings: strict),
    ],
    swiftLanguageModes: [.v6]
)
