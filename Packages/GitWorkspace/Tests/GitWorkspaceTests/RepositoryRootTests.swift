import Foundation
import Testing

@testable import GitWorkspace

/// The identity that makes two panes on one repository one observation.
///
/// Every trap here is one the hub already recorded: a trailing separator, a
/// `directoryHint`, a symlink spelling, and `/private` against `/tmp`.
@Suite final class RepositoryRootTests {
    let fixture: DirectoryFixture

    init() throws {
        fixture = try DirectoryFixture()
    }

    @Test func trailingSeparatorAndDirectoryHintSpellingsAreOneRoot() throws {
        let directory = try fixture.directory("repo")
        let path = directory.path(percentEncoded: false)

        let plain = RepositoryRoot(URL(filePath: path))
        let hinted = RepositoryRoot(URL(filePath: path, directoryHint: .isDirectory))
        let trailing = RepositoryRoot(URL(filePath: path + "/"))
        let doubled = RepositoryRoot(URL(filePath: path + "//"))

        #expect(plain == hinted)
        #expect(plain == trailing)
        #expect(plain == doubled)
        #expect(Set([plain, hinted, trailing, doubled]).count == 1)
        // The caller's spelling, used for display and the pane's shell, carries
        // no trailing separator whichever way it arrived.
        #expect(plain.path == trailing.path)
        #expect(!trailing.path.hasSuffix("/"))
    }

    @Test func aSymlinkSpellingIsTheSameRootAndKeepsItsOwnPath() throws {
        let real = try fixture.directory("real")
        let link = fixture.root.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let direct = RepositoryRoot(real)
        let viaLink = RepositoryRoot(link)

        #expect(direct == viaLink)
        // Identity collapses; the path a shell or a display sees does not. A pane
        // anchored through the link keeps running under the link.
        #expect(viaLink.path == link.path(percentEncoded: false))
        #expect(direct.path == real.path(percentEncoded: false))
        #expect(viaLink.identity == direct.identity)
        #expect(RepositoryRoot(viaLink.processURL) == direct)
        #expect(viaLink.processURL != viaLink.url)
    }

    /// The process URL is captured when the root is made. Deleting or retargeting
    /// the alias must not change it, or a later `git -C` would follow the new
    /// spelling into a different directory.
    @Test func processURLSurvivesAliasDeletionAndRetarget() throws {
        let original = try fixture.directory("original")
        let other = try fixture.directory("other")
        let link = fixture.root.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)

        let viaLink = RepositoryRoot(link)
        let originalRoot = RepositoryRoot(original)
        #expect(RepositoryRoot(viaLink.processURL) == originalRoot)
        #expect(viaLink.path == link.path(percentEncoded: false))

        try FileManager.default.removeItem(at: link)
        #expect(RepositoryRoot(viaLink.processURL) == originalRoot)
        #expect(viaLink.path == link.path(percentEncoded: false))
        #expect(RepositoryRoot(link).identity == RepositoryRoot(link).path)

        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        #expect(RepositoryRoot(viaLink.processURL) == originalRoot)
        #expect(RepositoryRoot(link) == RepositoryRoot(other))
        #expect(viaLink != RepositoryRoot(link))
    }

    @Test func privateAndTmpSpellingsAreOneRootWhenTheDirectoryExists() throws {
        let directory = try fixture.directory("shared")
        let resolved = directory.path(percentEncoded: false)
        // The fixture root is already symlink-resolved. Whichever of `/tmp` and
        // `/private/tmp` it spells, the other spelling must agree.
        let alternative: String
        if resolved.hasPrefix("/private/") {
            alternative = String(resolved.dropFirst("/private".count))
        } else if resolved.hasPrefix("/tmp/") || resolved.hasPrefix("/var/") {
            alternative = "/private" + resolved
        } else {
            return
        }
        guard FileManager.default.fileExists(atPath: alternative) else { return }

        #expect(RepositoryRoot(URL(filePath: alternative)) == RepositoryRoot(directory))
    }

    @Test func differentDirectoriesAreDifferentRoots() throws {
        let one = try fixture.directory("one")
        let two = try fixture.directory("two")

        #expect(RepositoryRoot(one) != RepositoryRoot(two))
    }

    @Test func aPathThatDoesNotExistYetIsStillARoot() {
        let missing = fixture.root.appending(path: "not/yet/here")

        let root = RepositoryRoot(missing)

        #expect(root.path == missing.path(percentEncoded: false))
        #expect(root == RepositoryRoot(URL(filePath: root.path + "/")))
    }
}
