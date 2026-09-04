import Foundation
import PaneControl

/// One line, and which stream it belongs on.
///
/// A value rather than a write, because the stream rule below is the thing worth
/// asserting and a renderer that writes as it goes can only be checked by
/// capturing file descriptors. The tool target replays these in order, so the
/// relative order of a note and the result it annotates is still decided here.
public struct RenderedLine: Equatable {
    public enum Stream: Equatable {
        /// A result line. The only thing a pipe downstream should ever see.
        case out

        /// A note, a warning, or a failure. Never parsed by anything: the exit
        /// status is what a script branches on.
        case err
    }

    public var stream: Stream
    public var text: String

    init(_ stream: Stream, _ text: String) {
        self.stream = stream
        self.text = text
    }
}

/// Turns a successful result into what the pane sees.
///
/// Results go to stdout and notes go to stderr, without exception, so
/// `baia publish | pbcopy` carries a ticket and nothing else and
/// `baia recv > log` carries message bodies and not a drop counter.
public enum Rendering {
    public static func render(_ result: ControlResult, for call: Invocation) -> [RenderedLine] {
        var lines: [RenderedLine] = []
        func out(_ text: String) { lines.append(RenderedLine(.out, text)) }
        func err(_ text: String) { lines.append(RenderedLine(.err, text)) }

        if call.json {
            out(json(result))
            return lines
        }

        // No `default:`. A new verb has to decide what it prints before the CLI
        // compiles, and "prints nothing" is a decision made here rather than
        // inherited by falling through.
        switch call.verb {
        case .split:
            if let pane = result.pane {
                out(pane)
            }

        // `cwd` prints nothing, and that is a decision rather than an
        // omission: an agent announcing where it is wants an exit status,
        // not a line of output in the middle of whatever it is doing.
        // `report` prints nothing for the same reason `cwd` does, and more so:
        // its caller is a hook running inside an agent's session, where a line of
        // output is noise in somebody else's transcript. The exit status is the
        // answer.
        // `layout apply` prints nothing, and that is a decision. Every id it could
        // report is in `baia list --tree`, which is where a script wanting to
        // address one of the new panes has to look anyway, because it needs the
        // records to tell them apart. A second, order-dependent list of the same
        // ids would be one more thing to keep truthful.
        // `move` prints nothing for the reason the rest of this arm does: the
        // window rearranged itself where the caller can see it, both pane ids were
        // the caller's own words, and there is no third fact to report. The exit
        // status carries the refusal.
        case .close, .focus, .resize, .equalize, .send, .revoke, .run, .cwd, .report, .layoutApply,
             .move:
            break

        // The document and nothing else, so `baia layout export > dev.json`
        // produces a file `baia layout apply` reads back. Pretty-printed with
        // sorted keys and unescaped slashes, because it is meant to be edited by
        // hand and to diff cleanly when it is committed.
        case .layoutExport:
            if let layout = result.layout {
                out(encoded(layout))
            }

        // One line per line, which is what makes `baia read` pipe into grep. The
        // truncation flag is deliberately not printed here: a caller who needs it
        // asks for `--json`, and a trailing marker in the plain output would end
        // up in somebody's grep results as though the pane had printed it.
        case .read:
            for line in result.lines ?? [] {
                out(line)
            }

        case .zoom:
            out((result.zoomed ?? false) ? "on" : "off")

        case .whoami:
            for line in blocks(result.panes ?? []) {
                out(line)
            }

        case .list:
            let records = result.panes ?? []
            for line in call.tree ? tree(records) : blocks(records) {
                out(line)
            }
            if records.count == 1 {
                // This reads as broken the first time and is correct: a pane the
                // owner opened by hand created nothing and has no peers, so it
                // is the whole of its own scope. Saying so costs one line and
                // saves the reader looking for the bug.
                err(
                    "only this pane is in scope. baia list shows the calling pane, the panes it "
                        + "created through the channel, and its peers."
                )
            }
            if let seq = result.seq {
                // The bootstrap, and the reason `list` is the verb the help
                // sends a subscriber to first: the records and the sequence they
                // were read at arrive in one frame, so no event lands between
                // the snapshot and the cursor and is seen by neither. Last and
                // on stdout, exactly like `subscribe`, so one `tail -1` reads
                // either. Absent from an answer that carries no sequence rather
                // than defaulted, because a cursor no ring minted is worse than
                // no cursor at all.
                out("seq \(seq)")
            }

        // One field per line like `list`, with a reason line under each derived
        // field. Everything on stdout: this is the answer, and there is no note
        // to keep off a pipe.
        case .explain:
            guard let e = result.explanation else { break }
            out(row("pane", e.pane))
            let activityLine: String = switch e.activityReading {
            case .idle: e.activity ?? "idle"
            case .cannotTell: e.activity ?? "cannot tell"
            case .running: e.activity ?? "running"
            }
            out(row("activity", activityLine))
            out(row("", e.activityReason))
            if e.hasForeground {
                out(row("processes", "pid  ppid  depth  verdict  matched"))
                for p in e.processes {
                    let depth = p.depth.map(String.init) ?? "-"
                    var line = "  \(p.pid)  \(p.parentPid)  \(depth)  \(p.verdict)"
                    if let token = p.matched { line += "  \(token)" }
                    if p.won { line += "  (won)" }
                    out(row("", line))
                }
            } else {
                // The no-foreground sentence stays in `activityReason`, printed
                // above under `activity`. Printing it again here would say the
                // same thing twice.
                out(row("processes", "none"))
            }
            if let r = e.report {
                var line = r.state.rawValue
                if let message = r.message { line += " \"\(message)\"" }
                if let seq = r.seq { line += "  seq \(seq)" }
                line += r.live ? "  live, \(r.secondsLeft)s left" : "  expired"
                out(row("report", line))
            } else {
                out(row("report", "none"))
            }
            out(row("latch", e.latch))
            out(row("seen", e.seen ? "yes" : "no"))
            out(row("attention", e.attention ?? "none"))
            out(row("", "authority: \(e.attentionDecidedBy)"))
            out(row("", e.attentionReason))

        case .publish:
            if let ticket = result.rendezvous {
                out(ticket)
                err(
                    "hand this to the panes you want as peers. It admits them to a "
                        + "communication edge and confers no control over this pane."
                )
            }

        case .connect:
            let peer = result.pane ?? ""
            if let name = result.name, !name.isEmpty {
                out("\(peer) \(name)")
            } else if !peer.isEmpty {
                out(peer)
            }

        case .peers:
            let records = result.panes ?? []
            if records.isEmpty {
                err("no peers. baia publish mints a ticket for one to connect with.")
            }
            for line in blocks(records) {
                out(line)
            }

        case .recv:
            for message in result.messages ?? [] {
                out("from \(message.from)")
                out(message.text)
                out("")
            }
            if let dropped = result.dropped, dropped > 0 {
                // Reported once and then reset by the server. A silent drop is
                // worse than a lost message, because the reader concludes
                // nothing was sent.
                err(
                    "\(dropped) message\(dropped == 1 ? " was" : "s were") dropped from a full "
                        + "mailbox since the last recv"
                )
            }
            if result.more == true {
                err("the mailbox still holds messages. Run baia recv again.")
            }

        case .subscribe:
            for event in result.events ?? [] {
                // One line per event, fields separated by spaces, so `while read`
                // splits it without a JSON parser. `--json` is there for anything
                // that wants structure.
                var line = "\(event.seq) \(event.kind.rawValue) \(event.pane)"
                if let createdBy = event.createdBy { line += " by \(createdBy)" }
                if let activity = event.activity { line += " \(activity)" }
                // Before the message, because it qualifies the message: a reader
                // taking everything after `via osc` has the text and knows what
                // it is worth. Marked like `by`, so a field that is present on
                // one kind and absent on the others cannot be mistaken for the
                // free text that follows it.
                if let source = event.source { line += " via \(source.rawValue)" }
                if let message = event.message { line += " \(message)" }
                out(line)
            }
            if result.gap == true {
                err(
                    "events were dropped before your cursor. Re-read baia list and "
                        + "subscribe again from the seq it reports."
                )
            }
            if result.more == true {
                err("more events are waiting. Run baia subscribe again from the seq below.")
            }
            if let seq = result.seq {
                // Last, and on stdout, because it is the one value the next call
                // needs and a script reads it with `tail -1`.
                out("seq \(seq)")
            }
        }

        return lines
    }

