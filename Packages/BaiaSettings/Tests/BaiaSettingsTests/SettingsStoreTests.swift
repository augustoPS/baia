import Darwin
import Foundation
import Testing

@testable import BaiaSettings

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    init(_ value: Value? = nil) {
        stored = value
    }

    func set(_ value: Value) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    func get() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

@Suite final class SettingsStoreTests {
    let fixture: DirectoryFixture

    init() throws {
        fixture = try DirectoryFixture()
    }

    private func text(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func keys(_ url: URL) -> Set<String> {
        let data = FileManager.default.contents(atPath: url.path(percentEncoded: false)) ?? Data()
        if case let .object(fields)? = JSONValue.parse(data) {
            return Set(fields.keys)
        }
        return []
    }

    /// Every name in the fixture root, for asserting what an operation did and
    /// did not leave beside the file.
    private func names() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path(percentEncoded: false)))
    }

    /// Holds the store's write lock for the whole of `body`, exactly as another
    /// cooperating process would. Acquired before `body` starts, so nothing in
    /// it can observe a moment when the lock was free.
    private func holdingWriteLock<Value>(
        named fileName: String = "config.json",
        _ body: () throws -> Value
    ) throws -> Value {
        let lockPath = fixture.root.appending(path: ".\(fileName).lock").path(percentEncoded: false)
        let descriptor = open(lockPath, O_RDWR | O_CREAT, 0o600)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        try #require(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// Runs `operation` on another thread and answers its outcome and elapsed
    /// time, or nil when it had not returned after ten seconds. That watchdog
    /// is the upper bound on a refusal: it is wide enough that scheduling
    /// noise cannot reach it, and an operation that never gives up on a held
    /// lock fails here instead of hanging the suite.
    private func awaitingOutcome<Value>(
        _ operation: @escaping @Sendable () -> Value
    ) -> (outcome: Value?, elapsed: TimeInterval) {
        let box = LockedBox<Value>()
        let group = DispatchGroup()
        let started = Date()
        group.enter()
        DispatchQueue.global().async {
            box.set(operation())
            group.leave()
        }
        let finished = group.wait(timeout: .now() + 10) == .success
        return (finished ? box.get() : nil, Date().timeIntervalSince(started))
    }

    @Test func theDefaultFileSitsUnderTheUsersConfigDirectory() {
        #expect(SettingsStore.defaultFileURL().path(percentEncoded: false)
            == NSHomeDirectory() + "/.config/baia/config.json")
    }

    @Test func loadReturnsTheDefaultsWhenThereIsNoFile() {
        let store = SettingsStore(fileURL: fixture.root.appending(path: "absent.json"))
        let result = store.load()
        #expect(result.settings == .defaultSettings)
        #expect(!result.documentIsUnreadable)
        #expect(result.invalidKeys.isEmpty)
    }

    @Test func loadReadsTheFileFromDisk() throws {
        let url = try fixture.file("config.json", contents: #"{"fontSize": 20}"#)
        #expect(SettingsStore(fileURL: url).load().settings.fontSize == 20)
    }

    @Test func loadReportsABrokenFileRatherThanPretendingItIsAbsent() throws {
        let url = try fixture.file("config.json", contents: "not json at all")
        #expect(SettingsStore(fileURL: url).load().documentIsUnreadable)
    }

    // MARK: - Inspecting

    @Test func inspectTellsTheFiveStatesApart() throws {
        // Each state gets its own word in front of the owner, and only the first
        // two accept an ordinary write. The unreadable case is a directory at the
        // path, which `contents(atPath:)` answers nil for.
        #expect(SettingsStore(fileURL: fixture.root.appending(path: "absent.json")).inspect() == .missing)
        #expect(SettingsStore(fileURL: try fixture.file("blank.json", contents: " \n\t")).inspect() == .malformed)
        #expect(SettingsStore(fileURL: try fixture.file("ok.json", contents: "{}")).inspect() == .valid)
        #expect(SettingsStore(fileURL: try fixture.file("bad.json", contents: "{ broken")).inspect() == .malformed)
        #expect(SettingsStore(fileURL: try fixture.file("list.json", contents: "[1, 2]")).inspect() == .notAnObject)
        let directory = fixture.root.appending(path: "dir.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(SettingsStore(fileURL: directory).inspect() == .unreadable)
    }

    // MARK: - The default file

    @Test func writeDefaultIfAbsentCreatesTheFileAndTheDirectoriesAboveIt() {
        let url = fixture.root.appending(path: "config/baia/config.json")
        let store = SettingsStore(fileURL: url)
        #expect(store.writeDefaultIfAbsent())
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    @Test func writeDefaultIfAbsentLeavesAnExistingFileAlone() throws {
        let url = try fixture.file("config.json", contents: #"{"fontSize": 20}"#)
        let store = SettingsStore(fileURL: url)
        #expect(!store.writeDefaultIfAbsent())
        #expect(store.load().settings.fontSize == 20)
    }

    @Test func theWrittenDefaultFileDecodesBackToTheDefaults() {
        let url = fixture.root.appending(path: "config.json")
        let store = SettingsStore(fileURL: url)
        #expect(store.writeDefaultIfAbsent())

        let result = store.load()
        #expect(result.settings == .defaultSettings)
        #expect(result.unknownKeys.isEmpty)
        #expect(result.invalidKeys.isEmpty)
        #expect(!result.documentIsUnreadable)
    }

    @Test func theWrittenDefaultFileNamesEveryKeyTheDecoderReads() {
        // A default file that omitted a key would still decode to the defaults, so
        // the round trip above cannot see the omission. Compared against
        // `SettingsDecoder.knownKeys` and not against a literal written here.
        let url = fixture.root.appending(path: "config.json")
        #expect(SettingsStore(fileURL: url).writeDefaultIfAbsent())
        #expect(keys(url) == SettingsDecoder.knownKeys)
    }

    @Test func theWrittenDefaultFileKeepsTheTildeItWasWrittenWith() throws {
        let url = fixture.root.appending(path: "config.json")
        #expect(SettingsStore(fileURL: url).writeDefaultIfAbsent())
        let text = try text(url)
        #expect(text.contains("~/Projects"))
        #expect(!text.contains(NSHomeDirectory()))
    }

    @Test func theWrittenFileIsReadableOnlyByItsOwner() throws {
        let url = fixture.root.appending(path: "config.json")
        #expect(SettingsStore(fileURL: url).writeDefaultIfAbsent())
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        let permissions = attributes[.posixPermissions] as? Int
        #expect(permissions.map { $0 & 0o077 } == 0)
    }

    // MARK: - Patching

    @Test func patchingWritesTheOneKeyAndAnswersWhatTheFileNowDecodesTo() throws {
        let url = fixture.root.appending(path: "config.json")
        let store = SettingsStore(fileURL: url)
        #expect(store.writeDefaultIfAbsent())

        let result = try store.patch([.themeName("Midnight")]).get()
        #expect(result.settings.themeName == "Midnight")
        #expect(result.invalidKeys.isEmpty)
        #expect(store.load().settings.themeName == "Midnight")
        #expect(keys(url) == SettingsDecoder.knownKeys)
    }

    @Test func patchingPreservesUnrelatedAndUnknownMembersAndTheTilde() throws {
        // The audit's S2 fixture, inverted into the expectation. The file was
        // edited by hand between the window opening and the write, and the write
        // carries that edit through because it never held a copy of the field.
        let url = try fixture.file("config.json", contents: """
        {"fontSize": 11, "backgroundHex": "#abcdef", "projectRoots": ["~/keep"], "ownersOwnKey": {"nested": true}}
        """)
        let store = SettingsStore(fileURL: url)
        _ = try store.patch([.fontSize(15)]).get()

        let text = try text(url)
        #expect(text.contains("\"fontSize\": 15"))
        #expect(text.contains("\"backgroundHex\": \"#abcdef\""))
        #expect(text.contains("\"projectRoots\": [\"~/keep\"]"))
        #expect(text.contains("\"ownersOwnKey\""))
        #expect(!text.contains(NSHomeDirectory()))
        // Four members in, four out: nothing was filled in from the defaults.
        #expect(keys(url) == ["fontSize", "backgroundHex", "projectRoots", "ownersOwnKey"])
    }

    @Test func patchingAMissingFileStartsFromTheStandardDocument() throws {
        // A first write on a fresh account leaves the owner the same fully
        // populated file a launch would have, with the one edit in it.
        let url = fixture.root.appending(path: "nested/deeper/config.json")
        let store = SettingsStore(fileURL: url)
        _ = try store.patch([.fontSize(15)]).get()
        #expect(keys(url) == SettingsDecoder.knownKeys)
        #expect(store.load().settings.fontSize == 15)
        #expect(try text(url).contains("\"projectRoots\": [\"~/Projects\"]"))
    }

    @Test func patchingABlankFileRefusesToReplaceIt() throws {
        let url = try fixture.file("config.json", contents: "\n")
        #expect(SettingsStore(fileURL: url).patch([.fontSize(15)]) == .failure(.malformed))
        #expect(try text(url) == "\n")
    }

    @Test func patchingRefusesAnInvalidEditAndWritesNothing() throws {
        // The audit's S3: the old writer reported success for `not-a-colour` and
        // the decoder rejected it on reload. Validation now sits in front of the
        // write, and the file's bytes do not move.
        let url = try fixture.file("config.json", contents: #"{"fontSize": 11}"#)
        let before = try text(url)
        let outcome = SettingsStore(fileURL: url).patch([.backgroundHex("not-a-colour")])
        guard case let .failure(.validation(error)) = outcome else {
            Issue.record("the invalid edit was not refused as a validation failure")
            return
        }
        #expect(error.key == .backgroundHex)
        #expect(try text(url) == before)
    }

    @Test func patchingRefusesAMalformedFileAndKeepsItsBytes() throws {
        // The audit's S4, inverted: the original bytes and the custom roots
        // inside them survive, because the store refuses rather than starting
        // over from an empty object.
        let url = try fixture.file("config.json", contents: #"{"projectRoots":["~/precious"], broken"#)
        let before = try text(url)
        #expect(SettingsStore(fileURL: url).patch([.fontSize(15)]) == .failure(.malformed))
        #expect(try text(url) == before)
    }

    @Test func patchingRefusesANonObjectFileAndKeepsItsBytes() throws {
        let url = try fixture.file("config.json", contents: "[\"~/precious\"]")
        let before = try text(url)
        #expect(SettingsStore(fileURL: url).patch([.fontSize(15)]) == .failure(.notAnObject))
        #expect(try text(url) == before)
    }

    @Test func patchingRefusesAnUnreadableFile() throws {
        let directory = fixture.root.appending(path: "config.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(SettingsStore(fileURL: directory).patch([.fontSize(15)]) == .failure(.read))
    }

    @Test func patchingReportsADirectoryItCannotCreate() throws {
        // A file where the directory should be. `mkdir` answers EEXIST for it,
        // which is not a directory, and the temporary write then fails.
        let blocker = try fixture.file("blocker", contents: "x")
        let store = SettingsStore(fileURL: blocker.appending(path: "config.json"))
        let outcome = store.patch([.fontSize(15)])
        #expect(outcome == .failure(.temporaryWrite) || outcome == .failure(.directory))
    }

    @Test func patchingLeavesNoTemporaryFileBehind() throws {
        let url = fixture.root.appending(path: "config.json")
        _ = try SettingsStore(fileURL: url).patch([.fontSize(15)]).get()
        let contents = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path(percentEncoded: false))
        #expect(!contents.contains { $0.hasSuffix(".tmp") })
        #expect(Set(contents) == ["config.json", ".config.json.lock"])
    }

    @Test func patchingTwiceWithTheSameValueProducesTheSameBytes() throws {
        let url = fixture.root.appending(path: "config.json")
        let store = SettingsStore(fileURL: url)
        _ = try store.patch([.fontSize(15)]).get()
        let first = try text(url)
        _ = try store.patch([.fontSize(15)]).get()
        #expect(try text(url) == first)
    }

    @Test func simultaneousStoreInstancesKeepBothDisjointEdits() throws {
        // A missing cross-process lock lets both calls read the same revision,
        // then the last rename silently discards the other successful edit.
        let payload = String(repeating: "x", count: 2 * 1_024 * 1_024)
        let url = try fixture.file("config.json", contents: """
        {"fontSize":11.5,"notificationsEnabled":true,"unknownNumber":1.234567890123456789,"payload":"\(payload)"}
        """)
        let ready = DispatchSemaphore(value: 0)
        let start = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let outcomes = [
            LockedBox<Result<SettingsDecodeResult, SettingsWriteFailure>>(),
            LockedBox<Result<SettingsDecodeResult, SettingsWriteFailure>>(),
        ]
        let edits: [SettingsEdit] = [.fontSize(20), .notificationsEnabled(false)]

        for index in edits.indices {
            let edit = edits[index]
            let outcome = outcomes[index]
            group.enter()
            DispatchQueue.global().async {
                ready.signal()
                start.wait()
                outcome.set(SettingsStore(fileURL: url).patch([edit]))
                group.leave()
            }
        }
        ready.wait()
        ready.wait()
        start.signal()
        start.signal()
        #expect(group.wait(timeout: .now() + 10) == .success)
        #expect(outcomes.allSatisfy { outcome in
            guard case .success? = outcome.get() else { return false }
            return true
        })

        let final = try text(url)
        let decoded = SettingsStore(fileURL: url).load().settings
        #expect(decoded.fontSize == 20)
        #expect(!decoded.notificationsEnabled)
        #expect(final.contains("1.234567890123456789"))
    }

    @Test func anExternalWriteDuringStagingIsMergedByRetryingFromTheNewBytes() throws {
        // The non-cooperating write lands after the candidate is staged and
        // before the generation check, through the store's own seam rather than
        // by racing a large fixture. The first attempt must notice, and the
        // retry must read the new bytes and land on them.
        let url = try fixture.file("config.json", contents: #"{"fontSize":11.5,"externalKey":"before"}"#)
        let external = #"{"fontSize":11.5,"externalKey":"after","unknownNumber":1.234567890123456789}"#
        let attempts = LockedBox<Int>(0)
        let store = SettingsStore(fileURL: url, afterStaging: {
            let count = (attempts.get() ?? 0) + 1
            attempts.set(count)
            if count == 1 { try? Data(external.utf8).write(to: url) }
        })

        let result = try store.patch([.fontSize(20)]).get()

        #expect(attempts.get() == 2)
        #expect(result.settings.fontSize == 20)
        let final = try text(url)
        #expect(final.contains(#""externalKey": "after""#))
        #expect(final.contains("1.234567890123456789"))
        #expect(try names() == ["config.json", ".config.json.lock"])
    }

    @Test func aWriterThatKeepsChangingTheFileIsRefusedAfterThreeAttempts() throws {
        // Every attempt finds a newer generation. The store stops after three,
        // answers `.conflict`, leaves the other writer's last document in place
        // and removes every stage it made.
        let url = try fixture.file("config.json", contents: #"{"fontSize":11.5}"#)
        let attempts = LockedBox<Int>(0)
        let store = SettingsStore(fileURL: url, afterStaging: {
            let count = (attempts.get() ?? 0) + 1
            attempts.set(count)
            try? Data(#"{"fontSize":11.5,"revision":\#(count)}"#.utf8).write(to: url)
        })

        #expect(store.patch([.fontSize(20)]) == .failure(.conflict))
        #expect(attempts.get() == 3)
        #expect(try text(url) == #"{"fontSize":11.5,"revision":3}"#)
        #expect(try names() == ["config.json", ".config.json.lock"])
    }

    @Test func patchingReportsALockFileItCannotOpen() throws {
        let url = try fixture.file("config.json", contents: "{}")
        let lockURL = fixture.root.appending(path: ".config.json.lock")
        try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: true)
        #expect(SettingsStore(fileURL: url).patch([.fontSize(20)]) == .failure(.lock))
    }

    @Test func patchingRefusesBoundedLockContention() throws {
        let url = try fixture.file("config.json", contents: "{}")
        let (outcome, elapsed) = try holdingWriteLock {
            awaitingOutcome { SettingsStore(fileURL: url).patch([.fontSize(20)]) }
        }

        // The lock was held for the whole call, so the only way out was to stop
        // waiting. Fifty 10 ms polls take at least half a second by `usleep`'s
        // contract, which is the lower bound; the watchdog in `awaitingOutcome`
        // is the upper one. No assertion sits close enough to either for
        // scheduling noise to reach it.
        #expect(outcome == .failure(.busy))
        #expect(elapsed >= 0.4)
        #expect(try text(url) == "{}")
        #expect(try names() == ["config.json", ".config.json.lock"])

        // Released, the same call lands: the refusal was the lock and nothing else.
        _ = try SettingsStore(fileURL: url).patch([.fontSize(20)]).get()
        #expect(SettingsStore(fileURL: url).load().settings.fontSize == 20)
    }

    @Test func canonicalFileAliasesContendOnOneLock() throws {
        let realURL = try fixture.file("config.json", contents: "{}")
        let aliasURL = fixture.root.appending(path: "alias.json")
        try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: realURL)

        let store = SettingsStore(fileURL: aliasURL)
        #expect(store.url == realURL)
        let (outcome, _) = try holdingWriteLock {
            awaitingOutcome { store.patch([.fontSize(20)]) }
        }
        #expect(outcome == .failure(.busy))
        #expect(try text(realURL) == "{}")
    }

    @Test func relativeAndCaseAliasesUseTheCanonicalLockIdentity() throws {
        let realURL = try fixture.file("config.json", contents: "{}")
        let relativeURL = fixture.root.appending(path: "nested/../config.json")
        #expect(SettingsStore(fileURL: relativeURL).url == realURL)

        let caseAlias = fixture.root.appending(path: "CONFIG.JSON")
        let (outcome, _) = try holdingWriteLock {
            awaitingOutcome { SettingsStore(fileURL: caseAlias).patch([.fontSize(20)]) }
        }
        #expect(outcome == .failure(.busy))
        #expect(try text(realURL) == "{}")
    }

    @Test func aStaleLegacyTemporaryIsNeverReusedOrRemoved() throws {
        let url = try fixture.file("config.json", contents: "{}")
        let stale = fixture.root.appending(path: ".config.json.\(getpid()).tmp")
        try "belongs to an interrupted writer".write(to: stale, atomically: false, encoding: .utf8)

        _ = try SettingsStore(fileURL: url).patch([.fontSize(20)]).get()

        #expect(try text(stale) == "belongs to an interrupted writer")
        #expect(SettingsStore(fileURL: url).load().settings.fontSize == 20)
    }

    @Test func aDanglingConfigLinkIsUnreadableAndIsLeftExactlyAsFound() throws {
        // A dotfiles link whose target has gone. Treating it as missing would
        // make every write a false `.conflict` (the generation check sees the
        // link where it expects nothing), and creating the target or replacing
        // the link would each decide something for the owner. It is unreadable,
        // every writer refuses, and the link is left alone.
        let target = fixture.root.appending(path: "dotfiles/config.json").path(percentEncoded: false)
        let link = fixture.root.appending(path: "config.json")
        try FileManager.default.createSymbolicLink(atPath: link.path(percentEncoded: false), withDestinationPath: target)
        let store = SettingsStore(fileURL: link)

        #expect(store.inspect() == .unreadable)
        #expect(store.load().settings == .defaultSettings)
        #expect(store.writeDefaultIfAbsent() == false)
        #expect(store.patch([.fontSize(20)]) == .failure(.read))
        #expect(store.repair(with: .defaultSettings) == .failure(.read))

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path(percentEncoded: false)) == target)
        #expect(!FileManager.default.fileExists(atPath: target))
        #expect(try names() == ["config.json", ".config.json.lock"])
    }

    // MARK: - Repair

    @Test func repairUsesTheSameBoundedWriteLockAsPatch() throws {
        let url = try fixture.file("config.json", contents: "broken")
        let (outcome, elapsed) = try holdingWriteLock {
            awaitingOutcome { SettingsStore(fileURL: url).repair(with: .defaultSettings) }
        }

        // Same bounds as the patch case: the lock never let go, so the refusal
        // came from the store giving up, no earlier than its polls allow and
        // well inside the watchdog. Nothing was backed up, staged or replaced.
        #expect(outcome == .failure(.busy))
        #expect(elapsed >= 0.4)
        #expect(try text(url) == "broken")
        #expect(try names() == ["config.json", ".config.json.lock"])

        // Released, the same repair lands.
        let receipt = try SettingsStore(fileURL: url).repair(with: .defaultSettings).get()
        #expect(try text(receipt.backupURL) == "broken")
        #expect(SettingsStore(fileURL: url).inspect() == .valid)
    }

    @Test func repairRefusesAnExternalEditThatDoesNotMatchItsBackupAndKeepsTheBackup() throws {
        let original = #"{"projectRoots":["~/precious"], broken"#
        let url = try fixture.file("config.json", contents: original)
        let external = #"{"fontSize":31,"externalKey":"newer"}"#
        let store = SettingsStore(fileURL: url, afterStaging: {
            try? Data(external.utf8).write(to: url)
        })

        #expect(store.repair(with: .defaultSettings) == .failure(.conflict))
        #expect(try text(url) == external)

        // The backup was written before the check and stays: it is the only
        // copy of the bytes the other writer replaced. A refused repair has no
        // receipt to name it, so it is found by its name beside the config.
        // The stage is gone.
        let backups = try names().filter { $0.hasPrefix("config.json.backup-") }
        #expect(backups.count == 1)
        for name in backups {
            #expect(try text(fixture.root.appending(path: name)) == original)
        }
        #expect(try names().subtracting(backups) == ["config.json", ".config.json.lock"])
    }

    @Test func aPatchArrivingWhileRepairHoldsTheLockLandsOnTheRepairedDocument() throws {
        let url = try fixture.file("config.json", contents: #"{"fontSize":11.5,"themeName":"Before"}"#)
        var replacement = Settings.defaultSettings
        replacement.themeName = "Repaired"
        let repaired = replacement
        let patchOutcome = LockedBox<Result<SettingsDecodeResult, SettingsWriteFailure>>()
        let patchFinished = DispatchGroup()
        patchFinished.enter()

        // The patch starts while repair holds the lock with its candidate
        // already staged, so it cannot run first: it waits on the lock, or at
        // worst arrives just after the release. Either way the repaired
        // document must end up carrying the patch, which is only possible if
        // the patch read the repaired bytes.
        let store = SettingsStore(fileURL: url, afterStaging: {
            DispatchQueue.global().async {
                patchOutcome.set(SettingsStore(fileURL: url).patch([.fontSize(20)]))
                patchFinished.leave()
            }
        })
        let receipt = try store.repair(with: repaired).get()
        #expect(receipt.result.settings.themeName == "Repaired")
        #expect(patchFinished.wait(timeout: .now() + 10) == .success)

        if case let .failure(failure)? = patchOutcome.get() {
            Issue.record("the patch did not land: \(failure)")
        }
        let final = SettingsStore(fileURL: url).load().settings
        #expect(final.themeName == "Repaired")
        #expect(final.fontSize == 20)
    }

    @Test func repairBacksUpTheOriginalBytesBeforeWritingAReplacement() throws {
        let original = #"{"projectRoots":["~/precious"], broken"#
        let url = try fixture.file("config.json", contents: original)
        let store = SettingsStore(fileURL: url)
        var settings = Settings.defaultSettings
        settings.themeName = "Midnight"

        let stamp = Date(timeIntervalSince1970: 1_788_000_000)
        let receipt = try store.repair(with: settings, at: stamp).get()

        #expect(receipt.backupURL.deletingLastPathComponent() == url.deletingLastPathComponent())
        #expect(receipt.backupURL.lastPathComponent.hasPrefix("config.json.backup-"))
        #expect(receipt.backupURL.lastPathComponent.contains(SettingsStore.backupTimestamp(stamp)))
        #expect(try text(receipt.backupURL) == original)
        #expect(receipt.result.settings.themeName == "Midnight")
        #expect(store.inspect() == .valid)
        #expect(store.load().settings.themeName == "Midnight")
        #expect(keys(url) == SettingsDecoder.knownKeys)
    }

    @Test func theBackupTimestampHasNoColons() {
        // A colon in a file name reads as a path separator in Finder.
        let stamp = SettingsStore.backupTimestamp(Date(timeIntervalSince1970: 1_788_000_000))
        #expect(!stamp.contains(":"))
        #expect(stamp.hasSuffix("Z"))
    }

    @Test func twoRepairsInOneSecondKeepBothBackups() throws {
        let url = try fixture.file("config.json", contents: "first broken")
        let store = SettingsStore(fileURL: url)
        let stamp = Date(timeIntervalSince1970: 1_788_000_000)
        let one = try store.repair(with: .defaultSettings, at: stamp).get()
        try "second broken".write(to: url, atomically: true, encoding: .utf8)
        let two = try store.repair(with: .defaultSettings, at: stamp).get()
        #expect(one.backupURL != two.backupURL)
        #expect(try text(one.backupURL) == "first broken")
        #expect(try text(two.backupURL) == "second broken")
    }

    @Test func repairAbortsWhenTheBackupCannotBeWritten() throws {
        // The directory is made read-only after the file exists, so the original
        // and its already-created write lock can be opened, but the backup
        // sibling cannot be created. Nothing is replaced.
        let url = try fixture.file("locked/config.json", contents: "broken")
        let directory = url.deletingLastPathComponent().path(percentEncoded: false)
        let lockURL = url.deletingLastPathComponent().appending(path: ".config.json.lock")
        #expect(FileManager.default.createFile(atPath: lockURL.path(percentEncoded: false), contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory) }

        #expect(SettingsStore(fileURL: url).repair(with: .defaultSettings) == .failure(.backup))
        #expect(try text(url) == "broken")
    }

    @Test func repairRefusesAMissingOrUnreadableFile() throws {
        #expect(SettingsStore(fileURL: fixture.root.appending(path: "absent.json"))
            .repair(with: .defaultSettings) == .failure(.read))
        let directory = fixture.root.appending(path: "dir.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(SettingsStore(fileURL: directory).repair(with: .defaultSettings) == .failure(.read))
    }

    @Test func everyFailureHasAMessage() {
        let failures: [SettingsWriteFailure] = [
            .validation(SettingsValidationError(key: .fontSize, message: "x")),
            .read, .malformed, .notAnObject, .directory, .lock, .busy, .conflict,
            .backup, .temporaryWrite, .rename,
        ]
        for failure in failures {
            #expect(!failure.message.isEmpty)
        }
    }
}
