import Foundation
import Testing

@testable import PaneControl

@Suite struct ControlLayoutTests {
    /// A two-tab document with a nested split, which is the shape everything below
    /// is asked about.
    private static func sample() -> ControlLayout {
        ControlLayout(tabs: [
            .split(
                axis: .horizontal,
                ratio: 0.4,
                first: .pane(cwd: "/Users/x/Projects/baia"),
                second: .split(
                    axis: .vertical,
                    ratio: 0.7,
                    first: .pane(cwd: nil),
                    second: .pane(cwd: "/Users/x/Projects/vault")
                )
            ),
            .pane(cwd: nil),
        ])
    }

    // MARK: What the document is, and is not

    /// **No pane id anywhere in the encoded document.**
    ///
    /// This is the property that lets `export` describe a window the caller cannot
    /// otherwise see. Asserted against the bytes rather than against the type,
    /// because the way an id gets in is somebody adding a field for one, and a
    /// test that walked the cases would keep passing when they did.
    @Test func nothingInAnEncodedDocumentLooksLikeAPaneID() throws {
        let data = try JSONEncoder().encode(Self.sample())
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("pane") == true, "the sample should have leaves in it")
        // A `PaneID` is a UUID string, which is the only shape a display id has.
        let uuid = try! NSRegularExpression(
            pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
        )
        let hits = uuid.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        #expect(hits == 0, "a document carried something shaped like a pane id")
    }

    /// The whole point of the type: a document written out and read back is the
    /// same document, so a file committed next to a Makefile still applies.
    @Test func aDocumentRoundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(Self.sample())
        #expect(try JSONDecoder().decode(ControlLayout.self, from: data) == Self.sample())
    }

    @Test func countAndDepthReadTheWholeDocument() {
        #expect(Self.sample().paneCount == 4)
        // The deepest tab, not the sum: one split holding a split holding panes.
        #expect(Self.sample().depth == 3)
    }

    // MARK: What it refuses

    @Test func aWellFormedDocumentIsNotRefused() {
        #expect(Self.sample().refusal() == nil)
    }

    /// A version this build does not write is refused rather than read
    /// optimistically, unlike `SessionSnapshot`'s additive rule. This document is
    /// edited by hand, so a field a newer baia added and this one ignores means
    /// opening the wrong panes rather than opening none.
    @Test func aDocumentFromAnotherVersionIsRefusedRatherThanGuessedAt() {
        var layout = Self.sample()
        layout.version = ControlLayout.currentVersion + 1
        let refusal = layout.refusal()
        #expect(refusal != nil)
        #expect(refusal?.contains("\(ControlLayout.currentVersion)") == true)
    }

    @Test func aDocumentWithNoTabsIsRefused() {
        #expect(ControlLayout(tabs: []).refusal() != nil)
    }

    /// **The cap is on processes, not on drawing.** Every leaf is a real shell, so
    /// a hand-written document asking for a thousand panes is a fork of a thousand
    /// shells wearing a layout's clothes.
    @Test func aDocumentPastThePaneCapIsRefused() {
        let atCap = ControlLayout(
            tabs: Array(repeating: .pane(cwd: nil), count: ControlLayout.maxPanes)
        )
        #expect(atCap.refusal() == nil)

        let overCap = ControlLayout(
            tabs: Array(repeating: .pane(cwd: nil), count: ControlLayout.maxPanes + 1)
        )
        #expect(overCap.refusal() != nil)
        #expect(overCap.refusal()?.contains("\(ControlLayout.maxPanes)") == true)
    }

    /// Depth is capped as well as pane count, because the walk that applies a
    /// document recurses and this is what bounds it. Built as a spine so the pane
    /// count stays inside its own cap and only depth can be what fails.
    @Test func aDocumentNestedPastTheDepthCapIsRefused() {
        func spine(_ depth: Int) -> ControlLayoutNode {
            depth <= 1
                ? .pane(cwd: nil)
                : .split(axis: .horizontal, ratio: 0.5, first: .pane(cwd: nil), second: spine(depth - 1))
        }
        #expect(ControlLayout(tabs: [spine(ControlLayout.maxDepth)]).refusal() == nil)
        #expect(ControlLayout(tabs: [spine(ControlLayout.maxDepth + 1)]).refusal() != nil)
    }

    /// Only a ratio that is not a fraction at all. Everything else is somebody
    /// asking for a narrow pane, and ``ControlLayout/clampedRatio(_:)`` decides
    /// what it becomes.
    @Test func onlyANonFiniteRatioIsRefused() {
        for ratio in [0.0, 1.0, -3.0, 42.0] {
            let layout = ControlLayout(tabs: [
                .split(axis: .horizontal, ratio: ratio, first: .pane(cwd: nil), second: .pane(cwd: nil)),
            ])
            #expect(layout.refusal() == nil, "\(ratio) should clamp rather than refuse")
        }
        for ratio in [Double.nan, .infinity, -.infinity] {
            let layout = ControlLayout(tabs: [
                .split(axis: .horizontal, ratio: ratio, first: .pane(cwd: nil), second: .pane(cwd: nil)),
            ])
            #expect(layout.refusal() != nil, "\(ratio) is not a fraction and should be refused")
        }
    }

    /// A bad ratio nested under good ones is still found. The walk stops at the
    /// first one, and the first one has to be reachable from anywhere in the tree.
    @Test func aBadRatioDeepInATreeIsStillFound() {
        let layout = ControlLayout(tabs: [
            .split(
                axis: .horizontal,
                ratio: 0.5,
                first: .pane(cwd: nil),
                second: .split(
                    axis: .vertical,
                    ratio: .nan,
                    first: .pane(cwd: nil),
                    second: .pane(cwd: nil)
                )
            ),
        ])
        #expect(layout.refusal() != nil)
    }

    // MARK: Clamping

    /// The band a dragged divider persists within. A ratio outside it describes a
    /// pane on screen at zero width: invisible, unreachable by mouse, and running
    /// a live shell.
    @Test func aRatioIsClampedIntoTheBandADraggedDividerLivesIn() {
        #expect(ControlLayout.clampedRatio(0.5) == 0.5)
        #expect(ControlLayout.clampedRatio(0) == ControlLayout.ratioBounds.lowerBound)
        #expect(ControlLayout.clampedRatio(1) == ControlLayout.ratioBounds.upperBound)
        #expect(ControlLayout.clampedRatio(-9) == ControlLayout.ratioBounds.lowerBound)
        #expect(ControlLayout.clampedRatio(9) == ControlLayout.ratioBounds.upperBound)
    }

    /// A non-finite ratio never reaches this, because ``ControlLayout/refusal()``
    /// answers first. It returns a middle rather than a NaN anyway, so the one
    /// path that could put a NaN into a split view does not exist.
    @Test func aNonFiniteRatioClampsToTheMiddleRatherThanPropagating() {
        #expect(ControlLayout.clampedRatio(.nan) == 0.5)
        #expect(ControlLayout.clampedRatio(.infinity) == 0.5)
    }

    // MARK: The wire

    /// The document rides in both directions on fields of its own, so a request
    /// and a response can each carry one and neither has to reuse a field named
    /// for something else.
    @Test func aLayoutSurvivesARequestAndAResponse() throws {
        let request = ControlRequest(
            token: "capability",
            verb: .layoutApply,
            args: ControlArgs(layout: Self.sample())
        )
        let line = try #require(ControlWire.encodeRequest(request))
        guard case let .request(decoded) = ControlWire.decodeRequest(line) else {
            Issue.record("the request did not decode")
            return
        }
        #expect(decoded.args.layout == Self.sample())

        let response = ControlResponse.success(ControlResult(layout: Self.sample()))
        let out = try #require(ControlWire.encodeResponse(response))
        #expect(ControlWire.decodeResponse(out)?.result?.layout == Self.sample())
    }
}
