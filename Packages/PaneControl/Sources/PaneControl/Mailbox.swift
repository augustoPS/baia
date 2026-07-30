import Foundation

/// One pane's inbox: a bounded FIFO and a count of what it could not hold.
///
/// Bounded because a mailbox is memory in the app process that a peer fills at
/// its own pace, and a pane that stops draining must cost the workspace a fixed
/// amount rather than an unbounded one.
///
/// **The drop count is part of the contract.** When the cap is reached the oldest
/// message goes, and the next drain says how many went. A silent drop is worse
/// than a lost message, because the reader concludes nothing was sent and goes
/// looking for the bug in the sender.
public struct Mailbox: Sendable, Equatable {
    /// Oldest first, which is the order a drain hands them back in.
    public private(set) var messages: [ControlMessage] = []

    /// Dropped since the last drain, reported once by that drain and then reset.
    public private(set) var dropped: Int = 0

    init() {}

    /// Appends, dropping from the front when the cap is reached.
    ///
    /// The new message always lands. Dropping the *newest* instead would make a
    /// full mailbox permanently deaf, which reads to the sender exactly like a
    /// peer that stopped listening on purpose.
    mutating func append(_ message: ControlMessage) {
        messages.append(message)
        while messages.count > ControlWire.maxMailboxMessages {
            messages.removeFirst()
            dropped += 1
        }
    }

    /// Hands back the leading `count` messages and the drop count, clearing both.
    ///
    /// Called only once a candidate response has been framed and found to fit, so
    /// the messages leaving here are messages that reached the caller.
    mutating func take(_ count: Int) -> (messages: [ControlMessage], dropped: Int) {
        let taken = Array(messages.prefix(count))
        messages.removeFirst(taken.count)
        let reported = dropped
        dropped = 0
        return (taken, reported)
    }

    var isEmpty: Bool { messages.isEmpty && dropped == 0 }
}

/// What one `recv` answered.
public struct Drain: Sendable, Equatable {
    /// Oldest first, at most ``ControlWire/maxDrainBatch`` of them.
    public var messages: [ControlMessage]

    /// True when the mailbox still holds messages this response could not carry,
    /// either because the batch cap or the frame cap stopped it.
    ///
    /// It means "poll again" and never "some are gone", because a message leaves
    /// the mailbox only once it has been framed into a response that fits.
    public var more: Bool

    /// How many were dropped from a full mailbox since the last drain. Reported
    /// once and then reset.
    public var dropped: Int

    /// The answer for a pane with nothing waiting, and the answer a parked `recv`
    /// is resolved with when its pane closes, when the channel is disabled, and
    /// at app terminate. A client never sees a bare EOF from a wait.
    public static let empty = Drain(messages: [], more: false, dropped: 0)
}

extension PaneGraph {
    // MARK: Sending

    /// Appends a message to a peer's mailbox.
    ///
    /// Authorization runs first and the size check second, in that order. A pane
    /// that is not a peer learns `unauthorized` and nothing else, including
    /// nothing about what sizes the peer would have accepted.
    ///
    /// The peer is named by its display pane id, off the wire. A non-peer, a pane
    /// that does not exist, and a string that is not an id at all all answer the
    /// same `unauthorized` with the same message, so a caller cannot probe for
    /// pane existence one id at a time.
    public mutating func send(
        token: String,
        peer: String,
        text: String
    ) -> ControlOutcome<ControlPaneID> {
        // `ControlVerb.send.scope` rather than `.peerEdge` written out, so the
        // sentence a malformed id draws cannot drift from the one `authorize`
        // draws for a live non-peer. The two being identical is the whole point
        // of refusing here at all.
        guard let target = ControlPaneID(uuidString: peer) else {
            return .denied(.unauthorized(ControlVerb.send.scope))
        }

        switch authorize(token: token, verb: .send, target: target) {
        case let .denied(error):
            return .denied(error)

        case let .allowed(actor, recipient):
            let message = ControlMessage(from: actor.description, text: text)

            // **Refused on the framed size, not on the payload size, and this is
            // the load-bearing half.** 48 KiB of U+0001 frames to more than
            // 288 KiB, because JSON escaping spends six bytes on a control byte,
            // so a payload inside the text budget can still be a message no
            // response can carry. Accepting one would put a message in a mailbox
            // that no `recv` could ever drain, blocking every message behind it
            // for as long as the pane lives.
            guard ControlWire.canBeDrained(message) else {
                return .denied(.messageTooLarge(
                    framed: ControlWire.drainFrameSize(
                        messages: [message],
                        dropped: ControlWire.maxMailboxMessages
                    )
                ))
            }

            // The text budget on top of it. The frame check above is what keeps
            // the mailbox drainable; this one keeps the documented budget a
            // number that is enforced rather than a number in a table.
            guard text.utf8.count <= ControlWire.maxMessagePayloadBytes else {
                return .denied(.messagePayloadTooLarge(bytes: text.utf8.count))
            }

            deliver(message, to: recipient)
            return .ok(recipient)
        }
    }

