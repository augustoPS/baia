import Foundation

/// Where a pane's project is rooted, and how that root was decided.
public struct Anchor: Equatable, Sendable {
    /// Whether the anchor is a git repository root or a plain directory. A plain
    /// anchor is what a pane gets outside any repository, so a file tree always
    /// has a root and a git panel can show nothing without special-casing nil.
    public enum Kind: Equatable, Sendable {
        case repository
        case plain
    }

    /// Whether the anchor was derived from the working directory or pinned by
    /// hand. Part of equality: pinning the directory the shell already sits in
    /// changes nothing but the source, and the display still has to update.
    public enum Source: Equatable, Sendable {
        case automatic
        case pinned
    }

    public let url: URL
    public let kind: Kind
    public let source: Source

    public init(url: URL, kind: Kind, source: Source) {
        // Canonicalized so two URLs for one directory cannot produce two unequal
        // anchors. The resolver passes a pin and a non-repository working
        // directory through verbatim, and a caller that built either without a
        // directory hint would otherwise read as a changed anchor to
        // PaneAnchorTracker, which notifies on inequality.
        //
        // Symlinks are deliberately not resolved: a pin is shown to the user as
        // they chose it, and the automatic path is already resolved by the
        // locator. So pinning a symlink to a repository yields `.repository`
        // with the symlink's own `displayName`, which is intended.
        self.url = URL(filePath: url.path(percentEncoded: false), directoryHint: .isDirectory)
        self.kind = kind
        self.source = source
    }

    /// The name a title or a sidebar shows.
    public var displayName: String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path(percentEncoded: false) : name
    }

    /// The repository this anchor names, or nil where there is none.
    ///
    /// Only a `.repository` anchor has git state. A `.plain` anchor gets nil and
    /// so does no anchor at all, which is why this takes the optional rather than
    /// being a property: a caller writing `anchor?.repositoryRoot` would get a
    /// doubly-optional URL and have to flatten it, and the two nils mean the same
    /// thing here. `PaneStatusSegments` then emits no git segments at all rather
    /// than a branch-shaped blank.
    public static func repositoryRoot(of anchor: Anchor?) -> URL? {
        guard let anchor, anchor.kind == .repository else { return nil }
        return anchor.url
    }
}
