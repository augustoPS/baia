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

        case .close, .focus, .resize, .equalize, .send, .revoke, .run:
            break

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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(result), let text = String(data: data, encoding: .utf8)
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
