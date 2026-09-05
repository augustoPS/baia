import Foundation
import Testing

@testable import WorkspaceLayout

/// The group-identity policy: which id a group keeps when the windows are captured
/// again.
///
/// Every test here is a gesture the owner can make — leave the workspace alone,
/// drag a tab out, merge two windows, open a new one — asked as "what should the
/// groups be called afterwards". The two properties that have to hold across all of
/// them are that an unchanged workspace is stable and that no two groups ever share
/// an id.
@Suite struct WindowGroupIdentityTests {
    /// Predictable new ids, so a test can assert *which* group got a fresh one
    /// rather than only that some id appeared.
    private final class Minter {
        private var issued = 0
        var count: Int { issued }
        func next() -> UUID {
            issued += 1
            return UUID(uuidString: "FFFFFFFF-0000-0000-0000-\(String(format: "%012d", issued))")!
        }
    }

    // MARK: Stability

    /// **The reason ids are not minted at capture.** Capturing twice with nothing
    /// changed produces the same ids, so the id names a group across saves rather
    /// than naming one save.
    @Test func repeatCaptureWithNoChangesKeepsTheSameIDs() {
        let left = UUID()
        let right = UUID()
        let claims = [[Optional(left), Optional(left)], [Optional(right)]]

        let minter = Minter()
        let first = WindowGroupIdentity.resolve(groups: claims, fresh: minter.next)
        let second = WindowGroupIdentity.resolve(groups: claims, fresh: minter.next)

        #expect(first == [left, right])
        #expect(second == first)
        // Nothing was minted at all, which is the sharper statement: a stable
        // workspace does not consume identity.
        #expect(minter.count == 0)
    }

    /// A group whose windows all claim the same id keeps it, however many tabs.
    @Test func anUnchangedGroupKeepsItsID() {
        let id = UUID()

        let resolved = WindowGroupIdentity.resolve(groups: [[id, id, id]])

        #expect(resolved == [id])
    }

    // MARK: New windows

    /// A window that has never been written has no claim, so its group is new.
    @Test func aGroupOfBrandNewWindowsGetsAFreshID() {
        let minter = Minter()

        let resolved = WindowGroupIdentity.resolve(groups: [[nil]], fresh: minter.next)

        #expect(resolved.count == 1)
        #expect(minter.count == 1)
    }

    /// A tab opened into an existing group does not renew that group's id: the
    /// group is the same group, now with one more tab.
    @Test func aNewTabInAnExistingGroupDoesNotChangeTheGroupsID() {
        let id = UUID()
        let minter = Minter()

        let resolved = WindowGroupIdentity.resolve(groups: [[id, nil]], fresh: minter.next)

        #expect(resolved == [id])
        #expect(minter.count == 0)
    }

    /// Even when the new tab is leftmost. The first *claim* in tab-bar order decides,
    /// not the first window, so inserting a tab at the front does not orphan the
    /// group's identity.
    @Test func aNewTabAtTheFrontOfAGroupStillKeepsTheGroupsID() {
        let id = UUID()
        let minter = Minter()

        let resolved = WindowGroupIdentity.resolve(groups: [[nil, id]], fresh: minter.next)

        #expect(resolved == [id])
        #expect(minter.count == 0)
    }

    // MARK: Merge

    /// Merge All Windows puts windows claiming different ids into one group. One id
    /// survives, and which one does not depend on hash order: it is the claim of the
    /// group's first window in tab-bar order.
    @Test func aMergeKeepsTheFirstWindowsIDDeterministically() {
        let left = UUID()
        let right = UUID()

        let resolved = WindowGroupIdentity.resolve(groups: [[left, left, right]])

        #expect(resolved == [left])
    }

    /// The same merge in the other order keeps the other id, and keeps it every
    /// time. The property being asserted is determinism, not which one wins.
    @Test func aMergeIsDeterministicWhicheverWindowLeads() {
        let left = UUID()
        let right = UUID()

        let once = WindowGroupIdentity.resolve(groups: [[right, left, left]])
        let again = WindowGroupIdentity.resolve(groups: [[right, left, left]])

        #expect(once == [right])
        #expect(again == once)
    }

    /// After a merge the surviving id is stable: capturing the merged group again
    /// does not mint another one.
    @Test func aMergedGroupIsStableOnTheNextCapture() {
        let left = UUID()
        let right = UUID()
        let minter = Minter()

        let merged = WindowGroupIdentity.resolve(groups: [[left, left, right]], fresh: minter.next)
        // Every window now claims the surviving id, which is what the app writes back.
        let again = WindowGroupIdentity.resolve(
            groups: [merged.map { Optional($0) } + [merged[0]]],
            fresh: minter.next
        )

        #expect(again == merged)
        #expect(minter.count == 0)
    }

