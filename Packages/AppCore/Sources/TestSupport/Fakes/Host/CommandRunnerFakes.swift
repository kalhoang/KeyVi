// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Command runner double for "Đặt lại quyền" (PLT-R740): records invocations, never executes anything.

public import InputHost
import Synchronization

public final class RecordingCommandRunner: CommandRunning, Sendable {
    private let invocations = Mutex<[CommandInvocation]>([])
    private let status: Int32

    public init(exitStatus: Int32 = 0) { status = exitStatus }

    public func run(_ invocation: CommandInvocation) throws -> Int32 {
        invocations.withLock { $0.append(invocation) }
        return status
    }

    public var recorded: [CommandInvocation] { invocations.withLock { $0 } }
}
