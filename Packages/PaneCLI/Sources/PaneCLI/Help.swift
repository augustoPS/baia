import Foundation
import PaneControl

/// `baia --help` and `baia --version`.
///
/// The exit-status table is generated from ``ExitStatus`` rather than written
/// out, so what the help promises and what the process exits with cannot drift.
/// A hand-maintained table here would be a second copy of the switch in
/// ``ExitStatus/status(for:)``, and the copy is the one that goes stale.
public enum Help {
    public static var text: String {
        var lines: [String] = []

        lines.append("baia: talk to the baia window this pane is in.")
        lines.append("")
        lines.append("LAYOUT, on the calling pane")
        lines.append("  split [--right|--down] [--cwd PATH] [--command CMD]")
        lines.append("                                        open a pane beside this one")
        lines.append("  --command runs CMD instead of a login shell, with ghostty's own meaning:")
        lines.append("  a bare value with arguments goes through /bin/sh -c, direct: execs without")
        lines.append("  a shell, shell: forces the wrap. The pane closes when CMD exits, so end it")
        lines.append("  with '; exec $SHELL -l' to leave a shell behind. No newlines.")
        lines.append("  close                                 close this pane")
        lines.append("  focus                                 make this pane the focused one")
        lines.append("  zoom [--on|--off]                     zoom this pane, if it is focused")
        lines.append("  resize <left|right|up|down> [--by R]  move the divider this pane sits on")
        lines.append("  equalize                              even out this pane's tab")
        lines.append("")
        lines.append("LAYOUT, on a pane you created")
        lines.append("  move <PANE> --beside <PANE> [--right|--down]")
        lines.append("                                        put one pane next to another")
        lines.append("  Both panes must be this pane or panes it created, and both must be in the")
        lines.append("  same tab. Nothing opens and nothing closes: the pane keeps its id and")
        lines.append("  whatever is running in it keeps running.")
        lines.append("")
        lines.append("INTROSPECTION, scoped")
        lines.append("  whoami [--json]                       this pane's record")
        lines.append("  list [--tree] [--json]                this pane, what it created, its peers")
        lines.append("")
        lines.append("LAYOUT DOCUMENTS")
        lines.append("  layout export                         print this window's arrangement")
        lines.append("  layout apply                          open a new window from one on stdin")
        lines.append("  baia layout export > dev.json, then baia layout apply < dev.json.")
        lines.append("  export carries the shape of the whole window and a working directory only")
        lines.append("  for the panes list already shows you. apply opens the rest at the default")
        lines.append("  directory, in a new window, and never reshapes this one.")
        lines.append("  On the wire they are layout-export and layout-apply, which also parse here.")
        lines.append("")
        lines.append("PEERING")
        lines.append("  publish [--as NAME] [--rotate]        mint a rendezvous ticket and print it")
        lines.append("  connect --stdin                       redeem a ticket read from stdin")
        lines.append("  peers [--json]                        established peers")
        lines.append("  send <PEER> <TEXT>|--stdin            put a message in a peer's mailbox")
        lines.append("  recv [--wait SECONDS] [--json]        drain this pane's mailbox")
        lines.append("  revoke <PEER>                         delete the edge, durably")
        lines.append("")
        lines.append("OBSERVATION, scoped exactly like list")
        lines.append("  subscribe --from SEQ [--wait SECONDS] [--kinds K,K]")
        lines.append("                                        events about panes you can see")
        lines.append("  kinds: " + ControlEventKind.allCases.map(\.rawValue).joined(separator: ", "))
        lines.append("  Take the first SEQ from baia list, which reports the sequence it read at.")
        lines.append("  The last line of every subscribe is the seq for the next call.")
        lines.append("")
        lines.append("NOT YET")
        lines.append("  run                                   cross-pane execution, v2")
        lines.append("")
        lines.append("SCOPE")
        lines.append("  A pane sees itself, the panes it created through this tool, and its peers.")
        lines.append("  Nothing else. list showing one entry is a pane that created nothing.")
        lines.append("")
        lines.append("STDIN, AND WHY")
        lines.append("  connect reads its ticket from stdin and never from an argument, because")
        lines.append("  every process running as you can read this one's arguments with ps. The")
        lines.append("  pane secret in the environment is never printed and never passed along.")
        lines.append("")
        lines.append("ENVIRONMENT")
        lines.append("  BAIA_SOCK   the socket of the baia that owns this pane. Injected per pane.")
        lines.append("              Absent means this baia runs without a channel.")
        lines.append("  BAIA_TOKEN  this pane's per-run secret. Never on disk, never in argv.")
        lines.append("  BAIA_PANE   this pane's public display id. Not a credential: every pane id")
        lines.append("              is in session.json, which any process running as you can read.")
        lines.append("")
        lines.append("EXIT STATUS")
        lines.append(status(ExitStatus.ok, "the request was answered ok"))
        lines.append(status(ExitStatus.usage, "these arguments name no such command. Nothing was sent."))
        lines.append(status(ExitStatus.environment, "this shell is not a pane of a baia with a channel"))
        lines.append(status(ExitStatus.transport, "the socket refused, died, or answered unreadably"))
        for row in ExitStatus.documentedMapping {
            lines.append(status(row.status, "\(row.name): \(row.blurb)"))
        }

        return lines.joined(separator: "\n")
    }

    public static var version: String {
        "baia, control protocol v\(ControlWire.version). Built with the app it talks to."
    }

    private static func status(_ code: Int32, _ meaning: String) -> String {
        "  " + String(code).padding(toLength: 6, withPad: " ", startingAt: 0) + meaning
    }
}
