import Foundation

/// The identity of one repository as the workspace observes it.
///
/// Two panes reach the same repository by different spellings: one anchored at
/// `~/Projects/vault`, one at `~/Projects/vault/`, one through a symlink, one
/// through `/private/tmp` where the other says `/tmp`. Keyed by `URL` they are
/// four repositories and four polls; the hub records the `directoryHint` trap in
/// so many words. Keyed by this type they are one.
///
/// Three paths live here and they are deliberately not the same string:
///
/// - ``url`` is the spelling the caller gave, normalised only in ways that cannot
///   change what a process sees: standardised, directory-hinted, no trailing
///   separator. It is what the display and a pane's own shell receive, so a pane
///   anchored through a symlink keeps showing and running under that symlink.
/// - ``path`` is ``url`` as a string, for display and for handing to a shell.
/// - ``identity`` is the private observation key: the same path with symlinks
///   resolved, so aliases collapse without rewriting anything the owner sees.
///   Equality and hashing use it and nothing else.
/// - ``processURL`` is ``identity`` as a directory URL. Shared git reads use this,
///   so deleting or retargeting an alias the first subscriber pinned cannot send
///   `git -C` into a missing path or a different repository.
///
/// The identity resolves through the filesystem as it is when the root is made,
/// which is what makes it physical rather than lexical. A path that does not
/// exist yet keeps its own spelling as its identity. Two spellings that differ
/// only by letter case on a case-insensitive volume are not collapsed; that
/// alias is rare enough that paying a `stat` on every anchor change for it was
/// not worth it, and it is recorded here rather than claimed.
public struct RepositoryRoot: Hashable, Sendable, CustomStringConvertible {
    /// The caller's spelling, normalised, with a directory hint.
    public let url: URL

    /// ``url`` as a path string without a trailing separator.
    public let path: String

    /// The physical identity, for deduplicating observation. Not for display,
    /// not for a pane's shell working directory.
    public let identity: String

    /// The path shared git reads must use: ``identity`` as a directory URL.
    ///
    /// Captured when the root is made. A later `stat` of ``url`` can follow a
    /// retargeted symlink into another repository; this URL does not.
    public var processURL: URL {
        URL(filePath: identity, directoryHint: .isDirectory)
    }

    public init(_ url: URL) {
        let spelled = Self.trimmed(url.standardizedFileURL.path(percentEncoded: false))
        path = spelled
        self.url = URL(filePath: spelled, directoryHint: .isDirectory)
        identity = Self.trimmed(
            URL(filePath: spelled, directoryHint: .isDirectory)
                .resolvingSymlinksInPath()
                .path(percentEncoded: false)
        )
    }

    public static func == (lhs: RepositoryRoot, rhs: RepositoryRoot) -> Bool {
        lhs.identity == rhs.identity
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(identity)
    }

    public var description: String { path }

    private static func trimmed(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }
}
