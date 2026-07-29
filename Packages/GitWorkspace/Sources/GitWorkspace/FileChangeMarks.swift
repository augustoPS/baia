import Foundation

/// What one glyph in a file tree says about a path, and what a directory says
/// about everything under it.
///
/// Design v3 §5.2. The changes list spends two columns on `XY`, because there the
/// index and the working tree are the question. In the tree the question is "has
/// this changed at all, and how much should I care", so the two collapse to the
/// more urgent of them and a directory carries the strongest mark beneath it.
/// **That rollup is what makes the tree navigable rather than decorative**: a
/// closed `Sources/` showing `M` is the one thing a collapsed row can say that its
/// own rows cannot.
public enum FileChangeMark: Sendable, Equatable, Comparable, CaseIterable {
    /// Ordered by how much it should interrupt, quietest first, which is what
    /// makes `max` the rollup and the collapse of `XY` one operation.
    case untracked
    case staged
    case unstaged
    case conflict

    /// The glyph, which is the owner's own vocabulary rather than a new one: `*`
    /// and `?` are what the footer and the shell prompt already print, and `M` and
    /// `!` are git's.
    public var glyph: Character {
        switch self {
        case .conflict: "!"
        case .unstaged: "*"
        case .staged: "M"
        case .untracked: "?"
        }
    }

    /// What one changed path is worth in a tree.
    ///
    /// Unstaged outranks staged for a file that is both: `MM` means committing now
    /// leaves the second `M` behind, and the tree's single glyph has to be the half
    /// that is still owed.
    public init?(_ change: RepositoryFileChange) {
        switch change.kind {
        case .unmerged: self = .conflict
        case .untracked: self = .untracked
        case .ordinary, .renamedOrCopied:
            if change.worktree != nil {
                self = .unstaged
            } else if change.index != nil {
                self = .staged
            } else {
                // Neither column carries a state, so there is nothing to draw. Git
                // does not emit this, and a mark invented for it would be a mark
                // nothing can explain.
                return nil
            }
        }
    }
}

/// Every path in a repository that has something to say, files and the
/// directories above them.
///
/// Built once per change list rather than searched per row: a tree draws its
/// visible rows on every scroll, and a linear scan of the changes for each of them
/// is the shape that makes a large repository stutter.
public struct FileChangeMarks: Sendable, Equatable {
    private var marks: [String: FileChangeMark] = [:]

    public init(_ changes: [RepositoryFileChange]) {
        for change in changes {
            guard let mark = FileChangeMark(change) else { continue }
            raise(change.path, to: mark)
            // Every directory above it, so a collapsed row answers for its
            // contents. Walked textually: these are repository-relative paths from
            // git and the tree is built from the same strings, so nothing here
            // asks the filesystem anything.
            var components = change.path.split(separator: "/").map(String.init)
            components.removeLast()
            var prefix = ""
            for component in components {
                prefix = prefix.isEmpty ? component : prefix + "/" + component
                raise(prefix, to: mark)
            }
        }
    }

    /// The mark for a path, or nil when nothing under it has changed.
    public subscript(path: String) -> FileChangeMark? { marks[path] }

    public var isEmpty: Bool { marks.isEmpty }

    private mutating func raise(_ path: String, to mark: FileChangeMark) {
        marks[path] = max(marks[path] ?? mark, mark)
    }
}
