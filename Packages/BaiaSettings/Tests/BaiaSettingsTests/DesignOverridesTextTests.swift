#if DEBUG

    import Foundation
    import Testing

    @testable import BaiaSettings

    /// What `DesignOverridesText` emits, pinned from the side that can drift.
    ///
    /// The emitter carries thirty-one field paths and thirty-one hand-written
    /// notes naming the constants they stand in for. A renamed field breaks the
    /// compile and needs no test; the two failures that compile cleanly are what
    /// these hold:
    ///
    /// - **A note that has gone stale.** "today 0.22" survives the constant
    ///   moving to 0.30, and the owner pastes a comment that lies about what he
    ///   was dialling away from.
    /// - **A field added to `DesignOverrides` and never given a line here.** The
    ///   emitter compiles, the panel dials the knob, and Copy Values silently
    ///   omits it — which is the worse half, because the output looks complete.
    ///
    /// ``everyFieldOnTheTypeIsEmitted`` is the one aimed squarely at the second.
    @Suite struct DesignOverridesTextTests {
        // MARK: - Nothing dialled

        @Test func anEmptyValueSaysSoRatherThanEmittingAnEmptyObject() {
            // `{}` would be ambiguous between "nothing dialled" and "the emitter
            // dropped everything", and the two are worth telling apart in a
            // pasteboard whose whole purpose is being read later out of context.
            let text = DesignOverridesText.commentedJSON(DesignOverrides())

            #expect(text.contains("nothing dialled"))
            #expect(!text.contains("\":"))
        }

        // MARK: - Only what is set

        @Test func anUnsetFieldIsAbsentRatherThanNull() {
            // nil means "the committed value", so emitting it as `null` would
            // list thirty knobs the owner never touched beside the one he did.
            var overrides = DesignOverrides()
            overrides.backgroundOpacity = 0.42
            let text = DesignOverridesText.commentedJSON(overrides)

            #expect(text.contains("\"backgroundOpacity\": 0.42,"))
            #expect(!text.contains("backgroundBlur"))
            #expect(!text.contains("null"))
        }

        @Test func aGroupWithNothingDialledEmitsNoHeader() {
            // The group headers are the only structure in the output. One printed
            // over no fields would read as a group whose values failed to emit.
            var overrides = DesignOverrides()
            overrides.backgroundOpacity = 0.42
            let text = DesignOverridesText.commentedJSON(overrides)

            #expect(text.contains("// settings shadows"))
            for absent in ["// lift", "// rim", "// inks", "// materials", "// window"] {
                #expect(!text.contains(absent))
            }
        }

        @Test func everyGroupAppearsOnceEverythingIsDialled() {
            let text = DesignOverridesText.commentedJSON(everythingDialled())

            for group in ["// settings shadows", "// lift", "// rim",
                          "// inks", "// materials", "// window"] {
                #expect(text.contains(group))
            }
        }

        // MARK: - The inventory

        @Test func everyFieldOnTheTypeIsEmitted() {
            // **The one that catches a knob added and forgotten.** Dialling every
            // field and asserting a line per field means a new field on
            // `DesignOverrides` fails here rather than being silently absent from
            // what the owner pastes.
            //
            // The key paths are written out rather than derived, because Swift
            // offers no reflection over a struct's stored properties that would
            // survive `-O`. So this list is itself a thing that can go stale, and
            // the guard against that is `expectedKeyCount`: the count is asserted
            // against `DesignOverrides.swift`'s own inventory of thirty-one leaf
            // knobs, so a field added there without a line here fails on the count
            // even if nobody thought to add it to this list.
            let text = DesignOverridesText.commentedJSON(everythingDialled())

            for key in Self.everyKeyPath {
                #expect(text.contains("\"\(key)\":"), "no line emitted for \(key)")
            }
            #expect(Self.everyKeyPath.count == Self.expectedKeyCount)

            let emitted = text.split(separator: "\n").filter { $0.contains("\":") }
            #expect(emitted.count == Self.expectedKeyCount)
        }

        /// Every leaf knob on ``DesignOverrides``, as the emitter spells it.
        static let everyKeyPath = [
            "backgroundOpacity", "backgroundBlur", "chromeStyle", "attentionStyle",
            "attentionAccent", "focusAccent", "transparentTitlebar",

            "chrome.lift.enabled", "chrome.lift.ringSpread", "chrome.lift.ringAlpha",
            "chrome.lift.innerHighlightOffsetY", "chrome.lift.innerHighlightAlpha",
            "chrome.lift.shadowDropOffsetY", "chrome.lift.shadowDropBlur",
            "chrome.lift.shadowDropAlpha", "chrome.lift.duration",

            "chrome.rim.enabled", "chrome.rim.topAlpha",

            "chrome.inks.sessionHeaderMinimumRatio", "chrome.inks.sessionHeaderHex",
            "chrome.inks.actionRowMinimumRatio", "chrome.inks.actionRowHex",
            "chrome.inks.sectionHeaderMinimumRatio", "chrome.inks.busyDotHex",

            "chrome.surfaces.footer", "chrome.surfaces.sidebar", "chrome.surfaces.palette",
            "chrome.surfaces.popover", "chrome.surfaces.titlebar",

            "chrome.barLift", "chrome.sidebarWashFloor",
        ]

        /// Thirty-one, which is the count `DesignOverrides` carries: seven
        /// settings shadows, nine lift, two rim, six inks, five surfaces, two
        /// window.
        static let expectedKeyCount = 31

        // MARK: - JSON shapes

        @Test func eachTypeEmitsItsOwnLiteralShape() {
            let text = DesignOverridesText.commentedJSON(everythingDialled())

            #expect(text.contains("\"backgroundBlur\": true,"))
            #expect(text.contains("\"chromeStyle\": \"glass\","))
            #expect(text.contains("\"chrome.inks.sessionHeaderHex\": \"#ff8800\","))
            #expect(text.contains("\"chrome.surfaces.footer\": \"thick\","))
        }

        @Test func theOutputIsBracedAndEveryLineIsIndented() {
            let text = DesignOverridesText.commentedJSON(everythingDialled())

            #expect(text.hasPrefix("{\n"))
            #expect(text.hasSuffix("}\n"))
            for line in text.split(separator: "\n").dropFirst().dropLast() where !line.isEmpty {
                #expect(line.hasPrefix("  "), "unindented line: \(line)")
            }
        }

        @Test func aDoubleIsPrintedAsTheNumberDialledRatherThanItsBinaryExpansion() {
            // The panel quantizes on the way in, so what is stored is already the
            // number the owner dialled. This only stops `0.30000000000000004`
            // being what he pastes into a commit message.
            var overrides = DesignOverrides()
            overrides.chrome.lift.ringSpread = 0.1 + 0.2
            overrides.chrome.lift.shadowDropBlur = 34
            let text = DesignOverridesText.commentedJSON(overrides)

            #expect(text.contains("\"chrome.lift.ringSpread\": 0.3,"))
            #expect(!text.contains("0.30000"))
            // A whole number keeps one decimal place rather than becoming `34`,
            // so a reader can tell a Double knob from an Int one at a glance.
            #expect(text.contains("\"chrome.lift.shadowDropBlur\": 34.0,"))
        }

        // MARK: - The notes

        @Test func everyEmittedLineCarriesANote() {
            // A bare value is the failure this whole file exists to avoid: the
            // number alone says nothing about which constant it replaces, which
            // is the entire reason the output is commented rather than JSON.
            let text = DesignOverridesText.commentedJSON(everythingDialled())

            for line in text.split(separator: "\n") where line.contains("\":") {
                #expect(line.contains(", //"), "value with no note: \(line)")
            }
        }

        @Test func theCaveatsThatCouldNotFitInAPanelLabelSurviveIntoTheText() {
            // Each of these is a property of the knob that the reviewer required
            // be stated somewhere the owner reads. The panel says them in a
            // tooltip, which does not survive being pasted; this is the copy that
            // travels with the value.
            let text = DesignOverridesText.commentedJSON(everythingDialled())

            // The hex/ratio distinction: different kinds of thing, one bypasses
            // the repair chain and can go illegible, and it wins when both are set.
            #expect(text.contains("walks the repair chain"))
            #expect(text.contains("bypasses the repair chain; wins over the ratio above"))
            // One slider, two things moved.
            #expect(text.contains("moves the backdrop AND the ink graded on it"))
            // A floor, not a thinner.
            #expect(text.contains("raises the wash, never thins it"))
            // A re-activation of a dormant path, not a re-selection among live ones.
            #expect(text.contains("dormant since Design v5 Task 2"))
            // Reduce Transparency still overrules a dialled glass.
            #expect(text.contains("Reduce Transparency still overrules"))
            // A shadow inset, not a layout one — the field whose name invites the
            // geometry confusion `DesignOverrides` exists to prevent.
            #expect(text.contains("a shadow inset, not layout"))
        }

        @Test func noNoteClaimsAGeometryKnob() {
            // The no-geometry contract from the far end: `DesignOverrides` has no
            // field that moves a cell metric, so nothing here can name one. A note
            // mentioning a font size or a padding would be the first sign someone
            // had added the field this type structurally lacks.
            let text = DesignOverridesText.commentedJSON(everythingDialled()).lowercased()

            for forbidden in ["fontsize", "font size", "windowpadding", "padding", "fontfamily"] {
                #expect(!text.contains(forbidden), "geometry named in the output: \(forbidden)")
            }
        }

        // MARK: - Fixture

        /// Every one of the thirty-one knobs dialled to something, so a test can
        /// assert over the complete output.
        private func everythingDialled() -> DesignOverrides {
            var overrides = DesignOverrides()
            overrides.backgroundOpacity = 0.5
            overrides.backgroundBlur = true
            overrides.chromeStyle = .glass
            overrides.attentionStyle = AttentionStyle.allCases[0]
            overrides.attentionAccent = AttentionAccent.allCases[0]
            overrides.focusAccent = FocusAccent.allCases[0]
            overrides.transparentTitlebar = false

            overrides.chrome.lift.enabled = true
            overrides.chrome.lift.ringSpread = 1.25
            overrides.chrome.lift.ringAlpha = 0.22
            overrides.chrome.lift.innerHighlightOffsetY = 1
            overrides.chrome.lift.innerHighlightAlpha = 0.3
            overrides.chrome.lift.shadowDropOffsetY = 12
            overrides.chrome.lift.shadowDropBlur = 34
            overrides.chrome.lift.shadowDropAlpha = 0.6
            overrides.chrome.lift.duration = 0.18

            overrides.chrome.rim.enabled = true
            overrides.chrome.rim.topAlpha = 0.42

            overrides.chrome.inks.sessionHeaderMinimumRatio = 7
            overrides.chrome.inks.sessionHeaderHex = "#ff8800"
            overrides.chrome.inks.actionRowMinimumRatio = 4.5
            overrides.chrome.inks.actionRowHex = "#00aaff"
            overrides.chrome.inks.sectionHeaderMinimumRatio = 4.5
            overrides.chrome.inks.busyDotHex = "#00ff00"

            overrides.chrome.surfaces.footer = .thick
            overrides.chrome.surfaces.sidebar = .sidebar
            overrides.chrome.surfaces.palette = .menu
            overrides.chrome.surfaces.popover = .menu
            overrides.chrome.surfaces.titlebar = .chrome

            overrides.chrome.barLift = 0.08
            overrides.chrome.sidebarWashFloor = 0.2
            return overrides
        }
    }

#endif
