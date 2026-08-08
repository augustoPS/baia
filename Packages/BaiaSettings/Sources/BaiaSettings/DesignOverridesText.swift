#if DEBUG

    import Foundation

    /// The design panel's Copy Values text: the dialled overrides as JSON with a
    /// comment per field naming the constant it stands in for.
    ///
    /// ## Why this lives in the package rather than beside the panel
    ///
    /// It was written in `Sources/` next to `DesignPanelController`, which is
    /// where it is used, and moved here because the app target has no test target
    /// and nothing there could reach it. That is this repository's own recorded
    /// lesson (`CLAUDE.md`, "Where logic belongs"): five rules were found living
    /// in `Sources/` and three of the five were wrong or unenforced when they
    /// moved to a package, because nothing could test them.
    ///
    /// This file is exactly that shape. It needs no `NSWindow` and no AppKit — it
    /// is a pure value-to-string map over ``DesignOverrides`` — while carrying
    /// thirty-one field paths and thirty-one hand-written notes naming the
    /// constants they stand in for. Both halves drift silently: a renamed field
    /// would fail to compile, but a note that still says "today 0.22" after the
    /// constant moved would not, and neither would a field added to
    /// ``DesignOverrides`` and never given a line here. ``DesignOverridesTextTests``
    /// is what holds them.
    ///
    /// ## Why this is hand-rolled and `DesignOverrides` has no `Codable`
    ///
    /// **Adjudicated in an earlier review, and recorded here because the absence
    /// looks like an omission.** `DesignOverrides` deliberately conforms to
    /// nothing that serialises, and this emitter is written by hand instead, for
    /// two reasons that both point the same way:
    ///
    /// 1. **What the owner wants copied is not valid JSON.** The useful artefact
    ///    of an afternoon of dialling is a value *beside the constant it replaces*
    ///    — `0.31, // ChromeMaterials.Lift.ringAlpha, today 0.22` — because the
    ///    number alone says nothing about where it goes. Comments are not JSON, so
    ///    a `Codable` encoder could not produce this output whatever was done to
    ///    it, and a second hand-rolled comment pass beside a `JSONEncoder` would be
    ///    two emitters for one string.
    /// 2. **`Codable` would make accidental persistence a one-liner.** The whole
    ///    argument of ``BaiaSettings/DesignOverrides`` is that a dial is a question
    ///    and is never written to `~/.config/baia/config.json`. With an encoder in
    ///    reach, "just save the panel state between launches" becomes two lines and
    ///    a plausible-sounding convenience, and the type's central invariant is
    ///    gone with nothing on screen to say so. Without one, the same change has
    ///    to be argued for.
    ///
    /// So the output is for a human to read and to paste into a commit message, a
    /// vault note, or a constant.
    ///
    /// ## And then it gained a parser, which does not disturb either reason
    ///
    /// **The sentence above used to end "and nothing here should ever gain a
    /// parser". ``parse(_:)`` below is that reversal, made deliberately and for a
    /// reason neither of the two arguments touches.** On macOS 26A5388g the design
    /// panel's own controls can crash the app inside the OS's new gesture bridge,
    /// so the crash-safe way to dial is to edit a file the app watches
    /// (`~/.config/baia/design-overrides.json`) and let a save re-theme the running
    /// app. That file's format is this emitter's output, which is what makes a
    /// paste of Copy Values into it work at all.
    ///
    /// Neither reason above is weakened by that:
    ///
    /// 1. **The format is still comments-beside-values**, because the parser was
    ///    written to the emitter rather than the emitter to a serializer. The
    ///    caveats travel into the file the owner edits, which is where he needs
    ///    them most.
    /// 2. **``DesignOverrides`` still conforms to nothing that serialises**, so
    ///    "just save the panel state between launches" is no closer to being a
    ///    one-liner than it was. This half is a *reader*: the app parses this text
    ///    and never writes it. The file is the owner's document, and the only
    ///    serialisation call site in the project is still Copy Values' clipboard
    ///    write.
    ///
    /// ## Only what is set
    ///
    /// A nil field is absent from the output rather than emitted as `null`,
    /// because nil means "the committed value" and printing all thirty-one would
    /// list the knobs the owner never touched beside the two he did.
    public enum DesignOverridesText {
        /// `overrides` as commented JSON, or a single comment when nothing is
        /// dialled.
        public static func commentedJSON(_ overrides: DesignOverrides) -> String {
            var lines: [String] = []

            appendSettingsShadows(overrides, into: &lines)
            appendLift(overrides.chrome.lift, into: &lines)
            appendRim(overrides.chrome.rim, into: &lines)
            appendInks(overrides.chrome.inks, into: &lines)
            appendSurfaces(overrides.chrome.surfaces, into: &lines)
            appendWindow(overrides.chrome, into: &lines)

            guard !lines.isEmpty else {
                return "{\n  // nothing dialled: every knob is on its committed value\n}\n"
            }
            return "{\n" + lines.joined(separator: "\n") + "\n}\n"
        }

        // MARK: - Groups

        private static func appendSettingsShadows(_ overrides: DesignOverrides, into lines: inout [String]) {
            var group: [String] = []
            append(&group, "backgroundOpacity", overrides.backgroundOpacity,
                   note: "shadows Settings.backgroundOpacity")
            append(&group, "backgroundBlur", overrides.backgroundBlur,
                   note: "shadows Settings.backgroundBlur")
            append(&group, "chromeStyle", overrides.chromeStyle?.rawValue,
                   note: "shadows Settings.chromeStyle; Reduce Transparency still overrules")
            append(&group, "attentionStyle", overrides.attentionStyle?.rawValue,
                   note: "shadows Settings.attentionStyle")
            append(&group, "attentionAccent", overrides.attentionAccent?.rawValue,
                   note: "shadows Settings.attentionAccent")
            append(&group, "focusAccent", overrides.focusAccent?.rawValue,
                   note: "shadows Settings.focusAccent")
            append(&group, "transparentTitlebar", overrides.transparentTitlebar,
                   note: "shadows Settings.transparentTitlebar; retired downstream")
            add(group, titled: "settings shadows", into: &lines)
        }

        private static func appendLift(_ lift: DesignOverrides.Chrome.Lift, into lines: inout [String]) {
            var group: [String] = []
            append(&group, "chrome.lift.enabled", lift.enabled,
                   note: "whether the lift draws at all")
            append(&group, "chrome.lift.ringSpread", lift.ringSpread,
                   note: "ChromeMaterials.Lift.ringSpread, today 0.5 pt")
            append(&group, "chrome.lift.ringAlpha", lift.ringAlpha,
                   note: "ChromeMaterials.Lift.ringAlpha, today 0.22")
            append(&group, "chrome.lift.innerHighlightOffsetY", lift.innerHighlightOffsetY,
                   note: "ChromeMaterials.Lift.innerHighlightOffsetY, today 1 pt (a shadow inset, not layout)")
            append(&group, "chrome.lift.innerHighlightAlpha", lift.innerHighlightAlpha,
                   note: "ChromeMaterials.Lift.innerHighlightAlpha, today 0.30")
            append(&group, "chrome.lift.shadowDropOffsetY", lift.shadowDropOffsetY,
                   note: "ChromeMaterials.Lift.shadow drop offset, today 12 pt")
            append(&group, "chrome.lift.shadowDropBlur", lift.shadowDropBlur,
                   note: "ChromeMaterials.Lift.shadow drop blur, today 34 pt")
            append(&group, "chrome.lift.shadowDropAlpha", lift.shadowDropAlpha,
                   note: "ChromeMaterials.Lift.shadow drop alpha, today 0.6")
            append(&group, "chrome.lift.duration", lift.duration,
                   note: "ChromeMaterials.Motion band, today 0.140-0.220 s")
            add(group, titled: "lift", into: &lines)
        }

        private static func appendRim(_ rim: DesignOverrides.Chrome.Rim, into lines: inout [String]) {
            var group: [String] = []
            append(&group, "chrome.rim.enabled", rim.enabled, note: "whether the rim draws at all")
            append(&group, "chrome.rim.topAlpha", rim.topAlpha,
                   note: "the live appearance's rimTopAlpha, today 0.42 dark / 0.86 light")
            add(group, titled: "rim", into: &lines)
        }

        private static func appendInks(_ inks: DesignOverrides.Chrome.Inks, into lines: inout [String]) {
            var group: [String] = []
            append(&group, "chrome.inks.sessionHeaderMinimumRatio", inks.sessionHeaderMinimumRatio,
                   note: "PaneTheme.minimumTextContrast, today 4.5 (walks the repair chain)")
            append(&group, "chrome.inks.sessionHeaderHex", inks.sessionHeaderHex,
                   note: "bypasses the repair chain; wins over the ratio above")
            append(&group, "chrome.inks.actionRowMinimumRatio", inks.actionRowMinimumRatio,
                   note: "today 4.5 (walks the repair chain)")
            append(&group, "chrome.inks.actionRowHex", inks.actionRowHex,
                   note: "bypasses the repair chain; wins over the ratio above")
            append(&group, "chrome.inks.sectionHeaderMinimumRatio", inks.sectionHeaderMinimumRatio,
                   note: "PaneTheme.sectionHeaderInk(on:) target, today 4.5")
            append(&group, "chrome.inks.busyDotHex", inks.busyDotHex,
                   note: "PaneTheme.ok; a filled shape, so no ratio beside it")
            add(group, titled: "inks", into: &lines)
        }

        private static func appendSurfaces(_ surfaces: DesignOverrides.Chrome.Surfaces, into lines: inout [String]) {
            var group: [String] = []
            let note = "re-activates a fill dormant since Design v5 Task 2; nil is today's untinted glass"
            append(&group, "chrome.surfaces.footer", surfaces.footer?.rawValue, note: note)
            append(&group, "chrome.surfaces.sidebar", surfaces.sidebar?.rawValue, note: note)
            append(&group, "chrome.surfaces.palette", surfaces.palette?.rawValue, note: note)
            append(&group, "chrome.surfaces.popover", surfaces.popover?.rawValue, note: note)
            append(&group, "chrome.surfaces.titlebar", surfaces.titlebar?.rawValue, note: note)
            add(group, titled: "materials", into: &lines)
        }

        private static func appendWindow(_ chrome: DesignOverrides.Chrome, into lines: inout [String]) {
            var group: [String] = []
            append(&group, "chrome.barLift", chrome.barLift,
                   note: "PaneTheme.barLift, today 0.08; moves the backdrop AND the ink graded on it")
            append(&group, "chrome.sidebarWashFloor", chrome.sidebarWashFloor,
                   note: "a floor applied as max(opacity, floor); raises the wash, never thins it")
            add(group, titled: "window", into: &lines)
        }

        // MARK: - Emitting

        /// Appends a group under its own comment header, or nothing when every
        /// field in it is nil.
        private static func add(_ group: [String], titled title: String, into lines: inout [String]) {
            guard !group.isEmpty else { return }
            if !lines.isEmpty { lines.append("") }
            lines.append("  // \(title)")
            lines.append(contentsOf: group)
        }

        private static func append(_ lines: inout [String], _ key: String, _ value: Double?, note: String) {
            guard let value else { return }
            lines.append("  \"\(key)\": \(trimmed(value)), // \(note)")
        }

        private static func append(_ lines: inout [String], _ key: String, _ value: Bool?, note: String) {
            guard let value else { return }
            lines.append("  \"\(key)\": \(value), // \(note)")
        }

        private static func append(_ lines: inout [String], _ key: String, _ value: String?, note: String) {
            guard let value else { return }
            lines.append("  \"\(key)\": \"\(value)\", // \(note)")
        }

        /// `0.22` rather than `0.22000000000000003`.
        ///
        /// The panel quantizes on the way in, so the stored value is already the
        /// number the owner dialled; this only stops the binary representation of
        /// that number from being what he pastes into a commit message.
        private static func trimmed(_ value: Double) -> String {
            let text = String(format: "%.4f", value)
            var trimmed = text
            while trimmed.hasSuffix("0") { trimmed.removeLast() }
            if trimmed.hasSuffix(".") { trimmed.append("0") }
            return trimmed
        }

        // MARK: - Reading it back

        /// Why a parse could not produce a ``DesignOverrides``, in a sentence the
        /// owner can act on.
        ///
        /// A message rather than a case per failure, because there is exactly one
        /// consumer — the watcher, which writes it to stderr the way
        /// `ConfigurationCenter.report` writes the settings decoder's complaints —
        /// and nothing branches on why. A case list would be a taxonomy with no
        /// reader, and the string is what has to be right.
        public struct ParseError: Error, Equatable, Sendable {
            /// What went wrong, naming the offending key wherever there is one.
            public let message: String
        }

        /// The overrides `text` describes, or why it could not be read.
        ///
        /// `text` is this file's own emitted format: commented JSON with flat
        /// dotted keys. That is not an accident of convenience — it is what lets
        /// the owner paste Copy Values' output straight into
        /// `~/.config/baia/design-overrides.json` and have the running app pick it
        /// up on save.
        ///
        /// ## One bad key fails the whole document, and this is the one place
        /// `BaiaSettings` refuses per-field resilience
        ///
        /// ``SettingsDecoder`` is resilient by design: a typo there costs one
        /// setting and sixteen good ones still apply, because `config.json` is
        /// read at launch and its spellings are learned from the file baia writes
        /// on first run. This file is the opposite situation. It is hand-edited
        /// repeatedly inside a single dialling session, from memory, with the app
        /// running and the owner watching a window for a change.
        ///
        /// In that loop a silently ignored `ringAlfa` does not cost one knob, it
        /// costs the answer: the owner saves, nothing moves, and the honest
        /// conclusion available to him is that *the knob does nothing* — which is
        /// exactly the question the session was convened to ask. So an unknown key
        /// and a mistyped value both refuse the document and name themselves, and
        /// the watcher keeps whatever was already dialled rather than dropping to
        /// a half-applied state nobody asked for.
        ///
        /// An empty object, and a file of nothing but comments, are not failures:
        /// they are "nothing dialled", which is what the emitter writes after a
        /// Reset and a legitimate thing to save.
        public static func parse(_ text: String) -> Result<DesignOverrides, ParseError> {
            let stripped = droppingTrailingComma(strippingComments(text))
            guard case let .object(fields)? = JSONValue.parse(Data(stripped.utf8)) else {
                return .failure(ParseError(
                    message: "not a JSON object once its // comments are stripped"
                ))
            }

            var overrides = DesignOverrides()
            for key in fields.keys.sorted() {
                // Sorted so a document with two bad keys always blames the same
                // one. `fields` is a dictionary and its iteration order varies per
                // run, which would otherwise make the reported key a coin flip and
                // the failing test flaky.
                guard let value = fields[key] else { continue }
                if let error = assign(value, forKey: key, into: &overrides) {
                    return .failure(error)
                }
            }
            return .success(overrides)
        }

        /// Writes one flat dotted key into `overrides`, or says why it could not.
        ///
        /// The key strings are the emitter's, above, and nothing derives one from
        /// the other: Swift offers no reflection over stored properties that
        /// survives `-O`, so both lists are written out and
        /// ``DesignOverridesTextTests`` holds them together — the emitter's
        /// inventory test from one side, and a sweep asserting the parser accepts
        /// every key the emitter writes from the other.
        private static func assign(
            _ value: JSONValue,
            forKey key: String,
            into overrides: inout DesignOverrides
        ) -> ParseError? {
            switch key {
            case "backgroundOpacity": return double(value, key, &overrides.backgroundOpacity)
            case "backgroundBlur": return bool(value, key, &overrides.backgroundBlur)
            case "chromeStyle": return rawValue(value, key, &overrides.chromeStyle)
            case "attentionStyle": return rawValue(value, key, &overrides.attentionStyle)
            case "attentionAccent": return rawValue(value, key, &overrides.attentionAccent)
            case "focusAccent": return rawValue(value, key, &overrides.focusAccent)
            case "transparentTitlebar": return bool(value, key, &overrides.transparentTitlebar)

            case "chrome.lift.enabled": return bool(value, key, &overrides.chrome.lift.enabled)
            case "chrome.lift.ringSpread": return double(value, key, &overrides.chrome.lift.ringSpread)
            case "chrome.lift.ringAlpha": return double(value, key, &overrides.chrome.lift.ringAlpha)
            case "chrome.lift.innerHighlightOffsetY":
                return double(value, key, &overrides.chrome.lift.innerHighlightOffsetY)
            case "chrome.lift.innerHighlightAlpha":
                return double(value, key, &overrides.chrome.lift.innerHighlightAlpha)
            case "chrome.lift.shadowDropOffsetY":
                return double(value, key, &overrides.chrome.lift.shadowDropOffsetY)
            case "chrome.lift.shadowDropBlur":
                return double(value, key, &overrides.chrome.lift.shadowDropBlur)
            case "chrome.lift.shadowDropAlpha":
                return double(value, key, &overrides.chrome.lift.shadowDropAlpha)
            case "chrome.lift.duration": return double(value, key, &overrides.chrome.lift.duration)

            case "chrome.rim.enabled": return bool(value, key, &overrides.chrome.rim.enabled)
            case "chrome.rim.topAlpha": return double(value, key, &overrides.chrome.rim.topAlpha)

            case "chrome.inks.sessionHeaderMinimumRatio":
                return double(value, key, &overrides.chrome.inks.sessionHeaderMinimumRatio)
            case "chrome.inks.sessionHeaderHex":
                return string(value, key, &overrides.chrome.inks.sessionHeaderHex)
            case "chrome.inks.actionRowMinimumRatio":
                return double(value, key, &overrides.chrome.inks.actionRowMinimumRatio)
            case "chrome.inks.actionRowHex":
                return string(value, key, &overrides.chrome.inks.actionRowHex)
            case "chrome.inks.sectionHeaderMinimumRatio":
                return double(value, key, &overrides.chrome.inks.sectionHeaderMinimumRatio)
            case "chrome.inks.busyDotHex":
                return string(value, key, &overrides.chrome.inks.busyDotHex)

            case "chrome.surfaces.footer": return rawValue(value, key, &overrides.chrome.surfaces.footer)
            case "chrome.surfaces.sidebar": return rawValue(value, key, &overrides.chrome.surfaces.sidebar)
            case "chrome.surfaces.palette": return rawValue(value, key, &overrides.chrome.surfaces.palette)
            case "chrome.surfaces.popover": return rawValue(value, key, &overrides.chrome.surfaces.popover)
            case "chrome.surfaces.titlebar": return rawValue(value, key, &overrides.chrome.surfaces.titlebar)

            case "chrome.barLift": return double(value, key, &overrides.chrome.barLift)
            case "chrome.sidebarWashFloor": return double(value, key, &overrides.chrome.sidebarWashFloor)

            default:
                return ParseError(message: "`\(key)` is not a knob baia dials")
            }
        }

        // MARK: - Reading one field

        private static func double(
            _ value: JSONValue, _ key: String, _ field: inout Double?
        ) -> ParseError? {
            guard case let .number(number) = value, number.isFinite else {
                return ParseError(message: "`\(key)` wants a number")
            }
            field = number
            return nil
        }

        private static func bool(
            _ value: JSONValue, _ key: String, _ field: inout Bool?
        ) -> ParseError? {
            guard case let .bool(flag) = value else {
                return ParseError(message: "`\(key)` wants true or false")
            }
            field = flag
            return nil
        }

        private static func string(
            _ value: JSONValue, _ key: String, _ field: inout String?
        ) -> ParseError? {
            guard case let .string(text) = value else {
                return ParseError(message: "`\(key)` wants a string")
            }
            field = text
            return nil
        }

        /// The one that catches a spelling no compiler could.
        ///
        /// The case lists it checks against are what an owner types from memory
        /// mid-session, so `"marble"` in a `Material` field is both easy to write
        /// and invisible to every check above this one: it is a string in a field
        /// that takes strings. The message names the spellings rather than only
        /// the key, because "wrong" without "these are the words" leaves him
        /// reading source to find them.
        private static func rawValue<Value: RawRepresentable & CaseIterable>(
            _ value: JSONValue, _ key: String, _ field: inout Value?
        ) -> ParseError? where Value.RawValue == String {
            guard case let .string(text) = value else {
                return ParseError(message: "`\(key)` wants a string")
            }
            guard let parsed = Value(rawValue: text) else {
                let spellings = Value.allCases.map(\.rawValue).joined(separator: ", ")
                return ParseError(message: "`\(key)`: `\(text)` is not one of \(spellings)")
            }
            field = parsed
            return nil
        }

        // MARK: - Comments

        /// `text` with every `//` comment removed, leaving JSON.
        ///
        /// Walks strings rather than searching for the marker. `"#00//00"` is a
        /// legal value for a hex field and truncating it there would turn a typo
        /// into a half-parsed document; no knob holds a path today, but a stripper
        /// that could not tell a marker inside a string from one outside it is a
        /// trap laid for the first field that does.
        ///
        /// Comment bodies are replaced with nothing rather than with spaces. The
        /// newline that ended the line is kept, so the remaining JSON keeps its
        /// line structure and the parser's own whitespace skipping does the rest.
        /// `/* */` is not understood: the emitter never writes one, so accepting
        /// it would be a second syntax with nothing producing it.
        private static func strippingComments(_ text: String) -> String {
            var out = ""
            out.reserveCapacity(text.count)
            var insideString = false
            var isEscaped = false
            var insideComment = false
            var previousWasSlash = false

            for character in text {
                if insideComment {
                    guard character == "\n" else { continue }
                    insideComment = false
                    out.append(character)
                    continue
                }
                if insideString {
                    out.append(character)
                    if isEscaped {
                        isEscaped = false
                    } else if character == "\\" {
                        isEscaped = true
                    } else if character == "\"" {
                        insideString = false
                    }
                    continue
                }
                if character == "/" {
                    if previousWasSlash {
                        // The first slash was already appended; take it back.
                        out.removeLast()
                        previousWasSlash = false
                        insideComment = true
                        continue
                    }
                    previousWasSlash = true
                    out.append(character)
                    continue
                }
                previousWasSlash = false
                if character == "\"" { insideString = true }
                out.append(character)
            }
            return out
        }

        /// `text` with a comma that has nothing after it but the closing brace
        /// removed.
        ///
        /// **Not leniency for its own sake: the emitter above writes one on every
        /// line, including the last.** `append` ends each entry with `", // note"`
        /// so the comma sits between the value and its comment, which is the only
        /// arrangement that keeps the note beside the number it annotates. Strip
        /// the comments and the last entry is left with a comma before `}`, which
        /// ``JSONValue/parse(_:)`` refuses — correctly, since `config.json` is real
        /// JSON and a trailing comma there is a typo worth reporting.
        ///
        /// So this is exactly wide enough for what the emitter produces and no
        /// wider: one comma, at the end of the document, before the final brace.
        /// A comma inside a string is untouched, since this runs after the
        /// comment stripper has already told strings from structure and only the
        /// document's tail is examined.
        private static func droppingTrailingComma(_ text: String) -> String {
            var characters = Array(text)
            var index = characters.count - 1
            while index >= 0, characters[index].isWhitespace { index -= 1 }
            guard index >= 0, characters[index] == "}" else { return text }
            index -= 1
            while index >= 0, characters[index].isWhitespace { index -= 1 }
            guard index >= 0, characters[index] == "," else { return text }
            characters.remove(at: index)
            return String(characters)
        }
    }

#endif
