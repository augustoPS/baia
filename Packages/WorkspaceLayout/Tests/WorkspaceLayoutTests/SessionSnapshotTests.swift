import Foundation
import Testing

@testable import WorkspaceLayout

@Suite struct SessionSnapshotTests {
    /// A tree four levels deep, mixing both axes and four different ratios.
    ///
    /// Depth is the point: the synthesized `Codable` for an indirect enum nests one
    /// container per level, and a shallow tree would round trip even if the
    /// recursion were wrong.
    private func deepTree(_ ids: [PaneID]) -> PaneTree {
        .split(
            axis: .horizontal,
            ratio: 0.3,
            first: .leaf(ids[0]),
            second: .split(
                axis: .vertical,
                ratio: 0.6,
                first: .split(
                    axis: .horizontal,
                    ratio: 0.45,
                    first: .leaf(ids[1]),
                    second: .split(axis: .vertical, ratio: 0.8, first: .leaf(ids[2]), second: .leaf(ids[3]))
                ),
                second: .leaf(ids[4])
            )
        )
    }

    @Test func aTreeFourLevelsDeepSurvivesAJSONRoundTrip() throws {
        let ids = [PaneID(), PaneID(), PaneID(), PaneID(), PaneID()]
        let tree = deepTree(ids)

        let data = try JSONEncoder().encode(tree)
        let decoded = try JSONDecoder().decode(PaneTree.self, from: data)

        #expect(decoded == tree)
        #expect(decoded.paneIDs == ids)
    }

    @Test func aWholeSnapshotSurvivesAJSONRoundTrip() throws {
        let ids = [PaneID(), PaneID(), PaneID(), PaneID(), PaneID()]
        let snapshot = SessionSnapshot(
            workspace: Workspace(
                tabs: [
                    Tab(id: UUID(), tree: deepTree(ids), focusedPane: ids[3], zoomedPane: ids[3]),
                    Tab(pane: PaneID()),
                ],
                focusedTabIndex: 1
            ),
            panes: [PaneState(id: ids[0], workingDirectory: "/Users/x/Projects", pinnedDirectory: "/Users/x")],
            windowFrame: WindowFrame(x: -12.5, y: 33, width: 1680, height: 1050),
            sidebar: nil
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)

        #expect(decoded == snapshot)
    }

    @Test func aSnapshotWithNoWindowFrameSurvivesAJSONRoundTrip() throws {
        // The optional field is the one a synthesized encoder can drop entirely, and a
        // decoder that then demanded it would fail on the first session written before
        // the window had ever been placed.
        let snapshot = SessionSnapshot(
            workspace: Workspace(pane: PaneID()),
            panes: [],
            windowFrame: nil,
            sidebar: nil
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)

        #expect(decoded == snapshot)
        #expect(decoded.windowFrame == nil)
    }

    @Test func theEncodedAxisIsTheWordAndNotAnEmptyObject() throws {
        let tree = PaneTree.split(
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(PaneID()),
            second: .leaf(PaneID())
        )

        let json = String(decoding: try JSONEncoder().encode(tree), as: UTF8.self)

        // What the `String` raw value on ``SplitAxis`` buys. Without it the compiler
        // writes `{"horizontal":{}}` for a case with no associated values, which is
        // unreadable in a file the owner is expected to open while debugging a layout.
        #expect(json.contains("\"axis\":\"horizontal\""))
    }

    @Test func theSchemaVersionIsWrittenIntoTheFile() throws {
        let snapshot = SessionSnapshot(workspace: Workspace(pane: PaneID()), panes: [], windowFrame: nil, sidebar: nil)

        let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)

        // The gate `SessionStore.load` reads. A snapshot encoded without it would load
        // back with a zero version and be refused, which would look like a corrupt file.
        #expect(json.contains("\"schemaVersion\":1"))
        #expect(SessionSnapshot.currentSchemaVersion == 1)
    }

    @Test func aDraggedRatioSurvivesTheFileAndComesBackAtThePathItWasSetOn() throws {
        let a = PaneID()
        let b = PaneID()
        let c = PaneID()
        var workspace = Workspace(
            tabs: [Tab(
                id: UUID(),
                tree: .split(
                    axis: .horizontal,
                    ratio: 0.5,
                    first: .leaf(a),
                    second: .split(axis: .vertical, ratio: 0.5, first: .leaf(b), second: .leaf(c))
                ),
                focusedPane: a,
                zoomedPane: nil
            )],
            focusedTabIndex: 0
        )
        let dragged = workspace.setRatio(at: SplitPath([1]), to: 0.32)
        #expect(dragged)

        let snapshot = SessionSnapshot(workspace: workspace, panes: [], windowFrame: nil, sidebar: nil)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: JSONEncoder().encode(snapshot))

        // The whole point of writing a drag into the model rather than leaving it in
        // the split view: every ratio in the owner's live session file was exactly
        // 0.5, which was on-disk proof that no drag had ever reached the model. This
        // is that proof inverted.
        #expect(decoded.workspace.tabs[0].tree.ratio(at: SplitPath([1])) == 0.32)
        #expect(decoded.workspace.tabs[0].tree.ratio(at: SplitPath()) == 0.5)
        #expect(decoded == snapshot)
    }

    @Test func aRatioOfZeroThatSurvivedTheFileStillLaysOutTwoPanes() throws {
        let first = PaneID()
        let second = PaneID()
        let tree = PaneTree.split(axis: .horizontal, ratio: 0, first: .leaf(first), second: .leaf(second))

        let decoded = try JSONDecoder().decode(PaneTree.self, from: JSONEncoder().encode(tree))
        let placed = decoded.layout(in: .unit)

        // The stored value comes back as it was written, ratio and all: clamping on
        // decode would need a hand-written `init(from:)`. The clamp lives where the
        // number becomes a rect, which is the only place it has to hold.
        #expect(decoded == tree)
        #expect(placed.allSatisfy { $0.rect.width >= 0.05 })
    }

    @Test func aRatioOfOneThatSurvivedTheFileStillLaysOutTwoPanes() throws {
        let first = PaneID()
        let second = PaneID()
        let tree = PaneTree.split(axis: .vertical, ratio: 1, first: .leaf(first), second: .leaf(second))

        let decoded = try JSONDecoder().decode(PaneTree.self, from: JSONEncoder().encode(tree))
        let placed = decoded.layout(in: .unit)

        #expect(placed.allSatisfy { $0.rect.height >= 0.05 })
    }
}
