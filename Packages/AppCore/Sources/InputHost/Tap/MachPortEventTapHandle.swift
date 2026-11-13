// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Production `EventTapHandle` around the `CFMachPort` returned by `CGEvent.tapCreate` (contracts.md section 3,
// ADR 0313). Never created in tests on a developer Mac. Workstream W1-F2.

internal import CoreFoundation
internal import CoreGraphics
internal import Synchronization

final class MachPortEventTapHandle: EventTapHandle, Sendable {
    /// CF objects without Sendable annotations. `CGEventTapEnable`, `CGEventTapIsEnabled`,
    /// `CFMachPortInvalidate` and run-loop source removal are documented as callable from any thread.
    private struct Port: @unchecked Sendable { let value: CFMachPort }
    private struct Installation: @unchecked Sendable {
        let source: CFRunLoopSource
        let runLoop: CFRunLoop
    }

    private let port: Port
    private let installation = Mutex<Installation?>(nil)

    init(port: CFMachPort) { self.port = Port(value: port) }

    /// `CFMachPortCreateRunLoopSource` + `CFRunLoopAddSource` on the tap thread's run loop (PLT-R303).
    func install(on runLoop: CFRunLoop) {
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port.value, 0) else { return }
        CFRunLoopAddSource(runLoop, source, .commonModes)
        installation.withLock { $0 = Installation(source: source, runLoop: runLoop) }
    }

    func setEnabled(_ enabled: Bool) { CGEvent.tapEnable(tap: port.value, enable: enabled) }

    var isEnabled: Bool { CGEvent.tapIsEnabled(tap: port.value) }

    /// `CFRunLoopRemoveSource` + `CFMachPortInvalidate` (PLT-R730).
    func invalidate() {
        let removed = installation.withLock { current -> Installation? in
            defer { current = nil }
            return current
        }
        if let removed { CFRunLoopRemoveSource(removed.runLoop, removed.source, .commonModes) }
        CFMachPortInvalidate(port.value)
    }
}
