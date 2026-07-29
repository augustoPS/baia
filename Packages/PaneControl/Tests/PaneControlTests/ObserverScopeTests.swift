import Foundation
import Testing

@testable import PaneControl

/// `observers` and `authorize` are two readers of one rule, and two readers is
/// what lets one of them be wrong. This suite is why a second reader is
/// acceptable at all.
@Suite struct ObserverScopeTests {
    /// A parent, its child, its grandchild, a peer of the parent, and a stranger.
    struct Fixture {
        static func capability(_ label: String) -> String { "c1-not-a-uuid-\(label)" }

        var graph = PaneGraph()
        let parent = ControlPaneID(rawValue: UUID())
        let child = ControlPaneID(rawValue: UUID())
        let grandchild = ControlPaneID(rawValue: UUID())
        let peer = ControlPaneID(rawValue: UUID())
        let stranger = ControlPaneID(rawValue: UUID())

        var tokens: [ControlPaneID: String] = [:]

        init() {
            let all = [
                ("parent", parent), ("child", child), ("grandchild", grandchild),
                ("peer", peer), ("stranger", stranger),
            ]
            for (label, pane) in all {
                let capability = Fixture.capability(label)
                tokens[pane] = capability
                let creator: ControlPaneID? = switch label {
                case "child": parent
                case "grandchild": child
                default: nil
                }
                graph.open(pane: pane, createdBy: creator, secret: PaneSecret(capability))
            }
            graph.addPeerEdge(between: parent, and: peer)
        }

        var everyPane: [ControlPaneID] { [parent, child, grandchild, peer, stranger] }
    }

