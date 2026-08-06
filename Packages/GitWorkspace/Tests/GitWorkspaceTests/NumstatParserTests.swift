import Foundation
import Testing

@testable import GitWorkspace

/// `git diff --raw --numstat -z`, read the same way `GitStatusChangesTests`
/// reads porcelain: fixtures built from a real capture rather than the
/// documentation.
///
/// Every fixture below was captured from git 2.50.1 against a repository
/// built to produce that exact shape (`git diff --raw --numstat --cached -z
/// -M`, confirmed byte for byte with `od -c`), not typed from a guess at the
/// grammar. See ``NumstatParser``'s own doc comment for why `--raw` rides
/// along, and for the leading empty field a two-path record carries that a
/// guess at the grammar would not have found.
///
/// A one-path record fits `PorcelainFixture.zeroed`'s one-NUL-per-line
/// convention, the same helper `GitStatusChangesTests` uses, and those
/// fixtures are written that way below. A two-path record's three NUL
/// terminated fields, one of them empty, do not fit a listing meant to be
/// read as lines, so those are built as explicit bytes through
/// ``twoPathRecord(rawStatus:oldPath:newPath:additions:deletions:)`` instead,
/// which assembles exactly the layout `od -c` showed and nothing a listing
/// format would have to approximate.
@Suite struct NumstatParserTests {
    /// A rename or copy's raw record and numstat record, kept as two separate
    /// halves rather than one concatenated blob: git groups every raw record
    /// before any numstat record, confirmed against a real multi-file
    /// capture (`git mv old.txt new.txt` beside an unrelated edit to
    /// `mod.txt`, read with `od -c`), and a fixture combining more than one
    /// record has to assemble `.raw` for every record first and `.numstat`
    /// for every record after, in the same order, to match that shape rather
    /// than interleaving a record's own two halves.
    private struct TwoPathRecord {
        let raw: [UInt8]
        let numstat: [UInt8]
    }

    /// `rawStatus` (`R100`, `C075`, and so on) NUL terminated with both paths
    /// NUL terminated after it for `.raw`; `additions TAB deletions TAB`, an
    /// empty NUL terminated field, then both paths again NUL terminated for
    /// `.numstat`. `additions` and `deletions` are passed as the literal text
    /// numstat prints, `"-"` for a binary file included, so a caller does not
    /// have to spell a `-` some other way.
    private func twoPathRecord(
        rawStatus: String,
        oldPath: String,
        newPath: String,
        additions: String,
        deletions: String
    ) -> TwoPathRecord {
        TwoPathRecord(
            raw: Array(":100644 100644 0000000 0000000 \(rawStatus)".utf8) + [0]
                + Array(oldPath.utf8) + [0]
                + Array(newPath.utf8) + [0],
            numstat: Array("\(additions)\t\(deletions)\t".utf8) + [0]
                + Array(oldPath.utf8) + [0]
                + Array(newPath.utf8) + [0]
        )
    }

    /// A single record's raw half followed immediately by its own numstat
    /// half, correct for a capture holding exactly one record, where "every
    /// raw record then every numstat record" and "this record's two halves
    /// back to back" are the same order.
    private func output(_ record: TwoPathRecord) -> [UInt8] {
        record.raw + record.numstat
    }

    @Test func emptyOutputHasNoEntries() {
        #expect(NumstatParser.parse([]).isEmpty)
    }

    @Test func aPlainAddIsOneEntryWithNoOriginalPath() {
        let output = PorcelainFixture.zeroed("""
        :000000 100644 0000000 a29bdeb A
        d.txt
        1\t0\td.txt

        """)
        let entries = NumstatParser.parse(output)
        #expect(entries.count == 1)
        #expect(entries[0].path == "d.txt")
        #expect(entries[0].originalPath == nil)
        #expect(entries[0].additions == 1)
        #expect(entries[0].deletions == 0)
    }

    @Test func aPlainModifyCarriesBothCounts() {
        let output = PorcelainFixture.zeroed("""
        :100644 100644 422c2b7 d68dd40 M
        mod.txt
        2\t0\tmod.txt

        """)
        let entries = NumstatParser.parse(output)
        #expect(entries.count == 1)
        #expect(entries[0].path == "mod.txt")
        #expect(entries[0].additions == 2)
        #expect(entries[0].deletions == 0)
    }

