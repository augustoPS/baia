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

    /// Reads a descendant pane's lines.
    ///
    /// **Descendant-scoped, and deliberately not peer-scoped.** Reading a pane the
    /// caller created is inside the trust model, because the caller made it.
    /// Reading a peer is not: peering is a communication edge, and a peer agreed
    /// to exchange messages rather than to be read. `list` is peer-scoped and this
    /// is not, and that asymmetry is intentional rather than an oversight.
    case read

    /// Prints the arrangement of the window the calling pane is in, as a document
    /// `layoutApply` can open.
    ///
    /// **Why this is `.scopedRead` and not something narrower.** A tab's layout
    /// carries the working directories of panes the caller never created, and the
    /// channel's rule is self, descendants, and peers. The answer is split along
    /// that line rather than withheld or granted whole:
    ///
    /// - **The shape goes out unconditionally**: the tree, the ratios, and the tab
    ///   order of the caller's own window. What is left after the split below is
    ///   structure with nothing in it to act on. No pane id, so the document is no
    ///   use as reconnaissance; no directory, so it names nothing the caller could
    ///   not name already; no focus and no zoom, so it says nothing about what the
    ///   owner is doing. A pane can already infer some of this without asking: a
    ///   sibling splitting resizes the caller's own grid and its shell hears
    ///   `SIGWINCH`. The tabs beside it are the part that is genuinely new, and
    ///   that widening is bought deliberately, because a layout that stops at one
    ///   tab cannot express the setup the verb exists to capture.
    /// - **A working directory goes out only where `list` would already show it.**
    ///   Same set, same resolver, computed by the server the way `list` computes
    ///   it: the caller, its descendants, and its peers. Every other pane exports
    ///   as a leaf with no directory, and `layoutApply` opens those at the default
    ///   one. So `make dev` still opens five panes in five repositories for the
    ///   owner who exported it, and a pane that created none of them learns the
    ///   window has five panes and not where any of them is working.
    ///
    /// Gated on the channel alone, with no key of its own, for the same reason:
    /// nothing in the answer exceeds what `list` already returns, and `list` is
    /// gated on the channel. `read` has a key because its answer carries another
    /// pane's screen. This one carries a shape.
    ///
    /// The two spellings are one verb. On the wire it is `layout-export`, because
    /// a verb is one string there; at the prompt it is `baia layout export`, which
    /// is what the CLI documents and what a Makefile will hold. The hyphenated
    /// form parses too, since the wire spelling is the CLI's head lookup, and
    /// there is no reason to add a rejection for a spelling that means the same
    /// thing.
    case layoutExport = "layout-export"

    /// Opens a **new** window from a layout document.
    ///
    /// `.selfOnly`, and the reason is that it never touches a pane it did not
    /// make. It creates; it does not reshape the caller's window, or any other.
    /// That is what keeps it inside v1: cross-pane mutation is deferred to v2, and
    /// a verb that re-split the caller's tab would be that, arriving early and
    /// under a different name.
    ///
    /// The new window is detached rather than joined to the caller's tab group.
    /// Joining would reorder a tab bar the owner arranged, which is a change to
    /// something the caller does not own even though no pane moves.
    ///
    /// Every pane it opens is recorded as created by the caller, so they appear in
    /// the caller's `list --tree` and their `paneOpened` events reach its
    /// `subscribe`, exactly like a pane from `split`.
    case layoutApply = "layout-apply"

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
        // Creates a window and reaches no existing pane, so it sits with the
        // layout verbs rather than earning a scope for the panes it makes.
        case .layoutApply:
            .selfOnly
        // Read-only, and scoped exactly like `list` because half its answer *is*
        // `list`'s: a working directory goes out only for a pane `list` would
        // already name. The other half is the window's shape, which carries no id
        // and no directory. Argued in full on the case itself.
        case .list, .layoutExport:
            .scopedRead
        // The first verb to exercise `.descendant` for anything. The scope has
        // been implemented and correct since v1 with no consumer; `run` declares
        // it and is refused by its gate.
        case .read:
            .descendant
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
             .subscribe, .cwd, .report, .layoutExport, .layoutApply:
            .channel
        case .read:
            .allowRead
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

    /// Gated by `controlChannelEnabled` and then by `controlAllowRead`.
    ///
    /// `read` is the first verb to put another pane's **content** in a response.
    /// Every other verb returns ids, self-chosen messages, and labels the app
    /// derived; this returns whatever is on a descendant's screen, including what
    /// the owner typed into it. Its own key so the capability is nameable and can
    /// be switched off, and so it is observable over the socket the way
    /// ``allowRun`` already is.
    case allowRead
}
