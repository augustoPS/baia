import Foundation

/// One entry in the file tree.
///
/// A value type holding its children rather than a node graph with parent
/// pointers. The tree is rebuilt from a fresh path list every time it is read,
/// never mutated in place, so there is nothing for a parent pointer to keep
/// consistent and nothing to leak.
public struct FileTreeNode: Sendable, Equatable {
    /// The last path component, as git wrote it.
    public let rawName: RepositoryPath

    /// The whole path, relative to the repository root, as git wrote it.
    ///
    /// Carried on every node rather than reconstructed by walking back up, because
    /// there is no way back up: a caller holding a node it was handed cannot
    /// otherwise say which file it has.
    public let rawPath: RepositoryPath

    /// What a row draws, which is lossy for a name that is not UTF-8.
    ///
    /// Derived rather than stored, so it cannot drift from ``rawName``. A caller
    /// that has to *name* the file rather than show it wants the bytes: see
    /// ``RepositoryPath``.
    public var name: String { rawName.display }

    /// The drawn spelling of ``rawPath``, lossy for the same reason ``name`` is.
    public var path: String { rawPath.display }

    /// True for a node the paths only implied.
    ///
    /// `git ls-files` lists files, so every directory here exists because something
    /// under it does. That is also why an empty directory never appears: git does
    /// not track one, so there is nothing to infer it from.
    public let isDirectory: Bool

    public let children: [FileTreeNode]

    /// Labelled for what they are rather than for how they are spelled, so a call
    /// site reads the same as it did when both were `String`s. A literal still
    /// works, since a path a caller can type has a text spelling.
    public init(
        name: RepositoryPath,
        path: RepositoryPath,
        isDirectory: Bool,
        children: [FileTreeNode]
    ) {
        rawName = name
        rawPath = path
        self.isDirectory = isDirectory
        self.children = children
    }
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
    /// **Bytes rather than a `String`, and that is the flag's other half.** `-z`
    /// stops the quoting and hands over whatever the filesystem holds, which is not
    /// always UTF-8; decoding it before the split replaces the byte with U+FFFD and
    /// the name is lost before anything here sees it. NUL is the one byte a path
    /// cannot contain, so it is the only one this looks for and every other byte
    /// passes through as path content.
    ///
    /// The output ends with a separator, so the last split is empty and is dropped
    /// rather than becoming a nameless node.
    public static func paths(fromNulSeparated output: [UInt8]) -> [RepositoryPath] {
        output.split(separator: 0, omittingEmptySubsequences: true).map(RepositoryPath.init)
    }

    /// Builds the tree, directories first and then files, each group sorted by name
    /// without regard to case.
    ///
    /// Directories first because that is what every file tree the owner already uses
    /// does, and case-insensitively because a list where `Apple` sorts before
    /// `apple` but after `Zebra` reads as unsorted.
    public static func build(paths: [RepositoryPath]) -> [FileTreeNode] {
        var root = Directory()
        for path in paths {
            // Empty components are dropped rather than kept: a doubled separator or
            // a trailing slash would otherwise produce a nameless node, which draws
            // as a blank row that cannot be clicked or explained.
            //
            // Split on the byte rather than on the character. A slash is one byte
            // and can never appear inside a UTF-8 sequence, so this is the same
            // split for a name that decodes and the only one available for a name
            // that does not.
            let components = path.bytes.split(separator: separator, omittingEmptySubsequences: true)
            guard !components.isEmpty else { continue }
            root.insert(components[...], at: [])
        }
        return root.nodes()
    }

    private static let separator = UInt8(ascii: "/")

    /// The tree under construction.
    ///
    /// A separate mutable shape from ``FileTreeNode`` so the public type can stay a
    /// `let`-only value: building needs to reach back into a directory that was
    /// already created, and a tree of immutable nodes would have to be rebuilt at
    /// every insert.
    private struct Directory {
        /// Keyed by the component's bytes, which is what makes two names that draw
        /// alike two entries. Keyed by the drawn spelling, every file whose name is
        /// not UTF-8 in one directory would collapse onto one node.
        ///
        /// Insertion order is not kept. The sort at the end is total, so the order
        /// paths arrive in cannot reach the output, which is what makes the tree a
        /// function of the set of paths rather than of the listing.
        var directories: [[UInt8]: Directory] = [:]
        var files: Set<[UInt8]> = []

        mutating func insert(_ components: ArraySlice<ArraySlice<UInt8>>, at prefix: [UInt8]) {
            guard let first = components.first else { return }
            let name = Array(first)
            let rest = components.dropFirst()

            if rest.isEmpty {
                // A path is a file at its last component, unless a longer path
                // already made the same name a directory. Trusting the last
                // component alone would let `a/b.txt` and `a/b.txt/c` produce two
                // nodes with one name.
                if directories[name] == nil { files.insert(name) }
                return
            }

            let childPrefix = joined(prefix, name)
            files.remove(name)
            var child = directories[name] ?? Directory()
            child.insert(rest, at: childPrefix)
            directories[name] = child
        }

        func nodes(prefix: [UInt8] = []) -> [FileTreeNode] {
            let directoryNodes = directories.map { name, directory -> FileTreeNode in
                let path = joined(prefix, name)
                return FileTreeNode(
                    name: RepositoryPath(name),
                    path: RepositoryPath(path),
                    isDirectory: true,
                    children: directory.nodes(prefix: path)
                )
            }
            let fileNodes = files.map { name in
                FileTreeNode(
                    name: RepositoryPath(name),
                    path: RepositoryPath(joined(prefix, name)),
                    isDirectory: false,
                    children: []
                )
            }
            return sorted(directoryNodes) + sorted(fileNodes)
        }

        private func joined(_ prefix: [UInt8], _ name: [UInt8]) -> [UInt8] {
            prefix.isEmpty ? name : prefix + [FileTree.separator] + name
        }

        /// Case-insensitive by the drawn name, with the bytes as the tie-break so
        /// two entries differing only in case, or only in a byte that draws as the
        /// replacement character, have a stable order rather than whichever the
        /// dictionary offered first.
        private func sorted(_ nodes: [FileTreeNode]) -> [FileTreeNode] {
            nodes.sorted {
                let left = $0.name.lowercased()
                let right = $1.name.lowercased()
                guard left == right else { return left < right }
                return $0.rawName.bytes.lexicographicallyPrecedes($1.rawName.bytes)
            }
        }
    }
}
