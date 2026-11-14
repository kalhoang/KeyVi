// SPDX-License-Identifier: GPL-3.0-or-later
//
// `trace-scan` (PLT-R904A, ADR 0007): reads the dev recorder's trace folder and prints a summary or one finding's
// excerpt. Standard output and standard error only. See TraceScanCommand and docs/runbooks/dev-recorder.md.

import Foundation
import TraceScanCore

let result = TraceScanCommand.run(Array(CommandLine.arguments.dropFirst()), now: Date(), timeZone: .current)
FileHandle.standardOutput.write(Data(result.output.utf8))
FileHandle.standardError.write(Data(result.error.utf8))
exit(result.exitCode)
