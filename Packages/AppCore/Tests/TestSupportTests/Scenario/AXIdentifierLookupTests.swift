// SPDX-License-Identifier: GPL-3.0-or-later
//
// The `ax` readback's lookup by identifier (PLT-R530, QA-R21) over a fake tree: what it finds is unchanged, and a miss
// names the first container read that failed, so a timed-out tree (-25204) tells itself from a tree without the
// element (VM run 20261119T005934Z, `testhost.sheet.commandS`).

import Testing

@testable import TestSupport

/// A node of a fake accessibility tree: its identifier read and its children read, each with an AXError code.
private final class Node {
    let identifier: AXAttributeRead<String>
    let children: AXAttributeRead<[Node]>

    init(_ identifier: String? = nil, code: Int32? = nil, children: [Node]? = nil, childrenCode: Int32? = nil) {
        self.identifier = AXAttributeRead(value: identifier, code: code ?? (identifier == nil ? Self.noValue : 0))
        self.children = AXAttributeRead(value: children, code: childrenCode ?? (children == nil ? Self.noValue : 0))
    }

    static let noValue: Int32 = -25212  // kAXErrorNoValue
    static let unsupported: Int32 = -25205  // kAXErrorAttributeUnsupported
    static let cannotComplete: Int32 = -25204  // kAXErrorCannotComplete, also a messaging timeout
    static let invalidElement: Int32 = -25202  // kAXErrorInvalidUIElement
}

private func lookup(_ identifier: String, in root: Node, maximumDepth: Int = 24) -> AXIdentifierLookup.Outcome<Node> {
    AXIdentifierLookup.find(
        identifier, in: root, maximumDepth: maximumDepth, identifierOf: \.identifier, childrenOf: \.children)
}

@Suite struct AXIdentifierLookupTests {
    @Test func findsTheElementDepthFirstAsBeforePltR530() throws {
        let mirror = Node("testhost.sheet.mirror")
        let window = Node(children: [Node("other"), Node(children: [mirror])])
        let outcome = lookup("testhost.sheet.mirror", in: Node(children: [window]))
        let found = try #require(outcome.found)
        #expect(found === mirror)
        #expect(outcome.firstFailure == nil)
    }

    /// Missing attributes are normal (most elements have no identifier, leaves have no children): no failure.
    @Test func aCleanTreeWithoutTheElementNamesNoFailurePltR530() {
        let tree = Node(
            children: [Node("a", children: []), Node(code: Node.unsupported, childrenCode: Node.unsupported)])
        let outcome = lookup("testhost.sheet.mirror", in: tree)
        #expect(outcome.found == nil && outcome.firstFailure == nil)
        #expect(
            AXIdentifierLookup.notFoundMessage("testhost.sheet.mirror", failure: outcome.firstFailure)
                == "no accessibility element with identifier testhost.sheet.mirror")
    }

    /// The miss of 20261119T005934Z as the walk sees a timed-out application: both reads of the root fail, and the
    /// first one is reported.
    @Test func aTimedOutApplicationIsNamedInTheMessagePltR530() {
        let app = Node(code: Node.cannotComplete, childrenCode: Node.cannotComplete)
        let outcome = lookup("testhost.sheet.mirror", in: app)
        let failure = AXIdentifierLookup.Failure(attribute: "AXIdentifier", depth: 0, code: Node.cannotComplete)
        #expect(outcome.found == nil && outcome.firstFailure == failure)
        #expect(
            AXIdentifierLookup.notFoundMessage("testhost.sheet.mirror", failure: outcome.firstFailure)
                == "no accessibility element with identifier testhost.sheet.mirror (AXIdentifier of AXApplication: "
                + "-25204)")
    }

    /// A container whose children cannot be read still prunes its subtree (what is found is unchanged); the first
    /// such failure in walk order is kept, deeper ones are named by depth.
    @Test func theFirstFailedContainerReadIsKeptPltR530() {
        let hidden = Node("testhost.sheet.mirror")
        let tree = Node(children: [
            Node(childrenCode: Node.cannotComplete), Node(children: [Node(childrenCode: Node.invalidElement)]),
            Node(children: [hidden], childrenCode: Node.cannotComplete),
        ])
        let outcome = lookup("testhost.sheet.mirror", in: tree)
        #expect(outcome.found == nil)
        #expect(outcome.firstFailure == .init(attribute: "AXChildren", depth: 1, code: Node.cannotComplete))
        #expect(outcome.firstFailure?.description == "AXChildren of an element at depth 1: -25204")
        let root = AXIdentifierLookup.Failure(attribute: "AXChildren", depth: 0, code: Node.cannotComplete)
        #expect(root.description == "AXChildren of AXApplication: -25204")
    }

    /// An element found after a failed read elsewhere is still found; the depth limit stops the walk as before.
    @Test func aFailureElsewhereDoesNotHideAnElementAndTheDepthLimitHoldsPltR530() throws {
        let mirror = Node("testhost.sheet.mirror")
        let tree = Node(children: [Node(childrenCode: Node.cannotComplete), Node(children: [mirror])])
        let found = try #require(lookup("testhost.sheet.mirror", in: tree).found)
        #expect(found === mirror)
        #expect(lookup("testhost.sheet.mirror", in: tree, maximumDepth: 1).found == nil)
    }
}
