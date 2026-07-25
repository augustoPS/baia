import Foundation
import Testing

@testable import PaneActivity

@Suite struct PaneActivityClassifierTests {
    /// Builds a snapshot with the fields a test cares about and defaults for the
    /// rest.
    ///
    /// `startedAtSecondsSinceBoot` is always nil here, which is not laziness: the
    /// classifier must never consult it, so every test in this suite passing with
    /// it absent is the assertion that it does not.
    private func process(
        pid: pid_t,
        parent: pid_t,
        name: String,
        path: String? = nil,
        arguments: [String] = []
    ) -> ProcessSnapshot {
        ProcessSnapshot(
            pid: pid,
            parentPid: parent,
            name: name,
            executablePath: path,
            arguments: arguments,
            startedAtSecondsSinceBoot: nil
        )
    }

    /// The pane's own shell, spelled the way ghostty leaves it.
    ///
    /// argv[0] carries the login hyphen and the path is the real binary, which is
    /// the exact shape measured from a live pane. Every tree here starts from it,
    /// so no test can pass by accident on a shell that would not occur.
    private var paneShell: ProcessSnapshot {
        process(pid: 100, parent: 10, name: "zsh", path: "/bin/zsh", arguments: ["-/bin/zsh"])
    }

    @Test func aTreeHoldingOnlyThePaneShellIsIdle() {
        #expect(PaneActivityClassifier.classify(tree: [paneShell], shellPid: 100) == .idleShell)
    }

    @Test func anEmptyTreeIsIdle() {
        #expect(PaneActivityClassifier.classify(tree: [], shellPid: 100) == .idleShell)
    }

    @Test func aLoginShellSpelledWithALeadingHyphenIsStillAShell() {
        // The hyphen half of `command(of:)`, on a nested shell rather than on the
        // pane's own, which is excluded by pid anyway. Without the strip the token
        // stays `-zsh`, which is in no set, so an idle pane would report a running
        // command named `-zsh`.
        let nested = process(pid: 101, parent: 100, name: "zsh", arguments: ["-zsh"])

        let activity = PaneActivityClassifier.classify(tree: [paneShell, nested], shellPid: 100)

        #expect(activity == .idleShell)
    }

    @Test func loginAndBashWithNothingElseAreIdle() {
        // ghostty's own spawn chain, which every pane contains and no pane is
        // running as a command. `login` publishes no argv at all, measured, so it
        // has to be recognisable from `name` alone and this tree gives it nothing
        // else.
        let login = process(pid: 101, parent: 100, name: "login", path: "/usr/bin/login")
        let bash = process(
            pid: 102,
            parent: 101,
            name: "bash",
            path: "/bin/bash",
            arguments: ["/bin/bash", "--noprofile", "--norc", "-c", "exec -l /bin/zsh"]
        )

        let activity = PaneActivityClassifier.classify(
            tree: [paneShell, login, bash],
            shellPid: 100
        )

        #expect(activity == .idleShell)
    }

    @Test func aNodeWhosePathEndsInClaudeIsTheAgent() {
        // The npm-installed shape of the agent: every field says `node` except the
        // exec path. Dropping the executable-path token leaves only `node`, which
        // is in no set, so the pane would report a command named `node` and lose
        // the one fact the owner is watching for.
        let agent = process(
            pid: 200,
            parent: 100,
            name: "node",
            path: "/opt/homebrew/bin/claude",
            arguments: ["node", "/opt/homebrew/bin/claude"]
        )

        let activity = PaneActivityClassifier.classify(tree: [paneShell, agent], shellPid: 100)

        #expect(activity == .agent(name: "claude", pid: 200))
    }

    @Test func anAgentThatRewroteItsNameToItsVersionIsStillTheAgent() {
        // Measured from the live Claude Code 2.1.220: `p_comm` is the version
        // string and `proc_pidpath` resolves the symlink into a versions
        // directory, so both of those tokens match nothing and only argv[0] names
        // it. A scan that stopped at the first unmatched token would put the
        // version number in the status bar as a running command.
        let agent = process(
            pid: 200,
            parent: 100,
            name: "2.1.220",
            path: "/Users/x/.local/share/claude/versions/2.1.220",
            arguments: ["claude", "--dangerously-skip-permissions"]
        )

        let activity = PaneActivityClassifier.classify(tree: [paneShell, agent], shellPid: 100)

        #expect(activity == .agent(name: "claude", pid: 200))
    }