    /// The result object exactly as it came off the wire.
    ///
    /// Re-encoded from the decoded value rather than reshaped, so `--json` is
    /// the machine format and a scope leak shows up in it verbatim rather than
    /// being tidied away by a renderer.
    private static func json(_ result: ControlResult) -> String {
        encoded(result)
    }

    /// One encoder for both the result envelope and the layout document, so a
    /// document read out of `--json` and one read off `layout export` are the same
    /// bytes rather than two formattings of the same value.
    static func encoded(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }

    // MARK: Records

    /// One labelled block per pane, blank line between.
    ///
    /// `whoami` and `list` render the same shape, because they return the same
    /// record and a second renderer is a second place for a scope leak to look
    /// ordinary.
    private static func blocks(_ records: [PaneRecord]) -> [String] {
        var lines: [String] = []
        for record in records {
            if !lines.isEmpty {
                lines.append("")
            }
            lines.append(row("pane", record.pane))
            lines.append(row("window", String(record.window)))
            lines.append(row("tab", String(record.tab)))
            append(&lines, "cwd", record.workingDirectory)
            append(&lines, "anchor", record.anchor)
            append(&lines, "branch", record.branch)
            append(&lines, "activity", record.activity)
            append(&lines, "attention", record.attention)
            append(&lines, "createdBy", record.createdBy)
            if !record.channels.isEmpty {
                lines.append(row("channels", record.channels.joined(separator: ", ")))
            }
            if !record.peers.isEmpty {
                lines.append(row("peers", record.peers.joined(separator: ", ")))
            }
        }
        return lines
    }

