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
}
