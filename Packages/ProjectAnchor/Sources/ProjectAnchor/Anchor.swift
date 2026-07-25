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
        self.url = url
        self.kind = kind
        self.source = source
    }

    /// The name a title or a sidebar shows.
    public var displayName: String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path(percentEncoded: false) : name
    }
}
