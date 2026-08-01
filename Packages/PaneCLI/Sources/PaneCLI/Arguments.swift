import Foundation
import PaneControl

/// One invocation, understood, before anything has been read or sent.
///
/// Public in the three members the tool target touches and no further. `json`
/// and `tree` are read by ``Rendering`` inside this package, so widening them
/// would publish a decision the caller has no business re-making.
public struct Invocation {
    public var verb: ControlVerb
    public var args: ControlArgs

    /// What this invocation takes off stdin, filled in after the environment
    /// has been checked rather than during parsing.
    public var stdin: StdinUse

    /// `--json`: print the result object exactly as it came off the wire.
    var json: Bool

    /// `list --tree`: render the parentage edges instead of a record per pane.
    var tree: Bool
}

/// What, if anything, an invocation reads from stdin.
///
/// Named rather than done inline so parsing stays free of I/O. The environment
/// is checked before a pipe is drained, so a ticket is not swallowed by an
/// invocation that was never going to reach a socket.
public enum StdinUse {
    case unused

    /// `connect`: the rendezvous ticket. **The only way in.** A ticket passed as
    /// `baia connect <TICKET>` is readable by every same-uid process through
    /// `ps -ww` for as long as this process lives, and a pane running a `ps` loop
    /// is precisely the adversary the channel bounds.
    case rendezvousTicket

    /// `send --stdin`: the message body.
    case messageBody

    /// `layout apply`: the document, which is a file rather than a secret.
    ///
    /// Stdin and not a path, so `baia layout apply < dev.json`, a heredoc, and a
    /// generator piping into it all work the same way, and so the CLI never opens
    /// a file on a caller's behalf. Reading a path would put a filesystem read
    /// inside a tool whose whole other job is talking to one socket.
    case layoutDocument
}

/// A command the CLI answers itself, without opening the socket.
///
/// **Deliberately not a ``ControlVerb``.** That enum is the closed set of things
/// the *channel* can be asked, and every case in it crosses a socket and passes
/// `PaneGraph.authorize`. `install-hooks` edits a file in the owner's home
/// directory and never connects to anything, so putting it there would force it a
/// scope and a setting gate that mean nothing for a filesystem write, and would
/// put that write inside the enum whose whole job is to enumerate what a
/// capability reaches.
public enum LocalCommand: Sendable, Equatable {
    /// Installs the Claude Code hook, or removes it.
    case installHooks(uninstall: Bool)
}

public enum ParseOutcome {
    case invoke(Invocation)

    /// Answered here, with no socket and no token.
    case local(LocalCommand)

    case help
    case version

    /// Nothing was sent, and this is why.
    case usage(String)
}

