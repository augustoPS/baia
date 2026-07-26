import Foundation
import Testing

@testable import BaiaSettings

@Suite final class SettingsStoreTests {
    let fixture: DirectoryFixture

    init() throws {
        fixture = try DirectoryFixture()
    }

    @Test func theDefaultFileSitsUnderTheUsersConfigDirectory() {
        // The path the owner has to be able to find and edit. It is also the one the
        // README documents, so a change here is a change to a document nobody would
        // think to update.
        #expect(SettingsStore.defaultFileURL().path(percentEncoded: false)
            == NSHomeDirectory() + "/.config/baia/config.json")
    }

    @Test func loadReturnsTheDefaultsWhenThereIsNoFile() {
        // The first-launch path. A missing file is not a failure and must not report
        // one, or every fresh install would open with an error about a file it was
        // never given.
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
        // Both cases end with the defaults applied, and only the flag distinguishes
        // "there is nothing to read" from "what you wrote cannot be read".
        let url = try fixture.file("config.json", contents: "not json at all")
        #expect(SettingsStore(fileURL: url).load().documentIsUnreadable)
    }

    @Test func writeDefaultIfAbsentCreatesTheFileAndTheDirectoriesAboveIt() {
        // `~/.config` need not exist on a fresh account, so a write that assumed the
        // parent directory would fail on exactly the machine this feature is for.
        let url = fixture.root.appending(path: "config/baia/config.json")
        let store = SettingsStore(fileURL: url)
        #expect(store.writeDefaultIfAbsent())
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    @Test func writeDefaultIfAbsentLeavesAnExistingFileAlone() throws {
        // The owner's own config is the thing this must never touch. It answers false
        // as well, so a caller cannot report having seeded a file it did not write.
        let url = try fixture.file("config.json", contents: #"{"fontSize": 20}"#)
        let store = SettingsStore(fileURL: url)
        #expect(!store.writeDefaultIfAbsent())
        #expect(store.load().settings.fontSize == 20)
    }

    @Test func theWrittenDefaultFileDecodesBackToTheDefaults() {
        // The file is a text literal rather than a serialization of
        // `defaultSettings`, so this is what stops the two from drifting apart. A
        // value edited in one place and not the other lands here.
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
        // the round trip above cannot see the omission. Reading the file back as JSON
        // is what pins "fully populated", which is the whole point of writing it:
        // the file is where the owner learns the key spellings.
        let url = fixture.root.appending(path: "config.json")
        #expect(SettingsStore(fileURL: url).writeDefaultIfAbsent())

        let data = FileManager.default.contents(atPath: url.path(percentEncoded: false)) ?? Data()
        var keys: Set<String> = []
        if case let .object(fields)? = JSONValue.parse(data) {
            keys = Set(fields.keys)
        }
        #expect(keys == [
            "fontFamily",
            "fontSize",
            "themeName",
            "backgroundHex",
            "backgroundOpacity",
            "backgroundBlur",
            "windowPadding",
            "windowPaddingBalance",
            "transparentTitlebar",
            "optionAsAlt",
            "cursorStyle",
            "projectRoots",
            "discoveryMaxDepth",
            "notificationsEnabled",
            "gitPollSeconds",
            "activityPollSeconds",
            "restoreSession",
            "focusStyle",
            "focusAccent",
            "attentionStyle",
            "unfocusedScrim",
        ])
    }

    @Test func theWrittenDefaultFileKeepsTheTildeItWasWrittenWith() throws {
        // The expanded home directory in the file would make it useless to copy
        // between machines, and the decoder expands it on every read anyway.
        let url = fixture.root.appending(path: "config.json")
        #expect(SettingsStore(fileURL: url).writeDefaultIfAbsent())

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("~/Projects"))
        #expect(!text.contains(NSHomeDirectory()))
    }

    @Test func theWrittenFileIsReadableOnlyByItsOwner() throws {
        // A config that gains a token or a remote host later starts private rather
        // than needing someone to remember to tighten it. Only the group and other
        // bits are asserted, because the umask can only remove bits from the 0o600
        // this asks for.
        let url = fixture.root.appending(path: "config.json")
        #expect(SettingsStore(fileURL: url).writeDefaultIfAbsent())

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        let permissions = attributes[.posixPermissions] as? Int
        #expect(permissions.map { $0 & 0o077 } == 0)
    }
}
