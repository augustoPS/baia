import Foundation

/// Which id a group keeps when the windows are captured again.
///
/// Group identity cannot be minted at capture time. `UUID()` on every snapshot
/// means a workspace nobody touched writes a different id on every coalesced save,
/// so the id names nothing: it cannot be compared across saves, and any later
/// feature that wants to say "this group" — a per-group setting, a restore that
/// matches a live window to a recorded one — has no handle to say it with.
///
/// It also cannot come from AppKit. `NSWindowTabGroup` has no stable identifier,
/// and the group object itself is replaced when a tab is dragged out and when two
/// windows are merged.
///
/// So identity is carried by the windows and reconciled here at capture. Each
/// window remembers the id of the group it was last written as part of, and this
/// decides what the group it is in *now* should be called.
///
/// **The policy: an id belongs to the group with the most windows claiming it.**
/// Ties go to the group walked first. Each group then keeps the first id in its
/// tab-bar order that it owns, or takes a fresh one. The case each clause exists for:
///
/// - *Unchanged:* every window in the group claims the same id, so the group owns
///   it and keeps it. This is the common case and the one that makes repeat capture
///   stable: two saves of an untouched workspace produce the same ids.
/// - *Detach:* a tab dragged out still claims the id of the group it left, and so
///   does every tab that stayed. The group that kept more tabs owns the id, and the
///   detached tab takes a fresh one, whichever of the two the walk met first. **Two
///   groups never share an id**, which is what makes the id usable as a key at all.
/// - *Merge:* the windows claim several ids, which is what Merge All Windows and a
///   drag-in produce. One survives, chosen deterministically as the first id in the
///   group's tab-bar order that the group owns, so the same merge always yields the
///   same answer rather than depending on dictionary order. A single tab dragged
///   into another group does not carry its old group's id with it: the group it
///   left still owns that id by count.
/// - *New:* a window that claims nothing has never been written; a group of such
///   windows takes a fresh id.
///
/// **What cannot be decided, stated rather than hidden.** Detaching one tab from a
/// group of two leaves two groups each claiming the same id with one window. The
/// claims cannot say which of them is the group that was left, and nothing else at
/// capture can either: AppKit does not report the history, and the caller's walk is
/// the order its controllers were created in, not the order the owner arranged. The
/// tie goes to the group walked first, which is the one holding the older window.
/// The invariants hold either way; the only thing at stake is which of two
/// one-tab groups keeps the handle, and that is recorded here as a limit rather
/// than dressed up as a rule.
///
/// Pure and window-free, so the policy is testable without an `NSWindow`. The app
/// supplies the claims and stores the answers back onto its controllers.
public enum WindowGroupIdentity {
    /// Assigns an id to each captured group.
    ///
    /// - Parameter groups: the claims of each group's windows, in tab-bar order,
    ///   with nil for a window that has never been written. The outer order is the
    ///   order the groups were walked, and it decides ties only.
    /// - Parameter fresh: mints a new id. A parameter so a test can make the new
    ///   ids predictable and assert *which* group got one.
    ///
    /// - Returns: one id per group, in the same order.
    public static func resolve(
        groups: [[UUID?]],
        fresh: () -> UUID = { UUID() }
    ) -> [UUID] {
        // Ownership first, over every group, so a group visited early cannot take an
        // id from a group visited later that has more windows claiming it. A later
        // group needs strictly more claims to take an id over, which is the tie
        // rule: equal counts stay with the earlier walk position.
        var owner: [UUID: (group: Int, count: Int)] = [:]
        for (index, claims) in groups.enumerated() {
            var counts: [UUID: Int] = [:]
            for case let id? in claims { counts[id, default: 0] += 1 }
            for (id, count) in counts where count > (owner[id]?.count ?? 0) {
                owner[id] = (index, count)
            }
        }

        var taken: Set<UUID> = []
        var resolved: [UUID] = []
        for (index, claims) in groups.enumerated() {
            // The first owned claim in tab-bar order is the deterministic survivor
            // of a merge. Owned, not merely claimed: a tab that arrived from another
            // group still claims that group's id and must not carry it in.
            let candidate = claims.compactMap { $0 }.first { owner[$0]?.group == index }
            if let candidate, taken.insert(candidate).inserted {
                resolved.append(candidate)
            } else {
                // Nothing claimed, or nothing this group owns: a new window, a
                // detached tab, or the loser of a tie. All get a new id.
                var new = fresh()
                // A `fresh` that repeats itself would silently alias two groups,
                // which is the one thing this function exists to prevent.
                while !taken.insert(new).inserted { new = fresh() }
                resolved.append(new)
            }
        }
        return resolved
    }
}
