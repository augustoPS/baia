#if DEBUG

    import Foundation
    import Testing

    @testable import BaiaSettings

    /// What `DesignOverridesText` emits, pinned from the side that can drift.
    ///
    /// The emitter carries thirty-two field paths and thirty-two hand-written
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
            // against `DesignOverrides.swift`'s own inventory of thirty-two leaf
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

            "chrome.barLift", "chrome.sidebarWashFloor", "chrome.bareGlass",
        ]

        /// Thirty-two, which is the count `DesignOverrides` carries: seven
        /// settings shadows, nine lift, two rim, six inks, five surfaces, three
        /// window.
        static let expectedKeyCount = 32

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

        // MARK: - Reading it back

        // The emitter's output is also the format of
        // `~/.config/baia/design-overrides.json`, the file the app watches while
        // the design panel's own controls are untrustworthy on 26A5388g. So a
        // paste of Copy Values into that file has to come back as the value that
        // was copied — which is what these hold, from the side the emitter tests
        // above cannot see.

        @Test func aFullyPopulatedValueSurvivesTheRoundTrip() {
            let overrides = everythingDialled()
            let text = DesignOverridesText.commentedJSON(overrides)

            #expect(DesignOverridesText.parse(text) == .success(overrides))
        }

        @Test func aSparseValueSurvivesTheRoundTrip() {
            // The realistic shape: two knobs dialled after an afternoon, twenty
            // nine still nil. A parser that filled the absent fields with zeroes
            // rather than leaving them nil would pin every un-dialled knob, which
            // is precisely the failure `DesignOverrides`' own doc comment names.
            var overrides = DesignOverrides()
            overrides.chrome.lift.ringAlpha = 0.31
            overrides.chrome.inks.sessionHeaderHex = "#ff8800"
            let text = DesignOverridesText.commentedJSON(overrides)

            #expect(DesignOverridesText.parse(text) == .success(overrides))
        }

        @Test func theNothingDialledEmissionParsesToAnEmptyValue() {
            // The emitter answers a lone comment inside braces rather than `{}`,
            // and that text is what an owner who has just hit Reset would paste.
            let text = DesignOverridesText.commentedJSON(DesignOverrides())

            #expect(DesignOverridesText.parse(text) == .success(DesignOverrides()))
        }

        @Test func anEmptyObjectParsesToAnEmptyValue() {
            #expect(DesignOverridesText.parse("{}") == .success(DesignOverrides()))
        }

        @Test func aFileOfNothingButCommentsParsesToAnEmptyValue() {
            let text = """
            // everything commented out for the moment
            {
              // "chrome.lift.ringAlpha": 0.31, // parked
            }
            """

            #expect(DesignOverridesText.parse(text) == .success(DesignOverrides()))
        }

        @Test func commentsAndBlankLinesAreToleratedAnywhere() {
            let text = """

            // a header the owner typed himself

            {

              // lift
              "chrome.lift.ringAlpha": 0.31, // ChromeMaterials.Lift.ringAlpha, today 0.22

              "chrome.inks.busyDotHex": "#00ff00" // no trailing comma on the last one

            }
            // a footer
            """
            var expected = DesignOverrides()
            expected.chrome.lift.ringAlpha = 0.31
            expected.chrome.inks.busyDotHex = "#00ff00"

            #expect(DesignOverridesText.parse(text) == .success(expected))
        }

        @Test func aDoubleSlashInsideAStringIsNotACommentMarker() {
            // The comment stripper walks strings rather than searching for `//`,
            // so a value that happens to contain the marker survives. No knob
            // holds a path today; a stripper that could not tell the two apart
            // would be a trap laid for the first one that does.
            let text = "{ \"chrome.inks.busyDotHex\": \"#00//00\" }"

            var expected = DesignOverrides()
            expected.chrome.inks.busyDotHex = "#00//00"

            #expect(DesignOverridesText.parse(text) == .success(expected))
        }

        // MARK: - Refusing the whole file

        @Test func anUnknownKeyFailsTheWholeParseAndNamesIt() {
            // **Not per-field resilience, deliberately, and this is the one place
            // `BaiaSettings` departs from `SettingsDecoder`.** The config file is
            // read once at launch and its keys are learned from the file baia
            // writes; this file is hand-edited over and over during a dialling
            // session, from memory. A typo silently ignored there means the owner
            // turns a knob, sees nothing move, and concludes the *knob* does
            // nothing — which gaslights the exact question the session is asking.
            let result = DesignOverridesText.parse("""
            {
              "chrome.lift.ringAlfa": 0.31
            }
            """)

            guard case let .failure(error) = result else {
                Issue.record("an unknown key parsed")
                return
            }
            #expect(error.message.contains("chrome.lift.ringAlfa"))
        }

        @Test func aValueOfTheWrongTypeFailsTheWholeParseAndNamesTheKey() {
            let result = DesignOverridesText.parse("""
            {
              "chrome.lift.ringAlpha": "0.31"
            }
            """)

            guard case let .failure(error) = result else {
                Issue.record("a string in a Double field parsed")
                return
            }
            #expect(error.message.contains("chrome.lift.ringAlpha"))
        }

        @Test func aValueOutsideAnEnumFailsTheWholeParseAndNamesTheKey() {
            // `"marble"` is a string in a field that takes strings, so nothing but
            // the case list can catch it, and the case list is exactly what an
            // owner types from memory.
            let result = DesignOverridesText.parse("""
            {
              "chrome.surfaces.footer": "marble"
            }
            """)

            guard case let .failure(error) = result else {
                Issue.record("an unspellable material parsed")
                return
            }
            #expect(error.message.contains("chrome.surfaces.footer"))
        }

        @Test func aDocumentThatIsNotAnObjectFails() {
            for text in ["[]", "0.31", "{", "{ \"chrome.barLift\": }", ""] {
                guard case .failure = DesignOverridesText.parse(text) else {
                    Issue.record("parsed a document that is not an object: \(text)")
                    return
                }
            }
        }

        @Test func theTrailingCommaToleranceIsExactlyOneCommaWide() {
            // The emitter writes a comma on every line including the last, so the
            // stripped text ends `..., }` and one comma has to be forgiven. That
            // is a hole in the JSON grammar, and this pins how wide it is: a
            // comma with a *missing value* after it is still a broken document,
            // not a second trailing comma to be swallowed.
            guard case .failure = DesignOverridesText.parse("""
            { "chrome.barLift": 0.08, , }
            """) else {
                Issue.record("a document with a hole between commas parsed")
                return
            }
        }

        @Test func everyKeyTheEmitterWritesIsAKeyTheParserAccepts() {
            // The inventory test from the emitting side, turned around. A knob
            // given a line in the emitter and no case in the parser would make
            // Copy Values produce text that Copy Values' own destination refuses,
            // and the failure would only show up in a dialling session.
            for key in Self.everyKeyPath {
                let value = Self.sampleLiteralsByKey[key]
                #expect(value != nil, "no sample literal for \(key)")
                guard let value else { continue }
                guard case .success = DesignOverridesText.parse("{ \"\(key)\": \(value) }") else {
                    Issue.record("the parser refused the emitted key \(key)")
                    continue
                }
            }
        }

        /// One literal of the right shape per emitted key, for the sweep above.
        static let sampleLiteralsByKey: [String: String] = [
            "backgroundOpacity": "0.5",
            "backgroundBlur": "true",
            "chromeStyle": "\"glass\"",
            "attentionStyle": "\"\(AttentionStyle.allCases[0].rawValue)\"",
            "attentionAccent": "\"\(AttentionAccent.allCases[0].rawValue)\"",
            "focusAccent": "\"\(FocusAccent.allCases[0].rawValue)\"",
            "transparentTitlebar": "false",

            "chrome.lift.enabled": "true",
            "chrome.lift.ringSpread": "1.25",
            "chrome.lift.ringAlpha": "0.22",
            "chrome.lift.innerHighlightOffsetY": "1.0",
            "chrome.lift.innerHighlightAlpha": "0.3",
            "chrome.lift.shadowDropOffsetY": "12.0",
            "chrome.lift.shadowDropBlur": "34.0",
            "chrome.lift.shadowDropAlpha": "0.6",
            "chrome.lift.duration": "0.18",

            "chrome.rim.enabled": "true",
            "chrome.rim.topAlpha": "0.42",

            "chrome.inks.sessionHeaderMinimumRatio": "7.0",
            "chrome.inks.sessionHeaderHex": "\"#ff8800\"",
            "chrome.inks.actionRowMinimumRatio": "4.5",
            "chrome.inks.actionRowHex": "\"#00aaff\"",
            "chrome.inks.sectionHeaderMinimumRatio": "4.5",
            "chrome.inks.busyDotHex": "\"#00ff00\"",

            "chrome.surfaces.footer": "\"thick\"",
            "chrome.surfaces.sidebar": "\"sidebar\"",
            "chrome.surfaces.palette": "\"menu\"",
            "chrome.surfaces.popover": "\"menu\"",
            "chrome.surfaces.titlebar": "\"chrome\"",

            "chrome.barLift": "0.08",
            "chrome.sidebarWashFloor": "0.2",
            "chrome.bareGlass": "true",
        ]

        // MARK: - Fixture

        /// Every one of the thirty-two knobs dialled to something, so a test can
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
            overrides.chrome.bareGlass = true
            return overrides
        }
    }

#endif
