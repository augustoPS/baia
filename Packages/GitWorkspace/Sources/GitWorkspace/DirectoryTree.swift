import Foundation

/// The tree a directory makes, for a pane sitting outside any repository.
///
/// **Why a walk here when ``FileTree`` rejected one.** That rejection was about
/// the repository tree, and it still stands: honouring an ignore file means
/// honouring negations, per-directory files, `core.excludesFile` and their
/// precedence, and a tree that disagrees with git about what is in a repository
/// is worse than one that omits an ignored file. Nothing here disagrees with git,
/// because nothing here runs where git does. Inside a repository the tree is
/// still `git ls-files --cached --others --exclude-standard`, which is already
/// tracked plus untracked minus ignored. This walk runs only where there is no
/// repository, and so nothing to ignore and nobody to disagree with.
///
/// That is also why there is no `git check-ignore` call: `--exclude-standard`
/// covers the repository case, and outside one the question does not arise.
public enum DirectoryTree {
    /// How deep the walk descends before listing a directory without opening it.
    public static let defaultMaxDepth = 6

    /// How many nodes the walk will produce before it stops.
    ///
    /// The anchor outside a repository is frequently a home directory or a volume
    /// root. Uncapped, the walk there is a hang rather than a tree, and it would
    /// be a hang on the main actor's poll.
    public static let defaultMaxEntries = 2000

    /// The forest under `root`, dotfiles omitted, directories before files.
    ///
    /// Ordering matches ``FileTree`` so a pane that crosses a repository boundary
    /// does not also change how its list is arranged.
    ///
    /// Paths are relative to `root`, again matching ``FileTree``, whose paths are
    /// relative to the repository root. The click handler puts that string on the
    /// prompt, and emitting an absolute path here would put a different kind of
    /// string there depending on which side of the boundary the pane sat.
    /// Breadth first, and that is the whole of why this is not four lines of
    /// recursion.
    ///
    /// A depth-first walk spends the budget on the first subtree it meets. Run
    /// against a directory of projects it returned the first project and nothing
    /// else: every later sibling fell off the end, and the owner was shown a top
    /// level missing most of itself. A shallow tree is still a tree; an incomplete
    /// top level is a wrong one. Levels are therefore filled in order, so depth is
    /// what gets lost when the budget runs out.
    public static func tree(
        at root: URL,
        maxDepth: Int = defaultMaxDepth,
        maxEntries: Int = defaultMaxEntries
    ) -> [FileTreeNode] {
        var budget = maxEntries
        let top = Builder(name: "", path: "", url: root, isDirectory: true)
        var frontier = [(node: top, depth: 0)]

        while !frontier.isEmpty, budget > 0 {
            var next: [(node: Builder, depth: Int)] = []
            for (node, depth) in frontier {
                guard budget > 0 else { break }
                expand(node, depth: depth, maxDepth: maxDepth, budget: &budget)
                for child in node.children where child.isDirectory && !child.isSymlink {
                    next.append((child, depth + 1))
                }
            }
            frontier = next
        }
        // Through the root's own `node` rather than mapping its children, so the
        // top level is grouped directories-then-files like every level under it.
        return top.node.children
    }

    /// Lists one directory into `node`, spending budget per entry.
    private static func expand(
        _ node: Builder,
        depth: Int,
        maxDepth: Int,
        budget: inout Int
    ) {
        guard depth < maxDepth else { return }

        // `contentsOfDirectory` reports an unreadable directory by throwing, and
        // meeting one part-way through somebody's home folder is ordinary rather
        // than an error worth propagating. `try?` degrades to an empty level,
        // which draws as a directory with nothing in it.
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: node.url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        // Sorted before the budget is spent, so a truncated level truncates the
        // same way twice rather than keeping whatever the filesystem happened to
        // hand back first.
        for entry in entries.sorted(by: { compare($0.lastPathComponent, $1.lastPathComponent) }) {
            guard budget > 0 else { return }
            budget -= 1
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let name = entry.lastPathComponent
            node.children.append(Builder(
                name: name,
                path: node.path.isEmpty ? name : node.path + "/" + name,
                url: entry,
                isDirectory: values?.isDirectory ?? false,
                // A symlink is listed and never entered. Following can loop, and
                // this tree is a picker rather than a crawler.
                isSymlink: values?.isSymbolicLink ?? false
            ))
        }
    }

    /// A node under construction.
    ///
    /// A reference type because breadth-first filling has to reach back into a
    /// level it already produced, and ``FileTreeNode`` is immutable by design.
    private final class Builder {
        let name: String
        let path: String
        let url: URL
        let isDirectory: Bool
        let isSymlink: Bool
        var children: [Builder] = []

        init(
            name: String,
            path: String,
            url: URL,
            isDirectory: Bool,
            isSymlink: Bool = false
        ) {
            self.name = name
            self.path = path
            self.url = url
            self.isDirectory = isDirectory
            self.isSymlink = isSymlink
        }

        /// The finished node, directories before files at every level.
        var node: FileTreeNode {
            let built = children.map(\.node)
            return FileTreeNode(
                // A `String` from `FileManager` rather than bytes from git, and it
                // has one by construction: a name this walk can see is a name macOS
                // already decoded.
                name: RepositoryPath(name),
                path: RepositoryPath(path),
                isDirectory: isDirectory,
                children: built.filter(\.isDirectory) + built.filter { !$0.isDirectory }
            )
        }
    }

    /// Case-insensitive, for the reason ``FileTree`` gives: a list where `Apple`
    /// sorts before `apple` but after `Zebra` reads as unsorted.
    private static func compare(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
    }
}
