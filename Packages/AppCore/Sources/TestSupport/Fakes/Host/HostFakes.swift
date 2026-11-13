// SPDX-License-Identifier: LicenseRef-App-Pending

public import AppModel
public import CompatRules
public import Foundation
public import InputHost
public import Injection

public final class FakeAXProvider: AXProvider, Sendable {
    public init() { unimplemented() }
    /// Sets the focused app/element; posts the given notification to observers.
    public func focus(pid: Int32, attributes: FocusAttributes, notify: AXNotificationKind?) { unimplemented() }
    public func setTimingOut(pid: Int32, _ timingOut: Bool) { unimplemented() }
    public func systemWideFocus() -> AXCallResult<AXFocusedElement?> { unimplemented() }
    public func attributes(of element: AXFocusedElement, request: AXAttributeRequest) -> AXCallResult<FocusAttributes> {
        unimplemented()
    }
    public func observe(
        pid: Int32, notifications: Set<AXNotificationKind>, handler: @escaping @Sendable (AXNotificationKind) -> Void
    ) -> (any AXObservation)? { unimplemented() }
    public func enableManualAccessibility(pid: Int32) -> Bool { unimplemented() }
    public var manualAccessibilityRequests: [Int32] { unimplemented() }
}

public final class FakeProcessIdentityProvider: ProcessIdentityProvider, Sendable {
    public init(processes: [ProcessIdentity]) { unimplemented() }
    public func identity(of pid: Int32) -> ProcessIdentity? { unimplemented() }
    public func isAlive(_ pid: Int32) -> Bool { unimplemented() }
    public func runningApplications() -> [ProcessIdentity] { unimplemented() }
}

public final class FakeSecureInputProbe: SecureInputProbe, Sendable {
    public init() { unimplemented() }
    public func set(enabled: Bool, holderPID: Int32?) { unimplemented() }
    public func isSecureEventInputEnabled() -> Bool { unimplemented() }
    public func secureInputHolderPID() -> Int32? { unimplemented() }
}

public final class FakePermissionProbe: PermissionProbe, Sendable {
    public init(trusted: Bool = true, post: Bool = true, listen: Bool = true) { unimplemented() }
    public func set(trusted: Bool, post: Bool, listen: Bool) { unimplemented() }
    public func isAccessibilityTrusted() -> Bool { unimplemented() }
    public func canPostEvents() -> Bool { unimplemented() }
    public func canListenToEvents() -> Bool { unimplemented() }
    public func promptForAccessibility() { unimplemented() }
    public func requestListenEventAccess() -> Bool { unimplemented() }
    public func requestPostEventAccess() -> Bool { unimplemented() }
    public func signingIdentityDigest() -> String? { unimplemented() }
}

@MainActor
public final class FakeInputSourceProvider: InputSourceProvider {
    public init(current: InputSourceInfo, layouts: [InputSourceID: KeyboardLayoutData]) { unimplemented() }
    public func select(_ source: InputSourceInfo) { unimplemented() }
    public func currentSource() -> InputSourceInfo { unimplemented() }
    public func currentLayoutData() -> KeyboardLayoutData? { unimplemented() }
    public func enabledSources() -> [InputSourceInfo] { unimplemented() }
    public func layoutData(for id: InputSourceID) -> KeyboardLayoutData? { unimplemented() }
    public func currentKeyboardType() -> UInt32 { unimplemented() }
    public func observeChanges(_ handler: @escaping @MainActor @Sendable () -> Void) -> any ObservationToken {
        unimplemented()
    }
}

@MainActor
public final class FakeWorkspaceEvents: WorkspaceEvents {
    public init() { unimplemented() }
    public func send(_ event: WorkspaceEvent) { unimplemented() }
    public func observe(_ handler: @escaping @MainActor @Sendable (WorkspaceEvent) -> Void) -> any ObservationToken {
        unimplemented()
    }
}

public final class FakeBundleInspector: BundleInspector, Sendable {
    public init(bundles: [URL: FakeBundle]) { unimplemented() }
    public struct FakeBundle: Sendable, Hashable {
        public var frameworks: [String]
        public var helpers: [String]
        public var files: [String]
        public var info: [String: JSONValue]
        public init(frameworks: [String], helpers: [String], files: [String], info: [String: JSONValue]) {
            self.frameworks = frameworks
            self.helpers = helpers
            self.files = files
            self.info = info
        }
    }

    public func frameworkNames(in bundle: URL) -> [String] { unimplemented() }
    public func helperAppNames(in bundle: URL) -> [String] { unimplemented() }
    public func containsFile(named name: String, in bundle: URL, maxDepth: Int) -> Bool { unimplemented() }
    public func infoDictionary(of bundle: URL) -> [String: JSONValue]? { unimplemented() }
}
