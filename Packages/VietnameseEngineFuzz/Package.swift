// swift-tools-version: 6.0
// SPDX-License-Identifier: MPL-2.0

import PackageDescription

// Coverage-guided fuzzing of the engine (spec/04-quality-release.md QA-R8, QA-R9; spec/01-engine.md 13.6).
// Linux CI builds `engine-fuzz` with `-sanitize=fuzzer` and `-DLIBFUZZER` (README.md); everywhere else the
// same executable replays the seed corpus and runs seeded mutations.
let package = Package(
    name: "VietnameseEngineFuzz",
    // PLT-R106: the app's macOS 12 floor (docs/decisions/0315-minimum-macos-12.md).
    platforms: [.macOS(.v12)],
    dependencies: [.package(path: "../VietnameseEngine")],
    targets: [
        .target(
            name: "EngineFuzzTarget",
            dependencies: [
                .product(name: "VietnameseEngine", package: "VietnameseEngine"),
                .product(name: "VietnameseEngineTesting", package: "VietnameseEngine"),
            ]
        ),
        .executableTarget(name: "engine-fuzz", dependencies: ["EngineFuzzTarget"]),
        .testTarget(name: "EngineFuzzTargetTests", dependencies: ["EngineFuzzTarget"]),
    ],
    swiftLanguageModes: [.v6]
)