    /// The parentage edges, indented.
    ///
    /// A pane whose `createdBy` names something outside the returned set is a
    /// root here, which is the ordinary case for the caller itself: the pane
    /// that created it is not in the caller's own scope.
    private static func tree(_ records: [PaneRecord]) -> [String] {
        let present = Set(records.map(\.pane))
        var children: [String: [PaneRecord]] = [:]
        var roots: [PaneRecord] = []

        for record in records.sorted(by: { $0.pane < $1.pane }) {
            if let parent = record.createdBy, present.contains(parent), parent != record.pane {
                children[parent, default: []].append(record)
            } else {
                roots.append(record)
            }
        }

        var lines: [String] = []
        // Guarded against a cycle rather than assumed acyclic. The graph cannot
        // hold one, and a renderer that hangs a pane's shell if it ever did is
        // not worth the four lines saved.
        var drawn: Set<String> = []

        func walk(_ record: PaneRecord, depth: Int) {
            guard drawn.insert(record.pane).inserted else { return }
            let indent = String(repeating: "  ", count: depth)
            var line = indent + record.pane
            if let activity = record.activity, !activity.isEmpty {
                line += "  \(activity)"
            }
            if let directory = record.workingDirectory, !directory.isEmpty {
                line += "  \(directory)"
            }
            lines.append(line)
            for child in children[record.pane] ?? [] {
                walk(child, depth: depth + 1)
            }
        }

        for root in roots {
            walk(root, depth: 0)
        }
        // Anything a cycle would have hidden still gets printed, flat, rather
        // than silently dropped from a listing whose whole job is completeness.
        for record in records where !drawn.contains(record.pane) {
            walk(record, depth: 0)
        }
        return lines
    }

    private static func append(_ lines: inout [String], _ label: String, _ value: String?) {
        guard let value, !value.isEmpty else { return }
        lines.append(row(label, value))
    }

    private static func row(_ label: String, _ value: String) -> String {
        label.padding(toLength: 11, withPad: " ", startingAt: 0) + value
    }
}