    @Test func anAgentBeatsTheBuildItSpawned() {
        // The specificity key, and the case depth alone gets wrong: `npm` is
        // deeper than `claude`. Ordering on depth first reports a build and loses
        // which pane holds an agent, which is the whole question.
        let agent = process(pid: 200, parent: 100, name: "claude", path: "/usr/local/bin/claude")
        let build = process(
            pid: 300,
            parent: 200,
            name: "npm",
            path: "/opt/homebrew/bin/npm",
            arguments: ["npm", "run", "build"]
        )

        let activity = PaneActivityClassifier.classify(
            tree: [paneShell, agent, build],
            shellPid: 100
        )

        #expect(activity == .agent(name: "claude", pid: 200))
    }

    @Test func aBareNpmRunBuildIsABuild() {
        let build = process(
            pid: 300,
            parent: 100,
            name: "npm",
            path: "/opt/homebrew/bin/npm",
            arguments: ["npm", "run", "build"]
        )

        let activity = PaneActivityClassifier.classify(tree: [paneShell, build], shellPid: 100)

        #expect(activity == .build(command: "npm"))
    }

    @Test func anInterpreterRunningABuildToolReportsTheTool() {
        // `npx vitest` is a `node` in every primary token. The interpreter step is
        // what reaches the tool. Without it the pane reports a command named
        // `npx`, which says nothing about what is being built.
        let build = process(
            pid: 300,
            parent: 100,
            name: "node",
            path: "/opt/homebrew/bin/npx",
            arguments: ["npx", "vitest", "run"]
        )

        let activity = PaneActivityClassifier.classify(tree: [paneShell, build], shellPid: 100)

        #expect(activity == .build(command: "vitest"))
    }

    @Test func anInterpreterFlagIsNotMistakenForAScript() {
        // The hyphen guard on the interpreter step. Without it the first argument
        // is taken for the script and the pane reports a command named `version`,
        // which is a flag rather than a program.
        let node = process(
            pid: 300,
            parent: 100,
            name: "node",
            path: "/opt/homebrew/bin/node",
            arguments: ["node", "--version"]
        )

        let activity = PaneActivityClassifier.classify(tree: [paneShell, node], shellPid: 100)

        #expect(activity == .command(name: "node"))
    }

    @Test func theDeeperOfTwoBuildsWins() {
        // The depth key on its own, with specificity held equal. `swift` drives
        // `swift-frontend`, and the frontend is the process actually compiling
        // while the driver waits on it.
        let driver = process(
            pid: 200,
            parent: 100,
            name: "swift",
            path: "/usr/bin/swift",
            arguments: ["swift", "build"]
        )
        let frontend = process(
            pid: 300,
            parent: 200,
            name: "swift-frontend",
            path: "/usr/bin/swift-frontend"
        )

        let activity = PaneActivityClassifier.classify(
            tree: [paneShell, driver, frontend],
            shellPid: 100
        )

        #expect(activity == .build(command: "swift-frontend"))
    }

    @Test func anUnrecognisedProgramIsNamedByItsPathRatherThanItsTruncatedName() {
        // `p_comm` keeps 16 characters, so the kernel's name for this one is a lie
        // by omission. Naming a command from `name` would put the truncation
        // straight into the status bar.
        let long = process(
            pid: 300,
            parent: 100,
            name: "some-very-long-",
            path: "/usr/local/bin/some-very-long-command",
            arguments: ["some-very-long-command"]
        )

        let activity = PaneActivityClassifier.classify(tree: [paneShell, long], shellPid: 100)

        #expect(activity == .command(name: "some-very-long-command"))
    }

    @Test func aProcessThatDoesNotDescendFromTheShellIsIgnored() {
        // A sibling pane's build, which lands in the array whenever the caller
        // hands over a tree rooted higher than one pane. Reporting it labels an
        // idle pane with another pane's work, which is the wrong-repo mistake this
        // feature exists to prevent rather than to create.
        let stranger = process(pid: 400, parent: 401, name: "make", path: "/usr/bin/make")

        let activity = PaneActivityClassifier.classify(
            tree: [paneShell, stranger],
            shellPid: 100
        )

        #expect(activity == .idleShell)
    }

