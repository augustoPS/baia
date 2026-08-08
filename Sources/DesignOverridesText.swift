#if DEBUG

    import BaiaSettings

    /// The design panel's Copy Values text: the dialled overrides as JSON with a
    /// comment per field naming the constant it stands in for.
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
    /// vault note, or a constant. It is not a format anything reads back, and
    /// nothing here should ever gain a parser.
    ///
    /// ## Only what is set
    ///
    /// A nil field is absent from the output rather than emitted as `null`,
    /// because nil means "the committed value" and printing it would list forty
    /// knobs the owner never touched beside the two he did.
    enum DesignOverridesText {
        /// `overrides` as commented JSON, or a single comment when nothing is
        /// dialled.
        static func commentedJSON(_ overrides: DesignOverrides) -> String {
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
    }

#endif
