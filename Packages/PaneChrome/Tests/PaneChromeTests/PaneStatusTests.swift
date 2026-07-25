import Foundation
import Testing

@testable import PaneChrome

@Suite struct PaneStatusTests {
    @Test func theShellDirectoryIsTildeAbbreviatedAgainstTheSuppliedHome() {
        #expect(PaneStatus.workingDirectory(
            ofShellAt: "/Users/gu/Projects/baia/Packages",
            anchoredAt: "/Users/gu/Projects/baia",
            home: "/Users/gu"
        ) == "~/Projects/baia/Packages")
    }

    @Test func aShellSittingAtTheAnchorHasNoDirectoryToShow() {
        // The leading segments already name the project. Restating it in the
        // widest trailing segment costs the working directory's own place on a
        // narrow bar and says nothing.
        #expect(PaneStatus.workingDirectory(
            ofShellAt: "/Users/gu/Projects/baia",
            anchoredAt: "/Users/gu/Projects/baia",
            home: "/Users/gu"
        ) == nil)
    }

    @Test func aTrailingSlashDoesNotMakeTheShellLookLikeItMoved() {
        // The kernel's `proc_pidinfo` answer and a URL built with a directory
        // hint spell the same directory differently, and six locator tests in
        // ProjectAnchor once failed on nothing but this.
        #expect(PaneStatus.workingDirectory(
            ofShellAt: "/Users/gu/Projects/baia/",
            anchoredAt: "/Users/gu/Projects/baia",
            home: "/Users/gu"
        ) == nil)
    }

    @Test func aHomePrefixThatIsNotAPathBoundaryIsNotAbbreviated() {
        // `/Users/gu` is a plain string prefix of `/Users/gutao/...`.
        // Abbreviating on that would produce `~tao/notes`, a path that exists
        // nowhere and cannot be pasted into anything.
        #expect(PaneStatus.workingDirectory(
            ofShellAt: "/Users/gutao/notes",
            anchoredAt: "/Users/gutao/Projects",
            home: "/Users/gu"
        ) == "/Users/gutao/notes")
    }

    @Test func aDirectoryOutsideHomeKeepsItsAbsolutePath() {
        #expect(PaneStatus.workingDirectory(
            ofShellAt: "/opt/homebrew/etc",
            anchoredAt: "/opt/homebrew",
            home: "/Users/gu"
        ) == "/opt/homebrew/etc")
    }

    @Test func homeItselfAbbreviatesToTheTildeAlone() {
        #expect(PaneStatus.workingDirectory(
            ofShellAt: "/Users/gu",
            anchoredAt: "/Users/gu/Projects",
            home: "/Users/gu"
        ) == "~")
    }

    @Test func anUnknownHomeLeavesThePathAlone() {
        // A caller with no home to offer gets the full path rather than a path
        // with a stray tilde welded to the front of it.
        #expect(PaneStatus.workingDirectory(
            ofShellAt: "/Users/gu/Projects/baia/Sources",
            anchoredAt: "/Users/gu/Projects/baia",
            home: ""
        ) == "/Users/gu/Projects/baia/Sources")
    }
}
