import Foundation

/// Writes edits back into an existing config document, one key at a time.
///
/// Read-modify-write rather than encode-from-``Settings``, for three reasons an
/// encoder cannot answer.
///
/// `projectRoots` is lossy in memory: ``SettingsDecoder`` expands the tilde on
/// read, so an encoder would write an absolute path over the `~/Projects` the
/// file is meant to carry between machines, on a write that never touched the
/// key.
///
/// A control edits one field and shares the document with every other, so a
/// write must not rewrite what it was not asked to. That was the 2026-09-04
/// audit's S2: a whole-window snapshot written as one transaction put a stale
/// value back over an edit made outside the window.
///
/// And an omitted key decodes to its default exactly as an absent one does, so
/// absence carries no information to round-trip on. That is the blind spot
/// `SettingsStoreTests` covers by comparing the default file's key set against
/// ``SettingsDecoder/knownKeys`` rather than by decoding it.
enum SettingsWriter {
    /// The order keys are written in, matching the grouping of
    /// ``SettingsStore/defaultFileContents``.
    ///
    /// Explicit because ``JSONValue/object(_:)`` is a dictionary and parsing the
    /// file loses whatever order it had. Sorted output would scramble a document
    /// grouped by subject, and the file is where the owner learns the spellings.
    static let keyOrder: [String] = SettingsKey.allCases.map(\.rawValue)

    /// `document` with each edit's key replaced and every other member kept, or
    /// nil when `document` is not an object.
    ///
    /// Nil rather than a fresh object. A document that is not an object is a
    /// file the owner mangled by hand, and writing a new one over it destroys
    /// whatever they had in it: the audit's S4 fixture lost custom project roots
    /// that way. ``SettingsStore/patch(_:)`` refuses instead and the window
    /// offers a repair that keeps a backup.
    static func patch(_ document: JSONValue, edits: [SettingsEdit]) -> JSONValue? {
        guard case var .object(members) = document else { return nil }
        for edit in edits {
            members[edit.key.rawValue] = edit.jsonValue
        }
        return .object(members)
    }

    /// A complete document holding every key `settings` has, for repair.
    ///
    /// The only time baia writes a document from ``Settings`` rather than from
    /// the file, and only ever after the original bytes have been backed up.
    /// Project roots come out tilde-abbreviated, so a repaired file is as
    /// portable as a first-launch one.
    static func document(from settings: Settings) -> JSONValue {
        var members: [String: JSONValue] = [:]
        for key in SettingsKey.allCases {
            members[key.rawValue] = SettingsEdit.value(of: key, in: settings).jsonValue
        }
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
