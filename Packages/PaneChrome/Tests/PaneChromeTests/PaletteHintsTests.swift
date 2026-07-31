import Testing

@testable import PaneChrome

/// What the command palette offers along its bottom edge, and when.
@Suite struct PaletteHintsTests {
    @Test func aPaletteWithResultsOffersBothActions() {
        let hints = PaletteHints.palette(hasResults: true)
        #expect(hints.map(\.label) == ["new tab", "split right", "close"])
    }

    /// **The fault this rule exists for.** `CommandPaletteController.open(at:)`
    /// opens `guard results.indices.contains(index)` and `go` opens
    /// `guard !results.isEmpty`, so with nothing matched both advertised actions
    /// return immediately. The footer said `↵ new tab  ⇧↵ split right` over the
    /// words `NO MATCHES`.
    ///
    /// This is the same fault `PaletteHintsView.hints` was introduced to fix,
    /// caught then across two panels and missed here across two states of one. Its
    /// comment is the argument either way: a hint that names the wrong action is
    /// read once and believed.
    @Test func aPaletteWithNoResultsOffersOnlyTheWayOut() {
        #expect(PaletteHints.palette(hasResults: false).map(\.label) == ["close"])
    }

    /// Escape is the one thing that works in both states, so it must never be the
    /// hint that gets dropped. Stated on its own because the empty case is a list
    /// of one and a rule that returned an empty list would still satisfy "does not
    /// advertise a dead action".
    @Test func escapeSurvivesInBothStates() {
        for hasResults in [true, false] {
            let hints = PaletteHints.palette(hasResults: hasResults)
            #expect(hints.contains { $0.key == "esc" && $0.label == "close" })
        }
    }

    /// The empty state is a strict subset rather than a different vocabulary. A
    /// hint whose wording changed with the result count would be a second thing to
    /// read at the moment the reader has already failed to find something.
    @Test func theEmptyStateOnlyRemovesRatherThanRewording() {
        let full = PaletteHints.palette(hasResults: true)
        for hint in PaletteHints.palette(hasResults: false) {
            #expect(full.contains(hint), "\(hint.label) is not one of the full set's hints")
        }
    }
}
