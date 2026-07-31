import Foundation
import PaneControl
import Testing

@testable import PaneCLI

/// `connect` reads its rendezvous ticket from stdin and never from argv.
///
/// This is a boundary and not a preference. `ps -ww` and `KERN_PROCARGS2` show
/// every same-uid process the full argv of every other, and a pane running a `ps`
/// loop is precisely the adversary the control channel bounds. A ticket that
/// spent one millisecond in this process's argv is a ticket that leaked.
///
/// So the assertions below are written against the *request*, not against the
/// parser's error message: an edit that adds a positional ticket argument would
/// have to keep it out of the encoded frame to pass, and there is nowhere else
/// for it to go.
@Suite struct ConnectTicketTests {
    /// Distinctive enough that a substring search over the frame cannot match it
    /// by accident, and shaped like the thing it stands for.
    private let ticket = "ticket-that-must-never-appear-in-argv"

    /// A stand-in for `$BAIA_TOKEN`, which the tests never read and the parser
    /// never sees. Present only so a request can be built the way `Run` builds
    /// one.
    private let paneCapability = "pane-capability-placeholder"

    /// The one that fails if somebody adds `baia connect <TICKET>`.
    ///
    /// Parsed, then encoded exactly the way `Run` encodes it, then searched. A
    /// positional ticket accepted into ``ControlArgs/rendezvous`` lands in the
    /// frame and this goes red; a positional ticket accepted and then dropped
    /// would pass, which is correct, because a dropped ticket is not a leaked
    /// one.
    @Test func aTicketPassedAsAnArgumentNeverReachesTheRequest() throws {
        let outcome = Arguments.parse(["connect", ticket])
        guard case let .invoke(call) = outcome else {
            // Refused at parse time, which is what this build does. Nothing was
            // encoded, so there is nothing to search: the ticket never got near
            // a frame.
            return
        }

        let request = ControlRequest(token: paneCapability, verb: call.verb, args: call.args)
        let frame = try #require(ControlWire.encodeRequest(request))
        let text = String(decoding: frame, as: UTF8.self)
        #expect(
            !text.contains(ticket),
            "a ticket given in argv reached the wire, where ps had already shown it"
        )
    }

    /// The refusal, and the reason in it.
    ///
    /// Refusing beats accepting and discarding, because the caller who typed it
    /// needs to know the value they typed is now readable by every process they
    /// run, and needs to be told the spelling that is not.
    @Test func aTicketPassedAsAnArgumentIsRefusedWithTheReasonWhy() {
        guard case let .usage(message) = Arguments.parse(["connect", ticket]) else {
            Issue.record("connect took a positional argument instead of refusing it")
            return
        }
        #expect(message.contains("ps"))
        #expect(message.contains("stdin"))
        // The refusal must not echo the ticket back: a message printed to a
        // terminal lands in scrollback, and scrollback outlives the process.
        #expect(!message.contains(ticket))
    }

    /// Both accepted spellings declare the read.
    ///
    /// `--stdin` is accepted and redundant, because stdin is the only source
    /// there is. The declaration is what `Run` branches on to drain the pipe, so
    /// a `connect` that lost it would send an empty rendezvous and blame the
    /// server for refusing it.
    @Test func connectDeclaresThatItReadsItsTicketFromStdin() {
        for argv in [["connect"], ["connect", "--stdin"]] {
            guard case let .invoke(call) = Arguments.parse(argv) else {
                Issue.record("\(argv.joined(separator: " ")) should parse")
                continue
            }
            #expect(call.stdin == .rendezvousTicket)
            // Parsing does no I/O, so the ticket is still absent here. That
            // ordering is the point: the environment is checked before the pipe
            // is drained, so a ticket is not swallowed by an invocation that was
            // never going to reach a socket.
            #expect(call.args.rendezvous == nil)
        }
    }

    /// `connect` is the only verb that reads a ticket. Walked over `allCases` so
    /// a second reader has to be decided here before it can exist.
    @Test func nothingButConnectReadsARendezvousTicket() {
        for verb in ControlVerb.allCases {
            let operand: [String] = switch verb {
            case .resize: ["left"]
            case .send: ["pane-1", "hello"]
            case .revoke: ["pane-1"]
            default: []
            }
            guard case let .invoke(call) = Arguments.parse([verb.rawValue] + operand) else {
                continue
            }
            switch verb {
            case .connect:
                #expect(call.stdin == .rendezvousTicket)
            case .layoutApply:
                // A document, and never a secret. It arrives on stdin so a file, a
                // heredoc and a generator all work the same way, not because argv
                // would leak it, which is the whole reason connect's ticket is
                // there. Named here rather than waved through by a `!=`, so a
                // third stdin reader has to be decided in this test to exist.
                #expect(call.stdin == .layoutDocument)
            default:
                #expect(call.stdin == .unused, "\(verb.rawValue) should read nothing from stdin")
            }
        }
    }

    /// The help says so too, in the words a reader looking for the reason would
    /// search for. A boundary nobody documents is a boundary somebody removes.
    @Test func theHelpTextExplainsWhyTheTicketIsNotAnArgument() {
        let text = Help.text
        #expect(text.contains("connect --stdin"))
        #expect(text.contains("connect reads its ticket from stdin and never from an argument"))
        #expect(text.contains("ps"))
    }
}
