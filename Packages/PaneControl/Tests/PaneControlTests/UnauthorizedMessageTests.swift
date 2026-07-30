import Foundation
import Testing

@testable import PaneControl

/// What a refusal *says*, as opposed to what it answers.
///
/// The matrix suite next door asserts codes, and a code is what a script branches
/// on. This asserts the sentence, which is what a person reads at 2am, and the two
/// are separate suites because they fail for different reasons: a wrong code is a
/// scope bug and a wrong sentence is a scope bug that already shipped correct
/// behaviour and described it wrongly.
///
/// The bug that produced this suite: one shared message, written for `scopedRead`,
/// recited at every scope. `send` travels a peer edge alone, and its refusal told
/// the caller it could reach "the panes it created", which is a set `send` has
/// never been able to reach. A reader who believed it would go looking for a
/// parentage bug that was not there.
@Suite struct UnauthorizedMessageTests {
    /// Reused rather than rebuilt. A second fixture is a second thing to keep
    /// true, and the relationships this needs are the ones that suite already
    /// stands up.
    typealias Fixture = AuthorizationMatrixTests.Fixture

    /// The clause each scope's sentence has to carry, and the clauses it must not.
    ///
    /// Written as substrings rather than as the whole message so a wording change
    /// does not fail this, and so what is being asserted stays legible: the claim
    /// is about which *set of panes* the sentence names, not about its prose.
    static func expectation(for scope: ControlScope) -> (says: String, neverSays: [String]) {
        switch scope {
        case .selfOnly:
            ("reaches no other", ["the panes it created", "peered with"])
        case .scopedRead:
            ("the panes it created, and the panes it has peered with", [])
        case .peerEdge:
            ("only the panes it has peered with", ["the panes it created"])
        case .descendant:
            ("does not carry control", ["reaches no other"])
        }
    }

    /// Every verb's refusal describes that verb's own reach.
    ///
    /// Driven from ``ControlVerb/allCases`` rather than from a list written here,
    /// so a verb added tomorrow is asserted the day it exists. It cannot be
    /// skipped either: a verb with no scope fails to compile in
    /// ``ControlVerb/scope``, which has no `default:`.
    @Test func everyVerbsRefusalDescribesItsOwnReach() {
        for verb in ControlVerb.allCases {
            let error = ControlError.unauthorized(verb.scope)
            let expected = Self.expectation(for: verb.scope)

            #expect(
                error.message.contains(expected.says),
                "\(verb.rawValue) is \(verb.scope) and its refusal does not say so: \(error.message)"
            )
            for wrong in expected.neverSays {
                #expect(
                    error.message.contains(wrong) == false,
                    "\(verb.rawValue) is \(verb.scope) and its refusal claims \"\(wrong)\": \(error.message)"
                )
            }
            #expect(error.code == .unauthorized, "\(verb.rawValue) changed code, not just wording")
        }
    }

    /// The regression, named.
    ///
    /// `send` reaches peers and nothing else, so the one clause it must never
    /// carry is the one it carried until this suite existed.
    @Test func sendDoesNotReciteParentage() {
        let message = ControlError.unauthorized(ControlVerb.send.scope).message
        #expect(message.contains("the panes it created") == false)
        #expect(message.contains("only the panes it has peered with"))
    }

    /// `read` and `run` follow parentage and explicitly do not follow peering, so
    /// their refusal has to say the opposite of `send`'s rather than the same
    /// thing in other words.
    @Test func controlFollowsParentageAndSaysWhyPeeringDoesNotCount() {
        for verb in [ControlVerb.read, .run] {
            let message = ControlError.unauthorized(verb.scope).message
            #expect(message.contains("the panes it created, transitively"))
            #expect(message.contains("does not carry control"))
        }
    }

    // MARK: The property the split had to preserve

    /// **The reason a single shared message existed.** For one verb, every way of
    /// being refused answers byte-identically: a live pane out of scope, a pane
    /// that is not open, and a string that is not a pane id at all.
    ///
    /// Splitting the message four ways is safe only because a scope is a property
    /// of the verb the caller chose and already knows. Varying it per *target*
    /// would hand a caller an oracle over id space, and the liveness check inside
    /// `authorize` is where that would happen first, since it returns before the
    /// scope switch is ever reached.
    @Test func sendRefusesEveryWayWithTheSameSentence() {
        let fixture = Fixture()
        // A copy, because `PaneGraph` is a value type and the fixture holds it as
        // a `let`. The ids stay the fixture's, which is the point: a second
        // `Fixture()` would mint different panes.
        var graph = fixture.graph
        let caller = Fixture.capability("root").rawValue

        // A live pane the caller has no edge to.
        let outOfScope = graph.send(
            token: caller,
            peer: fixture.unrelated.description,
            text: "hello"
        )
        // A pane that was open and is not any more.
        let notLive = graph.send(
            token: caller,
            peer: fixture.closed.description,
            text: "hello"
        )
        // Not a pane id at all, refused before `authorize` is consulted.
        let malformed = graph.send(
            token: caller,
            peer: "not-a-uuid",
            text: "hello"
        )
        // A peer whose edge was revoked, which is the one a caller is most likely
        // to be holding an id for.
        let revoked = graph.send(
            token: caller,
            peer: fixture.revoked.description,
            text: "hello"
        )

        let messages = [outOfScope, notLive, malformed, revoked].map { Self.refusal($0) }
        #expect(Set(messages).count == 1, "send's four refusals differ, which is an oracle: \(messages)")
        #expect(messages[0]?.contains("only the panes it has peered with") == true)
    }

    /// The same property for `revoke`, which shares `send`'s scope and its own
    /// early return for a malformed id. Two spellings of one sentence is how the
    /// two would drift apart.
    @Test func revokeRefusesEveryWayWithTheSameSentence() {
        let fixture = Fixture()
        // A copy, because `PaneGraph` is a value type and the fixture holds it as
        // a `let`. The ids stay the fixture's, which is the point: a second
        // `Fixture()` would mint different panes.
        var graph = fixture.graph
        let caller = Fixture.capability("root").rawValue

        let messages = [
            graph.revoke(token: caller, peer: fixture.unrelated.description),
            graph.revoke(token: caller, peer: fixture.closed.description),
            graph.revoke(token: caller, peer: "not-a-uuid"),
        ].map { Self.refusal($0) }

        #expect(Set(messages).count == 1, "revoke's refusals differ: \(messages)")
        #expect(messages[0]?.contains("only the panes it has peered with") == true)
    }

    /// A refused outcome's sentence, or nil for an outcome that was not refused.
    ///
    /// Nil rather than a fatal error so a test that accidentally succeeds fails on
    /// the comparison with something readable in it, rather than taking the suite
    /// down.
    static func refusal<T>(_ outcome: ControlOutcome<T>) -> String? {
        guard case let .denied(error) = outcome else { return nil }
        return error.message
    }
}
