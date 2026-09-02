import Foundation
import Testing

@testable import AgentIntegration

/// The script as it will land on disk.
///
/// The script's *behaviour* is not asserted here and cannot be: deciding a state
/// from a payload means running `sh`, and these tests run in a process that has
/// no business spawning one. `Diagnostics/agent-integration/` drives it for real.
/// What this suite protects is the shape, and the rules that are visible in the
/// text and would be easy to delete while editing it.
@Suite struct HookScriptTests {
    @Test func theScriptIsEmbeddedAndNotEmpty() {
        #expect(HookScript.body.isEmpty == false)
        #expect(HookScript.body.hasPrefix("#!/bin/sh"))
    }

    /// **The shebang stays first.** A `#!` that is not the first two bytes of a
    /// file is not a shebang, and the kernel would refuse to run what the header
    /// introduced.
    @Test func theHeaderGoesAfterTheShebang() {
        let installable = HookScript.installable(version: 3)
        let lines = installable.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.first == "#!/bin/sh")
        #expect(ManagedHeader.version(in: installable) == 3)
    }

    @Test func theInstallableFormKeepsTheWholeScript() {
        let installable = HookScript.installable()
        #expect(installable.contains("baia report --state"))
        #expect(installable.contains("baia report --release"))
    }

    /// Fails closed on every path. Counted rather than merely present, because the
    /// guards are the whole safety argument and losing one to an edit would be
    /// invisible.
    @Test func everyGuardExitsZero() {
        let body = HookScript.body
        #expect(body.contains("set -eu"))
        let guards = body.components(separatedBy: "|| exit 0").count - 1
        #expect(guards >= 7, "a guard was removed: only \(guards) remain")
    }

    /// The four rules herdr already paid for, each asserted by the token that
    /// implements it, so deleting one fails here rather than in somebody's session.
    @Test func theFourBorrowedRulesAreStillInTheScript() {
        let body = HookScript.body
        #expect(body.contains("agent_id"), "the subagent drop is gone")
        #expect(body.contains("AskUserQuestion"), "the blocked signal is gone")
        #expect(body.contains("SubagentStop"), "the note about not reviving an idle pane is gone")
        #expect(body.contains("BAIA_SOCK"), "the no-channel guard is gone")
    }

    /// **`SubagentStop` is named only in a comment.** The moment it appears in the
    /// decision, a recap emitted after the turn ended can revive an idle pane,
    /// which is baia's own attention bug from the other side.
    @Test func subagentStopIsNeverMappedToAState() {
        for line in HookScript.body.split(separator: "\n") where line.contains("SubagentStop") {
            let code = line.trimmingCharacters(in: .whitespaces)
            #expect(code.hasPrefix("#"), "SubagentStop reached the decision: \(code)")
        }
    }

    /// **Stdin is read before any guard can exit.** A hook that exits without
    /// reading its payload hands the agent a broken pipe mid-write, and a `cat`
    /// found only through PATH is one stripped PATH away from exit 127; the read
    /// goes through `command -p cat` and precedes the first `|| exit 0`.
    @Test func stdinIsReadBeforeAnyGuardCanExit() {
        let lines = HookScript.body.split(separator: "\n", omittingEmptySubsequences: false)
        let read = lines.firstIndex(where: { $0.contains("command -p cat") })
        // The header comment names the guard idiom; only code counts.
        let firstGuard = lines.firstIndex(where: { $0.contains("|| exit 0") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") })
        guard let read, let firstGuard else {
            Issue.record("the stdin read or the first guard is gone")
            return
        }
        #expect(read < firstGuard, "a guard at line \(firstGuard + 1) can exit before stdin is read at line \(read + 1)")
    }

    /// A turn that ends on an API error emits `StopFailure` and never `Stop`.
    /// Without this arm the pane stays `working` until the next turn.
    @Test func stopFailureMapsToIdle() {
        let decision = HookScript.body.split(separator: "\n").first { $0.contains("\"StopFailure\"") && $0.contains("elif") }
        #expect(decision != nil, "StopFailure is not in the decision")
        #expect(HookInstaller.entries(scriptPath: "/x").contains { $0.event == "StopFailure" && $0.matcher == nil })
    }

    /// The sequence is a clock. A counter restarted with the session would be
    /// superseded for the rest of the run, because `ReportStore` keeps ordering
    /// across a release and an expiry.
    @Test func theSequenceComesFromAClock() {
        #expect(HookScript.body.contains("time.time()"))
    }

    /// Nothing reaches the owner's transcript. `report` prints nothing by design
    /// and the script must not undo that by letting a failure through.
    @Test func nothingIsEverPrinted() {
        for line in HookScript.body.split(separator: "\n") {
            let code = line.trimmingCharacters(in: .whitespaces)
            guard code.hasPrefix("baia ") else { continue }
            #expect(code.contains("> /dev/null 2>&1"), "a baia call can speak: \(code)")
        }
    }

    /// **The python is the body of a single-quoted shell string**, so one
    /// apostrophe anywhere in it ends the string and the script dies at parse.
    ///
    /// That is the one failure this file cannot absorb. Every other rule here
    /// fails closed and silent; a syntax error fails loud, on every hook event, in
    /// somebody's session. Written on 2026-08-01, when a comment containing the
    /// word "fork" with a possessive did exactly that to a work-in-progress arm.
    @Test func thePythonBlockCarriesNoApostrophe() {
        let lines = HookScript.body.split(separator: "\n", omittingEmptySubsequences: false)
        guard let open = lines.firstIndex(where: { $0.contains("python3 -c '") }) else {
            Issue.record("the python block is gone")
            return
        }
        guard let close = lines[(open + 1)...].firstIndex(where: { $0.hasPrefix("'") }) else {
            Issue.record("the python block is never closed")
            return
        }
        for index in (open + 1) ..< close {
            #expect(
                lines[index].contains("'") == false,
                "an apostrophe on line \(index + 1) ends the shell string: \(lines[index])"
            )
        }
    }
}
