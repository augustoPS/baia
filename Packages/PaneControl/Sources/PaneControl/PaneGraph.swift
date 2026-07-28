import Foundation

/// Who may do what to whom, and nothing else.
///
/// A value type holding the token registry, the parentage edges, and the peer
/// edges, with no knowledge of `Workspace` whatsoever. It answers "may this
/// actor do this", not "what does the layout look like", and keeping the two
/// apart is what lets the authorization matrix be tested with no tree in
/// existence.
///
/// Every mutation returns whether it changed anything, matching `Workspace`'s
/// convention.
///
/// Isolation is the server's problem and not this type's. `PaneGraph` is a value
/// with no reference semantics to share: the server holds it on the main actor,
/// decodes frames off-main, and hops once per request to authorize and apply. No
/// lock, no second owner, and nothing here to make thread-safe.
///
/// **There is no public way to turn a secret into a pane except
/// ``authorize(token:verb:target:)``.** That is the point of the type's surface:
/// a read verb answering `whoami` gets its actor out of a ``Decision``, so no
/// response path can reach the registry even by accident.
public struct PaneGraph: Sendable, Equatable {
    /// Secret to pane.
    ///
    /// Internal rather than private, deliberately. The test proving that
    /// ``authorize(token:verb:target:)`` rejects a pane-id-shaped token *before*
    /// it looks anything up has to plant a registration the public API refuses
    /// to create. Against a private store that test could only show the lookup
    /// missing, which is the weaker claim this design exists to beat: "is not
    /// found" holds until something puts it there, and "is rejected" holds
    /// regardless.
    var registry: [PaneSecret: ControlPaneID] = [:]

    /// Child to parent.
    ///
    /// One index and no children index. Two indices are two things that can
    /// disagree, and this disagreement would be invisible and would widen a
    /// scope: a stale children entry hands an ancestor authority over a pane
    /// that was rerooted away from it. Walking up a parent chain is cheap at
    /// workspace sizes, and correctness here is not a place to trade.
    var parentOf: [ControlPaneID: ControlPaneID] = [:]

    /// Peer edges, held in both directions.
    ///
    /// Both halves are written by the same mutation and by no other, so unlike a
    /// derived children index there is no path that updates one and forgets the
    /// other. Peering is a communication edge and never a control edge: a peer
    /// may be seen and messaged, and may not be split, closed, resized, or run
    /// in.
    var peerEdges: [ControlPaneID: Set<ControlPaneID>] = [:]

    /// Published channels, keyed by owner and name together.
    ///
    /// The ticket that admits to each one lives in here and nowhere else: it is
    /// never persisted, never logged, and never returned by any verb except the
    /// `publish` of the pane that owns it.
    var channels: [ChannelKey: PublishedChannel] = [:]

    /// One bounded FIFO per pane that has been messaged.
    ///
    /// Created on the first delivery and dropped once drained, so a pane that
    /// nobody talks to owns nothing here. Mailboxes die with the app: they are a
    /// runtime rendezvous between live processes, and restoring one would hand a
    /// fresh shell a stranger's backlog.
    var mailboxes: [ControlPaneID: Mailbox] = [:]

    public init() {}

    // MARK: Lifetime

    /// Records a live pane, its capability, and where it came from.
    ///
    /// `createdBy` has no default, for the reason `PaneState.init` has none: a
    /// defaulted parameter lets every call site compile unchanged and record nil
    /// forever, and attributability that is silently nil is worse than absent
    /// because it reads as "the owner opened this".
    ///
    /// Returns false, changing nothing, when the secret parses as a pane id,
    /// when the secret is already issued to somebody, or when the pane is
    /// already open. Failure is closed and total: a refused registration leaves
    /// no half-registered pane whose token works but whose parentage is missing.
    ///
    /// A `createdBy` naming a pane that is not open yet is accepted and kept. On
    /// restore the app replays panes in whatever order the session file lists
    /// them, and a rule that dropped a forward edge would make parentage depend
    /// on iteration order. Dropping a *dangling* edge is a different rule, it
    /// belongs to `SessionStore.reconciled`, and it runs before any of this.
    @discardableResult
    public mutating func open(
        pane: ControlPaneID,
        createdBy: ControlPaneID?,
        secret: PaneSecret
    ) -> Bool {
        // The registry refuses what `authorize` also refuses. Both call the same
        // predicate, so this is one rule enforced twice and not two rules.
        guard secret.parsesAsPaneID == false else { return false }
        guard registry[secret] == nil else { return false }
        guard isOpen(pane) == false else { return false }

        registry[secret] = pane
        if let createdBy {
            parentOf[pane] = createdBy
        }
        return true
    }