    @Test func aTreeWithoutTheShellOrAnyOfItsDescendantsIsIdle() {
        // `shellPid` names a pid that neither appears in the tree nor parents
        // anything in it. Nothing is reachable, so nothing is reported. The
        // alternative, taking the most specific stranger, is what produces a
        // confident label for the wrong pane.
        let other = process(pid: 500, parent: 501, name: "make", path: "/usr/bin/make")

        #expect(PaneActivityClassifier.classify(tree: [other], shellPid: 100) == .idleShell)
    }

    @Test func aChildOutlivingTheShellEntryStillClassifies() {
        // The mirror of the test above: the shell's own entry is gone from the
        // array but its child still points at it. The pair is what pins the
        // reachability rule, since either test alone passes whichever way the
        // missing-shell case goes.
        let agent = process(pid: 200, parent: 100, name: "claude", path: "/usr/local/bin/claude")

        let activity = PaneActivityClassifier.classify(tree: [agent], shellPid: 100)

        #expect(activity == .agent(name: "claude", pid: 200))
    }

    @Test func aCycleInTheParentPointersTerminates() {
        // Two processes each claiming the other as parent. The depth walk follows
        // parent pointers, so an unbounded walk here never returns and the poll
        // timer freezes the window instead of mislabelling it. Reaching the
        // expectation at all is the assertion.
        let first = process(pid: 200, parent: 201, name: "make", path: "/usr/bin/make")
        let second = process(pid: 201, parent: 200, name: "make", path: "/usr/bin/make")

        let activity = PaneActivityClassifier.classify(
            tree: [paneShell, first, second],
            shellPid: 100
        )

        #expect(activity == .idleShell)
    }

    @Test func aProcessThatIsItsOwnParentTerminates() {
        // pid 0 really is its own parent on this machine, so a self-loop is not
        // hypothetical. It is also the shortest possible cycle, which a bound of
        // one step would miss.
        let loop = process(pid: 200, parent: 200, name: "make", path: "/usr/bin/make")

        let activity = PaneActivityClassifier.classify(tree: [paneShell, loop], shellPid: 100)

        #expect(activity == .idleShell)
    }

    @Test func theAnswerDoesNotDependOnTheOrderOfTheTree() {
        // ``ProcessTree`` builds its array by walking a dictionary, so array order
        // is not stable between polls. Two equally deep, equally specific builds
        // is the only case where the third key decides, and a pane whose label
        // alternated every second between two truthful answers would be worse than
        // either of them.
        let first = process(pid: 200, parent: 100, name: "make", path: "/usr/bin/make")
        let second = process(pid: 300, parent: 100, name: "cargo", path: "/usr/bin/cargo")

        let forwards = PaneActivityClassifier.classify(
            tree: [paneShell, first, second],
            shellPid: 100
        )
        let backwards = PaneActivityClassifier.classify(
            tree: [second, first, paneShell],
            shellPid: 100
        )

        #expect(forwards == backwards)
        #expect(forwards == .build(command: "cargo"))
    }

    @Test func aProcessWithNoNameAndNoPathIsNotClassified() {
        // Every token empty, which is what an entry stripped of `p_comm` and
        // refused by both path reads looks like. Naming it would put an empty
        // string in the status bar, so it drops out and the pane reads idle.
        let blank = process(pid: 200, parent: 100, name: "")

        let activity = PaneActivityClassifier.classify(tree: [paneShell, blank], shellPid: 100)

        #expect(activity == .idleShell)
    }

    @Test func theNameSetsAreDisjoint() {
        // The token scan tests the three sets in one order and stops at the first
        // hit, so a name in two sets would silently make that order load bearing.
        // This guards adding to the sets later, not today's contents.
        let agents = PaneActivityClassifier.agentNames
        let builds = PaneActivityClassifier.buildCommands
        let shells = PaneActivityClassifier.shellNames

        #expect(agents.isDisjoint(with: builds))
        #expect(agents.isDisjoint(with: shells))
        #expect(builds.isDisjoint(with: shells))
    }
}
