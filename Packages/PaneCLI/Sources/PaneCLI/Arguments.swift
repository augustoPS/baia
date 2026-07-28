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
}

public enum ParseOutcome {
    case invoke(Invocation)
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

        case .close, .focus, .equalize:
            if let token = tokens.take() {
                return .usage(unexpected(token, verb))
            }

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
        "baia \(verb.rawValue) does not take \(clamped(token))"
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
