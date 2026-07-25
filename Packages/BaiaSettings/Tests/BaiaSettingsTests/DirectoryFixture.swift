import Foundation

/// A throwaway directory tree under a unique temporary root.
///
/// `root` is stored with symlinks resolved, so a path built from it compares equal
/// to one the store read back through the file system. The directory is created
/// before it is resolved because `resolvingSymlinksInPath` only resolves
/// components that already exist.
final class DirectoryFixture {
    let root: URL

    init() throws {
        let base = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
            .appending(path: "baia-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = base.resolvingSymlinksInPath()
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes `contents` at `path`, relative to the fixture root, creating the
    /// directories above it the way a hand-placed config file would already have.
    @discardableResult
    func file(_ path: String, contents: String) throws -> URL {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
