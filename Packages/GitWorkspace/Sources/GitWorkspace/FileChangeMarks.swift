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
    /// and `?` are what the pane's chrome and the shell prompt already print, and `M` and
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
    /// Keyed on ``RepositoryPath`` and not on its drawn spelling, for the reason
    /// that type exists: `display` maps every byte it cannot read onto U+FFFD, so
    /// two files git reports separately collapse onto one entry and `max` hands
    /// the quieter of them the louder one's glyph. ``FileTree`` keys its nodes on
    /// bytes already; this is the other half of the same rule.
    private var marks: [RepositoryPath: FileChangeMark] = [:]

    /// The per-file status letter, for the paths git named and for no directory
    /// above them.
    ///
    /// **Files only, and the asymmetry against ``marks`` is the design.** A
    /// directory's mark is a *rollup* — the worst thing under it — which is a
    /// question urgency can answer and a letter cannot: `M` on a collapsed
    /// `Sources/` would claim the directory itself was modified, and there is no
    /// honest letter for "one of the nineteen files under here was deleted and
    /// two were added". So the tree draws the letter where git actually named a
    /// file and keeps the rolled-up dot on directories (2026-08-12, option B).
    ///
    /// Built in the same pass as the marks rather than in a second structure the
    /// caller would have to keep in step: the two answers come from one change
    /// list and are drawn on one row.
    private var letters: [RepositoryPath: RowStatusLetter] = [:]

    public init(_ changes: [RepositoryFileChange]) {
        for change in changes {
            // Before the `FileChangeMark` guard below, deliberately. That
            // initialiser returns nil when neither column carries a state, which
            // git does not emit; `RowStatusLetter` has no nil to return and folds
            // the same case into modified. Keying the letter first means the two
            // maps disagree only where git itself is incoherent, and the tree
            // draws no letter for a path it draws no mark for anyway.
            letters[change.rawPath] = RowStatusLetter(change)
            guard let mark = FileChangeMark(change) else { continue }
            raise(change.rawPath, to: mark)
            // Every directory above it, so a collapsed row answers for its
            // contents. Walked over bytes: these are repository-relative paths
            // from git and the tree splits the same bytes on the same separator,
            // so nothing here asks the filesystem anything.
            var components = change.rawPath.bytes
                .split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: true)
                .map(Array.init)
            guard !components.isEmpty else { continue }
            components.removeLast()
            var prefix: [UInt8] = []
            for component in components {
                if !prefix.isEmpty { prefix.append(UInt8(ascii: "/")) }
                prefix += component
                raise(RepositoryPath(prefix), to: mark)
            }
        }
    }

    /// The mark for a path, or nil when nothing under it has changed.
    public subscript(path: RepositoryPath) -> FileChangeMark? { marks[path] }

    /// The status letter for a file git named, or nil for a directory and for
    /// anything unchanged.
    ///
    /// A directory answers nil rather than a rolled-up letter, for the reason
    /// ``letters`` gives: a rollup is an urgency and this is a kind.
    public func letter(for path: RepositoryPath) -> RowStatusLetter? { letters[path] }

    public var isEmpty: Bool { marks.isEmpty }

    private mutating func raise(_ path: RepositoryPath, to mark: FileChangeMark) {
        marks[path] = max(marks[path] ?? mark, mark)
    }
}
