// SPDX-License-Identifier: GPL-3.0-or-later

/// Marks a contract body that a workstream has not implemented yet (docs/architecture/workstreams.md).
/// The skeleton compiles against every contract; calling an unimplemented member traps with its location.
/// A CI grep fails a release build if any call to this function remains.
public func unimplemented(
    _ function: StaticString = #function, file: StaticString = #fileID, line: UInt = #line
) -> Never {
    fatalError("unimplemented contract member \(function)", file: file, line: line)
}
