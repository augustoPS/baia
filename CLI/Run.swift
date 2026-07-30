import AgentIntegration
import Foundation
import PaneCLI
import PaneControl

/// The whole flow, in the order the order matters.
///
/// Parse, then check the environment, then read stdin, then send. Parsing does
/// no I/O so a ticket piped into an invocation that could never reach a socket
/// is not swallowed on its way to being discarded, and the environment is
/// checked before the pipe is drained for the same reason.
enum Run {
    static func main() -> Never {
        var call: Invocation

        switch Arguments.parse(Array(CommandLine.arguments.dropFirst())) {
        case .help:
            StandardStreams.out(Help.text)
            exit(ExitStatus.ok)
        case .version:
            StandardStreams.out(Help.version)
            exit(ExitStatus.ok)
        case let .usage(message):
            StandardStreams.err(message)
            exit(ExitStatus.usage)
        case let .local(command):
            // Answered here and now. No socket, no token, and no pane: this one
            // edits the owner's own files and is meant to be run from any shell,
            // including one outside baia entirely.
            exit(local(command))
        case let .invoke(parsed):
            call = parsed
        }

        guard let socketPath = ControlEnvironment.socketPath else {
            // The exact sentence the spec names, on its own line, because a
            // second baia that found the socket already owned injects no
            // BAIA_SOCK on purpose: handing its panes the *first* instance's
            // live socket would answer badToken with a completely misleading
            // story about the secret rather than the truth about the instance.
            StandardStreams.err("no baia is listening for this instance")
            StandardStreams.err(
                "This pane belongs to a baia running without a control channel, which happens "
                    + "when another baia already owned the socket at launch."
            )
            exit(ExitStatus.environment)
        }

        guard let paneSecret = ControlEnvironment.paneSecret else {
            StandardStreams.err(
                "this shell has no pane secret, so it is not a baia pane. The baia tool lives "
                    + "inside the app bundle and works only in a pane the app opened."
            )
            exit(ExitStatus.environment)
        }

        switch call.stdin {
        case .unused:
            break

        case .rendezvousTicket:
            let ticket = String(decoding: StandardStreams.readAllOfStdin(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ticket.isEmpty else {
                StandardStreams.err(
                    "nothing arrived on stdin. connect reads its rendezvous ticket from there and "
                        + "never from an argument, because ps shows any process running as you "
                        + "this one's full arguments."
                )
                exit(ExitStatus.usage)
            }
            call.args.rendezvous = ticket

        case .messageBody:
            var body = String(decoding: StandardStreams.readAllOfStdin(), as: UTF8.self)
            // One trailing newline, the one `echo` adds, and no more. Trimming
            // further would quietly edit somebody's message.
            if body.hasSuffix("\n") {
                body.removeLast()
            }
            call.args.text = body
        }

        if let wait = call.args.wait, wait > ControlWire.maxWaitSeconds {
            StandardStreams.err(
                "--wait is capped at \(ControlWire.maxWaitSeconds) seconds. Waiting "
                    + "\(ControlWire.maxWaitSeconds) and leaving the re-poll to you."
            )
            call.args.wait = ControlWire.maxWaitSeconds
        }

        if let body = call.args.text, body.utf8.count > ControlWire.maxMessagePayloadBytes {
            StandardStreams.err(
                "the message is \(body.utf8.count) bytes and the payload cap is "
                    + "\(ControlWire.maxMessagePayloadBytes)"
            )
            exit(ExitStatus.status(for: .refused))
        }

        let request = ControlRequest(token: paneSecret, verb: call.verb, args: call.args)

        // The cap that is actually enforced is the frame, not the payload, and
        // it is checked here so an over-cap request is refused with the status
        // the server would have used rather than reported as a transport
        // failure. JSON escaping inflates control bytes up to sixfold, so a
        // message inside the payload cap can still be a frame nothing can carry.
        if let line = ControlWire.encodeRequest(request), !ControlWire.fitsFrame(line) {
            StandardStreams.err(
                "this request frames to \(line.count) bytes and the cap is "
                    + "\(ControlWire.maxFrameBytes). JSON escaping inflates control characters, "
                    + "so a message under the payload cap can still be over the frame cap."
            )
            exit(ExitStatus.status(for: .refused))
        }

        let timeout = max(ControlWire.idleTimeoutSeconds, call.args.wait ?? 0) + 5
        let client = ControlClient(socketPath: socketPath)

        switch client.exchange(request, readTimeoutSeconds: timeout) {
        case let .answered(response):
            guard response.ok else {
                guard let failure = response.error else {
                    StandardStreams.err("baia answered a refusal with no reason in it")
                    exit(ExitStatus.transport)
                }
                StandardStreams.err(failure.message)
                exit(ExitStatus.status(for: failure.code))
            }
            StandardStreams.write(Rendering.render(response.result ?? ControlResult(), for: call))
            exit(ExitStatus.ok)

        case .closedWithoutAnswer:
            // close kills the shell that invoked this process, so losing the
            // race to the response is the request having worked. Every other
            // verb reaching here means the app went away mid-exchange.
            if call.verb == .close {
                exit(ExitStatus.ok)
            }
            StandardStreams.err("baia closed the connection without answering")
            exit(ExitStatus.transport)

        case let .broken(reason):
            StandardStreams.err(reason)
            exit(ExitStatus.transport)
        }
    }

    /// The subcommands the CLI answers itself.
    ///
    /// Prints what changed, unlike every verb that crosses the socket. Those are
    /// called by scripts and hooks, where a line of output is noise in somebody
    /// else's transcript; this one is typed by a person at their own prompt and
    /// silence would leave them guessing whether it worked.
    private static func local(_ command: LocalCommand) -> Int32 {
        switch command {
        case let .installHooks(uninstall):
            let layout = HookInstaller.Layout.standard(home: HookInstaller.Layout.home())
            let outcome = uninstall
                ? HookInstaller.uninstall(layout)
                : HookInstaller.install(layout)
            switch outcome {
            case let .changed(notes):
                for note in notes { StandardStreams.out(note) }
                return ExitStatus.ok
            case .unchanged:
                StandardStreams.out(uninstall ? "nothing to remove" : "already installed")
                return ExitStatus.ok
            case let .refused(reason):
                StandardStreams.err(reason)
                return ExitStatus.usage
            }
        }
    }
}
