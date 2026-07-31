/// One key hint along a palette's bottom edge.
public struct PaletteHint: Sendable, Equatable {
    public let key: String
    public let label: String

    public init(key: String, label: String) {
        self.key = key
        self.label = label
    }
}

/// What a palette offers, and in which state.
///
/// **In a package because the rule is answerable with no `NSView` in sight**, and
/// because the fault it fixes is one nothing could have caught while the list was
/// a static on the view that draws it. The rule is which hints, not how they are
/// laid out; `PaletteHintsView` still owns the drawing.
public enum PaletteHints {
    /// The way out, which works in every state and is therefore never dropped.
    public static let close = PaletteHint(key: "esc", label: "close")

    /// The command palette's hints.
    ///
    /// **Two actions, not three**, when there is something to act on. A new window
    /// is rare enough that the menu covers it, and every hint here is one the
    /// reader has to carry.
    ///
    /// **None of them when there is not.** `CommandPaletteController.open(at:)`
    /// opens `guard results.indices.contains(index)` and `go` opens
    /// `guard !results.isEmpty`, so under `NO MATCHES` both advertised actions
    /// return immediately, and the footer went on naming them. That is the fault
    /// `PaletteHintsView.hints` was introduced to fix, caught then across two
    /// panels and missed across two states of one panel: a hint that names the
    /// wrong action is read once and believed.
    ///
    /// Escape stays, and the empty state removes rather than rewords. Someone
    /// reading this row has just failed to find what they were looking for, which
    /// is the worst moment to hand them a second thing to parse.
    public static func palette(hasResults: Bool) -> [PaletteHint] {
        guard hasResults else { return [close] }
        return [
            PaletteHint(key: "\u{21A9}", label: "new tab"),
            PaletteHint(key: "\u{21E7}\u{21A9}", label: "split right"),
            close,
        ]
    }
}
