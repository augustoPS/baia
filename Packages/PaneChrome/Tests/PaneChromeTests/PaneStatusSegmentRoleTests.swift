import Foundation
import Testing

@testable import PaneChrome

/// The role-to-group mapping, which lived in the bar-metrics suite until
/// 2026-08-13 because the bar was the only thing that spent it. It is a property
/// of `PaneStatusSegmentRole` and never was a metric, so it moved here rather
/// than dying with the metrics that did belong to the footer.
@Suite struct PaneStatusSegmentRoleTests {
    /// The mapping is derived from the role so that two call sites cannot
    /// disagree about it. This is the assertion that a role added later was
    /// actually placed in a group rather than left to fall through.
    ///
    /// **The version this replaces asserted four counts and there were five
    /// groups.** `.notice` arrived with the capsule and no line here mentioned
    /// it, so the test that exists to catch an unplaced role would not have
    /// caught the last role added. Counted against `allCases` now, which is the
    /// only form that cannot drift: a new role either lands in a group whose
    /// count is stated below, or the total stops matching.
    @Test func everyRoleBelongsToExactlyOneGroup() {
        let grouped = Dictionary(
            grouping: PaneStatusSegmentRole.allCases,
            by: { $0.group }
        )
        #expect(grouped[.identity]?.count == 2)
        #expect(grouped[.repository]?.count == 3)
        #expect(grouped[.agent]?.count == 1)
        #expect(grouped[.context]?.count == 1)
        #expect(grouped[.notice]?.count == 1)

        // Every role is accounted for above. Without this, adding a role to a
        // group already named here leaves every count still passing.
        #expect(grouped.values.map(\.count).reduce(0, +) == PaneStatusSegmentRole.allCases.count)
    }
}
