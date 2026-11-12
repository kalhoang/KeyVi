// SPDX-License-Identifier: LicenseRef-App-Pending

/// Semver-ish version for `match.appVersion` / `match.macOS` (02-platform.md 5.4) and diagnostics.
/// Parses leading dot-separated integers ("27.1", "155.0.7000.12", "1.0.0-beta.2" -> [1, 0, 0]) and compares
/// component-wise, missing components counting as zero.
public struct LooseVersion: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public let components: [Int]
    public let original: String

    public init?(_ string: String) {
        var parts: [Int] = []
        for piece in string.split(separator: ".", omittingEmptySubsequences: false) {
            let digits = piece.prefix { $0.isASCII && $0.isNumber }
            guard let value = Int(digits) else { break }
            parts.append(value)
            if digits.count != piece.count { break }
        }
        guard !parts.isEmpty else { return nil }
        components = parts
        original = string
    }

    public var description: String { original }

    public static func < (lhs: LooseVersion, rhs: LooseVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: LooseVersion, rhs: LooseVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
    public func hash(into hasher: inout Hasher) {
        var trimmed = components
        while trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let version = LooseVersion(raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad version"))
        }
        self = version
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(original)
    }
}

/// Inclusive version range (`{min, max}` in 02-platform.md 5.4). Either bound may be absent.
public struct VersionRange: Sendable, Hashable, Codable {
    public var min: LooseVersion?
    public var max: LooseVersion?
    public init(min: LooseVersion? = nil, max: LooseVersion? = nil) {
        self.min = min
        self.max = max
    }

    public func contains(_ version: LooseVersion) -> Bool {
        if let min, version < min { return false }
        if let max, max < version { return false }
        return true
    }
}
