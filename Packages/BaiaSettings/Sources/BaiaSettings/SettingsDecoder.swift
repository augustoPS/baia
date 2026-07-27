import Foundation

/// What a decode produced, plus what it could not use.
///
/// The app surfaces the bad keys rather than silently ignoring them, because a
/// config that half-applies with no feedback is the worst outcome for a
/// hand-edited file: the owner sees his own value in the editor and a different
/// value on screen, with nothing connecting the two.
public struct SettingsDecodeResult: Sendable, Equatable {
    public var settings: Settings
    /// Fields the file carries that this version of baia does not read. A setting
    /// renamed or removed between versions shows up here rather than as a value
    /// that quietly stopped applying, which is why a retired key is left to land
    /// here rather than being accepted and ignored for a release.
    public var unknownKeys: [String]
    /// Fields whose value was the wrong type, out of range, or unspellable. Every
    /// one of them fell back to its default or was clamped into range, and every
    /// other field still applied.
    public var invalidKeys: [String]
    /// True when the file was not a JSON object at all, so no key could be
    /// blamed. Returned as data rather than repaired here, the way a stale pin is
    /// in `ProjectAnchor`: the decoder cannot know whether the owner wants the
    /// file rewritten, and only the app can tell him nothing he wrote applied.
    public var documentIsUnreadable: Bool
}

