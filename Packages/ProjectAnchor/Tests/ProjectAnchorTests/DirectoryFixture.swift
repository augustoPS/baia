import Foundation

/// A throwaway directory tree under a unique temporary root.
///
/// `root` is stored with symlinks resolved, so comparisons against locator
/// output (which resolves symlinks before walking) cannot diverge on a path
/// spelling. On this platform that resolution happens to be a no-op for the
/// temporary directory: `NSTemporaryDirectory()` already returns a
/// `/var/folders/...` path that resolves to itself byte for byte. The call stays
/// as defensive normalization for a fixture root that is not the temp directory.
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

    /// Creates `path`, relative to the fixture root, as a plain directory.
    @discardableResult
    func directory(_ path: String) throws -> URL {
        let url = root.appending(path: path)
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
