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

        // Back to a URL through the byte-preserving door. `URL(filePath:)` takes a
        // `String`, so a pointer that is not UTF-8 cannot go that way without the
        // substitution this reads bytes to avoid; `FileManager`'s
        // `string(withFileSystemRepresentation:length:)` is the inverse of the
        // representation the syscalls actually take and carries those bytes
        // through unharmed.
        let pointerPath = pointer.withUnsafeBufferPointer { buffer -> String in
            buffer.baseAddress.map { base in
                base.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                    FileManager.default.string(withFileSystemRepresentation: $0, length: buffer.count)
                }
            } ?? ""
        }
        guard !pointerPath.isEmpty else { return nil }

        // A relative pointer is relative to the worktree, not to the process's
        // working directory. `git worktree add --relative-paths` writes
        // `gitdir: ../.git/worktrees/<name>`, and resolving that against the
        // process instead of the root would land inside baia's own bundle.
        // Standardizing collapses the `..` without touching the filesystem.
        let target: URL = pointerPath.hasPrefix("/")
            ? URL(filePath: pointerPath, directoryHint: .isDirectory)
            : root.appending(path: pointerPath, directoryHint: .isDirectory).standardizedFileURL

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
    ///
    /// Bytes rather than text, for the reason in ``RepositoryPath``. The pointer
    /// names a path on a filesystem, and a filesystem path is a byte string.
    /// Decoding it through `String(decoding:as:)` replaces every byte it cannot
    /// read with U+FFFD, which never fails and never round-trips, so the pointer
    /// came back naming a file no filesystem holds. `fileExists` then said no and
    /// the worktree was reported as pruned: ``InProgressProbe`` went silent and
    /// the root read as an ordinary clone. macOS cannot create such a name, but
    /// it can mount one: a git directory on an ext4, NFS, SMB or ExFAT volume
    /// carries whatever bytes that filesystem holds.
    ///
    /// Internal rather than private so the byte-preservation arms can reach it:
    /// the end-to-end route needs a target directory APFS refuses to create.
    static func gitdirPointer(inFileAt path: String) -> [UInt8]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let prefix = Array(Self.pointerPrefix.utf8)
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            guard line.starts(with: prefix) else { continue }
            // Trimmed for newlines as well as spaces. A `.git` file written on
            // another platform, or copied through one, ends its line with CRLF,
            // and a trailing carriage return inside the path makes every probe
            // under the git directory miss while the path still looks right in
            // any message printed from it. Trimmed over bytes, since the ASCII
            // whitespace this drops is the whole of what git can write here and
            // a multi-byte scalar cannot contain one of these bytes.
            let value = Array(line.dropFirst(prefix.count).drop(while: Self.isASCIIWhitespace)
                .reversed().drop(while: Self.isASCIIWhitespace).reversed())
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// UTF-8 is self-synchronising: every byte of a multi-byte scalar has its high
    /// bit set, so none of them can equal one of these. Trimming them off a byte
    /// string cannot cut into a character.
    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
            || byte == UInt8(ascii: "\r") || byte == UInt8(ascii: "\n")
    }

    private static let pointerPrefix = "gitdir: "
}