    /// A tab dragged into another group still claims its old group's id. It does
    /// not carry that id in: the group it left owns it by count, and the group it
    /// joined keeps its own, even when the arriving tab landed leftmost.
    @Test func aTabMergedIntoAnotherGroupDoesNotCarryItsOldGroupsIDIn() {
        let left = UUID()
        let right = UUID()
        let minter = Minter()

        // One of three `left` tabs was dropped at the front of the `right` group.
        let resolved = WindowGroupIdentity.resolve(
            groups: [[left, left], [left, right, right]],
            fresh: minter.next
        )

        #expect(resolved == [left, right])
        #expect(minter.count == 0)
    }

    // MARK: Detach

    /// **The id stays with the group that kept more tabs.** A tab dragged out of a
    /// three-tab group still claims that group's id, and so do the two that
    /// stayed. Two claims outweigh one, whichever group the walk meets first, so the
    /// detached tab is the one that takes a fresh id.
    @Test func aDetachedTabTakesAFreshIDAndTheGroupItLeftKeepsItsOwn() {
        let original = UUID()
        let minter = Minter()

        let detachedFirst = WindowGroupIdentity.resolve(
            groups: [[original], [original, original]],
            fresh: minter.next
        )
        let detachedLast = WindowGroupIdentity.resolve(
            groups: [[original, original], [original]],
            fresh: minter.next
        )

        #expect(detachedFirst[1] == original)
        #expect(detachedFirst[0] != original)
        #expect(detachedLast[0] == original)
        #expect(detachedLast[1] != original)
        #expect(minter.count == 2)
    }

    /// **The tie, recorded as a limit.** Detaching one tab from a two-tab group
    /// leaves two one-window groups with the same claim, and nothing in the claims
    /// says which one was left. The earlier walk position keeps the id, which in the
    /// app is the group holding the older window. The invariants still hold: one
    /// keeps it, the other is fresh, and the answer is the same every time.
    @Test func aTwoTabDetachIsATieThatTheEarlierWalkedGroupWins() {
        let original = UUID()
        let minter = Minter()

        let resolved = WindowGroupIdentity.resolve(
            groups: [[original], [original]],
            fresh: minter.next
        )
        let again = WindowGroupIdentity.resolve(
            groups: [[original], [original]],
            fresh: minter.next
        )

        #expect(resolved[0] == original)
        #expect(resolved[1] != original)
        #expect(Set(resolved).count == 2)
        #expect(again[0] == resolved[0])
        #expect(minter.count == 2)
    }

    /// Detaching from a group that then closes still yields one group holding the
    /// original id, rather than two groups fighting over it.
    @Test func noTwoGroupsEverShareAnID() {
        let shared = UUID()

        let resolved = WindowGroupIdentity.resolve(groups: [[shared], [shared], [shared], [shared]])

        #expect(Set(resolved).count == 4)
        #expect(resolved.filter { $0 == shared }.count == 1)
    }

    /// The detached group is stable from its second capture on: once it has been
    /// written under its new id, nothing mints again.
    @Test func aDetachedGroupIsStableOnTheNextCapture() {
        let original = UUID()
        let minter = Minter()

        let first = WindowGroupIdentity.resolve(groups: [[original], [original]], fresh: minter.next)
        let second = WindowGroupIdentity.resolve(
            groups: [[first[0]], [first[1]]],
            fresh: minter.next
        )

        #expect(second == first)
        #expect(minter.count == 1)
    }

    // MARK: Degenerate inputs

    /// A `fresh` that repeats itself cannot alias two groups, which is the one thing
    /// the policy exists to prevent.
    @Test func aRepeatingMinterStillCannotProduceTwoGroupsWithOneID() {
        var issued = 0
        let repeated = UUID()
        let alternative = UUID()

        let resolved = WindowGroupIdentity.resolve(groups: [[nil], [nil]], fresh: {
            issued += 1
            return issued < 3 ? repeated : alternative
        })

        #expect(Set(resolved).count == 2)
    }

    @Test func noGroupsResolvesToNoIDs() {
        #expect(WindowGroupIdentity.resolve(groups: []).isEmpty)
    }

    /// A group whose windows all claim nothing, beside one that claims an id.
    @Test func aFreshGroupBesideAKnownOneLeavesTheKnownOneAlone() {
        let known = UUID()
        let minter = Minter()

        let resolved = WindowGroupIdentity.resolve(groups: [[nil, nil], [known]], fresh: minter.next)

        #expect(resolved[1] == known)
        #expect(resolved[0] != known)
        #expect(minter.count == 1)
    }
}
