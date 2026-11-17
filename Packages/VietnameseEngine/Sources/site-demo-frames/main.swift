// SPDX-License-Identifier: MPL-2.0
//
// Entry point of site-demo-frames; the tool itself is SiteDemoFrames.swift.

import Foundation

exit(
    SiteDemoFrames.run(
        arguments: Array(CommandLine.arguments.dropFirst()),
        currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)))
