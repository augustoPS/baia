import Foundation

/// Writes settings back into an existing config document.
///
/// Read-modify-write rather than encode-from-``Settings``, for three reasons an
/// encoder cannot answer.
///
/// `projectRoots` is lossy in memory: ``SettingsDecoder`` expands the tilde on
/// read, so an encoder would write an absolute path over the `~/Projects` the
/// file is meant to carry between machines, on the first write from a window
/// that does not even edit the key.
///
/// Nine keys sit outside the settings window's scope and inside the same
/// document, so the window must not rewrite what it does not own.
///
/// And an omitted key decodes to its default exactly as an absent one does, so
/// absence carries no information to round-trip on. That is the same blind spot
/// `SettingsStoreTests` covers by comparing the default file's key set against
/// ``SettingsDecoder/knownKeys`` rather than by decoding it.
enum SettingsWriter {
    /// The order keys are written in, matching the grouping of
    /// ``SettingsStore/defaultFileContents``.
    ///
    /// Explicit because ``JSONValue/object(_:)`` is a dictionary and parsing the
    /// file loses whatever order it had. Sorted output would scramble a document
    /// grouped by subject, and the file is where the owner learns the spellings.
    ///
    /// Pinned against ``SettingsDecoder/knownKeys`` by a test rather than by
    /// construction, so a key added to the decoder and forgotten here fails
    /// loudly instead of dropping out of every write it is not named in.
    static let keyOrder: [String] = [
        "fontFamily",
        "fontSize",
        "themeName",
        "backgroundHex",
        "backgroundOpacity",
        "backgroundBlur",
        "windowPadding",
        "windowPaddingBalance",
        "transparentTitlebar",
        "optionAsAlt",
        "cursorStyle",
        "projectRoots",
        "discoveryMaxDepth",
        "notificationsEnabled",
        "gitPollSeconds",
        "activityPollSeconds",
        "restoreSession",
        "focusAccent",
        "attentionStyle",
        "attentionAccent",
        "alertBehavior",
        "sidebar",
        "controlChannelEnabled",
        "controlAllowRun",
        "controlAllowRead",
    ]

    /// The fourteen keys the settings window owns.
    ///
    /// Everything outside this set is carried through untouched: the nine the
    /// window does not show, and any key the owner added that the decoder already
    /// reports as unread.
    ///
    /// Declared rather than inferred from ``patch(_:with:)``, and pinned against
    /// what that function actually writes by a test, so the two cannot drift into
    /// a key that is claimed but never assigned.
    static let appearanceKeys: Set<String> = [
        "themeName",
        "backgroundHex",
        "backgroundOpacity",
        "backgroundBlur",
        "windowPadding",
        "windowPaddingBalance",
        "transparentTitlebar",
        "fontFamily",
        "fontSize",
        "cursorStyle",
        "focusAccent",
        "attentionStyle",
        "attentionAccent",
        "alertBehavior",
    ]

    /// `document` with the appearance keys replaced from `settings`.
    ///
    /// A document that is not an object starts from empty rather than aborting. A
    /// file the owner mangled by hand decodes as unreadable, and accept still has
    /// to land the fourteen keys rather than silently doing nothing and leaving
    /// the window looking like it worked.
    static func patch(_ document: JSONValue, with settings: Settings) -> JSONValue {
        var members: [String: JSONValue]
        if case let .object(existing) = document {
            members = existing
        } else {
            members = [:]
        }

        members["themeName"] = .string(settings.themeName)
        members["backgroundHex"] = .string(settings.backgroundHex)
        members["backgroundOpacity"] = .number(settings.backgroundOpacity)
        members["backgroundBlur"] = .bool(settings.backgroundBlur)
        members["windowPadding"] = .number(settings.windowPadding)
        members["windowPaddingBalance"] = .bool(settings.windowPaddingBalance)
        members["transparentTitlebar"] = .bool(settings.transparentTitlebar)
        // Null rather than absent. The decoder reads both as unset, and the
        // default file says null, so the key stays visible to whoever opens the
        // file looking for the spelling.
        members["fontFamily"] = settings.fontFamily.map { JSONValue.string($0) } ?? .null
        members["fontSize"] = .number(settings.fontSize)
        members["cursorStyle"] = .string(settings.cursorStyle.rawValue)
        members["focusAccent"] = .string(settings.focusAccent.rawValue)
        members["attentionStyle"] = .string(settings.attentionStyle.rawValue)
        members["attentionAccent"] = .string(settings.attentionAccent.rawValue)
        members["alertBehavior"] = .string(settings.alertBehavior.rawValue)

        return .object(members)
    }

    /// `document` as the text to write to the config file.
    ///
    /// Keys named in ``keyOrder`` come first and in that order, so the file keeps
    /// the grouping the owner learned it by rather than the alphabetical order a
    /// dictionary would fall out in.
    ///
    /// Anything else follows, sorted. That covers a key the owner added which the
    /// decoder reports as unread: dropping it would delete their own text on top
    /// of having already warned about it, and sorting keeps two writes of one
    /// document byte-identical so the file does not churn.
    static func serialize(_ document: JSONValue) -> String {
        guard case let .object(members) = document else { return "{}\n" }

        let known = keyOrder.filter { members[$0] != nil }
        let unknown = members.keys.filter { !keyOrder.contains($0) }.sorted()

        let lines = (known + unknown).map { key in
            "  " + JSONValue.quoted(key) + ": " + members[key]!.serialized(indent: 1)
        }
        return "{\n" + lines.joined(separator: ",\n") + "\n}\n"
    }
}
