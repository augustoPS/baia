import Foundation

/// What a translucent pill's text is graded against, and what the capsule's
/// notice is drawn in.
///
/// **Why this is a type and not two literals at two draw calls.** Two surfaces
/// in this app paint the same layer stack — the capsule's pill
/// (`PaneClusterView.draw(_:)`: `theme.background` at
/// ``ChromeMaterials/PaneWash/floor``, then the material's `fillChrome`) and
/// the sidebar's `git init` offer, which cites the capsule's stack in its own
/// comments as the thing it copied. `Diagnostics/cluster-legibility` grades
/// both against one floor and one backdrop. Three copies of one derivation is
/// three chances for a measured constant to move on one surface and not the
/// other, which is the failure this repo has deleted duplicate switches over
/// before. The offer reads this too, so there is one assembly of the face and
/// one of the correction.
public enum PaneClusterInk {
    /// `#7c7c7c`, `glass-backdrop`'s finding 6b: the brightest backdrop this
    /// repo has measured a glass surface composite to. The same bound
    /// ``ChromeMaterials/PaneWash``'s floor is derived from, cited here rather
    /// than re-derived so the two cannot drift apart.
    public static let brightestMeasuredBackdrop = RGB(
        red: 124.0 / 255, green: 124.0 / 255, blue: 124.0 / 255
    )

    /// Six bytes: how far AppKit's own compositing lands *bright* of the
    /// package's sRGB flatten at the bright bound.
    ///
    /// Measured, not chosen: `Diagnostics/cluster-legibility` predicts
    /// `#303132` where it reads `#363638`. See ``worstFace(theme:chrome:)``
    /// for why the correction is applied to the backdrop the ink is graded on
    /// rather than to the paint the pill lays down.
    public static let compositingHeadroom = 6.0 / 255

    /// The brightest face a pill of this layer stack can present, which is what
    /// text on it has to survive.
    ///
    /// ``RGBA/composited(over:)`` is the package's sRGB flatten, the same layer
    /// stack `Diagnostics/cluster-legibility` predicts its measured band with,
    /// applied over ``brightestMeasuredBackdrop``.
    ///
    /// **The flatten is nominal and the screen is brighter, so this grades on
    /// the screen's number.** The probe's own README records the divergence:
    /// AppKit composites in the bitmap rep's space (Generic RGB, gamma 1.8) and
    /// the package flattens in sRGB bytes. The two agree to sub-byte in the
    /// dark regime — which is where every pin in this app lived until the
    /// bright bound joined — and diverge at the bright end, where the flatten
    /// lands about 6 bytes *dark* of the measurement: `#303132` predicted
    /// against `#363638` measured, 4.79:1 against the 4.41:1 the probe reads.
    /// Graded on the flatten alone the repair chain does not fire and the text
    /// ships under the floor on a face this app can put on screen, which is the
    /// failure mode the floor exists to catch.
    ///
    /// So the flatten's result is lifted by ``compositingHeadroom`` before it
    /// is graded. That is a correction toward the measurement rather than a
    /// safety margin invented for comfort: 6 bytes is what the probe measures
    /// the gap to be at this bound, and it is applied in the one direction that
    /// can only ever make the grade stricter. Should the two spaces ever be
    /// reconciled the constant goes to zero and nothing else here moves.
    ///
    /// **The backdrop it grades on is the pill's worst face and not its likely
    /// one**, which is the one honest choice available: under glass the real
    /// backdrop is whatever the compositor sampled, and the pill cannot know it
    /// at draw time. What it does know is the paint it lays down, so it grades
    /// against those layers over the brightest backdrop the repo has measured.
    /// Ink that clears that clears everything darker, which is every other
    /// case.
    ///
    /// `fillChrome` and not `fillThick` on purpose, though the pill wears
    /// `fillThick` when its pane is focused: `cluster-legibility`'s table has
    /// `fillThick` reading *better* over the bright bound (6.53:1 against
    /// 6.26:1), because more dark paint helps when the backdrop is the problem.
    /// The resting fill is therefore the worse of the two and grading on it
    /// covers both.
    public static func worstFace(theme: PaneTheme, chrome: ResolvedChrome) -> RGB {
        switch chrome {
        case let .glass(set):
            let washed = RGBA(rgb: theme.background, alpha: ChromeMaterials.PaneWash.floor)
                .composited(over: brightestMeasuredBackdrop)
            let face = set.fillChrome.composited(over: washed)
            return RGB(
                red: min(1, face.red + compositingHeadroom),
                green: min(1, face.green + compositingHeadroom),
                blue: min(1, face.blue + compositingHeadroom)
            )
        case .flat:
            // Opaque, so whatever is beneath composites away entirely and there
            // is no space divergence to correct: the face is a literal colour
            // this app sets, not a blend AppKit performs.
            return theme.background
        }
    }

    /// The colour a notice is drawn in on the pill.
    ///
    /// **``PaneStatusEmphasis/alert``, because that is what the footer said it
    /// in**, and the emphasis rather than a hand-picked red because
    /// ``PaneTheme/color(for:focused:on:)`` is the one derivation of a tier's
    /// colour in this app. `PaneStatusSegments.build(from:)` gives its notice
    /// segment `.alert`; the capsule's notice asks the same theme the same
    /// question, so a theme that restates its alert colour moves both surfaces
    /// and neither can answer for the other.
    ///
    /// **Focus is passed as false, always, and that is a decision rather than
    /// an omission.** `focused` reaches ``PaneTheme/color(for:focused:on:)``
    /// only to swap ``PaneStatusEmphasis/strong`` for the focus accent — the
    /// one tier focus touches — and `.alert` is not that tier, so the argument
    /// cannot change this answer. Passing the pill's live focus state would
    /// therefore be a wire that reads as meaningful and is not: it would
    /// suggest an unfocused pane's refusal is drawn differently, and the next
    /// person to change the palette would have to prove it is not. A literal
    /// `false` with this note is the honest spelling.
    ///
    /// The face is ``worstFace(theme:chrome:)``, which is what makes this
    /// legible rather than merely red: `theme.alert` on a bright-backdrop glass
    /// pill is not guaranteed to clear ``PaneTheme/minimumTextContrast`` on its
    /// own, and the repair chain inside `color(for:focused:on:)` walks it to
    /// the floor when it does not. That is the same instrument every footer
    /// tier and the sidebar offer's caption already go through, so no new
    /// threshold is invented here.
    public static func noticeInk(theme: PaneTheme, chrome: ResolvedChrome) -> RGB {
        theme.color(for: .alert, focused: false, on: worstFace(theme: theme, chrome: chrome))
    }
}
