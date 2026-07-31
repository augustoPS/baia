import Foundation

/// A window's arrangement, with no identities in it.
///
/// What `layout export` prints and `layout apply` reads: the shape of each tab's
/// splits, the fraction every divider sits at, the order of the tabs, and a
/// working directory per pane.
///
/// **A template, not a snapshot, and the difference is the whole design.** There
/// are no pane ids in here, no focus, no zoom, and no provenance. `apply` mints
/// fresh panes, so an id in the document would name a pane the applied window
/// will never hold, and a reader would take it for one it could address. Dropping
/// them is also what lets `export` describe the caller's whole window without
/// handing it a sibling's display id, which is the reconnaissance
/// ``PaneRecord/redacted(toVisible:)`` exists to withhold. The scope argument in
/// full is on ``ControlVerb/layoutExport``.
///
/// Written to be edited by hand and committed next to a Makefile, which is the
/// case the verb exists for. Nothing here is derived from anything else, so an
/// owner who deletes a subtree or retypes a path has a document that still means
/// what it looks like it means.
public struct ControlLayout: Sendable, Equatable, Codable {
    /// The document version this build writes and the only one it applies.
    ///
    /// Refused rather than guessed at, unlike ``SessionSnapshot``'s additive rule,
    /// because this document is written by hand: a file from a newer baia may use
    /// a field this build would silently ignore, and silently ignoring a field in
    /// a layout means opening the wrong panes rather than opening none.
    public static let currentVersion = 1

    /// How many panes one document may open.
    ///
    /// A cap and not a guess: every leaf is a real shell, so an applied document
    /// is a fork of exactly this many processes. Thirty-two is well past any
    /// arrangement a window can seat, and far short of a number that would matter.
    public static let maxPanes = 32

    /// How deeply splits may nest.
    ///
    /// Redundant against ``maxPanes`` for a well-formed tree and kept anyway,
    /// because the walk below recurses and the cap is what bounds it. Note what
    /// this does **not** defend: a frame that nests deeply enough to exhaust the
    /// stack does so inside the decoder, before anything here runs, bounded only
    /// by ``ControlWire/maxFrameBytes``. Availability against a pane that already
    /// holds a shell is not a boundary this channel claims; scope is.
    public static let maxDepth = 16

    /// The band a ratio is clamped into, matching the one a dragged divider
    /// persists within. A ratio outside it describes a pane that is on screen at
    /// zero width: invisible, unreachable by mouse, and running a live shell.
    public static let ratioBounds = 0.05 ... 0.95

    public var version: Int

    /// One tree per tab, in tab order. A one-tab document is the ordinary case and
    /// still an array, so `apply` has one shape to walk.
    public var tabs: [ControlLayoutNode]

    public init(version: Int = ControlLayout.currentVersion, tabs: [ControlLayoutNode]) {
        self.version = version
        self.tabs = tabs
    }

    /// Every pane the document would open.
    public var paneCount: Int {
        tabs.reduce(0) { $0 + $1.paneCount }
    }

    /// The deepest nesting in any tab, where a lone pane is 1.
    public var depth: Int {
        tabs.map(\.depth).max() ?? 0
    }

    /// Why this document cannot be applied, or nil when it can.
    ///
    /// A sentence rather than a code, because both callers print it: the CLI
    /// refuses a bad file before opening the socket, and the server refuses the
    /// same file again on the way in. **Neither check may be the only one.** The
    /// CLI's exists so a typo costs no round trip; the server's is the rule,
    /// because a frame can arrive with no CLI in front of it, which is the same
    /// division `--kinds` already follows.
    public func refusal() -> String? {
        guard version == ControlLayout.currentVersion else {
            return "this layout says version \(version) and baia writes and reads version "
                + "\(ControlLayout.currentVersion). Re-export it from the baia you are running."
        }
        guard tabs.isEmpty == false else {
            return "this layout has no tabs in it, so there is nothing to open"
        }
        let panes = paneCount
        guard panes <= ControlLayout.maxPanes else {
            return "this layout opens \(panes) panes and the cap is \(ControlLayout.maxPanes). "
                + "Every pane is a shell, so the cap is on processes rather than on drawing."
        }
        let depth = depth
        guard depth <= ControlLayout.maxDepth else {
            return "this layout nests \(depth) splits deep and the cap is "
                + "\(ControlLayout.maxDepth)"
        }
        if let bad = tabs.compactMap({ $0.firstUnusableRatio }).first {
            return "a split in this layout sits at \(bad), which is not a fraction. Ratios are "
                + "the first child's share of its split, between 0 and 1."
        }
        return nil
    }

    /// A ratio brought into ``ratioBounds``.
    ///
    /// Clamped rather than refused, matching what `resize --by` does with a
    /// fraction past its stop: a hand-edited 0.02 is somebody asking for a narrow
    /// pane, and answering that with a refusal helps nobody. Only a value that is
    /// not a fraction at all is refused, by ``refusal()``, because there is no
    /// nearest sensible reading of one.
    public static func clampedRatio(_ ratio: Double) -> Double {
        guard ratio.isFinite else { return 0.5 }
        return min(max(ratio, ratioBounds.lowerBound), ratioBounds.upperBound)
    }
}

/// One node of a layout: either a pane, or a divider with a node on each side.
///
/// The same shape as `WorkspaceLayout.PaneTree` and deliberately a different type.
/// This package imports Foundation and nothing else, and the CLI links it: a wire
/// type that was also a layout type would drag the layout package into the tool,
/// which is the reason ``ControlAxis`` exists beside `SplitAxis` rather than
/// instead of it.
///
/// `Codable` is the compiler's synthesized enum conformance, the same one
/// `PaneTree` relies on, so a leaf reads `{"pane":{"cwd":"/x"}}` and a split reads
/// `{"split":{"axis":"horizontal","ratio":0.5,"first":{…},"second":{…}}}`.
public indirect enum ControlLayoutNode: Sendable, Equatable, Codable {
    /// A pane, and where its shell starts.
    ///
    /// Nil means "wherever a new pane would have started anyway", which is what
    /// `apply` opens it at. Export leaves it nil for every pane outside what
    /// `list` would already show the caller, so a document exported from one pane
    /// carries its own directory and its descendants', and the shape of the rest.
    case pane(cwd: String?)

    /// A divider. `ratio` is the **first** child's share of this split's space,
    /// matching `PaneTree.split`, and `axis` is named after how the children sit:
    /// `horizontal` is side by side, which is what `baia split --right` asks for.
    case split(axis: ControlAxis, ratio: Double, first: ControlLayoutNode, second: ControlLayoutNode)

    public var paneCount: Int {
        switch self {
        case .pane: 1
        case let .split(_, _, first, second): first.paneCount + second.paneCount
        }
    }

    public var depth: Int {
        switch self {
        case .pane: 1
        case let .split(_, _, first, second): 1 + max(first.depth, second.depth)
        }
    }

    /// The first ratio in this subtree that no reading can rescue, or nil.
    ///
    /// Non-finite only. Everything else is a fraction somebody meant, and
    /// ``ControlLayout/clampedRatio(_:)`` decides what it becomes.
    var firstUnusableRatio: Double? {
        switch self {
        case .pane:
            nil
        case let .split(_, ratio, first, second):
            ratio.isFinite
                ? (first.firstUnusableRatio ?? second.firstUnusableRatio)
                : ratio
        }
    }
}
