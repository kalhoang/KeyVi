// SPDX-License-Identifier: GPL-3.0-or-later
//
// Production `BundleInspector` (PLT-R510): read-only, bounded FileManager listing of an app bundle on the ax
// thread. Results are cached by the focus tracker, so each bundle version is inspected once. Nothing here opens a
// file other than Info.plist, and no walk leaves the bundle (PLT-R384: the first fingerprint stays cheap).

public import AppModel
public import CompatRules
public import Foundation

public struct FileSystemBundleInspector: BundleInspector {
    /// Depth under `Contents/Frameworks` searched for nested helper apps (Chromium keeps them in
    /// `<Name> Framework.framework/Versions/<V>/Helpers/`).
    public static let helperSearchDepth = 5
    /// Upper bound on directory entries visited by one bounded search.
    public static let maximumEntries = 20_000

    let entryLimit: Int

    public init() { self.init(entryLimit: Self.maximumEntries) }

    init(entryLimit: Int) { self.entryLimit = max(0, entryLimit) }

    public func frameworkNames(in bundle: URL) -> [String] {
        guard let frameworks = Self.containedFolder(bundle.appendingPathComponent("Contents/Frameworks")) else {
            return []
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: frameworks.path)) ?? []
        return names.sorted()
    }

    public func helperAppNames(in bundle: URL) -> [String] {
        guard let frameworks = Self.containedFolder(bundle.appendingPathComponent("Contents/Frameworks")) else {
            return []
        }
        var names: [String] = []
        walk(frameworks, maxDepth: Self.helperSearchDepth) { url in
            guard url.pathExtension == "app" else { return .continue }
            names.append(url.lastPathComponent)
            return .skipDescendants
        }
        return names.sorted()
    }

    /// PLT-R510, PLT-R384: walks only `directory` (a folder inside the bundle chosen by the fingerprinter), at
    /// most `maxDepth` levels deep (1 = directly inside). False for a missing folder or one that is a link out
    /// of the bundle; linked folders inside the subtree are never entered. Entry names are compared, nothing is
    /// opened.
    public func containsFile(named name: String, in directory: URL, maxDepth: Int) -> Bool {
        guard let root = Self.containedFolder(directory) else { return false }
        var found = false
        walk(root, maxDepth: maxDepth) { url in
            guard url.lastPathComponent == name else { return .continue }
            found = true
            return .stop
        }
        return found
    }

    public func infoDictionary(of bundle: URL) -> [String: JSONValue]? {
        let url = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist.compactMapValues(Self.jsonValue)
    }

    enum Visit { case `continue`, skipDescendants, stop }

    /// Depth-first over real folders only: every entry of a listing is counted before any child folder is
    /// entered. The entry limit bounds the number of entries listed whatever order the file system lists in; a
    /// result near the limit can still depend on that order, because child folders are entered last-in first-out.
    /// Entries at depth `maxDepth` are visited but not entered; links to folders are visited, never entered.
    private func walk(_ root: URL, maxDepth: Int, _ body: (URL) -> Visit) {
        guard maxDepth > 0 else { return }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        var pending: [(url: URL, depth: Int)] = [(root, 0)]
        var visited = 0
        while let (folder, depth) = pending.popLast() {
            guard
                let children = try? FileManager.default.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            else { continue }
            for child in children {
                visited += 1
                guard visited <= entryLimit else { return }
                switch body(child) {
                case .stop: return
                case .skipDescendants: continue
                case .continue: break
                }
                if depth + 1 < maxDepth, Self.isRealFolder(child) { pending.append((child, depth + 1)) }
            }
        }
    }

    private static func isRealFolder(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    /// `directory` with links resolved, when it is an existing folder that stays inside its app bundle
    /// (PLT-R384). Without an enclosing bundle the folder itself is the boundary: a link is then not followed.
    static func containedFolder(_ directory: URL) -> URL? {
        let resolved = directory.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return nil }
        guard let boundary = bundleBoundary(of: directory) else {
            let isLink = (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
            return isLink ? nil : resolved
        }
        let limit = boundary.resolvingSymlinksInPath().path
        return resolved.path == limit || resolved.path.hasPrefix(limit + "/") ? resolved : nil
    }

    static let bundleExtensions: Set<String> = ["app", "framework", "xpc", "appex", "plugin", "bundle"]

    /// The outermost bundle around `url`: the folder holding the first `Contents` component whose parent has a
    /// bundle extension, so a `Contents` folder above the bundle does not widen the boundary (PLT-R384). Only
    /// when no such component exists does the first `Contents` decide.
    static func bundleBoundary(of url: URL) -> URL? {
        let components = url.standardizedFileURL.pathComponents
        let candidates = components.indices.filter { components[$0] == "Contents" && $0 >= 2 }
        let isBundle = { (index: Int) in
            bundleExtensions.contains((components[index - 1] as NSString).pathExtension.lowercased())
        }
        guard let index = candidates.first(where: isBundle) ?? candidates.first else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(components[..<index])), isDirectory: true)
    }

    static func jsonValue(_ value: Any) -> JSONValue? {
        switch value {
        case let string as String: return .string(string)
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let array as [Any]: return .array(array.compactMap(jsonValue))
        case let dictionary as [String: Any]: return .object(dictionary.compactMapValues(jsonValue))
        default: return nil
        }
    }
}
