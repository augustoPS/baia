import Foundation

/// How often each project has been opened, on disk.
///
/// The file is a tab separated `<count>TAB<path>` per line rather than JSON.
/// `JSONDecoder` and `JSONSerialization` both report a corrupt file by throwing,
/// and this package has no error channel, so a JSON store would need the `try?`
/// the house rules forbid. A line format needs no error channel at all: a line
/// that does not parse is skipped and the rest of the counts survive, which is
/// the behaviour wanted anyway for a file whose worst failure should cost the
/// owner a ranking hint and nothing else.
public struct RecentProjects: Sendable {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/baia/recent-projects.tsv`.
    ///
    /// Not `UserDefaults`. The counts grow one line per project the owner ever
    /// opens and are worth reading and editing by hand when the ranking looks
    /// wrong, which a plist in a defaults domain is not. Deleting the file resets
    /// the ranking to alphabetical, which is a supported repair.
    /// - Parameter directoryName: the folder under Application Support, matching
    ///   the one ``SessionStore`` uses. `baia` installed, `baia-dev` under test,
    ///   so a test build's ranking is its own rather than a rewrite of the one in
    ///   daily use.
    public static func defaultFileURL(directoryName: String = "baia") -> URL {
        URL.applicationSupportDirectory
            .appending(path: directoryName, directoryHint: .isDirectory)
            .appending(path: "recent-projects.tsv")
    }

    /// Empty when the file is absent or unreadable, which is the first run.
    public func load() -> [String: Int] {
        guard let data = FileManager.default.contents(atPath: fileURL.path(percentEncoded: false))
        else { return [:] }

        var counts: [String: Int] = [:]
        // Split on any newline. The file is written with plain feeds and is
        // documented as hand-editable, and an editor that saves it with CRLF would
        // otherwise arrive as one unparseable line, since a CRLF pair is a single
        // `Character` in Swift and "\n" does not match it.
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            // Split once, so a path containing a tab survives whole in the
            // remainder. `recordUse(of:)` refuses to write one, but the file is
            // documented as hand-editable and a rejected line here would drop a
            // count the owner put there on purpose.
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, let uses = Int(fields[0]), uses > 0 else { continue }

            // Absolute paths only. A relative one cannot be matched against a
            // `Project` URL, and keeping it would let a hand-edited `.` sit in
            // the file forever contributing nothing.
            let path = String(fields[1])
            guard path.hasPrefix("/") else { continue }
            counts[Self.key(of: path)] = uses
        }
        return counts
    }

    /// Increments the count for `path` and rewrites the file. False when the write
    /// failed or the path cannot be represented.
    ///
    /// The caller may pass either spelling of a directory path, with or without a
    /// trailing slash, since both are normalized to one key.
    public func recordUse(of path: String) -> Bool {
        let key = Self.key(of: path)

        // A path holding a tab or a newline cannot be written back and read the
        // same, and silently storing a line that `load` will skip would make the
        // count look recorded while ranking nothing. Refusing is the honest
        // answer, and the caller already treats false as "recency is not
        // available".
        guard key.hasPrefix("/"), !key.contains("\t"), !key.contains("\n") else { return false }

        var counts = load()
        counts[key, default: 0] += 1

        // Sorted by path so the file's bytes are a function of its contents
        // alone. Dictionary order is not stable across runs, and a file that
        // reshuffles on every project open is unreadable in a diff and untestable
        // byte for byte.
        let text = counts.keys.sorted()
            .map { "\(counts[$0] ?? 0)\t\($0)" }
            .joined(separator: "\n")

        // `mkdir` rather than `FileManager.createDirectory`, which throws. One
        // level is all that is needed: the parent of the default location is
        // `~/Library/Application Support`, which macOS creates for every account.
        // EEXIST is the normal case and is not an error here, so the result is not
        // consulted; the write below is what reports success.
        mkdir(fileURL.deletingLastPathComponent().path(percentEncoded: false), 0o755)

        // `Data.write(to:)` throws. `NSData.write(to:atomically:)` is the same
        // atomic write reporting failure as a Bool, which is the only shape this
        // package can use. Atomic matters because the whole file is rewritten on
        // every project open, so a partial write would cost every count rather
        // than one.
        return (Data((text + "\n").utf8) as NSData).write(to: fileURL, atomically: true)
    }

    /// The one spelling a path is stored and looked up under.
    ///
    /// A `URL` for a directory renders with a trailing slash while the same path
    /// from a shell, a config file, or this file does not. A key that disagrees on
    /// that slash never matches the lookup, so recency would silently rank
    /// nothing and look like it was never recorded. ``ProjectRanker`` normalizes
    /// through here for the same reason.
    static func key(of path: String) -> String {
        var key = path
        while key.count > 1, key.hasSuffix("/") { key.removeLast() }
        return key
    }
}
