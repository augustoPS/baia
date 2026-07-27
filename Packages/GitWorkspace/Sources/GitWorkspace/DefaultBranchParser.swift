/// Reads `git for-each-ref --format='%(refname) %(symref)' 'refs/remotes/*/HEAD'`.
///
/// One process answers both halves of the question: which remotes this repository
/// has an opinion from, and what each one's HEAD points at. `git symbolic-ref
/// refs/remotes/origin/HEAD` answers only the second half, and only for a remote
/// that happens to be called `origin`, so a checkout whose remote is `upstream`
/// would need a second process to find the name to ask about. Both are one spawn
/// for the common case; this one is one spawn for every case.
///
/// Kept free of any process running, like ``GitStatusParser`` and
/// ``GitWorktreeParser``, so the selection rule is covered on fixture strings
/// rather than on a repository per case.
public enum DefaultBranchParser {
    /// The branch the repository's remotes call default, or nil when they do not
    /// agree on one and none of them is `origin`.
    ///
    /// `origin` wins outright when it is present, because that is the remote the
    /// owner's own work goes to: a fork checkout has `upstream` pointing at the
    /// project's default and `origin` at the fork's, and the fork's is the branch
    /// he is actually always on. Without a preference the answer would fall out of
    /// `for-each-ref`'s refname sort, which is alphabetical and means nothing.
    ///
    /// With no `origin`, one remote answers on its own and several answer only
    /// when they agree. Disagreement returns nil rather than a pick, so the caller
    /// falls back to a rule that is wrong in a way the owner can predict from the
    /// branch name instead of one he would have to inspect the remotes to explain.
    public static func parse(_ output: String) -> String? {
        var candidates: [(remote: String, branch: String)] = []

        // Split on any newline for the reason ``GitStatusParser`` documents: a CRLF
        // pair is a single `Character` in Swift, so splitting on "\n" would leave a
        // capture that went through a CRLF filter as one unrecognised line.
        for record in output.split(whereSeparator: \.isNewline) {
            // Bounded at one split, so a branch name containing a space is kept
            // whole. git allows it, and the alternative silently drops the
            // repository's answer instead of reporting a name nobody can push to.
            let fields = record.split(
                separator: " ",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard fields.count == 2, let remote = remoteName(ofHeadRef: fields[0]) else { continue }

            // The target must live under the remote it was read from. Stripping a
            // prefix without checking it is there would yield a branch name with
            // `refs/` still in it, which matches no local branch and would name the
            // default in the tab forever.
            let prefix = "\(refsPrefix)\(remote)/"
            guard fields[1].hasPrefix(prefix) else { continue }

            // Stripped by length rather than by taking the last path component, so a
            // default called `release/2.0` survives as itself.
            let branch = fields[1].dropFirst(prefix.count)
            guard !branch.isEmpty else { continue }
            candidates.append((remote, String(branch)))
        }

        if let origin = candidates.first(where: { $0.remote == preferredRemote }) {
            return origin.branch
        }
        let named = Set(candidates.map(\.branch))
        return named.count == 1 ? named.first : nil
    }

    /// The remote a `refs/remotes/<remote>/HEAD` belongs to, or nil for any other
    /// ref.
    ///
    /// Everything between the prefix and the suffix, rather than one path
    /// component, because `git remote add gh/fork` is legal and its refs nest one
    /// level deeper.
    private static func remoteName(ofHeadRef ref: Substring) -> String? {
        guard ref.hasPrefix(refsPrefix), ref.hasSuffix(headSuffix) else { return nil }
        let name = ref.dropFirst(refsPrefix.count).dropLast(headSuffix.count)
        return name.isEmpty ? nil : String(name)
    }

    private static let refsPrefix = "refs/remotes/"
    private static let headSuffix = "/HEAD"
    private static let preferredRemote = "origin"
}
