import Foundation
import Testing

@testable import WorkspaceLayout

@Suite final class SessionStoreTests {
    let fixture: DirectoryFixture

    init() throws {
        fixture = try DirectoryFixture()
    }

    /// A store writing into a directory that does not exist yet, which is what a
    /// first launch on a clean machine finds.
    private func store(_ path: String = "state/session.json") -> SessionStore {
        SessionStore(fileURL: fixture.root.appending(path: path))
    }

    /// Two panes in one tab, a zoom, a window frame, and one pane state each. Built
    /// by hand so a bug in ``Workspace``'s mutators cannot make a coding test pass.
    private func sampleSnapshot() -> SessionSnapshot {
        let first = PaneID()
        let second = PaneID()
        return SessionSnapshot(
            workspace: Workspace(
                tabs: [Tab(
                    id: UUID(),
                    tree: .split(axis: .vertical, ratio: 0.4, first: .leaf(first), second: .leaf(second)),
                    focusedPane: second,
                    zoomedPane: second
                )],
                focusedTabIndex: 0
            ),
            panes: [
                PaneState(
                    id: first,
                    workingDirectory: "/Users/x/Projects",
                    pinnedDirectory: nil,
                    createdBy: nil
                ),
                PaneState(
                    id: second,
                    workingDirectory: nil,
                    pinnedDirectory: "/Users/x/Projects/baia",
                    createdBy: nil
                ),
            ],
            windowFrame: WindowFrame(x: 8, y: 8, width: 1200, height: 800),
            sidebar: nil
        )
    }

    @Test func aSavedSessionLoadsBackUnchanged() {
        let snapshot = sampleSnapshot()
        let store = store()

        #expect(store.save(snapshot))
        #expect(store.load() == snapshot)
    }

    @Test func aPaneOpenedByAnotherPaneRemembersWhichOneAcrossASave() {
        var snapshot = sampleSnapshot()
        let parent = snapshot.panes[0].id
        snapshot.panes[1].createdBy = parent
        let store = store()

        #expect(store.save(snapshot))
        // Parentage is the one part of the control channel's graph that persists.
        // Tokens are minted per run and never written; this is an identifier, and
        // an owner asking where a pane came from needs it to survive a relaunch.
        #expect(store.load()?.panes[1].createdBy == parent)
    }

    /// The guarantee ``SessionSnapshot/currentSchemaVersion`` claims in its own doc
    /// comment, and the one thing a round trip cannot show.
    ///
    /// Written as a literal rather than encoded from a value, because every
    /// ``PaneState`` this build can construct already carries `createdBy`. Encoding
    /// one and decoding it back proves the field survives its own writer and says
    /// nothing about the file already sitting on the owner's disk, which is the file
    /// that decides whether the first launch after an upgrade restores his session
    /// or opens an empty window. Loaded through ``SessionStore`` rather than through
    /// a bare `JSONDecoder`, so the version gate is part of what is being asserted:
    /// adding an optional field must not need a bump, and a bump would send every
    /// pre-upgrade file to nil here.
    @Test func aSessionWrittenBeforeParentageExistedStillLoads() throws {
        let json = """
        {"schemaVersion":1,"workspace":{"tabs":[],"focusedTabIndex":0},\
        "panes":[{"id":{"rawValue":"3B1E9F6A-4C2D-4E8B-9A1F-7D5C0E2B8A64"},\
        "workingDirectory":"/Users/x/Projects"}]}
        """
        try fixture.file("state/session.json", contents: json)

        let loaded = store().load()
        #expect(loaded?.panes.count == 1)
        // Nil is exactly what "the version that wrote this file did not record a
        // parent" means, and it is also what a pane the owner opened by hand says.
        #expect(loaded?.panes.first?.createdBy == nil)
        #expect(loaded?.panes.first?.workingDirectory == "/Users/x/Projects")
    }

    @Test func loadFindsNothingWhenNoSessionWasEverWritten() {
        // A first launch, which is not an error: `contents(atPath:)` answering nil is
        // the whole reason this API is not `throws`.
        #expect(store().load() == nil)
    }

    @Test func loadFindsNothingInAFileThatIsNotJSON() throws {
        try fixture.file("state/session.json", contents: "half a { session")

        // A truncated file is what an in-place write plus a crash would leave, and the
        // caller can do nothing with the error beyond opening a fresh workspace.
        #expect(store().load() == nil)
    }

    @Test func loadRefusesASchemaVersionFromTheFuture() {
        var snapshot = sampleSnapshot()
        snapshot.schemaVersion = SessionSnapshot.currentSchemaVersion + 1
        let store = store()

        #expect(store.save(snapshot))

        // The fields all decode, so nothing but the version check can catch this. A
        // newer baia may mean something else by the same ratio or the same tree shape,
        // and the wrong workspace would be written back over the good file on quit.
        #expect(store.load() == nil)
    }

    @Test func loadRefusesASchemaVersionFromThePast() {
        var snapshot = sampleSnapshot()
        snapshot.schemaVersion = 0
        let store = store()

        #expect(store.save(snapshot))

        // No migration exists to run, and version 0 is also what a snapshot encoded
        // without the field at all would come back as.
        #expect(store.load() == nil)
    }

