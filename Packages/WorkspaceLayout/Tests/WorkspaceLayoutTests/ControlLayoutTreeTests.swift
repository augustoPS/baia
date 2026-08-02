import Foundation
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
}
