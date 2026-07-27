import Foundation

/// Answers whether a head is the branch its repository is normally on, once per
/// repository.
///
/// The question exists because a status bar and a tab label want to say what is
/// unusual about a pane, and being on the default branch is the least unusual
/// thing a repository can report. Getting it wrong is not symmetric: a repository
/// whose default is `develop` used to be labelled `:develop` permanently, on the
/// one branch the owner never leaves.
///
/// ## Resolution order, and what each step costs
///
/// 1. `refs/remotes/*/HEAD`, read with one local `git for-each-ref`. Cheap, no
///    network, and it is the only local record of what a remote calls its default.
///    It is wrong or absent in three knowable ways. `git clone` writes it and
///    `git init` never does, so a repository that was never cloned has no answer at
///    all. `git remote add` writes no refs either, so a hand-wired remote stays
///    unanswered until someone runs `git remote set-head`. And it is a cache of a
///    fact that lives on the server: when a remote renames its default, this keeps
///    naming the old branch until a `set-head` or a fresh clone updates it, and
///    nothing local can notice. The cost of that last one is a tab that names the
///    new default as if it were unusual, which is visible and self-correcting
///    rather than silent.
/// 2. The name test, `main` or `master`. Wrong exactly where the old predicate was
///    wrong, and reached only where there is genuinely nothing to be right with.
///
/// `git config --get init.defaultBranch` is deliberately not in that list. It is
/// the user's preference for repositories created from now on, not a fact about
/// this one, so it answers confidently and wrongly for every repository cloned or
/// created before the preference was set, which is most of them. Paying a second
/// process to be wrong with more conviction than the name test is a bad trade.
///
/// ## Why this is a stored answer rather than part of the status read
///
/// ``GitCommand/status(ofRepositoryRoot:)`` runs on a timer, once per pane per
/// `gitPollSeconds`, and the default branch of a repository changes approximately
/// never. Folding the lookup into that read would put a second `git` process
/// behind every tick of every pane, permanently, to re-learn something that was
/// already known. So it is resolved on the first read of a repository and
/// remembered for the life of the resolver.
public final class DefaultBranchResolver: @unchecked Sendable {
    private let command: GitCommand

    /// `NSLock` and a dictionary rather than an actor, because every caller is
    /// synchronous: ``GitCommand`` blocks on `waitpid`, and the app already calls
    /// it from a utility queue. An actor would make this the one part of the
    /// package that forces its callers to be async.
    ///
    /// Not `Synchronization.Mutex`, which needs macOS 15 while this package
    /// deploys to 13.
    private let lock = NSLock()

    /// Keyed by path, and the value is itself optional: a repository that has been
    /// asked and has no answer is a different state from one that has not been
    /// asked. Collapsing them would re-run `for-each-ref` on every poll of every
    /// local-only repository, which is the exact set that can never answer.
    ///
    /// Never invalidated. A repository that gains a remote mid-session keeps using
    /// the name test until baia is restarted, which is the price of never forking
    /// git on a timer for this.
    private var resolved: [String: String?] = [:]

    public init(command: GitCommand = GitCommand()) {
        self.command = command
    }

    /// The repository's default branch, read once and remembered, or nil when
    /// nothing local knows it.
    ///
    /// The lookup runs while the lock is held. That serialises two panes opening on
    /// the same repository at the same moment, which is the point: releasing the
    /// lock around the spawn would let every pane in the window fork its own
    /// `for-each-ref` before the first answer landed, and the whole reason this type
    /// exists is that the answer only needs fetching once.
    public func defaultBranch(ofRepositoryRoot root: URL) -> String? {
        let key = root.path(percentEncoded: false)
        lock.lock()
        defer { lock.unlock() }
        if let remembered = resolved[key] { return remembered }
        let answer = command.defaultBranch(ofRepositoryRoot: root)
        resolved[key] = answer
        return answer
    }

    /// Whether `head` is the branch this repository is normally on.
    ///
    /// A detached HEAD is never it. That is not a special case so much as the
    /// plainest one: a detached head is the state the owner most needs the label
    /// to shout about, and it has no branch name to compare with.
    ///
    /// An unborn head compares by name like any other. A fresh `git init` sits on a
    /// branch that has no commits and is still the default one, and calling it
    /// unusual would put a `:main` on every repository for as long as it took to
    /// make the first commit.
    public func isDefaultBranch(
        _ head: RepositoryStatus.Head,
        ofRepositoryRoot root: URL
    ) -> Bool {
        switch head {
        case .detached:
            return false
        case let .branch(name), let .unborn(name):
            guard let answer = defaultBranch(ofRepositoryRoot: root) else {
                return Self.isConventionalDefault(name)
            }
            return name == answer
        }
    }

    /// The fallback, for a repository where no remote has ever said.
    ///
    /// A guess by name, and the same guess this whole type replaces. It stays
    /// because a repository with no remote has no default branch to be right
    /// about: the owner's vault is deliberately local-only, and answering "not the
    /// default" there would label its permanent branch as unusual forever, while
    /// answering "the default" would hide every branch he ever checks out in it.
    public static func isConventionalDefault(_ branch: String) -> Bool {
        branch == "main" || branch == "master"
    }
}
