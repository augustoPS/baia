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

    /// The root a clicked sidebar row's path is resolved against when the click is
    /// allowed to reach the prompt, or nil where nothing may be sent.
    ///
    /// **A repository and nothing else, which is what parts it from
    /// ``refusalRoot(of:)``.** A bare shell pane stays send-inert: the owner ruled
    /// on 2026-08-13 that a walked tree lists rows to *look* at, and that putting a
    /// path on the prompt stays a repository's affordance. The tree under a
    /// `.plain` anchor exists because `AppDelegate.refreshSidebar(of:)` gives it
    /// `listing = .directory` and walks it with `DirectoryTree`; that makes the
    /// rows real, not clickable-to-send.
    public static func promptRoot(of anchor: Anchor?) -> URL? {
        repositoryRoot(of: anchor)
    }

    /// The root a clicked row is resolved against **for the purpose of explaining a
    /// refusal**, or nil where there is no anchor at all.
    ///
    /// **Any anchor with a root, and that is the whole difference from
    /// ``promptRoot(of:)``.** Whether a path may be *sent* is a question about the
    /// pane; whether a path is *unholdable by a shell* is a question about the
    /// bytes, and it has the same answer under either kind of anchor.
    /// `PanePrompt.PromptPath.resolve` is lexical with no notion of git, so a plain
    /// directory resolves exactly as a repository root does.
    ///
    /// **Written after a silent refusal, on 2026-08-13.** `sendToPrompt` guarded on
    /// `kind == .repository`, left over from when only repositories had trees, and
    /// returned before `PromptPath.resolve` ran. A row whose name the shell cannot
    /// hold was refused with no reason given: the row drew its red flash off the
    /// `false` return, the beep sounded, and `showNotice` — the whole path that
    /// puts the reason on the pane's capsule — was never reached. The defect read
    /// as "the notice does not render", and the notice was never asked for.
    ///
    /// Keeping the two roots separate is what lets a bare pane stay send-inert
    /// *and* still say why a name is impossible, rather than trading one silence
    /// for another.
    ///
    /// Here rather than at the call site for this package's own rule: it is
    /// decidable without a window, and the app target has no test target, so a
    /// predicate living there is one nothing can grade. That is exactly how the
    /// original guard survived.
    public static func refusalRoot(of anchor: Anchor?) -> URL? {
        anchor?.url
    }
}
