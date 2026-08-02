import Foundation
import Testing

@testable import WorkspaceLayout

/// Pins the three claims ``SessionStore/createDirectory(atPath:)``'s own doc
/// comment makes, ahead of ``ControlTransport`` losing its copy of the same walk
/// and calling this one instead.
@Suite final class DirectoryCreationTests {
    let fixture: DirectoryFixture

    init() throws {
        fixture = try DirectoryFixture()
    }

    @Test func aRelativePathIsRefused() {
        #expect(!SessionStore.createDirectory(atPath: "relative/path"))
    }

    @Test func eexistIsSuccessSoCallingItTwiceInARowSucceedsTwice() {
        let path = fixture.root.appending(path: "one/two").path(percentEncoded: false)

        #expect(SessionStore.createDirectory(atPath: path))
        #expect(SessionStore.createDirectory(atPath: path))
    }

    @Test func aComponentThatIsAlreadyARegularFileFailsWithEnotdirOnTheNextMkdir() throws {
        try fixture.file("blocked", contents: "not a directory")
        let path = fixture.root.appending(path: "blocked/child").path(percentEncoded: false)

        #expect(!SessionStore.createDirectory(atPath: path))
    }
}
