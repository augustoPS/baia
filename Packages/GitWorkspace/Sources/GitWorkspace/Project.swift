import Foundation

/// One entry in the project palette.
public struct Project: Sendable, Equatable, Hashable {
    /// What the palette is offering to open.
    ///
    /// `.directory` exists because `lifetracker/` on this machine has no `.git`
    /// at all and is still a project the owner switches to. Treating every child
    /// of a root as a repository would drop it from the palette entirely.
    public enum Kind: Sendable, Equatable, Hashable {
        case repository
        case worktree(ofRepositoryNamed: String)
        case directory
    }

    public var url: URL
    public var displayName: String
    public var kind: Kind
    /// Path shown in the palette, relative to the root it was found under, for
    /// example `website/shop`. This is what disambiguates nested repositories.
    public var relativePath: String

    public init(url: URL, displayName: String, kind: Kind, relativePath: String) {
        // Canonicalized the way ProjectAnchor's `Anchor` is. `Project` is
        // `Hashable` so a caller may put these in a `Set`, and a URL built with
        // a directory hint hashes differently from one built without it for the
        // same directory, which would seat the same project twice.
        self.url = URL(filePath: url.path(percentEncoded: false), directoryHint: .isDirectory)
        self.displayName = displayName
        self.kind = kind
        self.relativePath = relativePath
    }
}