    /// git's own layout for a detected rename with no line changes: `R100`
    /// leads the raw block's status, and the numstat block is `0\t0\t` then
    /// an empty NUL terminated field before the two paths repeat. No `=>`.
    @Test func aRenameWithNoLineChangesCarriesTheOriginalPath() {
        let bytes = output(twoPathRecord(
            rawStatus: "R100", oldPath: "a.txt", newPath: "b.txt", additions: "0", deletions: "0"
        ))
        let entries = NumstatParser.parse(bytes)
        #expect(entries.count == 1)
        #expect(entries[0].originalPath == "a.txt")
        #expect(entries[0].path == "b.txt")
        #expect(entries[0].additions == 0)
        #expect(entries[0].deletions == 0)
    }

    /// A rename that stayed above git's similarity threshold (`R075`) despite
    /// carrying a real line change, which is what tells the two paths in the
    /// numstat block apart from an unrelated add-then-delete pair: the raw
    /// block's status letter, read first, says this record owns two paths.
    @Test func aRenameWithLineChangesCarriesBothCounts() {
        let bytes = output(twoPathRecord(
            rawStatus: "R075", oldPath: "old.txt", newPath: "new.txt", additions: "1", deletions: "0"
        ))
        let entries = NumstatParser.parse(bytes)
        #expect(entries.count == 1)
        #expect(entries[0].originalPath == "old.txt")
        #expect(entries[0].path == "new.txt")
        #expect(entries[0].additions == 1)
        #expect(entries[0].deletions == 0)
    }

    /// A copy (`C100`) is read the same as a rename: two paths, from the same
    /// leading-letter rule the raw block's status column uses.
    @Test func aCopyCarriesTheOriginalPath() {
        let bytes = output(twoPathRecord(
            rawStatus: "C100", oldPath: "source.txt", newPath: "copy.txt", additions: "0", deletions: "0"
        ))
        let entries = NumstatParser.parse(bytes)
        #expect(entries.count == 1)
        #expect(entries[0].originalPath == "source.txt")
        #expect(entries[0].path == "copy.txt")
    }

    /// `-\t-\tpath`, git's numstat spelling for "did not count lines", is a
    /// binary file. Nil counts rather than zero, so a caller cannot mistake a
    /// binary asset for a rebuild that changed nothing.
    @Test func aBinaryFileHasNilCountsAndStaysListed() {
        let output = PorcelainFixture.zeroed("""
        :000000 100644 0000000 366fd40 A
        c.bin
        -\t-\tc.bin

        """)
        let entries = NumstatParser.parse(output)
        #expect(entries.count == 1)
        #expect(entries[0].path == "c.bin")
        #expect(entries[0].additions == nil)
        #expect(entries[0].deletions == nil)
    }

    /// A renamed binary file: two paths in both blocks, and still nil counts.
    /// The path-count decision and the binary decision are independent, and
    /// this is the one fixture that exercises both at once.
    @Test func aBinaryRenameHasNilCountsAndTheOriginalPath() {
        let bytes = output(twoPathRecord(
            rawStatus: "R100", oldPath: "c.bin", newPath: "d.bin", additions: "-", deletions: "-"
        ))
        let entries = NumstatParser.parse(bytes)
        #expect(entries.count == 1)
        #expect(entries[0].originalPath == "c.bin")
        #expect(entries[0].path == "d.bin")
        #expect(entries[0].additions == nil)
        #expect(entries[0].deletions == nil)
    }

    /// A binary add, a text modify and an add all in one capture, mirroring
    /// how `GitStatusChangesTests.everyShape` exercises `GitStatusParser`
    /// against several record kinds at once, in git's own order.
    @Test func aCaptureMixingSeveralShapesParsesInOrder() {
        let output = PorcelainFixture.zeroed("""
        :000000 100644 0000000 d33e394 A
        bin.dat
        :100644 100644 0468ac6 41a158f M
        modify-me.txt
        :000000 100644 0000000 a29bdeb A
        plain-add.txt
        -\t-\tbin.dat
        1\t0\tmodify-me.txt
        3\t0\tplain-add.txt

        """)
        let entries = NumstatParser.parse(output)
        #expect(entries.map(\.path) == ["bin.dat", "modify-me.txt", "plain-add.txt"])
        #expect(entries.map(\.additions) == [nil, 1, 3])
        #expect(entries.map(\.deletions) == [nil, 0, 0])
    }

