import Foundation
import Testing

@testable import GitWorkspace

/// The tree a list of relative paths makes.
///
/// Pure, and deliberately so: the paths come from `git ls-files`, and every
/// question about shape, ordering and nesting can be answered without a repository
/// or a filesystem. The one test that needs a real repository lives in
/// `GitCommandTests`, where the process spawns already are.
@Suite struct FileTreeTests {
    @Test func noPathsMakeNoNodes() {
        #expect(FileTree.build(paths: []).isEmpty)
    }

    @Test func aTopLevelFileIsALeaf() {
        let tree = FileTree.build(paths: ["README.md"])
        #expect(tree.count == 1)
        #expect(tree[0].name == "README.md")
        #expect(tree[0].path == "README.md")
        #expect(tree[0].isDirectory == false)
        #expect(tree[0].children.isEmpty)
    }

    @Test func aNestedPathCreatesTheDirectoriesAboveIt() {
        let tree = FileTree.build(paths: ["Sources/App/main.swift"])
        #expect(tree.map(\.name) == ["Sources"])
        #expect(tree[0].isDirectory)
        #expect(tree[0].path == "Sources")
        #expect(tree[0].children.map(\.name) == ["App"])
        #expect(tree[0].children[0].path == "Sources/App")
        #expect(tree[0].children[0].children.map(\.name) == ["main.swift"])
        #expect(tree[0].children[0].children[0].path == "Sources/App/main.swift")
    }

    /// The property that makes this a tree rather than a list: two paths sharing a
    /// prefix share the directory nodes, they do not each grow their own.
    @Test func siblingsUnderOneDirectoryShareIt() {
        let tree = FileTree.build(paths: ["a/one.txt", "a/two.txt"])
        #expect(tree.count == 1)
        #expect(tree[0].children.map(\.name) == ["one.txt", "two.txt"])
    }

    @Test func directoriesSortBeforeFiles() {
        // `zzz` is a directory and `aaa.txt` is a file, so alphabetical order alone
        // would put the file first. Directories first is what every file tree the
        // owner uses does, and the test names the case where the two rules
        // disagree.
        let tree = FileTree.build(paths: ["aaa.txt", "zzz/inner.txt"])
        #expect(tree.map(\.name) == ["zzz", "aaa.txt"])
    }

    @Test func sortingWithinAGroupIgnoresCase() {
        let tree = FileTree.build(paths: ["banana.txt", "Apple.txt", "cherry.txt"])
        #expect(tree.map(\.name) == ["Apple.txt", "banana.txt", "cherry.txt"])
    }

    @Test func aPathWithSpacesSurvives() {
        let tree = FileTree.build(paths: ["my folder/old name.txt"])
        #expect(tree[0].name == "my folder")
        #expect(tree[0].children[0].name == "old name.txt")
        #expect(tree[0].children[0].path == "my folder/old name.txt")
    }

    @Test func deepNestingKeepsEveryLevel() {
        let tree = FileTree.build(paths: ["a/b/c/d/e.txt"])
        var node = tree[0]
        var names = [node.name]
        while let child = node.children.first {
            node = child
            names.append(node.name)
        }
        #expect(names == ["a", "b", "c", "d", "e.txt"])
        #expect(node.path == "a/b/c/d/e.txt")
    }

    /// An empty component is what a doubled separator or a trailing slash leaves
    /// behind. Keeping it would produce a nameless node that renders as a blank row
    /// nobody can click.
    @Test func emptyComponentsAreDropped() {
        let tree = FileTree.build(paths: ["a//b.txt", "c/"])
        #expect(tree.map(\.name) == ["a", "c"])
        #expect(tree[0].children.map(\.name) == ["b.txt"])
        #expect(tree[1].children.isEmpty)
    }

    @Test func theSamePathTwiceIsOneNode() {
        let tree = FileTree.build(paths: ["a/b.txt", "a/b.txt"])
        #expect(tree.count == 1)
        #expect(tree[0].children.map(\.name) == ["b.txt"])
    }

    /// `ls-files -z` separates with NUL and ends with one, so a naive split leaves a
    /// trailing empty path that would become a nameless root node.
    @Test func nulSeparatedOutputIsSplitAndTheTrailingEmptyDropped() {
        #expect(FileTree.paths(fromNulSeparated: bytes("a.txt\0b.txt\0")) == ["a.txt", "b.txt"])
    }

    @Test func emptyNulSeparatedOutputIsNoPaths() {
        #expect(FileTree.paths(fromNulSeparated: []).isEmpty)
    }

    /// The reason `-z` is passed at all. Without it git quotes any path with a
    /// space, a quote or a non-ASCII byte, and the tree would show a name nobody
    /// typed. With it the bytes arrive as they are.
    @Test func nulSeparationSurvivesAPathThatWouldOtherwiseBeQuoted() {
        let output = bytes("old name.txt\0caf\u{e9}.txt\0say \"hi\".txt\0")
        #expect(FileTree.paths(fromNulSeparated: output) == [
            "old name.txt",
            "caf\u{e9}.txt",
            "say \"hi\".txt",
        ])
    }

    /// The split is over bytes, so a byte that is not UTF-8 is a path character like
    /// any other. NUL is the one byte a path cannot hold, which is what `-z` trades
    /// on, and it is the only one this looks for.
    @Test func aPathThatIsNotUTF8SurvivesTheSplit() {
        let output = bytes("a.txt\0caf") + [0xE9] + bytes(".txt\0")

        #expect(FileTree.paths(fromNulSeparated: output) == [
            "a.txt",
            RepositoryPath(bytes("caf") + [0xE9] + bytes(".txt")),
        ])
    }

    /// What the tree draws and what the tree *is*, for a name that has no text
    /// spelling. The row shows the replacement character because it has to show
    /// something; the node still carries what git wrote, which is the half a caller
    /// needs to name the file.
    @Test func aNodeKeepsTheBytesOfANameThatIsNotUTF8() {
        let name = RepositoryPath(bytes("caf") + [0xE9] + bytes(".txt"))

        let tree = FileTree.build(paths: [name])

        #expect(tree.map(\.rawName) == [name])
        #expect(tree.map(\.rawPath) == [name])
        #expect(tree.map(\.name) == ["caf\u{FFFD}.txt"])
    }

    /// A directory whose own name is not UTF-8, so the split on `/` and the prefix a
    /// child's path is built from are both proved to be byte work. A child's path
    /// carries its parent's bytes, and rebuilding it from the drawn name would put
    /// the replacement character in the middle of a path.
    @Test func aDirectoryComponentThatIsNotUTF8ReachesItsChildrenIntact() {
        let directory = bytes("caf") + [0xE9]
        let tree = FileTree.build(paths: [RepositoryPath(directory + bytes("/main.swift"))])

        #expect(tree.map(\.rawName) == [RepositoryPath(directory)])
        #expect(tree[0].isDirectory)
        #expect(tree[0].children.map(\.rawPath) == [
            RepositoryPath(directory + bytes("/main.swift")),
        ])
    }

    private func bytes(_ string: String) -> [UInt8] { Array(string.utf8) }
}
