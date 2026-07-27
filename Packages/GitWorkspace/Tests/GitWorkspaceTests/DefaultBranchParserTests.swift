import Testing

@testable import GitWorkspace

/// The grammar of `git for-each-ref --format='%(refname) %(symref)'
/// 'refs/remotes/*/HEAD'`, on fixture strings, so the whole selection rule is
/// covered without a process per case.
@Suite struct DefaultBranchParserTests {
    @Test func readsTheBranchOriginsHeadPointsAt() {
        #expect(
            DefaultBranchParser.parse("refs/remotes/origin/HEAD refs/remotes/origin/develop\n")
                == "develop"
        )
    }

    @Test func prefersOriginOverEveryOtherRemote() {
        // A fork checkout has `origin` pointing at the fork and `upstream` at the
        // project. The branch the owner is "always on" is the fork's default, and
        // sorting order must not be what decides that: `for-each-ref` sorts by
        // refname, so a remote called `apple` would otherwise win.
        let output = """
        refs/remotes/apple/HEAD refs/remotes/apple/trunk
        refs/remotes/origin/HEAD refs/remotes/origin/main
        refs/remotes/upstream/HEAD refs/remotes/upstream/develop
        """
        #expect(DefaultBranchParser.parse(output) == "main")
    }

    @Test func usesTheOnlyRemoteEvenWhenItIsNotCalledOrigin() {
        // `git clone --origin upstream` and `git remote rename` both produce this.
        // Refusing to answer here would put a permanent `:develop` on a repository
        // that has a perfectly good answer.
        #expect(
            DefaultBranchParser.parse("refs/remotes/upstream/HEAD refs/remotes/upstream/develop")
                == "develop"
        )
    }

    @Test func acceptsSeveralRemotesThatNameTheSameBranch() {
        // Two remotes of the same project disagreeing about nothing is not
        // ambiguity. The answer is the same whichever one is consulted.
        let output = """
        refs/remotes/fork/HEAD refs/remotes/fork/main
        refs/remotes/upstream/HEAD refs/remotes/upstream/main
        """
        #expect(DefaultBranchParser.parse(output) == "main")
    }

    @Test func refusesSeveralRemotesThatDisagreeAndHaveNoOrigin() {
        // Nil rather than a guess. The caller falls back to the name test, which
        // is wrong in a knowable way, while picking one of these at random is
        // wrong in a way nobody can predict from the repository.
        let output = """
        refs/remotes/fork/HEAD refs/remotes/fork/main
        refs/remotes/upstream/HEAD refs/remotes/upstream/develop
        """
        #expect(DefaultBranchParser.parse(output) == nil)
    }

    @Test func keepsTheSlashesInsideABranchName() {
        // The remote prefix is stripped by length rather than by taking the last
        // path component, so a default called `release/2.0` survives. Taking the
        // last component would answer `2.0`, which matches no local branch, and
        // the tab would name the default branch forever.
        #expect(
            DefaultBranchParser.parse("refs/remotes/origin/HEAD refs/remotes/origin/release/2.0")
                == "release/2.0"
        )
    }

    @Test func readsARemoteWhoseOwnNameHasASlash() {
        // `git remote add gh/fork` is legal. The remote name is everything between
        // `refs/remotes/` and `/HEAD`, which is the only reading that survives it.
        #expect(
            DefaultBranchParser.parse("refs/remotes/gh/fork/HEAD refs/remotes/gh/fork/main")
                == "main"
        )
    }

    @Test func ignoresAHeadThatIsNotSymbolic() {
        // `%(symref)` is empty for a `refs/remotes/<remote>/HEAD` that holds an oid
        // rather than a pointer. There is no branch name in that, and emitting the
        // empty string would hide every branch in the repository.
        #expect(DefaultBranchParser.parse("refs/remotes/origin/HEAD ") == nil)
        #expect(DefaultBranchParser.parse("refs/remotes/origin/HEAD") == nil)
    }

    @Test func ignoresATargetOnADifferentRemote() {
        // Not something git writes. It is checked because the prefix strip is what
        // separates the branch from the ref, and stripping a prefix that is not
        // there would yield a branch name with `refs/remotes/` still in it.
        #expect(
            DefaultBranchParser.parse("refs/remotes/origin/HEAD refs/heads/main") == nil
        )
    }

    @Test func ignoresARefThatIsNotARemoteHead() {
        #expect(DefaultBranchParser.parse("refs/heads/main refs/heads/main") == nil)
        #expect(DefaultBranchParser.parse("refs/remotes/origin/main refs/remotes/origin/main") == nil)
    }

    @Test func readsNothingFromNothing() {
        // What a repository with no remote produces: exit 0 and an empty capture.
        // It has to read as "no answer" rather than as a parse failure, because the
        // caller's fallback is the same either way and this is the common case for
        // the owner's local-only vault.
        #expect(DefaultBranchParser.parse("") == nil)
        #expect(DefaultBranchParser.parse("\n\n") == nil)
    }

    @Test func readsOutputSeparatedByCarriageReturns() {
        // Split on any newline, for the same reason ``GitStatusParser`` does: a
        // CRLF pair is one `Character` in Swift, so a capture that went through a
        // CRLF filter parses as a single unrecognised line.
        let output = "refs/remotes/origin/HEAD refs/remotes/origin/develop\r\n"
        #expect(DefaultBranchParser.parse(output) == "develop")
    }
}
