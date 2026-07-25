import Foundation

/// Resolves where a repository root keeps its git directory.
///
/// Reaches `FileManager.default` inside the method bodies rather than storing
/// one. Storing a `FileManager` forfeits `Sendable`, since `FileManager` is not
/// itself `Sendable`, and no caller ever needed to substitute one: the tests
/// build real trees under a temporary directory.
public enum GitDirectory {
    /// Resolves a repository root's git directory. A normal clone has `.git` as a
    /// directory; a linked worktree or submodule has `.git` as a regular FILE
    /// holding a `gitdir: <path>` pointer, which may be relative to the worktree.
    ///
    /// Nil when there is no `.git` entry, when the file holds no pointer, or when
    /// the pointer names a directory that is not there. That last case is a
    /// worktree `git worktree prune` has already reaped, and answering with a
    /// path that does not exist would make ``InProgressProbe`` report "nothing in
    /// progress" for a repository with no git directory at all. Nil lets the
    /// caller tell those two apart.
    public static func url(forRepositoryRoot root: URL) -> URL? {
        let entryPath = root.appending(path: ".git").path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: entryPath, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue {
            return URL(filePath: entryPath, directoryHint: .isDirectory)
        }
        guard let pointer = gitdirPointer(inFileAt: entryPath) else { return nil }

        // A relative pointer is relative to the worktree, not to the process's
        // working directory. `git worktree add --relative-paths` writes
        // `gitdir: ../.git/worktrees/<name>`, and resolving that against the
        // process instead of the root would land inside baia's own bundle.
        // Standardizing collapses the `..` without touching the filesystem.
        let target: URL = pointer.hasPrefix("/")
            ? URL(filePath: pointer, directoryHint: .isDirectory)
            : root.appending(path: pointer, directoryHint: .isDirectory).standardizedFileURL

        let targetPath = target.path(percentEncoded: false)
        var targetIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetPath, isDirectory: &targetIsDirectory),
              targetIsDirectory.boolValue
        else { return nil }
        return URL(filePath: targetPath, directoryHint: .isDirectory)
    }

    /// True when the root is a linked worktree rather than a normal clone.
    ///
    /// "The `.git` entry is a file" is not the question, because a submodule's
    /// `.git` is a file too, pointing at `<super>/.git/modules/<name>`. The
    /// parent component of the pointer target separates them: git keeps worktree
    /// git directories under `worktrees/` and submodule ones under `modules/`.
    /// Calling a submodule a worktree would make the palette offer it as a
    /// sibling of the repository it lives inside.
    public static func isLinkedWorktree(repositoryRoot root: URL) -> Bool {
        guard let directory = url(forRepositoryRoot: root) else { return false }
        return directory.deletingLastPathComponent().lastPathComponent == "worktrees"
    }

    /// The path a `.git` file points at, or nil when the file holds no
    /// `gitdir:` line.
    ///
    /// `FileManager.contents(atPath:)` is used rather than `Data(contentsOf:)`
    /// because the latter throws and this package has no error channel: a file it
    /// cannot read is the same answer as a file that is not there.
    private static func gitdirPointer(inFileAt path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.hasPrefix(Self.pointerPrefix) else { continue }
            // Trimmed for newlines as well as spaces. A `.git` file written on
            // another platform, or copied through one, ends its line with CRLF,
            // and a trailing carriage return inside the path makes every probe
            // under the git directory miss while the path still looks right in
            // any message printed from it.
            let value = line.dropFirst(Self.pointerPrefix.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static let pointerPrefix = "gitdir: "
}
