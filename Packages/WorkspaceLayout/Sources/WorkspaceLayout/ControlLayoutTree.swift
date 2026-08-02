import Foundation

extension PaneTree {
    /// `path` itself when it names a directory that exists, nil otherwise.
    ///
    /// The rule ``build(_:createdBy:into:)`` applies to a document's `cwd`: a
    /// directory that is not a directory becomes nil, and a nil opens at the
    /// default rather than failing the whole apply.
    public static func existingDirectory(_ path: String) -> String? {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue ? path : nil
    }
}
