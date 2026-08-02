extension RepositoryFileChange {
    /// Where a change sits in commit order. Lower comes first.
    ///
    /// Four bands rather than a comparison, because the order is a policy about
    /// kinds and not a fact about paths, and a policy that is spelled out can be
    /// tested one band at a time.
    ///
    /// A file that is both staged and modified since ranks as staged. It prints
    /// `MM` and part of it is going into the commit, and the row's own two-column
    /// marker is what says the rest is not.
    var commitRank: Int {
        switch kind {
        case .unmerged: 0
        case .untracked: 3
        case .ordinary, .renamedOrCopied: index != nil ? 1 : 2
        }
    }
}

extension [RepositoryFileChange] {
    /// Conflicts first, then staged, then unstaged, then untracked, and by path
    /// within each group.
    ///
    /// The order is what a `git commit` needs answered, in the order it needs it:
    /// a conflict blocks the commit, a staged change is going into it, an
    /// unstaged one is not, and an untracked file is the one most easily
    /// forgotten. Git's own order is by path across all of them, which buries a
    /// conflict among fifty modified files.
    ///
    /// Ties break on ``RepositoryFileChange/path``, the drawn spelling, rather
    /// than on the bytes. That is what the surface did before this moved and it
    /// is kept deliberately: the tie-break exists so a list does not reshuffle
    /// between two reads, and the drawn spelling is the one the reader is
    /// scanning down. Two paths differing only outside UTF-8 therefore order
    /// arbitrarily against each other, which is a real limit and a smaller one
    /// than sorting a visible list by an invisible key.
    public func inCommitOrder() -> [RepositoryFileChange] {
        sorted { left, right in
            left.commitRank == right.commitRank
                ? left.path < right.path
                : left.commitRank < right.commitRank
        }
    }
}