/// The argument parser, hand-rolled.
///
/// No dependency, deliberately. The CLI ships inside the app bundle and links
/// one local package, so its whole third-party surface is empty, and a terminal
/// workspace that cannot be sandboxed treats its dependency list as a security
/// boundary.
public enum Arguments {
    public static func parse(_ argv: [String]) -> ParseOutcome {
        guard let head = argv.first else {
            return .usage("no command. Run baia --help.")
        }

        switch head {
        case "--help", "-h", "help":
            return .help
        case "--version":
            return .version
        default:
            break
        }

        // Before the verb lookup, because it is not one. An unknown local
        // subcommand stays a usage error rather than becoming `unknownVerb`,
        // which is a wire code and would claim the socket had refused something.
        if head == "install-hooks" {
            var uninstall = false
            var tokens = Tokens(Array(argv.dropFirst()))
            while let token = tokens.take() {
                switch token {
                case "--uninstall":
                    uninstall = true
                default:
                    return .usage("baia install-hooks does not take \(clamped(token))")
                }
            }
            return .local(.installHooks(uninstall: uninstall))
        }

        // `baia layout export` is two tokens at the prompt and one verb on the
        // wire. Rewritten into the wire spelling and parsed again rather than
        // given an arm of its own, so its flags reach the same switch every other
        // verb's do and there is no second place for a flag rule to live.
        if head == "layout" {
            let rest = Array(argv.dropFirst())
            if rest.contains("--help") || rest.contains("-h") {
                return .help
            }
            guard let sub = rest.first, sub.hasPrefix("-") == false else {
                return .usage("layout needs a command: export or apply.")
            }
            guard ControlVerb(rawValue: "layout-\(sub)") != nil else {
                return .usage(
                    "no layout command named \(clamped(sub)). There are two: export and apply."
                )
            }
            return parse(["layout-\(sub)"] + rest.dropFirst())
        }

        guard let verb = ControlVerb(rawValue: head) else {
            return .usage(
                "no command named \(clamped(head)). Run baia --help for the ones there are."
            )
        }

        let rest = Array(argv.dropFirst())
        if rest.contains("--help") || rest.contains("-h") {
            return .help
        }

        var call = Invocation(verb: verb, args: ControlArgs(), stdin: .unused, json: false, tree: false)
        var tokens = Tokens(rest)

        // No `default:` on this switch, and it must never get one. A new
        // `ControlVerb` case has to be given a spelling here before the CLI
        // compiles, which is the same mechanism `ControlVerb.scope` uses in the
        // package: a fallthrough would leave a verb reachable over the socket
        // and unreachable from the tool that exists to reach it.
        switch verb {
        case .split:
            while let token = tokens.take() {
                switch token {
                case "--right":
                    call.args.axis = .horizontal
                case "--down":
                    call.args.axis = .vertical
                case "--cwd":
                    guard let path = tokens.take() else {
                        return .usage("--cwd needs a path")
                    }
                    call.args.cwd = path
                case "--command":
                    guard let command = tokens.take() else {
                        return .usage("--command needs a command")
                    }
                    // The same rule the server applies, applied here so a typo is
                    // answered at the prompt rather than over the socket. See
                    // `ControlWire.refusalForCommand`: the newline half of it is a
                    // security boundary and this copy is the convenience one.
                    if let refusal = ControlWire.refusalForCommand(command) {
                        return .usage(refusal)
                    }
                    call.args.command = command
                default:
                    return .usage(unexpected(token, verb))
                }
            }
            // Matches ⌘D, which is `splitFocusedPane(axis: .horizontal)`. Spelled
            // here rather than left nil so the app is not asked to hold a second
            // opinion about what a bare split means.
            if call.args.axis == nil {
                call.args.axis = .horizontal
            }

        case .report:
            // Exactly one of `--state` or `--release`. A report about nothing is
            // not a report, and both together is a caller that has not decided,
            // so neither is answered by picking one.
            while let token = tokens.take() {
                switch token {
                case "--state":
                    guard let name = tokens.take(), let state = ReportedState(rawValue: name) else {
                        let known = ReportedState.allCases.map(\.rawValue).joined(separator: ", ")
                        return .usage("--state needs one of: \(known)")
                    }
                    call.args.state = state
                case "--release":
                    call.args.release = true
                case "--message":
                    guard let text = tokens.take() else {
                        return .usage("--message needs text")
                    }
                    call.args.text = text
                case "--ttl":
                    guard let raw = tokens.take(), let seconds = Int(raw) else {
                        return .usage("--ttl needs a number of seconds")
                    }
                    call.args.ttl = seconds
                case "--seq":
                    guard let raw = tokens.take(), let seq = UInt64(raw) else {
                        return .usage("--seq needs a whole number")
                    }
                    call.args.seq = seq
                case "--json":
                    call.json = true
                default:
                    return .usage(unexpected(token, verb))
                }
            }
            let releasing = call.args.release == true
            guard (call.args.state != nil) != releasing else {
                return .usage("report needs exactly one of --state or --release")
            }
            // A message rides a raise and never a clear, which is the rule
            // `ObservedPaneState` already follows for OSC messages. Meaningless
            // here rather than merely unused, so it is refused rather than
            // dropped: a caller who wrote it believes it will be shown.
            if call.args.text != nil, call.args.state != .blocked {
                return .usage("--message applies only to --state blocked")
            }

        case .read:
            // One positional and required, the pane to read, because a `read`
            // that defaulted to the caller would be an expensive way to ask a
            // question `whoami` answers, and a typo in a pane id would silently
            // become a read of oneself.
            guard let target = tokens.take(), !target.hasPrefix("--") else {
                return .usage("read needs a pane id")
            }
            call.args.peer = target
            while let token = tokens.take() {
                switch token {
                case "--lines":
                    guard let raw = tokens.take(), let count = Int(raw) else {
                        return .usage("--lines needs a number")
                    }
                    call.args.lines = count
                case "--json":
                    call.json = true
                default:
                    return .usage(unexpected(token, verb))
                }
            }

        case .cwd:
            // One positional, and required. `baia cwd` with nothing after it is
            // almost certainly a shell that meant to print the directory, and
            // answering that by silently announcing nothing would be worse than
            // saying what the verb needs.
            guard let path = tokens.take(), !path.hasPrefix("--") else {
                return .usage("cwd needs a path")
            }
            call.args.cwd = path
            // `--json` after the path, the way every other verb takes it. Without
            // it this verb prints nothing whether it worked or not, which makes a
            // refusal indistinguishable from success at the one moment somebody
            // is asking why nothing moved.
            while let token = tokens.take() {
                switch token {
                case "--json":
                    call.json = true
                default:
                    return .usage(unexpected(token, verb))
                }
            }

        case .close, .focus, .equalize:
            if let token = tokens.take() {
                return .usage(unexpected(token, verb))
            }

        case .layoutExport:
            // No `--json`, and the refusal says so rather than accepting it. The
            // plain output *is* the document, which is what `> dev.json` catches
            // and what `layout apply` reads back. A `--json` that wrapped the same
            // thing in a response envelope would hand somebody a file that looks
            // right and applies to nothing.
            if let token = tokens.take() {
                return .usage(
                    token == "--json"
                        ? "layout export already prints JSON. Its output is the document itself, "
                            + "which is what layout apply reads."
                        : unexpected(token, verb)
                )
            }

        case .layoutApply:
            if let token = tokens.take() {
                return .usage(unexpected(token, verb))
            }
            call.stdin = .layoutDocument

        case .zoom:
            while let token = tokens.take() {
                switch token {
                case "--on":
                    call.args.on = true
                case "--off":
                    call.args.on = false
                default:
                    return .usage(unexpected(token, verb))
                }
            }

        case .resize:
            guard let first = tokens.take() else {
                return .usage("resize needs a direction: left, right, up, or down")
            }
            guard let direction = ControlDirection(rawValue: first) else {
                return .usage(
                    "no direction named \(clamped(first)). Use left, right, up, or down."
                )
            }
            call.args.direction = direction
            while let token = tokens.take() {
                switch token {
                case "--by":
                    guard let raw = tokens.take() else {
                        return .usage("--by needs a fraction, for instance 0.05")
                    }
                    guard let value = Double(raw), value.isFinite else {
                        return .usage("--by wants a number, not \(clamped(raw))")
                    }
                    call.args.by = value
                default:
                    return .usage(unexpected(token, verb))
                }
            }

        case .whoami, .peers:
            while let token = tokens.take() {
                switch token {
                case "--json":
                    call.json = true
                default:
                    return .usage(unexpected(token, verb))
                }
            }

        case .list:
            while let token = tokens.take() {
                switch token {
                case "--json":
                    call.json = true
                case "--tree":
                    call.tree = true
                default:
                    return .usage(unexpected(token, verb))
                }
            }
            if call.json, call.tree {
                return .usage("--tree and --json render the same records two ways. Pick one.")
            }

        case .publish:
            while let token = tokens.take() {
                switch token {
                case "--as":
                    guard let name = tokens.take() else {
                        return .usage("--as needs a channel name")
                    }
                    call.args.name = name
                case "--rotate":
                    call.args.rotate = true
                default:
                    return .usage(unexpected(token, verb))
                }
            }

        case .connect:
            while let token = tokens.take() {
                switch token {
                case "--stdin":
                    // Accepted and redundant: stdin is the only source there is.
                    // Spelled in the docs and the help so the reason is visible
                    // at the call site rather than only here.
                    break
                default:
                    if token.hasPrefix("--") {
                        return .usage(unexpected(token, verb))
                    }
                    return .usage(
                        "a rendezvous ticket is never passed as an argument: every process "
                            + "running as you can read this one's argv with ps. Pipe it in, "
                            + "for instance `pbpaste | baia connect --stdin`."
                    )
                }
            }
            call.stdin = .rendezvousTicket

        case .send:
            var peer: String?
            var body: String?
            var bodyFromStdin = false
            while let token = tokens.take() {
                switch token {
                case "--stdin":
                    bodyFromStdin = true
                default:
                    if token.hasPrefix("--") {
                        return .usage(unexpected(token, verb))
                    }
                    if peer == nil {
                        peer = token
                    } else if body == nil {
                        body = token
                    } else {
                        return .usage("send takes one peer and one message")
                    }
                }
            }
            guard let peer else {
                return .usage("send needs a peer's pane id")
            }
            call.args.peer = peer
            if bodyFromStdin {
                guard body == nil else {
                    return .usage("send takes a message or --stdin, not both")
                }
                call.stdin = .messageBody
            } else {
                guard let body else {
                    return .usage("send needs a message, or --stdin to read one")
                }
                call.args.text = body
            }

        case .recv:
            while let token = tokens.take() {
                switch token {
                case "--json":
                    call.json = true
                case "--wait":
                    guard let raw = tokens.take() else {
                        return .usage("--wait needs a number of seconds")
                    }
                    guard let seconds = Int(raw), seconds >= 0 else {
                        return .usage("--wait wants a whole number of seconds, not \(clamped(raw))")
                    }
                    call.args.wait = seconds
                default:
                    return .usage(unexpected(token, verb))
                }
            }

        case .subscribe:
            var cursor: UInt64?
            while let token = tokens.take() {
                switch token {
                case "--json":
                    call.json = true
                case "--from":
                    guard let raw = tokens.take() else {
                        return .usage(
                            "--from needs a sequence number, or 0 to start from the beginning"
                        )
                    }
                    guard let value = UInt64(raw) else {
                        return .usage("--from wants a whole sequence number, not \(clamped(raw))")
                    }
                    cursor = value
                case "--wait":
                    guard let raw = tokens.take() else {
                        return .usage("--wait needs a number of seconds")
                    }
                    guard let seconds = Int(raw), seconds >= 0 else {
                        return .usage("--wait wants a whole number of seconds, not \(clamped(raw))")
                    }
                    call.args.wait = seconds
                case "--kinds":
                    guard let raw = tokens.take() else {
                        return .usage(
                            "--kinds needs a comma-separated list, any of: "
                                + ControlEventKind.allCases.map(\.rawValue).joined(separator: ", ")
                        )
                    }
                    let names = raw.split(separator: ",").map(String.init)
                    guard names.isEmpty == false else {
                        return .usage("--kinds needs at least one kind")
                    }
                    // Checked here so the common misspelling never costs a round
                    // trip. The server checks it too, and that check is the rule:
                    // this one can never be the only one, because a frame can
                    // arrive without this CLI in front of it.
                    for name in names where ControlEventKind(rawValue: name) == nil {
                        return .usage(
                            "\(clamped(name)) is not an event kind. --kinds takes any of: "
                                + ControlEventKind.allCases.map(\.rawValue).joined(separator: ", ")
                        )
                    }
                    call.args.kinds = names
                default:
                    return .usage(unexpected(token, verb))
                }
            }
            guard let cursor else {
                return .usage(
                    "subscribe needs --from SEQ. Take it from baia list, which reports the "
                        + "sequence its records were read at, or pass 0 for everything the ring holds."
                )
            }
            call.args.from = cursor

        case .revoke:
            guard let peer = tokens.take() else {
                return .usage("revoke needs a peer's pane id")
            }
            call.args.peer = peer
            if let token = tokens.take() {
                return .usage(unexpected(token, verb))
            }

        case .run:
            // Declared in v1 and refused in v1. It takes no arguments here
            // because the arguments it will take are v2's, and inventing their
            // spelling now would ship a shape nothing honours.
            if let token = tokens.take() {
                return .usage(
                    "run takes no arguments yet: it is declared in v1 and lands in v2. "
                        + "\(clamped(token)) is not one of them."
                )
            }
        }

        return .invoke(call)
    }

    /// Attacker-controlled up to the frame cap, so it is clamped before it is
    /// echoed. A 256 KiB message written to a terminal for a typo is a denial of
    /// service with a friendly face.
    static func clamped(_ text: String) -> String {
        text.count > 40 ? String(text.prefix(40)) + "..." : text
    }

    private static func unexpected(_ token: String, _ verb: ControlVerb) -> String {
        "baia \(spelling(of: verb)) does not take \(clamped(token))"
    }

    /// A verb as a person types it, which for `layout-export` is `layout export`.
    ///
    /// Derived from the wire spelling rather than tabulated beside it. A second
    /// table would be a second thing to keep in step, and the rule is small enough
    /// to state: a hyphen on the wire is a space at the prompt.
    static func spelling(of verb: ControlVerb) -> String {
        verb.rawValue.replacingOccurrences(of: "-", with: " ")
    }

    /// The tokens after the verb, walked once, left to right.
    private struct Tokens {
        private let items: [String]
        private var index: Int

        init(_ items: [String]) {
            self.items = items
            index = items.startIndex
        }

        mutating func take() -> String? {
            guard index < items.endIndex else { return nil }
            defer { index += 1 }
            return items[index]
        }
    }
}
