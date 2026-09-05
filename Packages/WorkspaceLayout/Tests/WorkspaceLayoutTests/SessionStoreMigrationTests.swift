import Foundation
import Testing

@testable import WorkspaceLayout

/// Reading a version 1 session file, and preserving it before the first version 2
/// write replaces it.
///
/// The documents here are written as literal JSON rather than encoded from a Swift
/// type. A fixture built by encoding today's types would only prove this build can
/// read itself; the question is whether it can read what an older build actually
/// wrote, so these are the bytes that build produced.
@Suite final class SessionStoreMigrationTests {
    let fixture: DirectoryFixture

    init() throws {
        fixture = try DirectoryFixture()
    }

    private func store(_ path: String = "state/session.json") -> SessionStore {
        SessionStore(fileURL: fixture.root.appending(path: path))
    }

    /// A version 1 document with two tabs, a frame, a sidebar and expansions: every
    /// field that build wrote, so nothing can be dropped unnoticed on the way across.
    private let v1 = """
    {"schemaVersion":1,\
    "workspace":{"tabs":[\
    {"id":"11111111-1111-1111-1111-111111111111",\
    "tree":{"leaf":{"_0":{"rawValue":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"}}},\
    "focusedPane":{"rawValue":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"}},\
    {"id":"22222222-2222-2222-2222-222222222222",\
    "tree":{"leaf":{"_0":{"rawValue":"BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"}}},\
    "focusedPane":{"rawValue":"BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"}}],\
    "focusedTabIndex":1},\
    "panes":[{"id":{"rawValue":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"},"workingDirectory":"/here"}],\
    "windowFrame":{"x":40,"y":60,"width":1440,"height":900},\
    "sidebar":{"width":312,"splitHeight":140},\
    "fileTreeExpansions":{"/repos/baia":["Sources"]}}
    """

    private let secondTabID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")

    // MARK: Reading version 1

    /// A version 1 file loads rather than being refused, which is the deliberate
    /// support for existing sessions: bumping the version must not throw away the
    /// workspace every current user already has on disk.
    @Test func aVersion1SessionLoadsInsteadOfBeingRejected() throws {
        try fixture.file("state/session.json", contents: v1)

        let loaded = store().inspect()

        guard case let .loaded(snapshot) = loaded else {
            Issue.record("version 1 was not loaded: \(loaded)")
            return
        }
        #expect(snapshot.schemaVersion == SessionSnapshot.currentSchemaVersion)
    }

    /// What the migration means: the flat tab list was one tab group, because that
    /// is what the app produced — every restored window was joined into a single
    /// group. One group at that frame is a reading of those bytes, not a guess.
    @Test func aVersion1SessionBecomesOneGroupAtItsRecordedFrame() throws {
        try fixture.file("state/session.json", contents: v1)

        let snapshot = try #require(store().load())

        #expect(snapshot.groups.count == 1)
        #expect(snapshot.groups[0].tabs.count == 2)
        #expect(snapshot.groups[0].frame == WindowFrame(x: 40, y: 60, width: 1440, height: 900))
        #expect(snapshot.activeGroup == snapshot.groups[0].id)
    }

    /// The old `focusedTabIndex` becomes the selection id of the tab it named, so a
    /// relaunch shows the tab the owner left showing rather than the first one.
    @Test func theOldFocusedTabIndexBecomesTheSelectedTabID() throws {
        try fixture.file("state/session.json", contents: v1)

        let snapshot = try #require(store().load())

        #expect(snapshot.groups[0].selectedTab == secondTabID)
        #expect(snapshot.groups[0].selected?.id == secondTabID)
    }

    /// Every other field crosses untouched. A migration that quietly dropped the
    /// sidebar would reproduce the exact bug ``SessionSnapshot``'s init comment
    /// records, one schema later.
    @Test func theSidebarPanesAndExpansionsCrossTheMigrationIntact() throws {
        try fixture.file("state/session.json", contents: v1)

        let snapshot = try #require(store().load())

        #expect(snapshot.groups[0].sidebar == SidebarGeometry(width: 312, splitHeight: 140))
        #expect(snapshot.fileTreeExpansions == ["/repos/baia": ["Sources"]])
        #expect(snapshot.panes.count == 1)
        #expect(snapshot.panes[0].workingDirectory == "/here")
    }

    /// A version 1 file with no tabs migrates to no groups, which `restoreSession`
    /// already treats as "open a fresh window" rather than as a failure.
    @Test func aVersion1SessionWithNoTabsMigratesToNoGroups() throws {
        try fixture.file(
            "state/session.json",
            contents: #"{"schemaVersion":1,"workspace":{"tabs":[],"focusedTabIndex":0},"panes":[]}"#
        )

        let snapshot = try #require(store().load())

        #expect(snapshot.groups.isEmpty)
        #expect(snapshot.activeGroup == nil)
    }