    /// Forgets a pane and everything that pointed at it.
    ///
    /// Its registration goes, so its secret stops working; its peer edges go in
    /// both directions; its published channels and their tickets go, along with
    /// every admission and denial naming it; its mailbox goes; and its children
    /// become roots rather than being reparented to its parent. Reparenting would
    /// silently widen the grandparent's scope to panes it never created, which is
    /// the same reasoning `SessionStore.reconciled` records for a dangling
    /// `createdBy` on restore.
    ///
    /// Everything at once and in one function, because a pane whose channels
    /// outlived it would leave a ticket admitting callers to an edge with nobody
    /// on the other end, and a cleanup the app has to remember to perform is a
    /// cleanup that will be forgotten on one path.
    @discardableResult
    public mutating func close(pane: ControlPaneID) -> Bool {
        var changed = false

        for (secret, owner) in registry where owner == pane {
            registry[secret] = nil
            changed = true
        }

        if parentOf.removeValue(forKey: pane) != nil { changed = true }

        for (child, parent) in parentOf where parent == pane {
            parentOf[child] = nil
            changed = true
        }

        if let peers = peerEdges.removeValue(forKey: pane) {
            changed = changed || peers.isEmpty == false
            for peer in peers {
                peerEdges[peer]?.remove(pane)
                if peerEdges[peer]?.isEmpty == true { peerEdges[peer] = nil }
            }
        }

        if retirePeering(of: pane) { changed = true }
        if mailboxes.removeValue(forKey: pane) != nil { changed = true }

        return changed
    }

    /// Whether the pane still holds a capability.
    ///
    /// Derived from the registry rather than tracked beside it, so "a closed
    /// pane's secret stops working" is structurally true instead of being a rule
    /// somebody has to remember to apply in two places.
    public func isOpen(_ pane: ControlPaneID) -> Bool {
        registry.values.contains(pane)
    }

    // MARK: Parentage

    public func parent(of pane: ControlPaneID) -> ControlPaneID? {
        parentOf[pane]
    }

    public func children(of pane: ControlPaneID) -> Set<ControlPaneID> {
        Set(parentOf.filter { $0.value == pane }.keys)
    }

    /// Whether `candidate` sits anywhere below `ancestor`, transitively.
    ///
    /// Walks up from the candidate rather than down from the ancestor: the walk
    /// is then bounded by tree depth instead of by workspace size, and it needs
    /// no children index to be correct.
    ///
    /// The visited set is not decoration. Nothing in the public API can build a
    /// cycle, since ``open(pane:createdBy:secret:)`` refuses a pane that is
    /// already open and nothing reparents. But an unbounded walk on an
    /// authorization path is a hang in the app process, and a hang is a worse
    /// answer than a denial for a shape that should be impossible.
    public func isDescendant(_ candidate: ControlPaneID, of ancestor: ControlPaneID) -> Bool {
        var seen: Set<ControlPaneID> = [candidate]
        var cursor = parentOf[candidate]
        while let current = cursor {
            if current == ancestor { return true }
            guard seen.insert(current).inserted else { return false }
            cursor = parentOf[current]
        }
        return false
    }

    // MARK: Peering

    public func peers(of pane: ControlPaneID) -> Set<ControlPaneID> {
        peerEdges[pane] ?? []
    }

    /// Establishes a peer edge in both directions.
    ///
    /// The admission ticket that authorises this, and the per-edge secret it
    /// mints, arrive with `publish` and `connect`. What lives here is the edge
    /// itself, so the authorization matrix can be exercised against a peer and a
    /// revoked peer before any of that exists.
    @discardableResult
    public mutating func addPeerEdge(between one: ControlPaneID, and other: ControlPaneID) -> Bool {
        guard one != other else { return false }
        guard isOpen(one), isOpen(other) else { return false }
        guard peerEdges[one]?.contains(other) != true else { return false }

        peerEdges[one, default: []].insert(other)
        peerEdges[other, default: []].insert(one)
        return true
    }