    /// A rename and a plain modify in one capture, raw block grouped before
    /// numstat block the way real git output is shaped (confirmed with
    /// `git mv old.txt new.txt` beside an edit to `mod.txt`, read with
    /// `od -c`), so the parser's per-record field count actually has to
    /// change between records rather than being fixed for a whole capture.
    @Test func aRenameFollowedByAPlainModifyParsesBothCorrectly() {
        let rename = twoPathRecord(
            rawStatus: "R100", oldPath: "old.txt", newPath: "new.txt", additions: "0", deletions: "0"
        )
        let modifyRaw = PorcelainFixture.zeroed("""
        :100644 100644 422c2b7 d68dd40 M
        mod.txt

        """)
        let modifyNumstat = PorcelainFixture.zeroed("2\t0\tmod.txt\n")
        let bytes = rename.raw + modifyRaw + rename.numstat + modifyNumstat

        let entries = NumstatParser.parse(bytes)
        #expect(entries.map(\.path) == ["new.txt", "mod.txt"])
        #expect(entries[0].originalPath == "old.txt")
        #expect(entries[1].originalPath == nil)
    }

    /// A path holding a byte that is not valid UTF-8. `RepositoryPath` is
    /// documented lossy on `display`; this confirms the parser hands the raw
    /// bytes through to it rather than decoding early and losing the byte for
    /// good.
    @Test func nonUtf8PathsAreCarriedAsBytes() {
        let path = Array("caf".utf8) + [0xE9] + Array(".txt".utf8)
        let output = Array(":000000 100644 0000000 a29bdeb A".utf8) + [0]
            + path + [0]
            + Array("2\t0\t".utf8) + path + [0]
        let entries = NumstatParser.parse(output)
        #expect(entries.count == 1)
        // Lossy on display, the same limit `RepositoryPath` documents.
        #expect(entries[0].path == "caf\u{FFFD}.txt")
    }

    /// A filename that looks exactly like the start of a fresh raw record: a
    /// leading `-`, which is also the binary marker, immediately followed by
    /// digits and a space. A parser that decided path boundaries by content
    /// rather than by the raw block's own field structure would misread this
    /// as record noise; `NumstatParser`'s own doc comment names the real
    /// repository shape (`-README.txt` renamed from `1-notes.txt`) this
    /// guards.
    @Test func aRenameIntoAPathThatLooksLikeARecordStartCarriesTheOriginalPath() {
        let bytes = output(twoPathRecord(
            rawStatus: "R080",
            oldPath: "1-notes.txt",
            newPath: "-100644 README.txt",
            additions: "1",
            deletions: "0"
        ))
        let entries = NumstatParser.parse(bytes)
        #expect(entries.count == 1)
        #expect(entries[0].originalPath == "1-notes.txt")
        #expect(entries[0].path == "-100644 README.txt")
    }

    /// A raw record with no matching numstat record, which a truncated or
    /// malformed capture could produce, stops the parse rather than
    /// fabricating a fileless entry.
    @Test func aTruncatedNumstatBlockStopsRatherThanFabricatingAnEntry() {
        let output = PorcelainFixture.zeroed("""
        :000000 100644 0000000 a29bdeb A
        d.txt

        """)
        #expect(NumstatParser.parse(output).isEmpty)
    }

    // MARK: - RepositoryChangeStats

    @Test func summaryTotalsSumOnlyRealCounts() {
        let entries = [
            NumstatEntry(path: "a.txt", additions: 10, deletions: 2),
            NumstatEntry(path: "b.txt", additions: 3, deletions: 0),
            NumstatEntry(path: "c.bin", additions: nil, deletions: nil),
        ]
        let stats = RepositoryChangeStats(entries: entries)
        #expect(stats.totalAdditions == 13)
        #expect(stats.totalDeletions == 2)
        #expect(stats.entries.count == 3)
    }

    @Test func summaryOfNoEntriesTotalsZero() {
        let stats = RepositoryChangeStats(entries: [])
        #expect(stats.totalAdditions == 0)
        #expect(stats.totalDeletions == 0)
    }

    @Test func lookupByPathFindsAnEntry() {
        let entries = [
            NumstatEntry(path: "a.txt", additions: 10, deletions: 2),
            NumstatEntry(path: "b.txt", additions: nil, deletions: nil),
        ]
        let stats = RepositoryChangeStats(entries: entries)
        #expect(stats.entry(forPath: RepositoryPath("a.txt"))?.additions == 10)
        #expect(stats.entry(forPath: RepositoryPath("missing.txt")) == nil)
    }
}
