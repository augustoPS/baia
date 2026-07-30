import Foundation
import Testing

@testable import PaneControl

/// The mailbox bounds, the drop count, and the two rules that keep a message from
/// being lost: a drain takes only what it has framed, and a `send` refuses what no
/// drain could ever frame.
@Suite struct MailboxTests {
    /// Two peered panes and a third that is nobody's peer.
    struct Fixture {
        static func capability(_ label: String) -> String { "c1-not-a-uuid-\(label)" }

        var graph = PaneGraph()
        let sender = ControlPaneID(rawValue: UUID())
        let receiver = ControlPaneID(rawValue: UUID())
        let stranger = ControlPaneID(rawValue: UUID())

        let senderToken = Fixture.capability("sender")
        let receiverToken = Fixture.capability("receiver")
        let strangerToken = Fixture.capability("stranger")

        init() {
            graph.open(pane: sender, createdBy: nil, secret: PaneSecret(senderToken))
            graph.open(pane: receiver, createdBy: nil, secret: PaneSecret(receiverToken))
            graph.open(pane: stranger, createdBy: nil, secret: PaneSecret(strangerToken))

            let ticket = RendezvousToken("c1-ticket-work")
            _ = graph.publish(pane: receiver, name: "work", ticket: ticket)
            _ = graph.connect(actor: sender, ticket: ticket, edgeSecret: EdgeSecret("c1-edge-one"))
        }

        /// Sends and fails the test on a denial, for the many tests whose subject
        /// is what happens after the message lands.
        mutating func send(_ text: String) {
            switch graph.send(token: senderToken, peer: receiver.description, text: text) {
            case .ok: break
            case let .denied(error): Issue.record("send was denied: \(error.message)")
            }
        }

        mutating func recv(
            limit: Int = ControlWire.maxDrainBatch,
            budget: Int = ControlWire.maxFrameBytes
        ) -> Drain {
            switch graph.recv(token: receiverToken, limit: limit, budget: budget) {
            case let .ok(drain): return drain
            case let .denied(error):
                Issue.record("recv was denied: \(error.message)")
                return .empty
            }
        }
    }

    // MARK: Who may send to whom

    /// **A non-peer must not learn whether a pane id exists.** A live pane out of
    /// scope, a pane that never existed, and a string that is not an id at all get
    /// one answer, down to the message, so there is nothing to compare and
    /// nothing to probe with.
    @Test func sendingToALiveNonPeerAndToANonexistentPaneAnswerIdentically() {
        var fixture = Fixture()

        let nonPeer = fixture.graph.send(
            token: fixture.senderToken,
            peer: fixture.stranger.description,
            text: "hello"
        )
        let nonexistent = fixture.graph.send(
            token: fixture.senderToken,
            peer: UUID().uuidString,
            text: "hello"
        )
        let malformed = fixture.graph.send(
            token: fixture.senderToken,
            peer: "not-an-id",
            text: "hello"
        )

        #expect(nonPeer == .denied(.unauthorized(ControlVerb.send.scope)))
        #expect(nonPeer == nonexistent)
        #expect(nonPeer == malformed)
        #expect(fixture.graph.waitingCount(of: fixture.stranger) == 0)
    }

