// SPDX-License-Identifier: GPL-3.0-or-later
//
// The `ax` readback's lookup of a field by `AXIdentifier` (PLT-R530, QA-R21): a depth-first walk from the application
// element. A container whose `AXIdentifier` or `AXChildren` read fails is pruned, as before, but the first such
// failure is kept for the "not found" message, so a miss tells a tree that timed out (-25204,
// `kAXErrorCannotComplete`, which a messaging timeout returns) from a tree without the element (VM run
// 20261119T005934Z, `testhost.sheet.commandS`; integration-suite.md section 10.10). Pure, so it is tested over a fake
// tree; `CompatHarness/Live/LiveInput.swift` reads the real attributes.

/// One attribute read: its value (nil when absent, of another type, or the read failed) and the `AXError` raw value
/// (0 is success). A failed read never carries a value.
public struct AXAttributeRead<Value> {
    public var value: Value?
    public var code: Int32

    public init(value: Value?, code: Int32) {
        self.value = code == AXIdentifierLookup.success ? value : nil
        self.code = code
    }
}

public enum AXIdentifierLookup {
    /// `kAXErrorSuccess`.
    public static let success: Int32 = 0
    /// `kAXErrorAttributeUnsupported` and `kAXErrorNoValue`: the element has no such attribute (most elements have no
    /// identifier, leaves have no children), which is not a failed read.
    static let absent: Set<Int32> = [-25205, -25212]

    /// The first container read that failed during a walk.
    public struct Failure: Sendable, Hashable, CustomStringConvertible {
        /// `AXIdentifier` or `AXChildren`.
        public var attribute: String
        /// 0 for the application element the walk starts from.
        public var depth: Int
        public var code: Int32

        public init(attribute: String, depth: Int, code: Int32) {
            self.attribute = attribute
            self.depth = depth
            self.code = code
        }

        /// `AXChildren of AXApplication: -25204`; numbers and attribute names only, never a value (PLT-R901).
        public var description: String {
            let element = depth == 0 ? "AXApplication" : "an element at depth " + String(depth)
            return attribute + " of " + element + ": " + String(code)
        }
    }

    /// What one walk found, and the first container read that failed on the way (nil when none did).
    public struct Outcome<Element> {
        public var found: Element?
        public var firstFailure: Failure?
    }

    /// Depth-first search for `AXIdentifier == identifier` below `root`, at most `maximumDepth` levels down. What it
    /// finds is what the walk found before failures were kept: a failed `AXChildren` read prunes that subtree.
    public static func find<Element>(
        _ identifier: String, in root: Element, maximumDepth: Int,
        identifierOf: (Element) -> AXAttributeRead<String>, childrenOf: (Element) -> AXAttributeRead<[Element]>
    ) -> Outcome<Element> {
        var firstFailure: Failure?
        func note(_ read: Int32, _ attribute: String, _ depth: Int) {
            guard firstFailure == nil, read != success, !absent.contains(read) else { return }
            firstFailure = Failure(attribute: attribute, depth: depth, code: read)
        }
        func visit(_ element: Element, depth: Int) -> Element? {
            let own = identifierOf(element)
            if own.value == identifier { return element }
            note(own.code, "AXIdentifier", depth)
            guard depth < maximumDepth else { return nil }
            let children = childrenOf(element)
            note(children.code, "AXChildren", depth)
            for child in children.value ?? [] {
                if let found = visit(child, depth: depth + 1) { return found }
            }
            return nil
        }
        let found = visit(root, depth: 0)
        return Outcome(found: found, firstFailure: firstFailure)
    }

    /// The `elementNotFound` message, with the first failed container read when there was one:
    /// `no accessibility element with identifier testhost.sheet.mirror (AXChildren of AXApplication: -25204)`.
    public static func notFoundMessage(_ identifier: String, failure: Failure?) -> String {
        "no accessibility element with identifier " + identifier + (failure.map { " (" + $0.description + ")" } ?? "")
    }
}