    /// Deletes a peer edge in both directions.
    ///
    /// Symmetric because the edge is: a `revoke` that removed one direction
    /// would leave the revoked peer still able to see and message the pane that
    /// revoked it, which is the revocation reading as done while nothing changed.
    @discardableResult
    public mutating func removePeerEdge(between one: ControlPaneID, and other: ControlPaneID) -> Bool {
        guard peerEdges[one]?.contains(other) == true else { return false }

        peerEdges[one]?.remove(other)
        peerEdges[other]?.remove(one)
        if peerEdges[one]?.isEmpty == true { peerEdges[one] = nil }
        if peerEdges[other]?.isEmpty == true { peerEdges[other] = nil }
        return true
    }

    // MARK: Authorization

    /// What a request is allowed to be.
    ///
    /// An explicit decision rather than a `Bool`, so a denial carries the code
    /// and the sentence the error response needs and no caller has to invent one
    /// from a false. An allowance names the resolved actor and target, which is
    /// how a handler gets the calling pane without any path back to the registry.
    public enum Decision: Sendable, Equatable {
        case allowed(actor: ControlPaneID, target: ControlPaneID)
        case denied(ControlError)
    }

    /// The single scope resolver. Every verb, read or write, comes through here.
    ///
    /// Two resolvers is what lets one of them be wrong, and the one that would
    /// be wrong is the read side: a scope leak on `list` fails by
    /// over-succeeding, which nothing shaped like a refusal test can see.
    ///
    /// `token` arrives as the raw string off the wire, deliberately. This
    /// function is the boundary where an untrusted string either becomes an
    /// identity or does not, and handing it a `PaneSecret` built elsewhere would
    /// move the first half of that decision somewhere with no test on it.
    ///
    /// A nil `target` means the caller itself, which is every v1 layout verb: they
    /// act on the calling pane and take no target at all.
    ///
    /// What this does *not* answer is whether the verb is switched on.
    /// ``ControlVerb/settingGate`` names the key and the server reads it, so a
    /// `run` that this function allows is still refused in v1 by its gate. Scope
    /// and availability are different questions and answering them in one place
    /// would make either one hard to see.
    public func authorize(token: String, verb: ControlVerb, target: ControlPaneID?) -> Decision {
        let secret = PaneSecret(token)

        // **The order of the next two statements is the design.** A token that
        // parses as a pane id is refused here, before the registry is consulted
        // at all, so the answer never depends on the registry being clean. Were
        // this a lookup miss instead, one stray registration would promote every
        // id in `session.json` to a master key, and `session.json` is readable by
        // every process the user owns.
        guard secret.parsesAsPaneID == false else { return .denied(.badToken) }
        guard let actor = registry[secret] else { return .denied(.badToken) }

        // A target that is not a live pane is `unauthorized` and never
        // `notFound`, so the answer for a pane that does not exist is
        // byte-identical to the answer for a live pane out of scope. A caller
        // that could tell them apart could enumerate the workspace one id at a
        // time.
        if let target, isOpen(target) == false { return .denied(.unauthorized) }

        // No `default:`, for the reason ``ControlVerb/scope`` has none: a scope
        // added without a decided resolution must fail to compile here rather
        // than fall through to whatever the fallback happened to be.
        switch verb.scope {
        case .selfOnly:
            // These verbs take no target. A named target that is not the caller
            // is refused rather than ignored, because ignoring it would let a
            // later wiring mistake pass silently through the one function whose
            // job is to catch exactly that.
            guard target == nil || target == actor else { return .denied(.unauthorized) }
            return .allowed(actor: actor, target: actor)

        case .scopedRead:
            let subject = target ?? actor
            guard subject == actor
                || isDescendant(subject, of: actor)
                || peers(of: actor).contains(subject)
            else { return .denied(.unauthorized) }
            return .allowed(actor: actor, target: subject)

        case .peerEdge:
            // No target means no peer named, which is not a request that can be
            // answered rather than one that defaults to the caller.
            guard let subject = target else { return .denied(.unauthorized) }
            guard peers(of: actor).contains(subject) else { return .denied(.unauthorized) }
            return .allowed(actor: actor, target: subject)

        case .descendant:
            // Control authority follows parentage and nothing else. A peer is
            // reachable for reading and messaging and is not reachable here:
            // peering is a communication edge, and a design that let it carry
            // control would make consent to talk into consent to be driven.
            let subject = target ?? actor
            guard subject == actor || isDescendant(subject, of: actor) else {
                return .denied(.unauthorized)
            }
            return .allowed(actor: actor, target: subject)
        }
    }
}
