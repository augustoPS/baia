import Foundation
import Testing
@testable import BaiaSettings

@Suite struct SettingsPreservationTests {
    @Test func numericNoOpPreservesTheOriginalBytes() throws {
        let fixture = try DirectoryFixture()
        let original = "{ \"fontSize\" : 11.500 }"
        let url = try fixture.file("config.json", contents: original)
        _ = try SettingsStore(fileURL: url).patch([.fontSize(11.5)]).get()
        #expect(try String(contentsOf: url, encoding: .utf8) == original)
    }

    @Test func defaultValuedEditStillCreatesAMissingFile() throws {
        let fixture = try DirectoryFixture()
        let url = fixture.root.appending(path: "config.json")
        _ = try SettingsStore(fileURL: url).patch([.backgroundBlur(true)]).get()
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
    @Test(arguments: ["9007199254740993", "1e400", "-0", "1.234567890123456789"])
    func untouchedNumbersKeepTheirExactSpelling(_ number: String) throws {
        let fixture = try DirectoryFixture()
        let url = try fixture.file("config.json", contents: "{\"custom\":[\(number)]}")
        _ = try SettingsStore(fileURL: url).patch([.fontSize(18)]).get()
        #expect(try String(contentsOf: url, encoding: .utf8).contains("[\(number)]"))
    }

    @Test(arguments: ["{\"x\":+1}", "{\"x\":01}", "{\"x\":.5}", "{\"x\":1.}", "{\"x\":1e}", "{\"x\":\"raw\tcontrol\"}", "", " \n"])
    func malformedExistingDocumentsAreNeverRewritten(_ original: String) throws {
        let fixture = try DirectoryFixture()
        let url = try fixture.file("config.json", contents: original)
        let store = SettingsStore(fileURL: url)
        #expect(store.inspect() == .malformed)
        #expect(store.patch([.fontSize(18)]) == .failure(.malformed))
        #expect(try String(contentsOf: url, encoding: .utf8) == original)
    }
}