    @Test func aMessageLandsInThePeersMailboxAndNotTheSendersOwn() {
        var fixture = Fixture()
        fixture.send("the build is green")

        #expect(fixture.graph.waitingCount(of: fixture.receiver) == 1)
        #expect(fixture.graph.waitingCount(of: fixture.sender) == 0)

        let drain = fixture.recv()
        #expect(drain.messages == [ControlMessage(
            from: fixture.sender.description,
            text: "the build is green"
        )])
        #expect(drain.more == false)
        #expect(drain.dropped == 0)
    }

    /// Revocation reaches the mailbox too, because `send` is `peerEdge`-scoped and
    /// the edge is gone. A revoked peer that could still write into the mailbox
    /// would make `revoke` a change of label rather than a change of reach.
    @Test func aRevokedPeerCannotSendAnyMore() {
        var fixture = Fixture()
        fixture.send("before")
        _ = fixture.graph.revoke(token: fixture.receiverToken, peer: fixture.sender.description)

        #expect(fixture.graph.send(
            token: fixture.senderToken,
            peer: fixture.receiver.description,
            text: "after"
        ) == .denied(.unauthorized(ControlVerb.send.scope)))
        #expect(fixture.graph.waitingCount(of: fixture.receiver) == 1)
    }

    /// `recv` is `selfOnly` and a pane id is not a capability, so there is no
    /// spelling of another pane's mailbox to read.
    @Test func recvNeedsACapabilityAndAPaneIDIsNotOne() {
        var fixture = Fixture()
        fixture.send("private")
        #expect(fixture.graph.recv(token: fixture.receiver.description) == .denied(.badToken))
        #expect(fixture.graph.waitingCount(of: fixture.receiver) == 1)
    }

    @Test func recvOnAnEmptyMailboxIsAnEmptyDrainRatherThanAnError() {
        var fixture = Fixture()
        #expect(fixture.recv() == .empty)
    }

    // MARK: The bounds

    @Test func theOldestMessageGoesWhenTheMailboxIsFull() {
        var fixture = Fixture()
        let overflow = 44
        for index in 0 ..< (ControlWire.maxMailboxMessages + overflow) {
            fixture.send("message \(index)")
        }

        #expect(fixture.graph.waitingCount(of: fixture.receiver)
            == ControlWire.maxMailboxMessages)

        let drain = fixture.recv()
        #expect(drain.dropped == overflow)
        // The oldest surviving message is the one after the last one dropped, so
        // the drop is from the front and the newest arrival is never the casualty.
        #expect(drain.messages.first?.text == "message \(overflow)")
    }

    /// Reported once, then reset. A drop count that repeated would have the reader
    /// chasing losses that already happened, and one that never appeared would
    /// have them concluding nothing was sent.
    @Test func theDropCountIsReportedByTheNextRecvAndThenReset() {
        var fixture = Fixture()
        for index in 0 ..< (ControlWire.maxMailboxMessages + 10) {
            fixture.send("message \(index)")
        }

        #expect(fixture.recv().dropped == 10)
        #expect(fixture.recv().dropped == 0)
    }

    @Test func aDrainStopsAtTheBatchCapAndSaysThereIsMore() {
        var fixture = Fixture()
        let sent = ControlWire.maxDrainBatch + 8
        for index in 0 ..< sent {
            fixture.send("message \(index)")
        }

        let drain = fixture.recv()
        #expect(drain.messages.count == ControlWire.maxDrainBatch)
        #expect(drain.more == true)
        #expect(fixture.graph.waitingCount(of: fixture.receiver)
            == sent - ControlWire.maxDrainBatch)
    }

    // MARK: The byte budget

    /// **A message leaves the mailbox only once it has been framed into a response
    /// that fits.** A drain that runs out of budget mid-batch answers with what
    /// fits and leaves the rest exactly where they were: `more` means "poll
    /// again", never "some are gone".
    ///
    /// The naive implementation, take 32 and hope, passes every count-shaped test
    /// above and loses everything past the cap here with `ok: true` on the way
    /// out.
    /// **The batch cap through the call the server actually makes.**
    ///
    /// Every other test here supplies `limit` and `budget`, including the
    /// fixture's own helper, which re-supplies the same two constants. The server
    /// supplies neither, so the defaulted path was the one path nothing
    /// exercised: changing `maxDrainBatch` to five would have left this suite
    /// green while every pane's `baia recv` quietly answered five. Found while
    /// pinning the same gap in `subscribe`, and it predates the ring.
    @Test func theDefaultedBatchCapIsTheOneTheServerGets() {
        var fixture = Fixture()
        for index in 0..<(ControlWire.maxDrainBatch + 5) {
            fixture.send("message \(index)")
        }

        switch fixture.graph.recv(token: fixture.receiverToken) {
        case let .ok(drain):
            #expect(drain.messages.count == ControlWire.maxDrainBatch)
            #expect(drain.more == true)
        case let .denied(error):
            Issue.record("recv was denied: \(error.message)")
        }
    }

    @Test func aDrainThatRunsOutOfBudgetLeavesTheRestInTheMailbox() {
        var fixture = Fixture()
        let sent = 20
        let body = String(repeating: "a", count: 20 * 1024)
        for index in 0 ..< sent {
            fixture.send("\(index):\(body)")
        }

        let drain = fixture.recv()
        #expect(drain.messages.isEmpty == false, "the drain made no progress at all")
        #expect(drain.messages.count < sent, "the whole batch fitted, so nothing was truncated")
        #expect(drain.more == true)
        #expect(fixture.graph.waitingCount(of: fixture.receiver) == sent - drain.messages.count)

        // What it did answer with is a frame the reader can accept.
        let size = ControlWire.drainFrameSize(messages: drain.messages, dropped: drain.dropped)
        #expect(size <= ControlWire.maxFrameBytes)
    }

    /// Nothing is lost across the polls, and nothing is reordered: what the sender
    /// sent is what the reader eventually reads, in that order.
    @Test func everyMessageSurvivesATruncatedDrainAndArrivesInOrder() {
        var fixture = Fixture()
        let body = String(repeating: "a", count: 20 * 1024)
        let sent = (0 ..< 20).map { "\($0):\(body)" }
        for text in sent {
            fixture.send(text)
        }

        var received: [String] = []
        var polls = 0
        while polls < 10 {
            polls += 1
            let drain = fixture.recv()
            received.append(contentsOf: drain.messages.map(\.text))
            if drain.more == false { break }
        }

        #expect(received == sent)
        #expect(fixture.graph.waitingCount(of: fixture.receiver) == 0)
    }

    /// **`send` refuses on the framed size and not on the payload size.**
    ///
    /// 48 KiB of U+0001 is inside the documented text budget and frames to more
    /// than 288 KiB, because JSON escaping spends six bytes on a control
    /// character. Accepting it would put a message in the mailbox that no `recv`
    /// could ever frame, blocking every message behind it for the life of the
    /// pane.
    @Test func sendRefusesAPayloadInsideTheTextBudgetThatNoResponseCouldFrame() {
        var fixture = Fixture()
        let text = String(repeating: "\u{01}", count: ControlWire.maxMessagePayloadBytes)
        #expect(text.utf8.count == ControlWire.maxMessagePayloadBytes)

        let framed = ControlWire.drainFrameSize(
            messages: [ControlMessage(from: fixture.sender.description, text: text)],
            dropped: ControlWire.maxMailboxMessages
        )
        // The arithmetic the spec's first draft got wrong, pinned rather than
        // asserted in prose: six bytes per control character, which is already
        // over the frame cap before the envelope is counted.
        #expect(framed > ControlWire.maxMessagePayloadBytes * 6)
        #expect(framed > ControlWire.maxFrameBytes)

        switch fixture.graph.send(
            token: fixture.senderToken,
            peer: fixture.receiver.description,
            text: text
        ) {
        case .ok:
            Issue.record("a message that no response can frame was accepted into a mailbox")
        case let .denied(error):
            #expect(error.code == .refused)
        }
        #expect(fixture.graph.waitingCount(of: fixture.receiver) == 0)
    }

    /// The documented text budget is enforced as well, so the row in the budget
    /// table is a number rather than a decoration.
    @Test func sendRefusesAPayloadOverTheTextBudgetEvenWhenItWouldFrame() {
        var fixture = Fixture()
        let text = String(repeating: "a", count: ControlWire.maxMessagePayloadBytes + 1)

        // It frames comfortably: this is the text cap talking and not the frame
        // cap.
        #expect(ControlWire.canBeDrained(
            ControlMessage(from: fixture.sender.description, text: text)
        ))

        switch fixture.graph.send(
            token: fixture.senderToken,
            peer: fixture.receiver.description,
            text: text
        ) {
        case .ok:
            Issue.record("the text budget was not enforced")
        case let .denied(error):
            #expect(error.code == .refused)
        }
        #expect(fixture.graph.waitingCount(of: fixture.receiver) == 0)
    }

    /// The two rules meet here: anything `send` accepts fits the first slot of a
    /// drain, so a mailbox always makes progress and no message can wedge the
    /// queue behind it.
    @Test func aMessageSendAcceptsAlwaysFitsTheFirstSlotOfADrain() {
        var fixture = Fixture()
        // As close to unframeable as `send` will still accept: 43,000 control
        // characters at six escaped bytes each, which is inside the frame cap by
        // a few thousand bytes and inside the text budget by six thousand. Two of
        // them cannot share a response, so the drain has to hand back one and
        // keep the other.
        let body = String(repeating: "\u{01}", count: 43_000)
        let first = "1" + body
        let second = "2" + body
        for text in [first, second] {
            #expect(text.utf8.count <= ControlWire.maxMessagePayloadBytes)
            #expect(ControlWire.canBeDrained(
                ControlMessage(from: fixture.sender.description, text: text)
            ))
            fixture.send(text)
        }

        let drain = fixture.recv()
        #expect(drain.messages.map(\.text) == [first], "a maximal message did not drain alone")
        #expect(drain.more == true)

        let rest = fixture.recv()
        #expect(rest.messages.map(\.text) == [second])
        #expect(rest.more == false)
    }

    // MARK: Lifetime

    @Test func closingAPaneDropsItsMailboxWithIt() {
        var fixture = Fixture()
        fixture.send("unread")
        fixture.graph.close(pane: fixture.receiver)

        #expect(fixture.graph.waitingCount(of: fixture.receiver) == 0)
        #expect(fixture.graph.mailboxes.isEmpty)
    }
}
