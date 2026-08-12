import Testing
@testable import PaneChrome

@Suite struct PaneClusterLayoutTests {
    private let segments: [PaneClusterSegment] = [
        .init(role: .place, text: "design-v6-native"),
        .init(role: .changes, text: "↑1*?3"),
        .init(role: .agent, text: "claude"),
        .init(role: .attention, text: ""),
    ]

    private let widths: [PaneClusterSegmentRole: Double] = [
        .place: 100, .changes: 40, .agent: 44,
        .attention: PaneClusterMetrics.dotDiameter,
    ]

    @Test func segmentsPlaceLeftToRightInsideThePill() {
        let placed = PaneClusterLayout.solve(segments: segments, widths: widths)
        #expect(placed.map(\.segment.role) == segments.map(\.role))
        #expect(placed.first?.x == PaneClusterMetrics.horizontalInset)
        for pair in zip(placed, placed.dropFirst()) {
            #expect(pair.0.x + pair.0.width <= pair.1.x)
        }
    }

    @Test func pillWidthClosesWithTheTrailingInset() {
        let placed = PaneClusterLayout.solve(segments: segments, widths: widths)
        let last = placed.last!
        let expected = last.x + last.width + PaneClusterMetrics.horizontalInset
        #expect(PaneClusterLayout.pillWidth(for: placed) == expected)
        #expect(PaneClusterLayout.pillWidth(for: []) == 0)
    }

    @Test func hitTestResolvesTheSegmentUnderX() {
        let placed = PaneClusterLayout.solve(segments: segments, widths: widths)
        let changes = placed[1]
        #expect(PaneClusterLayout.segment(at: changes.x + 1, in: placed)?.role == .changes)
        #expect(PaneClusterLayout.segment(at: -5, in: placed) == nil)
        // The gap between two segments belongs to neither: a click there
        // opens nothing rather than whichever card is luckier.
        let gapX = changes.x + changes.width + PaneClusterMetrics.segmentGap / 2
        #expect(PaneClusterLayout.segment(at: gapX, in: placed) == nil)
    }

    // MARK: - The spawn arrangement

    // The full truth table, all four cells, because the answer freezes into a
    // pane for its whole lifetime: a wrong cell here is a pane spawned with
    // the wrong bottom edge, and nothing downstream may correct it without
    // resizing a live grid.

    @Test func aClusterOnlySpawnUnderFlatRunsClearToTheBottom() {
        #expect(
            PaneClusterMetrics.bottomArrangement(clusterOnly: true, underGlass: false)
                == .fullHeightClear
        )
    }

    @Test func aClusterOnlySpawnUnderGlassRunsClearToTheBottom() {
        // Glass changes nothing once the footer is gone: the bump exists to
        // clear a bar overlapping the surface's last points, and there is no
        // bar to clear.
        #expect(
            PaneClusterMetrics.bottomArrangement(clusterOnly: true, underGlass: true)
                == .fullHeightClear
        )
    }

    @Test func aFooterSpawnUnderGlassRunsFullHeightWithTheBump() {
        #expect(
            PaneClusterMetrics.bottomArrangement(clusterOnly: false, underGlass: true)
                == .fullHeightWithBump
        )
    }

    @Test func aFooterSpawnUnderFlatInsetsAboveTheBar() {
        #expect(
            PaneClusterMetrics.bottomArrangement(clusterOnly: false, underGlass: false)
                == .insetAboveBar
        )
    }
}
