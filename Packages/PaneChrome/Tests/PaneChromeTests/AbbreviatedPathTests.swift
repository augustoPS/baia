import Testing

@testable import PaneChrome

/// `PaneStatus.abbreviated(_:home:)`, the tilde rule on its own. The cases
/// here are the ones the first app-target hand copy got wrong or nearly
/// wrong, promoted to tests the moment the helper moved somewhere testable.
@Suite struct AbbreviatedPathTests {
    /// The bug that forced the move: a home taken from
    /// `homeDirectoryForCurrentUser.path` carries a trailing slash, and a
    /// prefix test against `home + "/"` then never matches anything.
    @Test func aTrailingSlashOnHomeStillAbbreviates() {
        #expect(PaneStatus.abbreviated("/Users/gu/p", home: "/Users/gu/") == "~/p")
    }

    /// A directory URL's own `path` ends in a slash too, and the drawn value
    /// must not keep it: `~/p/` names the same place as `~/p` while looking
    /// like a different one.
    @Test func aTrailingSlashOnThePathIsTrimmed() {
        #expect(PaneStatus.abbreviated("/Users/gu/p/", home: "/Users/gu") == "~/p")
    }

    /// The boundary rule, unchanged from `workingDirectory`'s: `/Users/gu`
    /// against `/Users/gutao/p` is a string prefix and not a directory one,
    /// and abbreviating it would print a path that does not exist.
    @Test func aStringPrefixThatIsNotAPathBoundaryDoesNotAbbreviate() {
        #expect(PaneStatus.abbreviated("/Users/gutao/p", home: "/Users/gu") == "/Users/gutao/p")
    }

    @Test func exactlyAtHomeIsTilde() {
        #expect(PaneStatus.abbreviated("/Users/gu", home: "/Users/gu") == "~")
        #expect(PaneStatus.abbreviated("/Users/gu/", home: "/Users/gu") == "~")
    }

    @Test func aPathOutsideHomePassesThrough() {
        #expect(PaneStatus.abbreviated("/opt/homebrew", home: "/Users/gu") == "/opt/homebrew")
    }

    /// An empty home must not turn every absolute path into `~<path>`:
    /// with no root to compare against there is nothing to abbreviate.
    @Test func anEmptyHomeAbbreviatesNothing() {
        #expect(PaneStatus.abbreviated("/Users/gu/p", home: "") == "/Users/gu/p")
        #expect(PaneStatus.abbreviated("/Users/gu/p", home: "/") == "/Users/gu/p")
    }
}
