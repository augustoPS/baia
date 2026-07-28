import Foundation
import Testing

@testable import PaneControl

/// A record carries two fields that name panes other than the one it describes,
/// and both leaked past the scope rule until ``PaneRecord/redacted(toVisible:)``
/// existed. These pin the rule at the only layer `make test` can reach, since the
/// app target has no test bundle and the server that calls this is in it.
@Suite struct RecordRedactionTests {
    private func record(
        _ pane: String,
        createdBy: String? = nil,
        peers: [String] = []
    ) -> PaneRecord {
        PaneRecord(pane: pane, window: 1, tab: 1, createdBy: createdBy, peers: peers)
    }

    @Test func aParentTheCallerCannotSeeIsNotNamedByItsOwnRecord() {
        let redacted = record("self", createdBy: "parent").redacted(toVisible: ["self"])

        #expect(redacted.createdBy == nil)
    }

    @Test func aPaneLearnsWhichPanesItCreatedAndNeverWhichOneCreatedIt() {
        // The asymmetry is the whole rule: a scope is self, descendants and
        // peers, so a child is always in it and a parent never is. A record for
        // the child keeps createdBy because the value names the caller itself.
        let caller = record("caller", createdBy: "parent")
        let child = record("child", createdBy: "caller")
        let visible: Set<String> = ["caller", "child"]

        #expect(caller.redacted(toVisible: visible).createdBy == nil)
        #expect(child.redacted(toVisible: visible).createdBy == "caller")
    }

    @Test func aDescendantsPeersAreNamedOnlyWhereTheCallerCanAlreadySeeThem() {
        // The leak this closes. A descendant may peer with anything; the caller
        // has no edge to those panes and no scope over them, so their ids are
        // reconnaissance rather than information the caller was owed.
        let child = record("child", peers: ["stranger", "caller", "otherChild"])

        let redacted = child.redacted(toVisible: ["caller", "child", "otherChild"])

        #expect(redacted.peers == ["caller", "otherChild"])
    }

    @Test func aRecordNamingNobodyOutsideTheScopeIsUnchanged() {
        let untouched = record("caller", createdBy: nil, peers: ["peer"])

        #expect(untouched.redacted(toVisible: ["caller", "peer"]) == untouched)
    }

    @Test func redactionIsOmissionSoNothingConfirmsWhatWasWithheld() {
        // A withheld parent must not become a placeholder. A record saying
        // "createdBy: hidden" would confirm a parent exists, which is the fact
        // the redaction is keeping.
        let encoded = try! JSONEncoder().encode(
            record("self", createdBy: "parent").redacted(toVisible: ["self"])
        )
        let text = String(decoding: encoded, as: UTF8.self)

        #expect(!text.contains("createdBy"))
        #expect(!text.contains("parent"))
    }

    @Test func everythingIsRedactedAgainstAnEmptyScope() {
        let stripped = record("self", createdBy: "parent", peers: ["a", "b"])
            .redacted(toVisible: [])

        #expect(stripped.createdBy == nil)
        #expect(stripped.peers.isEmpty)
    }

    @Test func channelsSurviveBecauseTheyBelongToTheSubjectAndNameNoOtherPane() {
        // Deliberately not filtered. A published name is the subject's own, and
        // the caller can already see the subject or it would have no record at
        // all. Pinned so a later reader does not "fix" it into the filter.
        var published = record("child")
        published.channels = ["builder", "watcher"]

        #expect(published.redacted(toVisible: ["child"]).channels == ["builder", "watcher"])
    }
}