public enum SettingsDecoder {
    /// One bad or unknown field must never discard the whole file. Every field
    /// falls back to its default independently and is reported in `invalidKeys`.
    public static func decode(_ data: Data) -> SettingsDecodeResult {
        // A file of nothing but whitespace is what `touch` and an emptied editor
        // buffer leave behind. It configures nothing, which is different from
        // being broken, so it is not reported: an error in front of the owner for
        // a file that says nothing at all would be noise he cannot act on.
        guard data.contains(where: { !JSONValue.isWhitespace($0) }) else {
            return SettingsDecodeResult(
                settings: .defaultSettings,
                unknownKeys: [],
                invalidKeys: [],
                documentIsUnreadable: false
            )
        }

        // A top-level array, a bare scalar, invalid UTF-8, an unterminated string,
        // and a trailing comma all land here. There is no key to blame for any of
        // them, so the flag is the only channel that can tell the owner why none
        // of his settings applied.
        guard case let .object(fields)? = JSONValue.parse(data) else {
            return SettingsDecodeResult(
                settings: .defaultSettings,
                unknownKeys: [],
                invalidKeys: [],
                documentIsUnreadable: true
            )
        }

        var reader = Reader(fields: fields)
        var settings = Settings.defaultSettings

        if let family = reader.text("fontFamily") {
            // An empty string is not a font name. ghostty would fall back to its
            // own default and the pane would render in a font the file does not
            // name, which reads as the key having no effect.
            if family.isEmpty {
                reader.reject("fontFamily")
            } else {
                settings.fontFamily = family
            }
        }

        if let size = reader.number("fontSize") {
            // Out of range falls back to the default instead of clamping to the
            // bound, unlike the fields below. A 4 point terminal is as unusable as
            // a 0 point one, so the nearest legal value would trade one broken
            // pane for another; 11.5 is the only size known to work here.
            if Settings.Limits.fontSize.contains(size) {
                settings.fontSize = size
            } else {
                reader.reject("fontSize")
            }
        }

        if let theme = reader.text("themeName") {
            if theme.isEmpty {
                reader.reject("themeName")
            } else {
                settings.themeName = theme
            }
        }

        if let hex = reader.text("backgroundHex") {
            if Self.isColourHex(hex) {
                settings.backgroundHex = hex
            } else {
                reader.reject("backgroundHex")
            }
        }

        if let opacity = reader.number("backgroundOpacity") {
            // Clamped rather than defaulted, because the intent survives the
            // clamp: 1.5 says opaque and -0.2 says transparent. ghostty clamps
            // this key itself, so matching it keeps the two configs behaving the
            // same way for the same file.
            settings.backgroundOpacity = Self.clamped(
                opacity,
                to: Settings.Limits.opacity,
                key: "backgroundOpacity",
                reader: &reader
            )
        }

        if let blur = reader.flag("backgroundBlur") {
            settings.backgroundBlur = blur
        }

        if let padding = reader.number("windowPadding") {
            settings.windowPadding = Self.clamped(
                padding,
                to: Settings.Limits.padding,
                key: "windowPadding",
                reader: &reader
            )
        }

        if let balance = reader.flag("windowPaddingBalance") {
            settings.windowPaddingBalance = balance
        }

        if let transparent = reader.flag("transparentTitlebar") {
            settings.transparentTitlebar = transparent
        }

        if let optionAsAlt = reader.flag("optionAsAlt") {
            settings.optionAsAlt = optionAsAlt
        }

        if let style = reader.text("cursorStyle") {
            // A style ghostty does not know is dropped by its config parser with
            // no diagnostic, so passing an unknown spelling through would leave a
            // cursor that ignores the file and reports nothing.
            if let style = CursorStyle(rawValue: style) {
                settings.cursorStyle = style
            } else {
                reader.reject("cursorStyle")
            }
        }

        if let roots = reader.list("projectRoots") {
            // Expanded here rather than at every use site: a path taken straight
            // from the file starts with a literal `~` directory that exists
            // nowhere, and a discovery walk would then find nothing and report no
            // error. An empty string is dropped for the same reason, since it
            // expands to itself and names no directory.
            let usable = roots.filter { !$0.isEmpty }
            if usable.count != roots.count {
                reader.reject("projectRoots")
            }
            settings.projectRoots = usable.map(Settings.expandingTilde)
        }

        if let depth = reader.number("discoveryMaxDepth") {
            // A fractional depth is a typo rather than a shallower walk, so it
            // falls back instead of rounding to a number the file never asked for.
            if depth != depth.rounded() {
                reader.reject("discoveryMaxDepth")
            } else {
                let bounded = Self.clamped(
                    depth,
                    to: Settings.Limits.discoveryDepth,
                    key: "discoveryMaxDepth",
                    reader: &reader
                )
                settings.discoveryMaxDepth = Int(bounded)
            }
        }

        if let notifications = reader.flag("notificationsEnabled") {
            settings.notificationsEnabled = notifications
        }

        if let seconds = reader.number("gitPollSeconds") {
            settings.gitPollSeconds = Self.clamped(
                seconds,
                to: Settings.Limits.pollSeconds,
                key: "gitPollSeconds",
                reader: &reader
            )
        }

        if let seconds = reader.number("activityPollSeconds") {
            settings.activityPollSeconds = Self.clamped(
                seconds,
                to: Settings.Limits.pollSeconds,
                key: "activityPollSeconds",
                reader: &reader
            )
        }

        if let restore = reader.flag("restoreSession") {
            settings.restoreSession = restore
        }

        // The two design keys. Each is read through `init(rawValue:)` and falls
        // back on its own, the way `cursorStyle` does above, so a typo in one of
        // them leaves the other applied and names itself in `invalidKeys`.
        // Neither spelling reaches ghostty, so an unknown one costs a reported
        // rejection rather than a silently dropped terminal config line.
        //
        // `focusStyle` and `unfocusedScrim` were two more of these until the
        // focus treatment was settled at one. They are deliberately not accepted
        // and ignored here: a key that stopped applying has to be visible, which
        // is the whole reason `unknownKeys` exists, and quietly swallowing them
        // is exactly how `focusAccent` sat dead for nine days.
        if let accent = reader.text("focusAccent") {
            if let accent = FocusAccent(rawValue: accent) {
                settings.focusAccent = accent
            } else {
                reader.reject("focusAccent")
            }
        }

        if let style = reader.text("attentionStyle") {
            if let style = AttentionStyle(rawValue: style) {
                settings.attentionStyle = style
            } else {
                reader.reject("attentionStyle")
            }
        }

        return SettingsDecodeResult(
            settings: settings,
            // Both lists are sorted, and a `Dictionary`'s key order is not stable
            // between runs. The app renders these, and an order that reshuffles on
            // every launch reads as the file having changed when it did not. The
            // set is defence in depth: no field above rejects twice today, and a
            // repeated name would read as two separate problems with one key.
            unknownKeys: reader.unknownKeys.sorted(),
            invalidKeys: Set(reader.invalidKeys).sorted(),
            documentIsUnreadable: false
        )
    }

