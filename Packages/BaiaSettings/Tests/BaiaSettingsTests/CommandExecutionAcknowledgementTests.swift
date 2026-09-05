import Foundation
import Testing

@testable import BaiaSettings

@Suite final class CommandExecutionAcknowledgementTests {
    let fixture: DirectoryFixture

    init() throws {
        fixture = try DirectoryFixture()
    }

    @Test func theDefaultPathSitsInTheInstallationsSupportDirectory() {
        // Beside `session.json` and `control.sock`, per build, so the Debug and
        // Release copies each ask once and a fresh installation asks again.
        let url = CommandExecutionAcknowledgement.defaultFileURL(directoryName: "baia-dev")
        #expect(url.path(percentEncoded: false).hasSuffix("/Application Support/baia-dev/command-execution.ack"))
    }

    @Test func aFreshInstallationIsNotAcknowledged() {
        let store = CommandExecutionAcknowledgement(fileURL: fixture.root.appending(path: "support/command-execution.ack"))
        #expect(!store.isAcknowledged)
    }

    @Test func recordingThenReadingRoundTrips() throws {
        let url = fixture.root.appending(path: "support/command-execution.ack")
        let store = CommandExecutionAcknowledgement(fileURL: url)
        #expect(store.record(at: Date(timeIntervalSince1970: 1_788_000_000)))
        #expect(store.isAcknowledged)
        #expect(try String(contentsOf: url, encoding: .utf8).hasPrefix("acknowledged 2026-"))
        #expect(store.revoke())
        #expect(!store.isAcknowledged)
    }

    @Test func aFileWithTheWrongContentDoesNotCount() throws {
        // An empty file, or one something else wrote, is not a confirmation the
        // owner gave. Only the marker this type writes reads back as one.
        let url = try fixture.file("command-execution.ack", contents: "")
        #expect(!CommandExecutionAcknowledgement(fileURL: url).isAcknowledged)
        try "yes".write(to: url, atomically: true, encoding: .utf8)
        #expect(!CommandExecutionAcknowledgement(fileURL: url).isAcknowledged)
    }

    @Test func theConfigFileCannotStandInForTheAcknowledgement() {
        // The two live in different files on purpose: a hand-edited
        // `controlAllowRun: true` decodes fine and still leaves this false.
        let result = SettingsDecoder.decode(Data("{\"controlAllowRun\": true}".utf8))
        #expect(result.settings.controlAllowRun)
        let store = CommandExecutionAcknowledgement(fileURL: fixture.root.appending(path: "command-execution.ack"))
        #expect(!store.isAcknowledged)
    }
}