    /// An out-of-range index in a version 1 file selects a tab that exists, matching
    /// the clamp reconciliation already applied to it.
    @Test func anOutOfRangeVersion1IndexStillSelectsARealTab() throws {
        try fixture.file(
            "state/session.json",
            contents: v1.replacingOccurrences(of: "\"focusedTabIndex\":1", with: "\"focusedTabIndex\":9")
        )

        let snapshot = try #require(store().load())

        #expect(snapshot.groups[0].selected != nil)
        #expect(snapshot.groups[0].selectedTab == secondTabID)
    }

    // MARK: What is still refused

    /// Version 0 and every version above what this build writes are still refused
    /// whole. Only the one older shape this build can reconstruct exactly is read.
    @Test func aVersionBelowTheOldestReadableIsStillRefused() throws {
        try fixture.file("state/session.json", contents: #"{"schemaVersion":0,"panes":[]}"#)

        #expect(store().inspect() == .rejected(.unsupportedSchema(0)))
    }

    @Test func aVersionFromTheFutureIsStillRefused() throws {
        try fixture.file("state/session.json", contents: #"{"schemaVersion":3,"groups":[]}"#)

        #expect(store().inspect() == .rejected(.unsupportedSchema(3)))
    }

    /// A file claiming version 1 whose body is not a version 1 document is malformed
    /// rather than migrated. The version is a claim about the shape, and a claim
    /// that does not hold is not a licence to guess.
    @Test func aVersion1ClaimOverGarbageIsMalformedRatherThanMigrated() throws {
        try fixture.file("state/session.json", contents: #"{"schemaVersion":1,"workspace":"not an object"}"#)

        #expect(store().inspect() == .rejected(.malformed))
    }

    // MARK: The backup before the first version 2 write

    /// **The migration's own preservation rule.** The first write after reading a
    /// version 1 file copies those exact bytes aside before replacing them, so a
    /// downgrade still has the document it understands.
    @Test func theFirstWriteAfterAMigrationBacksUpTheVersion1Bytes() throws {
        try fixture.file("state/session.json", contents: v1)
        let store = store()
        let snapshot = try #require(store.load())

        #expect(store.saveResult(snapshot) == .saved)

        let backup = try String(contentsOf: store.migrationBackupURL(), encoding: .utf8)
        #expect(backup == v1)
        // And the target really was replaced, so the backup is not standing in for a
        // write that never happened.
        let written = try String(contentsOf: fixture.root.appending(path: "state/session.json"), encoding: .utf8)
        #expect(written.contains("\"schemaVersion\":2"))
        #expect(written.contains("\"groups\""))
    }

    /// A migration that cannot preserve what it came from does not overwrite it.
    /// The version 1 document is still at the target, byte for byte, afterwards.
    ///
    /// The directory refuses the write, so no name in the series can be created.
    /// That is the one shape that is not recoverable by trying another name.
    @Test func aWriteIsRefusedWhenNoMigrationBackupCanBeCreated() throws {
        try fixture.file("state/session.json", contents: v1)
        let store = store()
        let snapshot = try #require(store.load())
        let directory = fixture.root.appending(path: "state").path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory) }

        #expect(store.saveResult(snapshot) == .migrationBackupFailed)
        #expect(store.verifiedMigrationBackupURL == nil)

        let untouched = try String(contentsOf: fixture.root.appending(path: "state/session.json"), encoding: .utf8)
        #expect(untouched == v1)
    }

    /// **The downgrade cycle the backup exists for.** This build migrates and backs
    /// up bytes A. An older build then refuses the version 2 file and, through R01's
    /// recovery, writes a fresh version 1 document B. Back on this build, B migrates
    /// too, and its backup must land beside A rather than being refused because A
    /// is in the way. A fixed name refused every save from here on.
    @Test func aSecondMigrationAfterADowngradeBacksUpToANumberedSibling() throws {
        try fixture.file("state/session.json", contents: v1)
        let first = store()
        #expect(first.saveResult(try #require(first.load())) == .saved)
        #expect(first.verifiedMigrationBackupURL == first.migrationBackupURL())

        // What the older build leaves behind: version 1 again, different bytes.
        let later = v1.replacingOccurrences(of: "\"focusedTabIndex\":1", with: "\"focusedTabIndex\":0")
        try fixture.file("state/session.json", contents: later)
        let second = store()

        #expect(second.saveResult(try #require(second.load())) == .saved)

        #expect(second.verifiedMigrationBackupURL == second.migrationBackupURL(attempt: 2))
        #expect(try String(contentsOf: second.migrationBackupURL(), encoding: .utf8) == v1)
        #expect(try String(contentsOf: second.migrationBackupURL(attempt: 2), encoding: .utf8) == later)
        let written = try String(contentsOf: fixture.root.appending(path: "state/session.json"), encoding: .utf8)
        #expect(written.contains("\"schemaVersion\":2"))
    }

    /// Every earlier backup in the series is left exactly as it was. Three cycles
    /// produce three siblings, each holding the bytes of its own migration.
    @Test func eachMigrationInTheSeriesKeepsEveryEarlierBackupIntact() throws {
        let documents = [
            v1,
            v1.replacingOccurrences(of: "\"focusedTabIndex\":1", with: "\"focusedTabIndex\":0"),
            v1.replacingOccurrences(of: "\"width\":312", with: "\"width\":400"),
        ]
        for document in documents {
            try fixture.file("state/session.json", contents: document)
            let store = store()
            #expect(store.saveResult(try #require(store.load())) == .saved)
        }

        let reader = store()
        for (index, document) in documents.enumerated() {
            let backup = reader.migrationBackupURL(attempt: index + 1)
            #expect(try String(contentsOf: backup, encoding: .utf8) == document)
        }
        #expect(!FileManager.default.fileExists(
            atPath: reader.migrationBackupURL(attempt: 4).path(percentEncoded: false)
        ))
    }

    /// A file at the first name that this store did not write is never written
    /// through, and is never taken as the backup either: the bytes go to the next
    /// name, and the foreign file is untouched.
    @Test func aForeignFileAtTheBackupNameIsSkippedAndLeftAlone() throws {
        try fixture.file("state/session.json", contents: v1)
        try fixture.file("state/session.json.v1-backup", contents: "not a session at all")
        let store = store()
        let snapshot = try #require(store.load())

        #expect(store.saveResult(snapshot) == .saved)

        #expect(store.verifiedMigrationBackupURL == store.migrationBackupURL(attempt: 2))
        #expect(try String(contentsOf: store.migrationBackupURL(), encoding: .utf8) == "not a session at all")
        #expect(try String(contentsOf: store.migrationBackupURL(attempt: 2), encoding: .utf8) == v1)
    }

    /// A directory at the first name is a foreign entry like any other: skipped for
    /// the next name rather than refusing the write.
    @Test func aDirectoryAtTheBackupNameIsSkippedForTheNextOne() throws {
        try fixture.file("state/session.json", contents: v1)
        try fixture.directory("state/session.json.v1-backup")
        let store = store()
        let snapshot = try #require(store.load())

        #expect(store.saveResult(snapshot) == .saved)

        #expect(store.verifiedMigrationBackupURL == store.migrationBackupURL(attempt: 2))
        #expect(try String(contentsOf: store.migrationBackupURL(attempt: 2), encoding: .utf8) == v1)
    }

    /// The series is bounded. With every name taken by other bytes, the write is
    /// refused and the version 1 document stays at the target, rather than the
    /// store scanning a directory full of files it did not write.
    @Test func anExhaustedBackupSeriesRefusesTheWriteAndLeavesTheSourceAlone() throws {
        try fixture.file("state/session.json", contents: v1)
        let store = store()
        for attempt in 1 ... SessionStore.migrationBackupAttempts {
            try fixture.file(
                "state/" + store.migrationBackupURL(attempt: attempt).lastPathComponent,
                contents: "occupied \(attempt)"
            )
        }
        let snapshot = try #require(store.load())

        #expect(store.saveResult(snapshot) == .migrationBackupFailed)

        let untouched = try String(contentsOf: fixture.root.appending(path: "state/session.json"), encoding: .utf8)
        #expect(untouched == v1)
        #expect(try String(contentsOf: store.migrationBackupURL(attempt: 1), encoding: .utf8) == "occupied 1")
        #expect(try String(contentsOf: store.migrationBackupURL(attempt: SessionStore.migrationBackupAttempts), encoding: .utf8)
            == "occupied \(SessionStore.migrationBackupAttempts)")
    }

    /// The second save does not back up again. The file at the target is version 2
    /// by then, and copying it over the preserved version 1 document would destroy
    /// the only thing the backup exists for.
    @Test func aSecondSaveDoesNotOverwriteTheMigrationBackup() throws {
        try fixture.file("state/session.json", contents: v1)
        let store = store()
        let snapshot = try #require(store.load())

        #expect(store.saveResult(snapshot) == .saved)
        #expect(store.saveResult(snapshot) == .saved)

        let backup = try String(contentsOf: store.migrationBackupURL(), encoding: .utf8)
        #expect(backup == v1)
        #expect(!FileManager.default.fileExists(
            atPath: store.migrationBackupURL(attempt: 2).path(percentEncoded: false)
        ))
    }

    /// A session that was already version 2 writes no backup at all: there is no
    /// older document to preserve, and a stray file beside the session would read as
    /// one.
    @Test func aVersion2SessionWritesNoMigrationBackup() throws {
        let store = store()
        let snapshot = SessionSnapshot(
            groups: [WindowGroup(tab: Tab(pane: PaneID()))],
            activeGroup: nil,
            panes: [],
            fileTreeExpansions: nil
        )

        #expect(store.saveResult(snapshot) == .saved)

        #expect(!FileManager.default.fileExists(
            atPath: store.migrationBackupURL().path(percentEncoded: false)
        ))
    }

    /// The migration backup is a separate concern from R01's rejection backup, and
    /// arming one must not arm the other. A migrated file is loaded, not rejected,
    /// so recovery has nothing to do.
    @Test func aMigratedSessionIsNotTreatedAsARejectedOne() throws {
        try fixture.file("state/session.json", contents: v1)
        let store = store()
        let snapshot = try #require(store.load())

        #expect(store.recover(replacingWith: snapshot) == .notRejected)
        #expect(store.saveResult(snapshot) == .saved)
    }

    /// R01's gate is unchanged by any of this: a rejected file still blocks every
    /// automatic save, and a migration cannot be a way past it.
    @Test func aRejectedFileStillBlocksSavesAfterTheMigrationPathExists() throws {
        try fixture.file("state/session.json", contents: "not json at all")
        let store = store()

        #expect(store.inspect() == .rejected(.malformed))

        let snapshot = SessionSnapshot(
            groups: [WindowGroup(tab: Tab(pane: PaneID()))],
            activeGroup: nil,
            panes: [],
            fileTreeExpansions: nil
        )
        #expect(store.saveResult(snapshot) == .blocked(.malformed))
        let untouched = try String(contentsOf: fixture.root.appending(path: "state/session.json"), encoding: .utf8)
        #expect(untouched == "not json at all")
    }

    /// A migrated session that round trips through the store comes back as the
    /// groups it migrated into, so the write is of the new shape and not of a
    /// re-encoded old one.
    @Test func aMigratedSessionReloadsAsGroupsFromDisk() throws {
        try fixture.file("state/session.json", contents: v1)
        let first = store()
        let migrated = try #require(first.load())
        #expect(first.saveResult(migrated) == .saved)

        // A second store over the same path, so the answer comes from the bytes
        // rather than from anything the first one is still holding.
        let reread = try #require(store().load())

        #expect(reread == migrated)
        #expect(reread.groups.count == 1)
        #expect(reread.groups[0].selectedTab == secondTabID)
    }

    /// **The whole restore path, which the test above stops one call short of.**
    ///
    /// `restoreSession` does not hand `load()`'s result straight on: it passes it
    /// through ``SessionStore/reconciled(_:directoryExists:resolveAnchor:)`` first,
    /// and that rebuilds the snapshot field by field. So a migrated session crosses
    /// two steps before anything about it reaches disk again, and the tests above
    /// cover only the first. This covers both together, which is what an owner
    /// launching this build over an existing version 1 file actually goes through.
    ///
    /// The version is what it asserts, since the groups are already covered by
    /// `aMigratedSessionReloadsAsGroupsFromDisk`. It comes out as version 2 because
    /// ``SessionSnapshot/migrating(_:)`` stamps the current version when it builds
    /// the migrated value, and reconciliation carries that forward: the propagation
    /// is what keeps a snapshot describing itself as whatever it was decoded as,
    /// which for every supported path is the current version already.
    @Test func aReconciledMigratedSessionIsWrittenAsTheCurrentSchema() throws {
        try fixture.file("state/session.json", contents: v1)
        let first = store()
        let migrated = try #require(first.load())

        let (reconciled, _) = SessionStore.reconciled(
            migrated,
            directoryExists: { _ in true },
            resolveAnchor: { $0.workingDirectory }
        )

        #expect(reconciled.schemaVersion == SessionSnapshot.currentSchemaVersion)

        #expect(first.saveResult(reconciled) == .saved)
        let written = try String(
            contentsOf: fixture.root.appending(path: "state/session.json"),
            encoding: .utf8
        )
        #expect(written.contains("\"schemaVersion\":2"))
        #expect(written.contains("\"groups\""))

        // Read back rather than only inspected as text, so the round trip is closed
        // by the decoder that will actually meet these bytes on the next launch.
        let reread = try #require(store().load())
        #expect(reread.schemaVersion == SessionSnapshot.currentSchemaVersion)
        #expect(reread.groups.count == 1)
    }
}
