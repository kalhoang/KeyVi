// swift-tools-version: 6.0
// SPDX-License-Identifier: MPL-2.0

import PackageDescription

let strict: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "VietnameseEngine",
    // ENG-R1201, PLT-R106: the app's macOS 12 floor (docs/decisions/0315-minimum-macos-12.md).
    platforms: [.macOS(.v12)],
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
        // ENG-T40 benchmark (ENG-R1230 to ENG-R1233, QA-R14). Not a product: a development tool that
        // replays the generated corpus and a fuzz stream in a release build and writes JSON.
        .executableTarget(
            name: "engine-benchmark",
            dependencies: ["VietnameseEngine", "VietnameseEngineData", "VietnameseEngineTesting"],
            path: "Benchmarks/EngineBenchmark",
            swiftSettings: strict
        ),
        // PRD-R73: types the website's demo sentences through the real engine and writes site/demo/frames.json
        // (website redesign design of 16/11/2026, section 7.4). Not a product: a development tool with a check mode.
        .executableTarget(
            name: "site-demo-frames",
            dependencies: ["VietnameseEngine", "VietnameseEngineData", "VietnameseEngineTesting"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "VietnameseEngineTests",
            dependencies: ["VietnameseEngine", "VietnameseEngineTesting"],
            resources: [.copy("Corpus")],
            swiftSettings: strict
        ),
        // Depends on lexicon-builder so that its logic is unit-tested in-process (`@testable import
        // lexicon_builder`, counted in coverage) and the executable is built before the CLI tests run it.
        .testTarget(
            name: "VietnameseEngineDataTests",
            dependencies: ["VietnameseEngine", "VietnameseEngineData", "VietnameseEngineTesting", "lexicon-builder"],
            swiftSettings: strict
        ),
        // QA-R68: the W11 collision corpus and its adversarial sets with their frozen expected outputs, the
        // host-mode replay and the memory simulation (spec/01-engine.md 13.11, ENG-R876, ENG-R877).
        .testTarget(
            name: "CollisionCorpusTests",
            dependencies: ["VietnameseEngine", "VietnameseEngineData", "VietnameseEngineTesting"],
            resources: [.copy("Fixtures")],
            swiftSettings: strict
        ),
        // Unit-tests site-demo-frames in-process (`@testable import site_demo_frames`).
        .testTarget(
            name: "SiteDemoFramesTests",
            dependencies: ["site-demo-frames", "VietnameseEngine", "VietnameseEngineData", "VietnameseEngineTesting"],
            swiftSettings: strict
        ),
    ],
    swiftLanguageModes: [.v6]
)
