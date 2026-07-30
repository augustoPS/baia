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
    ]
}
