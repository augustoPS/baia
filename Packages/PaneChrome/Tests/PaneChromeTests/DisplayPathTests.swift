import Testing

@testable import PaneChrome

/// The rows here are the same ones `shell/prompt.zsh` was checked against in
/// `claude-dotfiles`, because the two implement one rule and the day they
/// disagree is the day a directory has two names.
@Suite struct DisplayPathTests {
    @Test func keepsAPathThatIsAlreadyTwoComponents() {
        #expect(DisplayPath.shortened("~/Projects") == "~/Projects")
        #expect(DisplayPath.shortened("/usr") == "/usr")
    }

    /// The parent is `~` or `/`, so collapsing costs the tilde and the root and
    /// saves nothing: both spellings are the same width.
    @Test func keepsAParentThatIsOnlyTheHomeOrTheRoot() {
        #expect(DisplayPath.shortened("~/Projects/baia") == "~/Projects/baia")
        #expect(DisplayPath.shortened("/usr/local") == "/usr/local")
    }

    @Test func dropsEverythingAboveTheLastTwoComponents() {
        #expect(DisplayPath.shortened("~/Projects/baia/Sources") == "../baia/Sources")
        #expect(DisplayPath.shortened("/usr/local/share/man") == "../share/man")
    }

    /// The case that prompted this: 76 characters of machine-generated prefix
    /// with the two the owner reads at the end.
    @Test func shortensTheTemporaryDirectory() {
        #expect(
            DisplayPath.shortened("/private/var/folders/pp/4p7nc/T/baia-path-picker-fixture/src")
                == "../baia-path-picker-fixture/src"
        )
    }

    @Test func leavesTheRootAndABareComponentAlone() {
        #expect(DisplayPath.shortened("/") == "/")
        #expect(DisplayPath.shortened("~") == "~")
        #expect(DisplayPath.shortened("baia") == "baia")
    }

    @Test func returnsAnEmptyPathUnchanged() {
        #expect(DisplayPath.shortened("") == "")
    }

    /// A trailing slash would otherwise make the last component empty, and every
    /// path would shorten to its own parent with a dangling separator.
    @Test func ignoresATrailingSlash() {
        #expect(DisplayPath.shortened("~/Projects/baia/Sources/") == "../baia/Sources")
        #expect(DisplayPath.shortened("~/Projects/") == "~/Projects")
    }

    /// No filesystem access and no symlink resolution: the caller has already
    /// chosen which spelling of the directory it means, and resolving here would
    /// show a path the owner cannot find in their own prompt.
    @Test func doesNotResolveAnythingItIsGiven() {
        #expect(DisplayPath.shortened("/var/folders/x/T/repo") == "../T/repo")
        #expect(DisplayPath.shortened("/private/var/folders/x/T/repo") == "../T/repo")
    }

    @Test func keepsAComponentThatHoldsASpace() {
        #expect(DisplayPath.shortened("~/Projects/my repo/src") == "../my repo/src")
    }
}
