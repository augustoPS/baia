import Foundation
import Testing

@testable import GitWorkspace

@Suite final class RecentProjectsTests {
    let fixture: DirectoryFixture
    let recent: RecentProjects

    init() throws {
        fixture = try DirectoryFixture()
        // Under the fixture, never under the real Application Support directory. A
        // test that wrote to `defaultFileURL()` would reorder the owner's own
        // palette on every run.
        recent = RecentProjects(fileURL: fixture.root.appending(path: "state/recent-projects.tsv"))
    }

    /// The file's bytes, or nil when it was never written.
    private func storedText() -> String? {
        let url = fixture.root.appending(path: "state/recent-projects.tsv")
        guard let data = FileManager.default.contents(atPath: url.path(percentEncoded: false)) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    @Test func loadsNothingWhenTheFileIsNotThere() {
        // The first run. An empty dictionary rather than nil, so the ranker needs
        // no branch for a machine that has never opened a project.
        #expect(recent.load().isEmpty)
    }

    @Test func recordsAFirstUse() {
        #expect(recent.recordUse(of: "/Users/pasqualotto/Projects/baia"))
        #expect(recent.load() == ["/Users/pasqualotto/Projects/baia": 1])
    }

    @Test func createsTheContainingDirectory() {
        // `state/` does not exist when the suite starts, and an atomic write needs
        // the directory to place its temporary file in. Without the `mkdir` the
        // very first `recordUse` on a fresh machine returns false forever.
        #expect(!FileManager.default.fileExists(
            atPath: fixture.root.appending(path: "state").path(percentEncoded: false)
        ))
        #expect(recent.recordUse(of: "/Users/pasqualotto/Projects/baia"))
    }

    @Test func incrementsAnExistingCount() {
        #expect(recent.recordUse(of: "/Users/pasqualotto/Projects/baia"))
        #expect(recent.recordUse(of: "/Users/pasqualotto/Projects/baia"))
        #expect(recent.load() == ["/Users/pasqualotto/Projects/baia": 2])
    }

    @Test func countsTwoSpellingsOfOneDirectoryOnce() {
        // A caller holding a `Project` has a path ending in a slash, while one
        // reading a config file or a shell argument does not. Two keys for one
        // directory splits the count and the project never rises in the ranking.
        #expect(recent.recordUse(of: "/Users/pasqualotto/Projects/baia/"))
        #expect(recent.recordUse(of: "/Users/pasqualotto/Projects/baia"))
        #expect(recent.load() == ["/Users/pasqualotto/Projects/baia": 2])
    }

    @Test func keepsSeparateProjectsSeparate() {
        #expect(recent.recordUse(of: "/Users/pasqualotto/Projects/website/shop"))
        #expect(recent.recordUse(of: "/Users/pasqualotto/Projects/website/admin"))
        #expect(recent.recordUse(of: "/Users/pasqualotto/Projects/website/shop"))
        #expect(recent.load() == [
            "/Users/pasqualotto/Projects/website/admin": 1,
            "/Users/pasqualotto/Projects/website/shop": 2,
        ])
    }

    @Test func writesTheFileSortedByPath() {
        // The bytes are a function of the contents alone. Dictionary order is not
        // stable across runs, so a file that reshuffles on every project open is
        // unreadable in a diff and cannot be asserted on at all.
        #expect(recent.recordUse(of: "/Users/pasqualotto/Projects/website/shop"))
        #expect(recent.recordUse(of: "/Users/pasqualotto/Projects/baia"))
        #expect(storedText() == """
        1\t/Users/pasqualotto/Projects/baia
        1\t/Users/pasqualotto/Projects/website/shop

        """)
    }

    @Test func skipsALineWithNoCount() throws {
        // The file is documented as hand-editable, so a botched edit has to cost
        // the line and not the file. Every other count survives.
        try fixture.file("state/recent-projects.tsv", contents: """
        3\t/Users/pasqualotto/Projects/baia
        not-a-number\t/Users/pasqualotto/Projects/vault
        \t/Users/pasqualotto/Projects/scripts
        5
        """)
        #expect(recent.load() == ["/Users/pasqualotto/Projects/baia": 3])
    }

    @Test func skipsALineWhosePathIsNotAbsolute() throws {
        // A relative path cannot be matched against a `Project` URL, so keeping it
        // would leave a line in the file contributing nothing forever.
        try fixture.file("state/recent-projects.tsv", contents: """
        2\tbaia
        4\t/Users/pasqualotto/Projects/vault
        """)
        #expect(recent.load() == ["/Users/pasqualotto/Projects/vault": 4])
    }

    @Test func skipsALineWithANonPositiveCount() throws {
        // A zero contributes nothing to a ranking and a negative one would rank a
        // project below the ones that were never opened, which is not a state
        // `recordUse` can produce and is a state a hand edit can.
        try fixture.file("state/recent-projects.tsv", contents: """
        0\t/Users/pasqualotto/Projects/baia
        -3\t/Users/pasqualotto/Projects/vault
        """)
        #expect(recent.load().isEmpty)
    }

    @Test func refusesAPathThatCannotBeWrittenBackAndReadTheSame() {
        // A tab is the field separator and a newline is the record separator, so
        // either one inside a path produces a line `load` would skip. Storing it
        // anyway makes the count look recorded while ranking nothing, and false is
        // what the caller already treats as "recency is unavailable".
        #expect(!recent.recordUse(of: "/Users/pasqualotto/Projects/two\ttabs"))
        #expect(!recent.recordUse(of: "/Users/pasqualotto/Projects/two\nlines"))
        #expect(storedText() == nil)
    }

    @Test func refusesARelativePath() {
        #expect(!recent.recordUse(of: "baia"))
        #expect(storedText() == nil)
    }

    @Test func preservesCountsItDidNotTouch() {
        // The whole file is rewritten on every use, so a bug in the merge loses
        // every other project's history rather than one.
        #expect(recent.recordUse(of: "/Users/pasqualotto/Projects/baia"))
        #expect(recent.recordUse(of: "/Users/pasqualotto/Projects/baia"))
        #expect(recent.recordUse(of: "/Users/pasqualotto/Projects/vault"))
        #expect(recent.load()["/Users/pasqualotto/Projects/baia"] == 2)
    }

    @Test func rankingFindsAProjectRecordedThroughItsDirectoryURL() {
        // The round trip both types have to agree on. A caller records a path taken
        // from a `Project.url`, which ends in a slash, and the ranker looks the
        // project up again later. Either side skipping the normalization leaves the
        // count in the file and invisible to the ranking, which presents as recency
        // never working while the file fills up correctly.
        let project = Project(
            url: URL(filePath: "/Users/pasqualotto/Projects/vault", directoryHint: .isDirectory),
            displayName: "vault",
            kind: .repository,
            relativePath: "vault"
        )
        let other = Project(
            url: URL(filePath: "/Users/pasqualotto/Projects/baia", directoryHint: .isDirectory),
            displayName: "baia",
            kind: .repository,
            relativePath: "baia"
        )
        #expect(recent.recordUse(of: project.url.path(percentEncoded: false)))

        let ranked = ProjectRanker.rank([other, project], query: "", recency: recent.load())

        #expect(ranked.map(\.displayName) == ["vault", "baia"])
    }

    @Test func defaultFileURLLivesUnderApplicationSupport() {
        // Not `UserDefaults`: the counts are worth reading and editing by hand when
        // the ranking looks wrong, and deleting the file is a supported repair.
        let url = RecentProjects.defaultFileURL()
        #expect(url.lastPathComponent == "recent-projects.tsv")
        #expect(url.deletingLastPathComponent().lastPathComponent == "baia")
        #expect(url.path(percentEncoded: false).contains("Application Support"))
    }
}
