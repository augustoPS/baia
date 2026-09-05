import Foundation
import Testing

@testable import BaiaSettings

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
        #expect(contents == ["config.json"])
    }

    @Test func patchingTwiceWithTheSameValueProducesTheSameBytes() throws {
        let url = fixture.root.appending(path: "config.json")
        let store = SettingsStore(fileURL: url)
        _ = try store.patch([.fontSize(15)]).get()
        let first = try text(url)
        _ = try store.patch([.fontSize(15)]).get()
        #expect(try text(url) == first)
    }

    // MARK: - Repair

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
        // can be read and the sibling cannot be created. Nothing is replaced.
        let url = try fixture.file("locked/config.json", contents: "broken")
        let directory = url.deletingLastPathComponent().path(percentEncoded: false)
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
            .read, .malformed, .notAnObject, .directory, .backup, .temporaryWrite, .rename,
        ]
        for failure in failures {
            #expect(!failure.message.isEmpty)
        }
    }
}
