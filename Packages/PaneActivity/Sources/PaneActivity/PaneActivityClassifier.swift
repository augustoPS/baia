import Foundation

/// Turns a process tree into the one ``PaneActivity`` worth showing for a pane.
///
/// Pure and total. Every tree produces an answer, including an empty one, one
/// whose shell is missing, and one whose parent pointers form a cycle, because
/// the caller is a poll timer with nowhere to report a failure to. That
/// totality is also what makes the interesting cases testable from hand built
/// arrays rather than from a live pane holding a live agent.
public enum PaneActivityClassifier {
    /// Pure. `tree` is every process at or under the pane's shell, `shellPid`
    /// the shell itself. Deepest and most specific wins, so a `claude` that
    /// itself spawned `npm` still classifies as the agent.
    ///
    /// Ambiguity is resolved by three keys in a fixed order, so one tree always
    /// yields one answer and a pane's label cannot flicker between two equally
    /// defensible readings of the same processes:
    ///
    /// 1. Specificity: agent, then build, then command. An agent that spawned a
    ///    build stays the agent, because running builds is how the agent works.
    /// 2. Depth below `shellPid`, deepest first. The deepest process of a
    ///    category is the one doing the work while its ancestors wait on it.
    /// 3. Highest pid. Only reachable for two processes of one category at one
    ///    depth, where no key carries real meaning, and it exists purely so
    ///    the answer does not depend on array order. ``ProcessTree`` builds
    ///    its array by walking a dictionary, so that order is not stable
    ///    across calls.
    public static func classify(tree: [ProcessSnapshot], shellPid: pid_t) -> PaneActivity {
        let depths = depthsBelow(shellPid, in: tree)
        var best: Candidate?
        for process in tree {
            // The pane's own shell is idle by definition, and it is excluded by
            // pid rather than by name. baia hands over the pid it spawned, so a
            // pane running a shell that is not in `shellNames` must still read
            // as idle rather than as permanently running a command called `nu`.
            guard process.pid != shellPid, let depth = depths[process.pid] else { continue }
            guard let (rank, activity) = candidate(process) else { continue }
            let contender = Candidate(
                rank: rank,
                depth: depth,
                pid: process.pid,
                activity: activity
            )
            guard let incumbent = best else {
                best = contender
                continue
            }
            if contender.beats(incumbent) { best = contender }
        }
        return best?.activity ?? .idleShell
    }

    /// The agents worth naming.
    ///
    /// Matching runs over ``identifyingTokens(of:)`` rather than over
    /// `ProcessSnapshot.name`, because none of these is reliably its own
    /// process name: the current Claude Code reports its version string, and an
    /// npm-installed agent reports `node`.
    public static let agentNames: Set<String> = [
        "claude",
        "codex",
        "gemini",
        "aider",
        "cursor-agent",
    ]

    /// Commands that mean a build or a package install is in flight.
    ///
    /// `swift-frontend` is here as well as `swift`, because a `swift build`
    /// that is deep in compilation has the driver's children doing the work and
    /// the deepest-wins rule would otherwise land on a name nobody recognises.
    public static let buildCommands: Set<String> = [
        "make",
        "xcodebuild",
        "swift",
        "swift-frontend",
        "npm",
        "pnpm",
        "yarn",
        "vite",
        "vitest",
        "astro",
        "tsc",
        "cargo",
        "go",
        "docker",
    ]

    /// Names that are plumbing rather than a running command.
    ///
    /// `login` and `bash` are in here for ghostty's own spawn chain, where
    /// `login -flp` runs a `bash --noprofile --norc` that execs the real `zsh`.
    /// Both links would otherwise surface as the pane permanently running
    /// something. The cost is accepted and real: a hand written `bash build.sh`
    /// also reads as a shell, because separating it from the wrapper would mean
    /// guessing from arguments that `login` does not even publish.
    public static let shellNames: Set<String> = [
        "zsh",
        "bash",
        "sh",
        "fish",
        "login",
    ]

    /// Programs whose first argument is the thing actually running.
    ///
    /// Private because it steers matching rather than describing anything a
    /// caller would display, and deliberately short. A long list turns every
    /// `python somescript.py` into a guess about the script's name, while these
    /// cover the shape that matters: an agent or a build tool installed as a
    /// script, where every field except the first argument says `node`.
    private static let scriptInterpreters: Set<String> = [
        "node",
        "npx",
        "bun",
        "deno",
        "python",
        "python3",
        "ruby",
    ]

    /// A classified process plus the three keys that order it against others.
    private struct Candidate {
        let rank: Int
        let depth: Int
        let pid: pid_t
        let activity: PaneActivity

        func beats(_ other: Candidate) -> Bool {
            if rank != other.rank { return rank < other.rank }
            if depth != other.depth { return depth > other.depth }
            return pid > other.pid
        }
    }

