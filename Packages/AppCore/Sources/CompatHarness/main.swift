// SPDX-License-Identifier: GPL-3.0-or-later
//
// `compat-harness` (PLT-R530, PLT-R821, QA-R16): command-line entry. Parsing, planning, scenario execution,
// soak and benchmark logic live in TestSupport/Scenario and are unit tested; this file only wires the live
// services (Live/*.swift). They are constructed only when `HarnessEnvironment.allowsLive` agrees: never for
// `--dry-run`, and otherwise only on a machine whose environment sets `COMPAT_HARNESS_LIVE=1` (the self-hosted
// runner, QA-R12, QA-R13). Anywhere else a live command exits 3 before posting an event, launching an app or
// changing an input source, even when `--dry-run` was forgotten.

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

let allowsLive = HarnessEnvironment.allowsLive(options: options, environment: ProcessInfo.processInfo.environment)
let environment = HarnessEnvironment(
    fileSystem: LocalFileSystem(), console: StandardConsole(), clock: MachClock(), sleeper: TaskSleeper(),
    live: allowsLive ? LiveServices() : nil)
let status = await Harness(options: options, environment: environment).execute()
exit(status.rawValue)
