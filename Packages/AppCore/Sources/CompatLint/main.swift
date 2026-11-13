// SPDX-License-Identifier: GPL-3.0-or-later
//
// compat-lint: CI checks over compat/rules.json and compat/matrix.json (PLT-R505, PLT-R506, PLT-R521,
// PLT-R531). The logic is `CompatLintCommand` in CompatRules, where it is unit tested.

import AppModel
import CompatRules
import Foundation

let outcome = CompatLintCommand.run(
    arguments: Array(CommandLine.arguments.dropFirst()), environment: ProcessInfo.processInfo.environment,
    fileSystem: LocalFileSystem(), today: Date())
FileHandle.standardOutput.write(Data(outcome.output.utf8))
exit(outcome.exitCode)
