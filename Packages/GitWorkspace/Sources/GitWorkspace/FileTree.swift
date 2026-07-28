import Foundation

/// One entry in the file tree.
///
/// A value type holding its children rather than a node graph with parent
/// pointers. The tree is rebuilt from a fresh path list every time it is read,
/// never mutated in place, so there is nothing for a parent pointer to keep
/// consistent and nothing to leak.
public struct FileTreeNode: Sendable, Equatable {
    /// The last path component, which is what a row draws.
    public let name: String

    /// The whole path, relative to the repository root.
    ///
    /// Carried on every node rather than reconstructed by walking back up, because
    /// there is no way back up: a caller holding a node it was handed cannot
    /// otherwise say which file it has.
    public let path: String

    /// True for a node the paths only implied.
    ///
    /// `git ls-files` lists files, so every directory here exists because something
    /// under it does. That is also why an empty directory never appears: git does
    /// not track one, so there is nothing to infer it from.
    public let isDirectory: Bool

    public let children: [FileTreeNode]
}

/// The tree a list of relative paths makes, and the parse that produces the list.
///
/// Kept free of any process running, the same split ``GitStatusParser`` follows:
/// ``GitCommand`` runs `git ls-files` and hands the output here, so every question
/// about nesting and ordering is answerable on a string.
///
/// **Why `git ls-files` and not a directory walk that reads `.gitignore`.** The
/// alternative was considered and rejected. Honouring an ignore file means
/// honouring negations, per-directory ignore files, `.git/info/exclude`, the
/// `core.excludesFile` global, and the precedence between them. Every one of those
/// is a place to disagree with git, and a tree that disagrees with git about what
/// is in the repository is worse than a tree that omits an ignored file: the first
/// is wrong in a way the owner cannot see, the second is wrong in a way he asked
/// for. Asking git costs one process on a read that is already gated behind a
/// poll.
public enum FileTree {
    /// Splits `git ls-files -z` output into paths.
    ///
    /// `-z` rather than the default, because git quotes any path holding a space, a
    /// quote or a byte outside ASCII, and a tree rendering `"caf\303\251.txt"` shows
    /// a name nobody typed. NUL separation has no escaping at all.
    ///
    /// The output ends with a separator, so the last split is empty and is dropped
    /// rather than becoming a nameless node.
    public static func paths(fromNulSeparated output: String) -> [String] {
        output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    }

    /// Builds the tree, directories first and then files, each group sorted by name
    /// without regard to case.
    ///
    /// Directories first because that is what every file tree the owner already uses
    /// does, and case-insensitively because a list where `Apple` sorts before
    /// `apple` but after `Zebra` reads as unsorted.
    public static func build(paths: [String]) -> [FileTreeNode] {
        var root = Directory()
        for path in paths {
            // Empty components are dropped rather than kept: a doubled separator or
            // a trailing slash would otherwise produce a nameless node, which draws
            // as a blank row that cannot be clicked or explained.
            let components = path.split(separator: "/", omittingEmptySubsequences: true)
            guard !components.isEmpty else { continue }
            root.insert(components[...], at: "")
        }
        return root.nodes()
    }

    /// The tree under construction.
    ///
    /// A separate mutable shape from ``FileTreeNode`` so the public type can stay a
    /// `let`-only value: building needs to reach back into a directory that was
    /// already created, and a tree of immutable nodes would have to be rebuilt at
    /// every insert.
    private struct Directory {
        /// Insertion order is not kept. The sort at the end is total, so the order
        /// paths arrive in cannot reach the output, which is what makes the tree a
        /// function of the set of paths rather than of the listing.
        var directories: [String: Directory] = [:]
        var files: Set<String> = []

        mutating func insert(_ components: ArraySlice<Substring>, at prefix: String) {
            guard let first = components.first else { return }
            let name = String(first)
            let rest = components.dropFirst()

            if rest.isEmpty {
                // A path is a file at its last component, unless a longer path
                // already made the same name a directory. Trusting the last
                // component alone would let `a/b.txt` and `a/b.txt/c` produce two
                // nodes with one name.
                if directories[name] == nil { files.insert(name) }
                return
            }

            let childPrefix = prefix.isEmpty ? name : prefix + "/" + name
            files.remove(name)
            var child = directories[name] ?? Directory()
            child.insert(rest, at: childPrefix)
            directories[name] = child
        }

        func nodes(prefix: String = "") -> [FileTreeNode] {
            let directoryNodes = directories.map { name, directory -> FileTreeNode in
                let path = prefix.isEmpty ? name : prefix + "/" + name
                return FileTreeNode(
                    name: name,
                    path: path,
                    isDirectory: true,
                    children: directory.nodes(prefix: path)
                )
            }
            let fileNodes = files.map { name in
                FileTreeNode(
                    name: name,
                    path: prefix.isEmpty ? name : prefix + "/" + name,
                    isDirectory: false,
                    children: []
                )
            }
            return sorted(directoryNodes) + sorted(fileNodes)
        }

        /// Case-insensitive by name, with the name itself as the tie-break so two
        /// entries differing only in case have a stable order rather than whichever
        /// the dictionary offered first.
        private func sorted(_ nodes: [FileTreeNode]) -> [FileTreeNode] {
            nodes.sorted {
                let left = $0.name.lowercased()
                let right = $1.name.lowercased()
                return left == right ? $0.name < $1.name : left < right
            }
        }
    }
}