    @Test func saveCreatesTheDirectoriesAboveTheFile() throws {
        let store = SessionStore(fileURL: fixture.root.appending(path: "one/two/three/session.json"))

        #expect(store.save(sampleSnapshot()))

        // Application Support has no baia directory until the first save makes it, and
        // a save that reported success without writing anything would lose every
        // session silently.
        #expect(try fixture.entries("one/two/three") == ["session.json"])
    }

    @Test func saveLeavesNoTemporaryFileBesideTheSession() throws {
        let store = store()

        #expect(store.save(sampleSnapshot()))
        #expect(store.save(sampleSnapshot()))

        // The temporary is invisible to `load`, so the only way a leaked one shows up
        // is by reading the directory. Two saves in a row, because the second is the
        // one that finds a temporary already there.
        #expect(try fixture.entries("state") == ["session.json"])
    }

    @Test func savingASmallerSessionOverALargerOneLeavesNoTailBehind() {
        let store = store()
        var large = sampleSnapshot()
        large.workspace.addTab(pane: PaneID())
        large.workspace.addTab(pane: PaneID())
        let small = SessionSnapshot(
            workspace: Workspace(pane: PaneID()),
            panes: [],
            windowFrame: nil,
            sidebar: nil
        )

        #expect(store.save(large))
        #expect(store.save(small))

        // A write that opened the existing file without truncating would leave the tail
        // of the larger session past the end of the smaller one, and the trailing bytes
        // make the whole file undecodable.
        #expect(store.load() == small)
    }

    @Test func saveReportsFailureWhenAFileSitsWhereADirectoryHasToGo() throws {
        try fixture.file("state", contents: "not a directory")
        let store = store()

        // mkdir answers EEXIST for the file and the write below fails with ENOTDIR.
        // Reporting false is what lets the caller leave the old session alone rather
        // than believe it saved.
        #expect(!store.save(sampleSnapshot()))
    }

    @Test func theDefaultFileURLIsUnderApplicationSupport() {
        let path = SessionStore.defaultFileURL().path(percentEncoded: false)

        #expect(path.hasPrefix(NSHomeDirectory()))
        #expect(path.hasSuffix("/Library/Application Support/baia/session.json"))
    }
}

/// The sidebar's geometry, which was added to the snapshot without a schema bump.
@Suite struct SidebarGeometryPersistenceTests {
    private func snapshot(sidebar: SidebarGeometry?) -> SessionSnapshot {
        SessionSnapshot(
            workspace: Workspace(tabs: [], focusedTabIndex: 0),
            panes: [],
            windowFrame: nil,
            sidebar: sidebar
        )
    }

    @Test func aGeometryRoundTripsThroughTheFile() throws {
        let written = snapshot(sidebar: SidebarGeometry(width: 312, splitHeight: 140))
        let data = try JSONEncoder().encode(written)
        let read = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        #expect(read.sidebar?.width == 312)
        #expect(read.sidebar?.splitHeight == 140)
    }

    /// The reason no schema bump was needed. A file written before this field
    /// existed must still load, and nil is what "the previous version did not record
    /// this" means, which the defaults then answer.
    @Test func aFileWrittenBeforeTheFieldExistedStillLoads() throws {
        let json = """
        {"schemaVersion":1,"workspace":{"tabs":[],"focusedTabIndex":0},"panes":[]}
        """
        let read = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        #expect(read.sidebar == nil)
        #expect(read.schemaVersion == SessionSnapshot.currentSchemaVersion)
    }

    @Test func aSessionThatNeverOpenedASidebarWritesNothingForIt() throws {
        let data = try JSONEncoder().encode(snapshot(sidebar: nil))
        let read = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        #expect(read.sidebar == nil)
    }
}

/// Reconciliation rebuilds the snapshot field by field, so every field has to be
/// carried across by hand. This is the test for the one that was not.
@Suite struct ReconcileCarriesEveryFieldTests {
    private func snapshot() -> SessionSnapshot {
        let pane = PaneID()
        return SessionSnapshot(
            workspace: Workspace(pane: pane),
            panes: [PaneState(id: pane, workingDirectory: "/tmp", createdBy: nil)],
            windowFrame: WindowFrame(x: 1, y: 2, width: 3, height: 4),
            sidebar: SidebarGeometry(width: 462, splitHeight: 516)
        )
    }

    /// The bug this suite exists for: a sidebar dragged wide, quit, and relaunched
    /// into the default, because reconciliation dropped the field on the way through
    /// while the file on disk was perfectly correct.
    @Test func theSidebarGeometrySurvivesReconciliation() {
        let (reconciled, _) = SessionStore.reconciled(snapshot()) { _ in true }
        #expect(reconciled.sidebar?.width == 462)
        #expect(reconciled.sidebar?.splitHeight == 516)
    }

    @Test func theWindowFrameSurvivesReconciliation() {
        let (reconciled, _) = SessionStore.reconciled(snapshot()) { _ in true }
        #expect(reconciled.windowFrame?.width == 3)
    }

    /// Dropping every pane must not take the geometry with it. The window is gone
    /// and the column's size is still the owner's answer for the next one.
    @Test func theGeometrySurvivesEvenWhenEveryPaneIsDropped() {
        let (reconciled, dropped) = SessionStore.reconciled(snapshot()) { _ in false }
        #expect(!dropped.isEmpty)
        #expect(reconciled.sidebar?.width == 462)
    }
}
