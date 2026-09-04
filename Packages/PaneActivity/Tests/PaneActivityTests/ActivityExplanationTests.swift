import Foundation
import Testing

@testable import PaneActivity

@Suite struct ActivityExplanationTests {
    private func process(
        pid: pid_t, parent: pid_t, name: String, path: String? = nil, arguments: [String] = []
    ) -> ProcessSnapshot {
        ProcessSnapshot(
            pid: pid, parentPid: parent, name: name, executablePath: path,
            arguments: arguments, startedAtSecondsSinceBoot: nil
        )
    }

    private var paneShell: ProcessSnapshot {
        process(pid: 100, parent: 10, name: "zsh", path: "/bin/zsh", arguments: ["-/bin/zsh"])
    }

    /// The explanation's answer is `classify`'s answer, on every tree this suite
    /// builds. `classify` is defined as `explain(...).activity`, so this is the
    /// test that the definition still holds after any later edit to either.
    @Test func theAnswerIsWhatClassifyAnswers() {
        let trees: [[ProcessSnapshot]] = [
            [],
            [paneShell],
            [paneShell, process(pid: 101, parent: 100, name: "zsh", arguments: ["-zsh"])],
            [paneShell, process(pid: 200, parent: 100, name: "claude", path: "/Users/x/.local/bin/claude", arguments: ["claude"])],
            [paneShell, process(pid: 200, parent: 100, name: "claude", arguments: ["claude"]),
             process(pid: 300, parent: 200, name: "npm", arguments: ["npm", "test"])],
            [paneShell, process(pid: 200, parent: 100, name: "vim", arguments: ["vim", "x"])],
            [paneShell, process(pid: 200, parent: 100, name: "", arguments: [])],
        ]
        for tree in trees {
            #expect(
                PaneActivityClassifier.explain(tree: tree, shellPid: 100).activity
                    == PaneActivityClassifier.classify(tree: tree, shellPid: 100)
            )
        }
    }

    @Test func anIdleShellSaysNothingIsRunning() {
        let explanation = PaneActivityClassifier.explain(tree: [paneShell], shellPid: 100)
        #expect(explanation.activity == .idleShell)
        #expect(explanation.processes.count == 1)
        #expect(explanation.processes[0].verdict == .paneShell)
        #expect(explanation.processes[0].depth == 0)
        #expect(explanation.processes[0].won == false)
        #expect(explanation.reason.contains("nothing is running below the pane's shell"))
    }

    @Test func aNestedShellIsNamedAsPlumbingAndStillIdle() {
        let nested = process(pid: 101, parent: 100, name: "zsh", arguments: ["-zsh"])
        let explanation = PaneActivityClassifier.explain(tree: [paneShell, nested], shellPid: 100)
        #expect(explanation.activity == .idleShell)
        let verdict = explanation.processes.first { $0.pid == 101 }
        #expect(verdict?.verdict == .shell)
        #expect(verdict?.matched == "zsh")
        #expect(verdict?.depth == 1)
        #expect(explanation.reason.contains("only shells"))
    }

    @Test func anAgentAboveABuildWinsAndTheBuildIsNamedAsOutranked() {
        let agent = process(pid: 200, parent: 100, name: "claude", arguments: ["claude"])
        let build = process(pid: 300, parent: 200, name: "npm", arguments: ["npm", "test"])
        let explanation = PaneActivityClassifier.explain(tree: [paneShell, agent, build], shellPid: 100)

        #expect(explanation.activity == .agent(name: "claude", pid: 200))
        let winner = explanation.processes.first { $0.won }
        #expect(winner?.pid == 200)
        #expect(winner?.verdict == .agent(name: "claude"))
        #expect(explanation.processes.first { $0.pid == 300 }?.verdict == .build(command: "npm"))
        #expect(explanation.processes.first { $0.pid == 300 }?.depth == 2)
        #expect(explanation.processes.filter(\.won).count == 1)
        #expect(explanation.reason.contains("claude"))
        #expect(explanation.reason.contains("agent before build before command"))
    }

    @Test func twoCommandsAtOneDepthAreSettledByPidAndTheReasonSaysSo() {
        let a = process(pid: 200, parent: 100, name: "vim", arguments: ["vim"])
        let b = process(pid: 201, parent: 100, name: "less", arguments: ["less"])
        let explanation = PaneActivityClassifier.explain(tree: [paneShell, a, b], shellPid: 100)
        #expect(explanation.activity == .command(name: "less"))
        #expect(explanation.processes.first { $0.won }?.pid == 201)
        #expect(explanation.reason.contains("highest pid"))
    }

    @Test func aProcessWithNoTokenIsUnnameableAndTheReasonSaysTheClassifierCannotTell() {
        let blank = process(pid: 200, parent: 100, name: "", arguments: [])
        let explanation = PaneActivityClassifier.explain(tree: [paneShell, blank], shellPid: 100)
        #expect(explanation.activity == .unnameable)
        #expect(explanation.processes.first { $0.pid == 200 }?.verdict == .unnameable)
        #expect(explanation.processes.first { $0.pid == 200 }?.matched == nil)
        #expect(explanation.reason.contains("cannot tell"))
    }

    /// A process that never reaches `shellPid` belongs to another pane. It is
    /// listed, because the caller asked what the snapshot saw, and it is named as
    /// outside so nobody reads it as this pane's.
    @Test func aProcessOutsideThePaneIsListedAsOutsideAndNeverWins() {
        let stranger = process(pid: 900, parent: 5, name: "claude", arguments: ["claude"])
        let explanation = PaneActivityClassifier.explain(tree: [paneShell, stranger], shellPid: 100)
        #expect(explanation.activity == .idleShell)
        let verdict = explanation.processes.first { $0.pid == 900 }
        #expect(verdict?.verdict == .outsidePane)
        #expect(verdict?.depth == nil)
        #expect(verdict?.won == false)
    }

    /// Ordered by depth then pid, so the rendering reads top down without
    /// sorting, and so the order does not depend on `ProcessTree`'s dictionary
    /// walk.
    @Test func processesAreOrderedByDepthThenPidWithOutsidersLast() {
        let agent = process(pid: 200, parent: 100, name: "claude", arguments: ["claude"])
        let build = process(pid: 300, parent: 200, name: "npm", arguments: ["npm"])
        let stranger = process(pid: 50, parent: 5, name: "vim", arguments: ["vim"])
        let explanation = PaneActivityClassifier.explain(
            tree: [stranger, build, agent, paneShell], shellPid: 100
        )
        #expect(explanation.processes.map(\.pid) == [100, 200, 300, 50])
    }

    /// The Global Constraint: `explain`'s answer is no wider than `list` plus
    /// pids. `matched` is the token the classifier keyed on, and it is a token
    /// and never argv, so a secret sitting anywhere else in a command line never
    /// reaches it.
    @Test func matchedIsATokenAndNeverArgv() {
        let agent = process(
            pid: 200, parent: 100, name: "claude", path: "/Users/x/.local/bin/claude",
            arguments: ["claude", "--resume", "secret-session"]
        )
        let build = process(
            pid: 300, parent: 200, name: "npm", arguments: ["npm", "test", "--", "--token", "abc"]
        )
        let command = process(
            pid: 400, parent: 100, name: "curl",
            arguments: ["curl", "-H", "Authorization: x", "https://example"]
        )
        let explanation = PaneActivityClassifier.explain(
            tree: [paneShell, agent, build, command], shellPid: 100
        )

        #expect(explanation.processes.first { $0.pid == 200 }?.matched == "claude")
        #expect(explanation.processes.first { $0.pid == 300 }?.matched == "npm")
        #expect(explanation.processes.first { $0.pid == 400 }?.matched == "curl")

        for verdict in explanation.processes {
            #expect(verdict.matched?.contains("secret-session") != true)
            #expect(verdict.matched?.contains("abc") != true)
            #expect(verdict.matched?.contains("Authorization") != true)
        }
    }
}
