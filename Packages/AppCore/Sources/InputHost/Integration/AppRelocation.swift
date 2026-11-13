// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PLT-R710: before any permission request the app must run from /Applications or ~/Applications and not be
// translocated; otherwise it offers to move itself and relaunch, and never requests permissions from the
// original location (a grant recorded for a temporary path does not follow the app). The location verdict
// comes from ShellCore's `AppLocationCheck`; the alert from the App. Workstream W2-A.

public import Foundation

/// File operations of the move. Production: FileManager in the App target; tests: an in-memory fake. Nothing
/// here ever deletes: replaced or original copies go to the Trash.
public protocol RelocationFileOperations: Sendable {
    func itemExists(at url: URL) -> Bool
    func copyItem(at source: URL, to destination: URL) throws
    func moveToTrash(_ url: URL) throws
    /// True when the item can be moved away (not translocated, not on a read-only volume such as a DMG).
    func isRemovable(_ url: URL) -> Bool
    /// Clears the download quarantine on the copied bundle, so the copy is not translocated again (the user
    /// confirmed the move; the app already passed Gatekeeper). VERIFY on current macOS.
    func clearQuarantine(at url: URL) throws
    /// True when the directory exists and this account may create items in it.
    func isWritableDirectory(_ url: URL) -> Bool
    /// Creates one directory (mode 0755); the parent exists.
    func createDirectory(at url: URL) throws
}

/// Launches the copy and ends this process. Production: `NSWorkspace.openApplication` then terminate.
@MainActor
public protocol AppRelauncher: AnyObject {
    func launch(_ bundleURL: URL) async throws
    func terminate()
}

public enum RelocationError: Error, Sendable, Hashable {
    case copyFailed
    case replaceFailed
    case launchFailed
}

/// Copies the bundle into the Applications folder (replacing an older copy by moving it to the Trash),
/// relaunches the copy and quits. The original goes to the Trash when it can be removed, so the user does not
/// keep launching the old copy.
@MainActor
public struct AppRelocator {
    public let files: any RelocationFileOperations
    public let relauncher: any AppRelauncher
    public let applicationsDirectory: URL

    public init(files: any RelocationFileOperations, relauncher: any AppRelauncher, applicationsDirectory: URL) {
        self.files = files
        self.relauncher = relauncher
        self.applicationsDirectory = applicationsDirectory
    }

    /// PLT-R710 accepts /Applications and ~/Applications. A standard (non-admin) account cannot write to
    /// /Applications, so the move would fail there; the user's own folder is the fallback.
    public static func applicationsDirectory(system: URL, user: URL, files: any RelocationFileOperations) -> URL {
        files.isWritableDirectory(system) ? system : user
    }

    public func destination(for bundleURL: URL) -> URL {
        applicationsDirectory.appendingPathComponent(bundleURL.lastPathComponent, isDirectory: true)
    }

    /// Returns the destination after the copy launched; this process should then quit. On failure nothing was
    /// launched and the original is untouched.
    public func relocate(_ bundleURL: URL) async -> Result<URL, RelocationError> {
        let target = destination(for: bundleURL)
        if !files.itemExists(at: applicationsDirectory) {
            do { try files.createDirectory(at: applicationsDirectory) } catch { return .failure(.copyFailed) }
        }
        if files.itemExists(at: target) {
            do { try files.moveToTrash(target) } catch { return .failure(.replaceFailed) }
        }
        do { try files.copyItem(at: bundleURL, to: target) } catch { return .failure(.copyFailed) }
        try? files.clearQuarantine(at: target)
        do { try await relauncher.launch(target) } catch { return .failure(.launchFailed) }
        if files.isRemovable(bundleURL) { try? files.moveToTrash(bundleURL) }
        return .success(target)
    }
}

/// The PLT-R710 gate: verdict, offer, move. Generic over the verdict's reason type (ShellCore's
/// `AppLocationCheck.Reason`), so this module does not depend on the shell.
@MainActor
public struct LocationGate<Reason: Sendable> {
    public enum Verdict: Sendable {
        case ok
        case mustMove(Reason)
    }

    public let verdict: @MainActor () -> Verdict
    /// Shows the move offer; true = "move and relaunch".
    public let offer: @MainActor (Reason) -> Bool
    /// Tells the user the move failed (the app then quits without asking for permissions).
    public let reportFailure: @MainActor (RelocationError) -> Void
    public let relocator: AppRelocator
    public let bundleURL: URL

    public init(
        verdict: @escaping @MainActor () -> Verdict, offer: @escaping @MainActor (Reason) -> Bool,
        reportFailure: @escaping @MainActor (RelocationError) -> Void, relocator: AppRelocator, bundleURL: URL
    ) {
        self.verdict = verdict
        self.offer = offer
        self.reportFailure = reportFailure
        self.relocator = relocator
        self.bundleURL = bundleURL
    }

    public func resolve() async -> LaunchLocationDecision {
        guard case .mustMove(let reason) = verdict() else { return .proceed }
        guard offer(reason) else { return .quit }
        switch await relocator.relocate(bundleURL) {
        case .success: return .relocating
        case .failure(let error):
            reportFailure(error)
            return .quit
        }
    }
}
