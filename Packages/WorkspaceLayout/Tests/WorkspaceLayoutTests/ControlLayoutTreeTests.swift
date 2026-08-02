import Foundation
import PaneControl
import Testing

@testable import WorkspaceLayout

@Suite struct ControlLayoutTreeTests {
    @Test func anExistingDirectoryIsReturnedAsIs() throws {
        let fixture = try DirectoryFixture()
        let path = try fixture.directory("project").path(percentEncoded: false)
        #expect(PaneTree.existingDirectory(path) == path)
    }

    @Test func aMissingPathIsNil() throws {
        let fixture = try DirectoryFixture()
        let missing = fixture.root.appending(path: "nope").path(percentEncoded: false)
        #expect(PaneTree.existingDirectory(missing) == nil)
    }

    @Test func aFileRatherThanADirectoryIsNil() throws {
        let fixture = try DirectoryFixture()
        let path = try fixture.file("readme.txt", contents: "hi").path(percentEncoded: false)
        #expect(PaneTree.existingDirectory(path) == nil)
    }

    /// A split whose second child is itself a split, so a bug that nests the
    /// wrong side or swaps an axis at the second level (a tree builder "looks
    /// right and produces the wrong shape at depth two") shows up here rather
    /// than surviving on a one-level tree.
    @Test func aDepthTwoTreeKeepsEveryPaneInItsOwnPositionWithItsOwnState() throws {
        let fixture = try DirectoryFixture()
        let existingPath = try fixture.directory("project").path(percentEncoded: false)
        let missingPath = fixture.root.appending(path: "nope").path(percentEncoded: false)
        let parent = PaneID()

        let node = ControlLayoutNode.split(
            axis: .horizontal,
            ratio: 0.6,
            first: .pane(cwd: existingPath),
            second: .split(
                axis: .vertical,
                ratio: 0.3,
                first: .pane(cwd: nil),
                second: .pane(cwd: missingPath)
            )
        )

        var states: [PaneState] = []
        let tree = PaneTree.build(node, createdBy: parent, into: &states)

        #expect(states.count == 3)
        // Appended depth first, first child before second, which is the order
        // `PaneTree.paneIDs` reads back: a caller zipping the two arrays together
        // (as `applyLayout` does through `SessionSnapshot.panes`) needs them to
        // agree on order, not just on membership.
        #expect(tree.paneIDs == states.map(\.id))
        #expect(states.allSatisfy { $0.createdBy == parent })
        #expect(states.allSatisfy { $0.pinnedDirectory == nil })
        #expect(states[0].workingDirectory == existingPath)
        #expect(states[1].workingDirectory == nil)
        #expect(states[2].workingDirectory == nil)

        guard case let .split(outerAxis, outerRatio, outerFirst, outerSecond) = tree else {
            Issue.record("expected the root to be a split")
            return
        }
        #expect(outerAxis == .horizontal)
        #expect(outerRatio == 0.6)
        guard case let .leaf(firstID) = outerFirst else {
            Issue.record("expected the first child to be the existing-directory pane's leaf")
            return
        }
        #expect(firstID == states[0].id)

        guard case let .split(innerAxis, innerRatio, innerFirst, innerSecond) = outerSecond else {
            Issue.record("expected the second child to be the nested split")
            return
        }
        #expect(innerAxis == .vertical)
        #expect(innerRatio == 0.3)
        guard case let .leaf(secondID) = innerFirst else {
            Issue.record("expected the inner split's first child to be the nil-cwd pane's leaf")
            return
        }
        #expect(secondID == states[1].id)
        guard case let .leaf(thirdID) = innerSecond else {
            Issue.record("expected the inner split's second child to be the missing-path pane's leaf")
            return
        }
        #expect(thirdID == states[2].id)
    }
}
