import Foundation

/// A throwaway directory tree under a unique temporary root.
///
/// `root` is stored with symlinks resolved. On macOS the temporary directory
/// lives under `/var/folders`, and `/var` is a symlink to `/private/var`. The
/// locator resolves symlinks before walking, so it returns `/private/var/...`
/// paths and an unresolved fixture root would never compare equal to them.
final class DirectoryFixture {
    let root: URL
    private let manager = FileManager.default

    init() throws {
        let base = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
            .appending(path: "baia-anchor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = base.resolvingSymlinksInPath()
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// Creates `path`, relative to the fixture root, as a plain directory. The
    /// directory hint matters: the locator returns directory URLs, and a hintless
    /// URL for the same path compares unequal to one carrying the hint.
    @discardableResult
    func directory(_ path: String) throws -> URL {
        let url = root.appending(path: path, directoryHint: .isDirectory)
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Creates `path` as a repository root the way `git init` does: a directory
    /// holding a `.git` directory.
    @discardableResult
    func repository(_ path: String) throws -> URL {
        let url = try directory(path)
        try manager.createDirectory(at: url.appending(path: ".git"), withIntermediateDirectories: true)
        return url
    }

    /// Creates `path` as a linked worktree, whose `.git` is a *file* holding a
    /// `gitdir:` pointer rather than a directory. Submodules look the same.
    @discardableResult
    func worktree(_ path: String, pointingAt gitdir: String) throws -> URL {
        let url = try directory(path)
        try "gitdir: \(gitdir)\n".write(
            to: url.appending(path: ".git"),
            atomically: true,
            encoding: .utf8
        )
        return url
    }
}