    /// Puts a message in a pane's mailbox with no check of any kind.
    ///
    /// Internal, like the peering state machine, so the only way a message
    /// reaches a mailbox is through ``send(token:peer:text:)`` and therefore
    /// through `authorize`.
    mutating func deliver(_ message: ControlMessage, to pane: ControlPaneID) {
        var box = mailboxes[pane] ?? Mailbox()
        box.append(message)
        mailboxes[pane] = box
    }

    // MARK: Receiving

    /// Drains the calling pane's own mailbox.
    ///
    /// `recv` is `selfOnly`: a pane drains itself and nothing else, so there is
    /// no target to name and no way to read a mailbox that is not yours.
    public mutating func recv(
        token: String,
        limit: Int = ControlWire.maxDrainBatch,
        budget: Int = ControlWire.maxFrameBytes
    ) -> ControlOutcome<Drain> {
        switch authorize(token: token, verb: .recv, target: nil) {
        case let .denied(error):
            return .denied(error)
        case let .allowed(actor, _):
            return .ok(drain(pane: actor, limit: limit, budget: budget))
        }
    }

    /// Takes as many messages as fit, and leaves the rest where they are.
    ///
    /// **A message leaves the mailbox only once it has been framed into a
    /// response that fits.** Each candidate batch is encoded and measured before
    /// it is accepted, so a drain that runs out of budget mid-batch answers with
    /// what fits and `more: true`, and the messages it could not carry are still
    /// there for the next poll. The alternative, taking 32 and hoping, loses
    /// every message past the cap with `ok: true` on the way out.
    ///
    /// Measured rather than estimated. An estimate that is wrong by one byte in
    /// the direction that matters either drops a message or writes a frame the
    /// reader will refuse, and the batch cap keeps the cost at 32 encodes.
    ///
    /// The fit is computed with `more` spelled `false`, which is one byte longer
    /// than `true`, so the response finally written is never larger than the one
    /// that was measured.
    ///
    /// Internal, and pane-taking, for the reason the peering state machine is:
    /// it performs no authorization, so it is reachable only through
    /// ``recv(token:limit:budget:)``.
    mutating func drain(pane: ControlPaneID, limit: Int, budget: Int) -> Drain {
        guard var box = mailboxes[pane] else { return .empty }

        var count = 0
        while count < box.messages.count, count < limit {
            let candidate = Array(box.messages.prefix(count + 1))
            let size = ControlWire.drainFrameSize(messages: candidate, dropped: box.dropped)
            guard size <= budget else { break }
            count += 1
        }

        let taken = box.take(count)
        let more = box.messages.isEmpty == false
        // An empty mailbox is dropped rather than kept at zero, so a pane that
        // was messaged once does not own a table entry for the rest of the run.
        mailboxes[pane] = box.isEmpty ? nil : box

        return Drain(messages: taken.messages, more: more, dropped: taken.dropped)
    }

    /// How many messages are waiting.
    ///
    /// For the server deciding whether a parked `recv` has anything to wake for,
    /// and for tests that need to see what a truncated drain left behind. A count
    /// and not the contents: reading a mailbox goes through
    /// ``recv(token:limit:budget:)`` and therefore through a capability.
    public func waitingCount(of pane: ControlPaneID) -> Int {
        mailboxes[pane]?.messages.count ?? 0
    }
}
