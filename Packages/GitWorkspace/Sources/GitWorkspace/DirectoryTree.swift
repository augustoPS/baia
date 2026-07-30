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
    public static func tree(
        at root: URL,
        maxDepth: Int = defaultMaxDepth,
        maxEntries: Int = defaultMaxEntries
    ) -> [FileTreeNode] {
        var budget = maxEntries
        return walk(root, prefix: "", depth: 0, maxDepth: maxDepth, budget: &budget)
    }

    private static func walk(
        _ directory: URL,
        prefix: String,
        depth: Int,
        maxDepth: Int,
        budget: inout Int
    ) -> [FileTreeNode] {
        guard budget > 0 else { return [] }

        // `contentsOfDirectory` answers nil-ish by throwing, and an unreadable
        // directory is an ordinary thing to meet on a walk of somebody's home
        // folder rather than an error worth propagating. `try?` degrades to an
        // empty level, which draws as a directory with nothing in it.
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var directories: [FileTreeNode] = []
        var files: [FileTreeNode] = []

        // Sorted before the budget is spent, so a truncated walk still truncates
        // the same way twice rather than keeping whatever the filesystem happened
        // to hand back first.
        for entry in entries.sorted(by: { compare($0.lastPathComponent, $1.lastPathComponent) }) {
            guard budget > 0 else { break }
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let name = entry.lastPathComponent
            let path = prefix.isEmpty ? name : prefix + "/" + name
            budget -= 1

            // A symlink is listed and not entered. Following can loop, and this
            // tree is a picker rather than a crawler.
            let isSymlink = values?.isSymbolicLink ?? false
            guard values?.isDirectory == true, !isSymlink else {
                if isSymlink, values?.isDirectory == true {
                    directories.append(FileTreeNode(
                        name: name, path: path, isDirectory: true, children: []
                    ))
                } else {
                    files.append(FileTreeNode(
                        name: name, path: path, isDirectory: false, children: []
                    ))
                }
                continue
            }

            let children = depth + 1 >= maxDepth
                ? []
                : walk(entry, prefix: path, depth: depth + 1, maxDepth: maxDepth, budget: &budget)
            directories.append(FileTreeNode(
                name: name, path: path, isDirectory: true, children: children
            ))
        }

        return directories + files
    }

    /// Case-insensitive, for the reason ``FileTree`` gives: a list where `Apple`
    /// sorts before `apple` but after `Zebra` reads as unsorted.
    private static func compare(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
    }
}
