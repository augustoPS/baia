import Foundation
import Testing

@testable import GitWorkspace

@Suite final class DirectoryTreeTests {
    let fixture: DirectoryFixture

    init() throws {
        fixture = try DirectoryFixture()
    }

    @Test func directoriesComeBeforeFilesAndEachGroupSortsByName() throws {
        // The same order `FileTree` produces, so a pane that moves between a
        // repository and a plain directory does not also change how its list is
        // arranged.
        _ = try fixture.file("plain/b.txt")
        _ = try fixture.file("plain/a.txt")
        _ = try fixture.directory("plain/zebra")
        _ = try fixture.file("plain/zebra/kept.txt")
        _ = try fixture.directory("plain/apple")
        _ = try fixture.file("plain/apple/kept.txt")

        let tree = DirectoryTree.tree(at: fixture.root.appending(path: "plain"))
        #expect(tree.map(\.name) == ["apple", "zebra", "a.txt", "b.txt"])
        #expect(tree.map(\.isDirectory) == [true, true, false, false])
    }

    @Test func namesSortCaseInsensitively() throws {
        // `FileTree` sorts this way because a list where Apple comes before apple
        // but after Zebra reads as unsorted.
        _ = try fixture.file("plain/Zebra.txt")
        _ = try fixture.file("plain/apple.txt")
        _ = try fixture.file("plain/Banana.txt")

        let tree = DirectoryTree.tree(at: fixture.root.appending(path: "plain"))
        #expect(tree.map(\.name) == ["apple.txt", "Banana.txt", "Zebra.txt"])
    }

    @Test func dotfilesAreOmitted() throws {
        _ = try fixture.file("plain/visible.txt")
        _ = try fixture.file("plain/.hidden")
        _ = try fixture.directory("plain/.git")
        _ = try fixture.file("plain/.git/config")

        let tree = DirectoryTree.tree(at: fixture.root.appending(path: "plain"))
        #expect(tree.map(\.name) == ["visible.txt"])
    }

    @Test func pathsAreRelativeToTheRootTheWalkStartedAt() throws {
        // `FileTreeNode.path` is relative to the repository root for the git tree,
        // and the click handler puts that path on the prompt. A walk that emitted
        // absolute paths would put a different kind of string there depending on
        // which side of a repository boundary the pane sat.
        _ = try fixture.file("plain/nested/deep/file.txt")

        let tree = DirectoryTree.tree(at: fixture.root.appending(path: "plain"))
        let nested = try #require(tree.first { $0.name == "nested" })
        let deep = try #require(nested.children.first { $0.name == "deep" })
        let file = try #require(deep.children.first)
        #expect(nested.path == "nested")
        #expect(deep.path == "nested/deep")
        #expect(file.path == "nested/deep/file.txt")
    }

    @Test func theDepthCapStopsTheDescent() throws {
        _ = try fixture.file("plain/one/two/three/four/deep.txt")

        let tree = DirectoryTree.tree(at: fixture.root.appending(path: "plain"), maxDepth: 2)
        let one = try #require(tree.first)
        let two = try #require(one.children.first)
        #expect(one.name == "one")
        #expect(two.name == "two")
        // Depth 2 is reached, so `two` is listed but not descended into.
        #expect(two.children.isEmpty)
    }

    @Test func theEntryCapTruncatesRatherThanRunningAway() throws {
        // The anchor outside a repository is often a home directory or a volume
        // root. An uncapped walk there is a hang, not a tree.
        for index in 0 ..< 50 {
            _ = try fixture.file("plain/file\(index).txt")
        }
        let tree = DirectoryTree.tree(at: fixture.root.appending(path: "plain"), maxEntries: 10)
        #expect(DirectoryTreeTests.count(tree) == 10)
    }

    @Test func aSymlinkedDirectoryIsListedAndNotFollowed() throws {
        // Following can loop, and this tree is a picker rather than a crawler.
        _ = try fixture.file("plain/real/inside.txt")
        let link = fixture.root.appending(path: "plain/link")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: fixture.root.appending(path: "plain/real")
        )

        let tree = DirectoryTree.tree(at: fixture.root.appending(path: "plain"))
        let linked = try #require(tree.first { $0.name == "link" })
        #expect(linked.children.isEmpty)
        // The real directory is still walked; only the link is left alone.
        let real = try #require(tree.first { $0.name == "real" })
        #expect(real.children.map(\.name) == ["inside.txt"])
    }

    @Test func anUnreadableDirectoryYieldsNothingRatherThanTrapping() {
        let missing = fixture.root.appending(path: "was-never-there")
        #expect(DirectoryTree.tree(at: missing).isEmpty)
    }

    @Test func anEmptyDirectoryIsListedUnlikeInTheGitTree() throws {
        // The opposite of `FileTree`, and deliberately. git cannot track an empty
        // directory so the repository tree can never infer one, but a walk sees it
        // and hiding it would be the walk disagreeing with the filesystem.
        _ = try fixture.directory("plain/empty")

        let tree = DirectoryTree.tree(at: fixture.root.appending(path: "plain"))
        let empty = try #require(tree.first)
        #expect(empty.name == "empty")
        #expect(empty.isDirectory)
        #expect(empty.children.isEmpty)
    }

    /// Every node in the forest, however deep.
    private static func count(_ nodes: [FileTreeNode]) -> Int {
        nodes.reduce(0) { $0 + 1 + count($1.children) }
    }
}
