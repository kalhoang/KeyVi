// swift-tools-version: 6.0
// SPDX-License-Identifier: MPL-2.0

import PackageDescription

let strict: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "VietnameseEngine",
    // ENG-R1201: macOS 13 floor so the engine never constrains the app's own minimum.
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "VietnameseEngine", targets: ["VietnameseEngine"]),
        .library(name: "VietnameseEngineData", targets: ["VietnameseEngineData"]),
        .library(name: "VietnameseEngineTesting", targets: ["VietnameseEngineTesting"]),
        .executable(name: "lexicon-builder", targets: ["lexicon-builder"]),
    ],
    targets: [
        // Core: Swift standard library only (ENG-R1201, PLT-R103). No Foundation, no AppKit.
        .target(name: "VietnameseEngine", swiftSettings: strict),
        // Bundled resources (ENG-R812): the core never embeds data.
        .target(
            name: "VietnameseEngineData",
            dependencies: ["VietnameseEngine"],
            resources: [.copy("Resources")],
            swiftSettings: strict
        ),
        // Independent oracle, corpus generators, simulated text field, fuzz drivers (ENG-T01).
        .target(name: "VietnameseEngineTesting", dependencies: ["VietnameseEngine"], swiftSettings: strict),
        // Builds resource files from pinned inputs (ENG-R810, ENG-R820).
        .executableTarget(name: "lexicon-builder", dependencies: ["VietnameseEngine"], swiftSettings: strict),
        .testTarget(
            name: "VietnameseEngineTests",
            dependencies: ["VietnameseEngine", "VietnameseEngineTesting"],
            resources: [.copy("Corpus")],
            swiftSettings: strict
        ),
        .testTarget(
            name: "VietnameseEngineDataTests",
            dependencies: ["VietnameseEngine", "VietnameseEngineData", "VietnameseEngineTesting"],
            swiftSettings: strict
        ),
    ],
    swiftLanguageModes: [.v6]
)
