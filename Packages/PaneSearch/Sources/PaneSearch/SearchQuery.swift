import Foundation

/// What to look for, and how hard to look.
///
/// The case rule is derived rather than configured. A lowercase needle matches
/// case-insensitively and any uppercase character makes the whole query exact,
/// which is what every editor the owner already uses does, so there is nothing
/// to learn and no toggle whose state can disagree with what the field says.
public struct SearchQuery: Sendable, Equatable {
    public let needle: String

    /// True when the needle carries an uppercase character, which is the whole
    /// of the smart-case rule.
    ///
    /// Decided once here rather than per line. Both walks ask, and a search
    /// crosses tens of thousands of lines, so a property that rescans the needle
    /// on every one of them is paid for in the keystroke.
    public let isCaseSensitive: Bool

    /// The needle as bytes, lowercased when the case rule says so, or nil when
    /// it is not plain ASCII and only the general walk can match it.
    ///
    /// Held for the same reason as `isCaseSensitive`: building it per line cost
    /// 0.58 seconds on a 3.9 MB scrollback, more than the byte search it feeds.
    let asciiNeedle: [UInt8]?

    public init(needle: String) {
        self.needle = needle
        let caseSensitive = needle.contains { $0.isUppercase }
        isCaseSensitive = caseSensitive
        let bytes = Array(needle.utf8)
        asciiNeedle = bytes.allSatisfy { $0 < 0x80 }
            ? (caseSensitive ? bytes : bytes.map(Self.lowercased))
            : nil
    }

    /// An empty needle is not a match for anything. Deliberately not trimmed:
    /// spaces are a legitimate search, and trimming would make a query for
    /// indentation silently become a query for nothing.
    public var isEmpty: Bool {
        needle.isEmpty
    }

    public func matches(line: String) -> Bool {
        range(in: line) != nil
    }

    /// The character offsets of the first hit, or nil.
    ///
    /// Offsets rather than `String.Index`, because they survive being handed to
    /// `PaletteRow`, which maps them onto drawing runs, and because an index
    /// from one string applied to another traps.
    public func range(in line: String) -> Range<Int>? {
        hits(in: line, limit: 1).first
    }

    /// Every hit in one line, in order, up to `limit`.
    ///
    /// One call per line rather than one per hit, because the walk has to keep
    /// state to stay linear. The first version searched a rebuilt
    /// `String(characters[searchStart...])` after every hit and then counted
    /// characters from the line's start to place it, which is O(hits x length):
    /// one 80,000 character line with 8,000 hits took 9.2 seconds on the main
    /// thread, against 0.008 for the same line here. That input is ordinary,
    /// because the screen read returns logical lines and a `cat` of a minified
    /// bundle or a base64 blob arrives as exactly one of them.
    ///
    /// Hits do not overlap: the walk resumes at the end of the previous hit, so
    /// `aa` in `aaa` is one hit and not two, which is what a reader stepping
    /// through them expects.
    public func hits(in line: String, limit: Int) -> [Range<Int>] {
        guard !isEmpty, limit > 0 else { return [] }
        return asciiHits(in: line, limit: limit) ?? generalHits(in: line, limit: limit)
    }

    /// The byte walk, or nil when this line or this needle is not plain ASCII
    /// and the general walk has to answer instead.
    ///
    /// Worth the special case because `String.range(of:options:)` costs about
    /// 5.5 microseconds per line whatever the line holds: scanning a 3.9 MB
    /// scrollback for a needle with no hits, which is every keystroke of a
    /// specific search, took 0.35 seconds of blocked main thread against 0.004
    /// here. Terminal output is overwhelmingly ASCII, and the lines that are not
    /// fall back rather than being matched by a second rule.
    ///
    /// Not private, here and below: a second matching rule is only honest if a
    /// test can run both walks over the same lines and compare them.
    func asciiHits(in line: String, limit: Int) -> [Range<Int>]? {
        guard let folded = asciiNeedle else { return nil }

        let found = line.utf8.withContiguousStorageIfAvailable { bytes -> [Range<Int>]? in
            // A byte offset is a character offset only when every byte stands
            // for a whole character. Any byte above ASCII is part of a
            // multi-byte scalar, and a carriage return can pair with a newline
            // into one character, so both send the line to the general walk.
            for byte in bytes where byte >= 0x80 || byte == 0x0D { return nil }
            guard folded.count <= bytes.count else { return [] }

            var hits: [Range<Int>] = []
            var start = 0
            let lastStart = bytes.count - folded.count

            while start <= lastStart, hits.count < limit {
                var offset = 0
                while offset < folded.count {
                    let byte = bytes[start + offset]
                    let candidate = isCaseSensitive ? byte : Self.lowercased(byte)
                    if candidate != folded[offset] { break }
                    offset += 1
                }
                if offset == folded.count {
                    hits.append(start ..< (start + folded.count))
                    start += folded.count
                } else {
                    start += 1
                }
            }
            return hits
        }
        // Two optionals collapse to one: the outer is "no contiguous storage",
        // the inner is "not plain ASCII", and both mean the same to the caller.
        return found ?? nil
    }

    /// The walk for everything the byte path refuses.
    ///
    /// Indices into the line itself, advanced hit by hit, with each offset
    /// measured from the previous hit rather than from the line's start, so the
    /// line is traversed once however many hits it holds.
    func generalHits(in line: String, limit: Int) -> [Range<Int>] {
        let options: String.CompareOptions = isCaseSensitive ? [] : [.caseInsensitive]
        var hits: [Range<Int>] = []
        var searchStart = line.startIndex
        var offsetOfSearchStart = 0

        while hits.count < limit, searchStart < line.endIndex,
              let hit = line.range(of: needle, options: options, range: searchStart ..< line.endIndex)
        {
            let start = offsetOfSearchStart + line.distance(from: searchStart, to: hit.lowerBound)
            // Measured from the hit's own bounds and not from the needle's
            // length, because a case-insensitive fold can match a run of a
            // different length than the needle.
            let end = start + line.distance(from: hit.lowerBound, to: hit.upperBound)
            hits.append(start ..< end)

            // A zero-width hit cannot happen, because an empty needle returns
            // early, but advancing by at least one keeps this loop terminating
            // if that ever stops being true.
            if hit.upperBound > hit.lowerBound {
                searchStart = hit.upperBound
                offsetOfSearchStart = end
            } else if hit.lowerBound < line.endIndex {
                searchStart = line.index(after: hit.lowerBound)
                offsetOfSearchStart = start + 1
            } else {
                break
            }
        }
        return hits
    }

    private static func lowercased(_ byte: UInt8) -> UInt8 {
        byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte
    }
}