    /// What one process would classify as on its own, or nil when it is a shell
    /// or carries no usable identifier at all.
    ///
    /// The scan stops at the first token that lands in any of the three sets,
    /// which is why the sets have to stay disjoint: an overlapping member would
    /// make the answer depend on which set happened to be tested first. A token
    /// in none of them is skipped rather than ending the scan, which is what
    /// lets Claude Code through: its `proc_pidpath` component `2.1.220` matches
    /// nothing and the next token, argv[0], is `claude`.
    private static func candidate(_ process: ProcessSnapshot) -> (rank: Int, activity: PaneActivity)? {
        let tokens = identifyingTokens(of: process)
        for token in tokens {
            if agentNames.contains(token) {
                return (0, .agent(name: token, pid: process.pid))
            }
            if buildCommands.contains(token) {
                return (1, .build(command: token))
            }
            if shellNames.contains(token) {
                return nil
            }
        }
        // An unrecognised process is named by its most specific token rather
        // than by `name`, so a `vim` reached through a wrapper reads as `vim`
        // and not as whatever the kernel truncated the wrapper to.
        guard let name = tokens.first else { return nil }
        return (2, .command(name: name))
    }

    /// The identifiers to match against, most specific first.
    ///
    /// The order is the whole design, and it was measured rather than guessed
    /// against the live Claude Code on this machine. `name` is last because it
    /// is truncated to 16 bytes and freely rewritable, and that process reports
    /// `2.1.220`. `proc_pidpath` is no better for it, resolving the symlink to
    /// `~/.local/share/claude/versions/2.1.220`. What names the agent is
    /// `KERN_PROCARGS2`: an exec path of `~/.local/bin/claude` and an argv[0]
    /// of `claude`.
    ///
    /// The exec path is preferred over argv[0] because a process may set
    /// argv[0] to anything, while the exec path had to name a file that
    /// existed. The interpreter step covers the shape the same programs still
    /// have elsewhere, `node /opt/homebrew/bin/claude`, where every field
    /// except the script says `node`.
    private static func identifyingTokens(of process: ProcessSnapshot) -> [String] {
        let primaries = [
            process.executablePath.map { command(of: $0) },
            process.arguments.first.map { command(of: $0) },
            command(of: process.name),
        ].compactMap { $0 }

        var tokens: [String] = []
        // The flag check is what keeps `node --version` from classifying as a
        // command called `-version`. A first argument that starts with a hyphen
        // is an option to the interpreter, never the script it is about to run.
        if primaries.contains(where: { scriptInterpreters.contains($0) }),
           process.arguments.count > 1,
           !process.arguments[1].hasPrefix("-") {
            tokens.append(command(of: process.arguments[1]))
        }
        tokens.append(contentsOf: primaries)
        return tokens.filter { !$0.isEmpty }
    }

    /// The last path component of an argument, with a leading hyphen dropped.
    ///
    /// A login shell announces itself by prefixing argv[0] with a hyphen, and
    /// both spellings occur: a plain `-zsh`, and `-/bin/zsh`, which is the
    /// measured argv[0] of the shell in a live ghostty pane. Taking the
    /// component first handles the second and dropping the hyphen handles the
    /// first, so both reach ``shellNames`` and an idle pane does not report
    /// itself as running `zsh`.
    private static func command(of argument: String) -> String {
        let last = (argument as NSString).lastPathComponent
        return last.hasPrefix("-") ? String(last.dropFirst()) : last
    }

    /// How far each process sits below `shellPid`, for the processes that reach
    /// it.
    ///
    /// The upward walk is bounded by `tree.count` steps instead of trusting the
    /// parent pointers to form a tree. A cycle would otherwise be a loop that
    /// never returns on the poll timer, which presents as a frozen window
    /// rather than as a wrong label, and the bound is safe because a real chain
    /// among n processes reaches `shellPid` in fewer than n steps.
    ///
    /// `shellPid` need not appear in `tree`: a process whose `parentPid` is the
    /// shell gets depth 1 whether or not the shell's own entry survived the
    /// snapshot. Anything that fails to reach `shellPid` gets no depth at all,
    /// which is what stops a process belonging to a sibling pane from being
    /// reported as this pane's activity.
    private static func depthsBelow(_ shellPid: pid_t, in tree: [ProcessSnapshot]) -> [pid_t: Int] {
        var parents: [pid_t: pid_t] = [:]
        for process in tree {
            parents[process.pid] = process.parentPid
        }

        var depths: [pid_t: Int] = [:]
        for process in tree {
            var current = process.pid
            var steps = 0
            while steps <= tree.count {
                if current == shellPid {
                    depths[process.pid] = steps
                    break
                }
                guard let parent = parents[current] else { break }
                current = parent
                steps += 1
            }
        }
        return depths
    }
}