    /// Pulls `value` into `range`, reporting `key` when it had to move.
    ///
    /// A clamp is still a value the file asked for and did not get, so the app has
    /// to hear about it. A silently corrected opacity is indistinguishable from a
    /// key that does nothing, which is the confusion this whole result type exists
    /// to remove.
    private static func clamped(
        _ value: Double,
        to range: ClosedRange<Double>,
        key: String,
        reader: inout Reader
    ) -> Double {
        guard !range.contains(value) else { return value }
        reader.reject(key)
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// True for `#RRGGBB` and for the three digit `#RGB` shorthand.
    ///
    /// Written out rather than matched with `NSRegularExpression`, which compiles
    /// its pattern at every call and would be the only regular expression in the
    /// project. ghostty accepts more spellings than these two (a bare colour name,
    /// an `rgb:` form), and only these two are promised, so anything else is
    /// reported here instead of being handed to the terminal to drop in silence.
    ///
    /// `isHexDigit` alone is not enough: it is true for the full width forms of
    /// the ASCII digits, which ghostty cannot parse.
    private static func isColourHex(_ text: String) -> Bool {
        guard text.hasPrefix("#") else { return false }
        let digits = text.dropFirst()
        guard digits.count == 3 || digits.count == 6 else { return false }
        return digits.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    /// Reads one field at a time and remembers which ones it touched.
    ///
    /// The unknown-key list is the set of fields this reader never asked for,
    /// rather than a hand-maintained list of known names. So a key added to
    /// ``Settings`` and forgotten here shows up as unknown in the full-config
    /// test, which is what keeps the two from drifting apart.
    private struct Reader {
        let fields: [String: JSONValue]
        private(set) var invalidKeys: [String] = []
        private var readKeys: Set<String> = []

        init(fields: [String: JSONValue]) {
            self.fields = fields
        }

        var unknownKeys: [String] {
            fields.keys.filter { !readKeys.contains($0) }
        }

        mutating func reject(_ key: String) {
            invalidKeys.append(key)
        }

        mutating func text(_ key: String) -> String? {
            guard let value = value(key) else { return nil }
            guard case let .string(text) = value else {
                reject(key)
                return nil
            }
            return text
        }

        mutating func number(_ key: String) -> Double? {
            guard let value = value(key) else { return nil }
            guard case let .number(number) = value else {
                reject(key)
                return nil
            }
            // An exponent too large for a `Double` parses to infinity rather than
            // failing, and infinity would survive every range check that uses
            // `min` and `max`. NaN would defeat them the other way, by comparing
            // false against both bounds.
            guard number.isFinite else {
                reject(key)
                return nil
            }
            return number
        }

        mutating func flag(_ key: String) -> Bool? {
            guard let value = value(key) else { return nil }
            // A 0 or a 1 is refused rather than read as a boolean. Accepting them
            // invites "yes" and "on" next, and every alias is a spelling that has
            // to keep working for as long as the file format exists.
            guard case let .bool(flag) = value else {
                reject(key)
                return nil
            }
            return flag
        }

        mutating func list(_ key: String) -> [String]? {
            guard let value = value(key) else { return nil }
            guard case let .array(items) = value else {
                reject(key)
                return nil
            }
            var texts: [String] = []
            for item in items {
                // One non-string element degrades the whole list rather than being
                // skipped. A silently shortened list of project roots is a
                // workspace with a missing project and no explanation for it.
                guard case let .string(text) = item else {
                    reject(key)
                    return nil
                }
                texts.append(text)
            }
            return texts
        }

        /// The value for `key`, or nil when the field is absent or null. Records
        /// the key in both of those cases, so a null does not read as unknown.
        private mutating func value(_ key: String) -> JSONValue? {
            guard let value = fields[key] else { return nil }
            readKeys.insert(key)
            // `null` is how the written default file spells "leave this alone" for
            // `fontFamily`, whose default is ghostty's own font choice. Reading it
            // as a bad value would make the file baia writes itself report an
            // invalid key on the very first load.
            guard value != .null else { return nil }
            return value
        }
    }
}
