import Foundation

/// Finds the git repository that contains a directory, by walking upward.
///
/// Comparisons are made on path strings rather than on `URL` values throughout.
/// Two `URL`s for the same directory compare unequal when one was built with a
/// directory hint and the other was not, which makes URL equality a trap here.
///
/// Reaches `FileManager.default` directly rather than storing an injected one.
/// Storing a `FileManager` would forfeit `Sendable`, since it is not itself
/// `Sendable`, and no caller ever needed to substitute one: the tests drive
/// behaviour through the `ceiling` parameter and a real temporary directory.
public struct GitRepositoryLocator: Sendable {
    private let ceilingPath: String

    /// - Parameter ceiling: the walk stops *below* this directory, so a
    ///   repository sitting at the ceiling itself is never claimed. Defaults to
    ///   the user's home directory: a dotfiles repository at `$HOME` would
    ///   otherwise claim every non-repository directory the shell ever enters,
    ///   which is worse than falling back to the working directory. The pin
    ///   covers anyone whose home is their project.
    public init(ceiling: URL? = nil) {
        let resolved = (ceiling ?? FileManager.default.homeDirectoryForCurrentUser)
            .resolvingSymlinksInPath()
        ceilingPath = Self.normalized(resolved.path(percentEncoded: false))
    }

    /// True when `directory` itself holds a `.git` entry. A pin is taken
    /// verbatim rather than resolved upward, so it needs this rather than a walk.
    public func isRepositoryRoot(_ directory: URL) -> Bool {
        let path = Self.normalized(
            directory.resolvingSymlinksInPath().path(percentEncoded: false)
        )
        return holdsGitEntry(path)
    }

    /// The closest repository root at or above `directory`, or nil when there is
    /// none below the ceiling. Nil for a path that does not exist.
    public func repositoryRoot(containing directory: URL) -> URL? {
        let start = Self.normalized(
            directory.resolvingSymlinksInPath().path(percentEncoded: false)
        )
        guard FileManager.default.fileExists(atPath: start) else { return nil }

        // The ceiling only bounds the walk when the start is inside it. Starting
        // outside home (/opt/homebrew, /Volumes/...) walks to "/" instead, so
        // resolution keeps working there rather than returning nil everywhere.
        let bounded = start == ceilingPath || start.hasPrefix(ceilingPath + "/")

        var current = start
        while current != "/" {
            if bounded, current == ceilingPath { return nil }
            if holdsGitEntry(current) {
                return URL(filePath: current, directoryHint: .isDirectory)
            }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// A repository root holds `.git` as either a directory (a normal clone) or
    /// a regular file (a linked worktree or a submodule, holding a `gitdir:`
    /// pointer). `fileExists` covers both in one call.
    private func holdsGitEntry(_ directoryPath: String) -> Bool {
        FileManager.default.fileExists(atPath: directoryPath + "/.git")
    }

    /// Drops a trailing slash so prefix comparisons and equality behave. Leaves
    /// "/" alone.
    private static func normalized(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }
}
