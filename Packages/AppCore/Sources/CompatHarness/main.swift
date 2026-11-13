// SPDX-License-Identifier: LicenseRef-App-Pending
//
// `compat-harness` (PLT-R530, PLT-R821, QA-R16): command-line entry. Parsing, planning, scenario execution,
// soak and benchmark logic live in TestSupport/Scenario and are unit tested; this file only wires the live
// services (Live/*.swift). `--dry-run` never constructs them, so a dry run cannot post an event, launch an
// app or change an input source. Everything else runs on the self-hosted runner only (QA-R12, QA-R13).

import AppModel
import Foundation
import RealtimeSupport
import TestSupport

let arguments = Array(CommandLine.arguments.dropFirst())
let options: HarnessOptions
do {
    options = try HarnessCommandLine.parse(arguments)
} catch {
    StandardConsole().emitError("compat-harness: " + error.description)
    StandardConsole().emitError(HarnessCommandLine.usage)
    exit(HarnessExit.usage.rawValue)
}

let needsLive = !options.dryRun && [.run, .soak, .bench].contains(options.command)
let environment = HarnessEnvironment(
    fileSystem: LocalFileSystem(), console: StandardConsole(), clock: MachClock(),
    live: needsLive ? LiveServices() : nil)
let status = await Harness(options: options, environment: environment).execute()
exit(status.rawValue)
