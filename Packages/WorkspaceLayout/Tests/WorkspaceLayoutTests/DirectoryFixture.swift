import Foundation

/// A throwaway directory tree under a unique temporary root.
///
/// The same shape as ProjectAnchor's fixture, for the same reason: ``SessionStore``
/// is driven against the real filesystem rather than behind a protocol, so an
/// atomic save that only works against a mock cannot be reported as a pass.
///
/// `root` is stored with symlinks resolved, so a path built here and a path
/// `SessionStore` hands back cannot diverge on a `/private` prefix.
final class DirectoryFixture {
    let root: URL
    private let manager = FileManager.default

    init() throws {
        let base = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
            .appending(path: "baia-workspace-\(UUID().uuidString)")
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

    /// Writes `contents` to `path`, relative to the fixture root, creating the
    /// directories above it.
    @discardableResult
    func file(_ path: String, contents: String) throws -> URL {
        let url = root.appending(path: path)
        try manager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Everything directly inside `path`, sorted. A save that leaves its temporary
    /// file behind is invisible to a load, so the only way to catch it is to look at
    /// the directory.
    func entries(_ path: String) throws -> [String] {
        try manager.contentsOfDirectory(
            atPath: root.appending(path: path).path(percentEncoded: false)
        ).sorted()
    }
}
