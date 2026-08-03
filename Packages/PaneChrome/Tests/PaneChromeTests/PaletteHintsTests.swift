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

/// The verb mode's hints, which differ from the project mode's because a verb
/// has one action and a project has two.
@Suite struct PaletteVerbHintsTests {
    /// The project row advertises "split right", and `open(at:)` ignores the
    /// action for a verb, so carrying that hint into verb mode would name an
    /// action that does nothing. That is the fault this whole type exists to
    /// prevent.
    @Test func verbModeNamesOneActionAndNotTwo() {
        let hints = PaletteHints.verbs(hasResults: true)
        #expect(hints.map(\.label) == ["run", "close"])
        #expect(!hints.contains { $0.label == "split right" })
    }

    @Test func verbModeWithNoResultsOffersOnlyTheWayOut() {
        #expect(PaletteHints.verbs(hasResults: false).map(\.label) == ["close"])
    }

    @Test func escapeSurvivesBothVerbStates() {
        for hasResults in [true, false] {
            #expect(PaletteHints.verbs(hasResults: hasResults).contains { $0.label == "close" })
        }
    }
}
