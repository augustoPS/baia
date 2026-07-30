import Foundation

/// Everything the control channel can be asked to do, and nothing else.
///
/// A closed set rather than a string the server matches on, so the wire, the
/// CLI, and the authorization matrix all draw from one list. A verb that is not
/// in here decodes to ``ControlErrorCode/unknownVerb`` and never reaches a
/// handler.
///
/// Backed by `String` so a frame carries `"verb": "split"` and stays readable
/// with `nc`, which the testing plan depends on. The raw values are the wire
/// spelling and a rename is a protocol break, which is why a test asserts them
/// against a literal table rather than trusting the case names.
public enum ControlVerb: String, Sendable, Hashable, Codable, CaseIterable {
    // Layout, self-relative. Every v1 layout verb acts on the calling pane and
    // takes no target: the parentage graph is exercised read-only until v2.
    case split
    case close
    case focus
    case zoom
    case resize
    case equalize

    /// Says where the calling pane is working now.
    ///
    /// Advisory, and not a pin. `PaneAnchorTracker` already reads the foreground
    /// process's cwd once a second, so a shell that cds and an agent that chdirs
    /// itself are both tracked without this. What no poller can see is an agent
    /// that runs `cd /foo && cmd` in a subshell: neither its own cwd nor the
    /// shell's ever moves, so the only thing able to report it is the agent. A
    /// later poll that disagrees wins, because then the pane genuinely moved.
    case cwd

    /// Says what the calling pane is doing, overriding both pollers until it is
    /// released or lapses.
    ///
    /// Self-relative like `cwd`, and for the same reason: it is a statement about
    /// the caller and reaches nothing else. What it overrides is a conclusion the
    /// app drew about that same pane, which the pane is better placed to make.
    case report

    // Introspection, scoped to the caller, its descendants, and its peers.
    case whoami
    case list

    // Peering, a communication edge rather than a control edge.
    case publish
    case connect
    case peers
    case send
    case recv
    case revoke

    /// Observation. Reads the ring, consumes nothing, and names no target.
    case subscribe

    /// Cross-pane execution. Declared in v1 and refused in v1.
    ///
    /// Present rather than absent because absence would make
    /// ``ControlSettingGate/allowRun`` unobservable: both values of
    /// `controlAllowRun` would answer `unknownVerb`, a test asserting that would
    /// pass, and the key would have no consumer while looking like it had one.
    /// Declared, the key changes the answer from `disabled` to `refused`, which
    /// the diagnostic can see over the real socket.
    case run

    /// What relationship this verb requires between the calling pane and what it
    /// touches.
    ///
    /// **This switch has no `default:` and must never get one.** It is the
    /// mechanism, not the doc comment, that stops a verb being added without a
    /// decided scope: a new case fails to compile here first, and only then
    /// fails the authorization matrix. A `default:` would silently hand a new
    /// verb whatever scope happened to be the fallback, which for a security
    /// boundary is the widest one somebody will regret.
    public var scope: ControlScope {
        switch self {
        // Layout, all of it caller-relative.
        case .split, .close, .focus, .zoom, .resize, .equalize:
            .selfOnly
        // Peering verbs that mint, list, or drain something the caller owns.
        // `connect` is here because the rendezvous token it redeems is the
        // authority for the edge, not the caller's relationship to the peer.
        // `cwd` reports about the caller and reaches nothing else, so it sits
        // with the other self-relative verbs rather than earning a scope of its
        // own.
        case .whoami, .publish, .connect, .peers, .recv, .subscribe, .cwd, .report:
            .selfOnly
        case .list:
            .scopedRead
        case .send, .revoke:
            .peerEdge
        case .run:
            .descendant
        }
    }

    /// Which settings key has to be true before this verb does anything.
    ///
    /// **No `default:` here either, for the same reason.** A verb whose gate was
    /// never decided must not inherit the permissive one by falling through.
    public var settingGate: ControlSettingGate {
        switch self {
        case .split, .close, .focus, .zoom, .resize, .equalize,
             .whoami, .list, .publish, .connect, .peers, .send, .recv, .revoke,
             .subscribe, .cwd, .report:
            .channel
        case .run:
            .allowRun
        }
    }
}

/// What a verb is allowed to reach, which is the only question
/// `PaneGraph.authorize` answers.
///
/// Named after the relationship rather than after read or write, because reads
/// and writes share one resolver by design: two resolvers is what lets one of
/// them be wrong.
public enum ControlScope: Sendable, Hashable {
    /// Acts on the calling pane and takes no target. Every v1 layout verb, plus
    /// the peering verbs that mint or drain something belonging to the caller.
    /// Nothing here can name another pane, so nothing here can reach one.
    case selfOnly

    /// Reads the caller, its descendants, and its peers, and nothing else. A
    /// scope leak here fails by over-succeeding rather than by refusing, which
    /// is why the diagnostic asserts on the contents of a `list` and not on
    /// whether it was refused.
    case scopedRead

    /// Requires an established peer edge to the named target. A target that is
    /// not a peer answers `unauthorized` and never `notFound`, so a non-peer
    /// cannot learn whether a pane id exists.
    case peerEdge

    /// Mutation authority over a descendant, transitively. v2. The edge is
    /// recorded from the first commit so v2 inherits real provenance, but no v1
    /// verb exercises this scope for mutation.
    case descendant
}

/// The settings key a verb is gated on.
///
/// Layered rather than exclusive: `controlChannelEnabled` gates every verb, and
/// ``allowRun`` names the *additional* key its verb needs. A disabled channel
/// therefore answers `disabled` for `run` too, and the two keys are still
/// distinguishable, because with the channel on, `controlAllowRun` alone moves
/// `run` from `disabled` to `refused`.
public enum ControlSettingGate: Sendable, Hashable, CaseIterable {
    /// Gated by `controlChannelEnabled` only.
    case channel

    /// Gated by `controlChannelEnabled` and then by `controlAllowRun`. `split`
    /// hands a pane a shell it could already have spawned; `run` hands it
    /// execution in another pane's context. They do not share a switch.
    case allowRun
}
