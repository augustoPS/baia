import Foundation

/// A throwaway directory tree under a unique temporary root.
///
/// `root` is stored with symlinks resolved, so a comparison against a path that
/// went through `resolvingSymlinksInPath` cannot diverge on a spelling. The
/// directory has to exist before it is resolved, because resolution only rewrites
/// components that are already there, which is why `createDirectory` comes first.
final class DirectoryFixture {
    let root: URL
    private let manager = FileManager.default

    init() throws {
        let base = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
            .appending(path: "baia-gitworkspace-\(UUID().uuidString)")
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
    /// holding a `.git` directory. No git process is involved, so tests that only
    /// need the shape stay in the millisecond range.
    @discardableResult
    func repository(_ path: String) throws -> URL {
        let url = try directory(path)
        try manager.createDirectory(
            at: url.appending(path: ".git"),
            withIntermediateDirectories: true
        )
        return url
    }

    /// Creates `path` as a linked worktree or a submodule, whose `.git` is a
    /// *file* holding a `gitdir:` pointer rather than a directory. The pointer is
    /// written verbatim, so a test can hand it a relative path or a trailing
    /// carriage return.
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

    /// Creates `path` as a file, with its parent directories.
    @discardableResult
    func file(_ path: String, contents: String = "") throws -> URL {
        let url = root.appending(path: path)
        try manager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The fixture root's own spelling of `path`, carrying the directory hint.
    ///
    /// Production code hands back directory URLs, and `URL` equality separates a
    /// hinted URL from a hintless one for the same path. Tests comparing raw
    /// output need the hint on the expectation; tests comparing a ``Project`` or a
    /// ``Worktree`` do not, since both canonicalize in their initializer.
    func directoryURL(_ path: String) -> URL {
        URL(
            filePath: root.appending(path: path).path(percentEncoded: false),
            directoryHint: .isDirectory
        )
    }
}