    /// The property. For every ordered pair, being in the audience and being
    /// allowed to `list` are the same fact.
    @Test func observersAgreesWithAuthorizeForEveryPair() {
        let fixture = Fixture()
        for subject in fixture.everyPane {
            let audience = fixture.graph.observers(of: subject)
            for actor in fixture.everyPane {
                let allowed: Bool
                switch fixture.graph.authorize(
                    token: fixture.tokens[actor]!, verb: .list, target: subject
                ) {
                case .allowed: allowed = true
                case .denied: allowed = false
                }
                #expect(
                    audience.contains(actor) == allowed,
                    "actor \(actor) and subject \(subject) disagree"
                )
            }
        }
    }

    @Test func theAudienceIsSelfAncestorsAndPeers() {
        let fixture = Fixture()
        #expect(fixture.graph.observers(of: fixture.grandchild) == [
            fixture.grandchild, fixture.child, fixture.parent,
        ])
        #expect(fixture.graph.observers(of: fixture.parent) == [
            fixture.parent, fixture.peer,
        ])
        #expect(fixture.graph.observers(of: fixture.stranger) == [fixture.stranger])
    }

    /// A cycle cannot be built through the public API, and an unbounded walk on a
    /// path the app runs per event would be a hang rather than a wrong answer.
    @Test func theWalkTerminatesOnAPlantedCycle() {
        var graph = PaneGraph()
        let a = ControlPaneID(rawValue: UUID())
        let b = ControlPaneID(rawValue: UUID())
        graph.open(pane: a, createdBy: nil, secret: PaneSecret("c1-not-a-uuid-a"))
        graph.open(pane: b, createdBy: nil, secret: PaneSecret("c1-not-a-uuid-b"))
        graph.parentOf[a] = b
        graph.parentOf[b] = a

        #expect(graph.observers(of: a) == [a, b])
    }

    /// The ordering invariant, and the case the whole audience design exists for.
    /// Emitting before the teardown is what puts the parent in the audience.
    @Test func aCloseEmittedBeforeTeardownReachesTheParent() {
        var fixture = Fixture()
        fixture.graph.emit(
            .paneClosed, pane: fixture.child, createdBy: nil, message: nil, activity: nil
        )
        fixture.graph.close(pane: fixture.child)

        switch fixture.graph.subscribe(token: fixture.tokens[fixture.parent]!, from: 0) {
        case let .ok(batch):
            #expect(batch.events.map(\.kind) == [.paneClosed])
            #expect(batch.events.first?.pane == fixture.child.description)
        case let .denied(error):
            Issue.record("the parent was denied: \(error.message)")
        }
    }

    /// The same invariant failing, recorded as a test so the ordering is not
    /// something a reader has to infer from a doc comment.
    @Test func aCloseEmittedAfterTeardownReachesNobodyButItself() {
        var fixture = Fixture()
        fixture.graph.close(pane: fixture.child)
        fixture.graph.emit(
            .paneClosed, pane: fixture.child, createdBy: nil, message: nil, activity: nil
        )

        switch fixture.graph.subscribe(token: fixture.tokens[fixture.parent]!, from: 0) {
        case let .ok(batch):
            #expect(batch.events.isEmpty)
        case let .denied(error):
            Issue.record("the parent was denied: \(error.message)")
        }
    }

    /// The mirror invariant: an open is emitted after the registration, so the
    /// parentage exists to put the parent in the audience.
    @Test func anOpenEmittedAfterRegistrationReachesTheParent() {
        var fixture = Fixture()
        let fresh = ControlPaneID(rawValue: UUID())
        fixture.graph.open(
            pane: fresh,
            createdBy: fixture.parent,
            secret: PaneSecret(Fixture.capability("fresh"))
        )
        fixture.graph.emit(
            .paneOpened, pane: fresh, createdBy: fixture.parent, message: nil, activity: nil
        )

        switch fixture.graph.subscribe(token: fixture.tokens[fixture.parent]!, from: 0) {
        case let .ok(batch):
            #expect(batch.events.map(\.kind) == [.paneOpened])
            #expect(batch.events.first?.createdBy == fixture.parent.description)
        case let .denied(error):
            Issue.record("the parent was denied: \(error.message)")
        }
    }

    /// A pane is not told who created it, on the stream any more than anywhere
    /// else.
    ///
    /// ``PaneRecord/redacted(toVisible:)`` already drops `createdBy` from `list`
    /// and from `whoami` for this exact reader, because a pane's scope is itself,
    /// its descendants and its peers, and a parent is in none of the three. An
    /// event is one more read of the same records, so it answers the same way or
    /// the branch ships two rules for one field.
    @Test func theSubjectIsNotToldWhoCreatedIt() {
        var fixture = Fixture()
        fixture.graph.emit(
            .paneOpened,
            pane: fixture.child,
            createdBy: fixture.parent,
            message: nil,
            activity: nil
        )

        switch fixture.graph.subscribe(token: fixture.tokens[fixture.child]!, from: 0) {
        case let .ok(batch):
            #expect(batch.events.map(\.kind) == [.paneOpened])
            #expect(batch.events.first?.createdBy == nil)
        case let .denied(error):
            Issue.record("the subject was denied: \(error.message)")
        }
    }

    /// The wider half of the same disclosure. A peer of the subject is in the
    /// subject's audience and has no edge at all to the subject's creator, so it
    /// reads the event and not the id.
    @Test func aPeerOfTheSubjectIsNotToldWhoCreatedIt() {
        var fixture = Fixture()
        fixture.graph.addPeerEdge(between: fixture.child, and: fixture.stranger)
        fixture.graph.emit(
            .paneOpened,
            pane: fixture.child,
            createdBy: fixture.parent,
            message: nil,
            activity: nil
        )

        switch fixture.graph.subscribe(token: fixture.tokens[fixture.stranger]!, from: 0) {
        case let .ok(batch):
            #expect(batch.events.map(\.kind) == [.paneOpened])
            #expect(batch.events.first?.createdBy == nil)
        case let .denied(error):
            Issue.record("the peer was denied: \(error.message)")
        }
    }

    /// One entry, two entitlements, which is why the redaction is at the read and
    /// not at the emit. The grandparent may `list` the creator and reads the id;
    /// the subject reads the same entry with the field gone.
    @Test func anAncestorAboveTheCreatorStillReadsTheId() {
        var fixture = Fixture()
        fixture.graph.emit(
            .paneOpened,
            pane: fixture.grandchild,
            createdBy: fixture.child,
            message: nil,
            activity: nil
        )

        switch fixture.graph.subscribe(token: fixture.tokens[fixture.parent]!, from: 0) {
        case let .ok(batch):
            #expect(batch.events.first?.createdBy == fixture.child.description)
        case let .denied(error):
            Issue.record("the grandparent was denied: \(error.message)")
        }

        switch fixture.graph.subscribe(token: fixture.tokens[fixture.grandchild]!, from: 0) {
        case let .ok(batch):
            #expect(batch.events.first?.createdBy == nil)
        case let .denied(error):
            Issue.record("the subject was denied: \(error.message)")
        }
    }

    /// The negative invariant the whole capability model rests on, restated for
    /// the new verb: a token that parses as a pane id is refused before the
    /// registry is consulted.
    @Test func aPaneIdShapedTokenIsRefusedBeforeTheRingIsTouched() {
        var fixture = Fixture()
        fixture.graph.emit(
            .paneOpened, pane: fixture.child, createdBy: nil, message: nil, activity: nil
        )

        switch fixture.graph.subscribe(token: fixture.parent.description, from: 0) {
        case .ok:
            Issue.record("a pane-id-shaped token was accepted")
        case let .denied(error):
            #expect(error.code == .badToken)
        }
    }

    @Test func theCurrentSequenceIsWhatListWillReport() {
        var fixture = Fixture()
        #expect(fixture.graph.currentSequence == 0)
        fixture.graph.emit(
            .paneOpened, pane: fixture.child, createdBy: nil, message: nil, activity: nil
        )
        #expect(fixture.graph.currentSequence == 1)
    }
}
