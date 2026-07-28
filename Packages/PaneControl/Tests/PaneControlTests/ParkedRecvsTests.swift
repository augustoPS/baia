import Foundation
import Testing

@testable import PaneControl

/// One long poll per connection, and the pipelined second `recv` that used to
/// vanish.
///
/// The defect this suite exists for: two `recv --wait` frames on one connection,
/// which the NDJSON wire allows and `nc` produces without trying, silently
/// replaced the first waiter. Its request was then answered by no frame at all,
/// and its deadline stayed armed to resolve the *second* waiter early. Rule 5
/// permits one request with no response and it is already spent on the over-cap
/// line.
@Suite struct ParkedRecvsTests {
    /// A deadline stand-in, so the table can be exercised without a queue. The
    /// real server parks a `DispatchWorkItem`; the table has never cared which.
    struct Deadline: Equatable {
        let label: String
    }

    static func waiter(_ pane: ControlPaneID, _ label: String) -> ParkedRecvs<Deadline>.Waiter {
        let capability = "c1-not-a-uuid-\(label)"
        return ParkedRecvs<Deadline>.Waiter(
            pane: pane,
            token: capability,
            deadline: Deadline(label: label)
        )
    }

    // MARK: The rule

    @Test func a_second_park_on_one_connection_is_refused_and_leaves_the_first_alone() {
        let pane = ControlPaneID(rawValue: UUID())
        var parked = ParkedRecvs<Deadline>()

        #expect(parked.park(7, Self.waiter(pane, "first")) == .parked)
        #expect(parked.park(7, Self.waiter(pane, "second")) == .alreadyParked)

        // The incumbent, not the newcomer. A displaced waiter is a request nobody
        // answers and a deadline nobody cancels.
        #expect(parked[7]?.deadline == Deadline(label: "first"))
        #expect(parked.ids == [7])
    }

    /// Two `recv --wait` frames pipelined on one connection owe two response
    /// frames: the incumbent's, whenever it resolves, and the newcomer's refusal,
    /// immediately. This is the table's half of that, which is that the refusal is
    /// reported rather than swallowed and the incumbent survives to be answered.
    @Test func both_pipelined_recvs_have_an_answer_to_be_written() {
        let pane = ControlPaneID(rawValue: UUID())
        var parked = ParkedRecvs<Deadline>()

        var owed: [String] = []

        switch parked.park(3, Self.waiter(pane, "first")) {
        case .parked: break
        case .alreadyParked: owed.append("refused")
        }
        switch parked.park(3, Self.waiter(pane, "second")) {
        case .parked: break
        case .alreadyParked: owed.append("refused")
        }

        // The newcomer's frame is owed now.
        #expect(owed == ["refused"])

        // The incumbent's frame is owed when it resolves, and it is still there to
        // resolve.
        let resolved = parked.remove(3)
        #expect(resolved?.deadline == Deadline(label: "first"))
        #expect(parked.isEmpty)
    }

    @Test func a_removed_waiter_is_handed_back_so_its_deadline_can_be_cancelled() {
        let pane = ControlPaneID(rawValue: UUID())
        var parked = ParkedRecvs<Deadline>()
        _ = parked.park(1, Self.waiter(pane, "only"))

        #expect(parked.remove(1)?.deadline == Deadline(label: "only"))
        #expect(parked.remove(1) == nil)
        #expect(parked[1] == nil)
    }

    @Test func parking_again_after_the_first_resolved_is_allowed() {
        let pane = ControlPaneID(rawValue: UUID())
        var parked = ParkedRecvs<Deadline>()

        _ = parked.park(4, Self.waiter(pane, "first"))
        parked.remove(4)

        #expect(parked.park(4, Self.waiter(pane, "second")) == .parked)
        #expect(parked[4]?.deadline == Deadline(label: "second"))
    }

    // MARK: Who is parked, and who is oldest

    @Test func ids_are_ordered_by_connection_id_which_is_accept_order() {
        let pane = ControlPaneID(rawValue: UUID())
        var parked = ParkedRecvs<Deadline>()

        for id in [9, 2, 5] {
            _ = parked.park(id, Self.waiter(pane, "\(id)"))
        }

        #expect(parked.ids == [2, 5, 9])
    }

    @Test func waiters_are_findable_by_pane_and_the_oldest_is_the_lowest_id() {
        let mine = ControlPaneID(rawValue: UUID())
        let theirs = ControlPaneID(rawValue: UUID())
        var parked = ParkedRecvs<Deadline>()

        _ = parked.park(2, Self.waiter(theirs, "theirs"))
        _ = parked.park(6, Self.waiter(mine, "mine-late"))
        _ = parked.park(4, Self.waiter(mine, "mine-early"))

        #expect(parked.ids(of: mine) == [4, 6])
        #expect(parked.oldest(of: mine) == 4)

        // Unrestricted, for the pool eviction that takes whatever it can get.
        #expect(parked.oldest(of: nil) == 2)
    }

    @Test func an_empty_table_has_nothing_to_evict() {
        let parked = ParkedRecvs<Deadline>()
        #expect(parked.isEmpty)
        #expect(parked.oldest(of: nil) == nil)
        #expect(parked.ids.isEmpty)
    }
}
