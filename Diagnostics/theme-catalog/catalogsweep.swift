// Every shipped ghostty theme crossed with every `FocusAccent`, graded by the
// rules the chrome owes and checked against the figures the doc comments state.
//
// Driven through `PaneTheme.accent(for:)` and `PaneTheme.attentionColour(_:_:)`
// rather than through this file's own copy of their formulas. A probe that
// restated the derivations would pass while the shipped switch resolved
// something else, which is the failure `theConfiguredFocusAccentReachesTheTheme`
// exists for one layer down.
//
// One argument selects a negative control, each damaging exactly one rule. The
// first attempt at this had a single control that replaced `nightshade` with the
// bar it is drawn on, and it *passed*: `nightshade`'s pinned raw-clear count is
// already 0, the repair chain lifts a bar-coloured accent like any other, and
// `derived(from:)` still had a whole palette to walk. A control that cannot fail
// is the thing this file is supposed to catch, so there are three now and each
// one names the mistake it imitates.

import BaiaSettings
import Foundation
import GhosttyTheme
import PaneChrome

enum Mode: String {
    /// Nothing damaged.
    case sweep

    /// Grade the raw derivation instead of the repaired ink, which is the
    /// mistake of measuring a colour somewhere other than where it is drawn.
    case breakRepair = "break-repair"

    /// Grade `stock` instead of `derive`. `stock` is unguarded on purpose, so a
    /// check pointed at it is a check that grades the value which promises
    /// nothing and reports on the one that promises the floor.
    case breakDerive = "break-derive"

    /// Replace every accent with the bar it is drawn on, so the counted figures
    /// move. This is the control for the pins rather than for a colour rule.
    case breakPins = "break-pins"

    /// Resolve `sea`'s rows with `nightshade`'s derivation and the reverse, so a
    /// row is judged on a candidate the walk should never have handed it.
    ///
    /// It grades something no other control does: which accent's candidate the
    /// derive walk resolved. `focusedAccent` and the palette are untouched, so the
    /// raw-clear rows and the collision figures do not move, which the run
    /// confirms.
    ///
    /// **It was built to isolate `deriveMissesByAccent` and it does not, which is
    /// worth more written down than quietly deleted.** Measured 2026-08-02: it
    /// takes the misses from 10 to 26 and spreads them over 15 themes, so
    /// ``Pinned/deriveMisses`` and the Retro rule below both fail on it first. The
    /// cause is that the substitution applies to all 485 themes, and a fill that
    /// misses the floor on a palette with room is a *new* miss rather than a moved
    /// one.
    ///
    /// An isolating control has to keep the total at 10 and the theme at Retro
    /// while changing the split, which means redistributing *within* Retro's
    /// fourteen rows: two that currently clear have to start missing and two that
    /// miss have to stop. Nothing external to the walk can arrange that, and
    /// arranging it inside the walk means reverse-engineering why `accent` clears
    /// on a palette of two greens where `bone` does not. Until someone does, the
    /// honest scope of that pin is narrower than "catches a redistribution": it
    /// catches one that preserves both the count and the theme, and no cheap
    /// mutation produces such a thing.
    case breakDistribution = "break-distribution"
}

let mode = CommandLine.arguments.dropFirst().first.flatMap(Mode.init(rawValue:)) ?? .sweep

/// The floors, taken from `PaneTheme` rather than written down again.
let minimumTextContrast = PaneTheme.minimumTextContrast
let minimumSeparation = PaneTheme.minimumAttentionSeparation

/// The figures the prose states, each against the sentence it backs.
///
/// **This is the half of the probe that is not a rule about colour.** Every one
/// of these numbers appears in a doc comment, and until this file existed
/// nothing in the repo could notice when the catalog moved out from under one.
/// It did: the comments said 463 themes and 2315 rows for as long as the catalog
/// had 485 and 3395, and `SettingsView.swift` had said 485 the whole time. A
/// libghostty bump is *expected* to fail here. Re-measure, then move the prose
/// and these pins in the same commit.
enum Pinned {
    /// `FocusAccent.nightshade`, `PaneTheme.attentionColour(_:behavior:)`,
    /// `PaneTheme.alertBehaviorMatters(for:)`, `AttentionColourTests`.
    static let themes = 485

    /// "10 of the 3395 theme-by-`focusAccent` rows", in
    /// `deriveOnAThemeWithNothingToBlendTowardsStillAnswers`.
    static let rows = 3395

    /// "141 of the 485 catalog themes land within ΔE00 10 of their own bar",
    /// in `attentionColour(_:behavior:)` and three places that quote it.
    static let accentIsTheBar = 141

    /// The escape hatch, and the one theme allowed into it.
    static let deriveMisses = 10
    static let deriveMissTheme = "Retro"

    /// "clears 4.5:1 on the bar for none of the 485, against 204 for
    /// ``twilight``, 252 for ``sea`` and 421 for ``bone``", in
    /// `FocusAccent.nightshade`.
    static let rawClears: [FocusAccent: Int] = [
        .accent: 140, .bone: 421, .ansi5: 215, .ansi6: 312,
        .twilight: 204, .nightshade: 0, .sea: 252,
    ]

    /// "`sea` still lands within ΔE00 10 of raw `ansi6` on 165 of the 485", in
    /// `PaneTheme.seaAccent` and in `seaIsFarFromTheCyanItStartsFromOnThisTheme`.
    ///
    /// The figure the fraction argument actually turns on, and it was asserted
    /// for a day before it was measured. `seaIsFarEnoughFromTheCyanItStartsFrom`
    /// claimed to be the case for halfway over 0.35 and passed on `darkPastel`
    /// at every fraction down to 0.15, because one theme cannot see a catalog
    /// rule. Measured 2026-08-02: 258 collide at 0.35 and 165 at 0.50, so
    /// halfway buys 93 themes and does not buy the guarantee.
    static let seaCollidesWithAnsi6 = 165

    /// Which accents own the ten, and the sentence it backs is the one at
    /// `AttentionColourTests.swift` scoping the hatch: it was "8 of 2315 across
    /// five accents", `sea` joins the four that land there and `nightshade` does
    /// not. ``deriveMisses`` and ``deriveMissTheme`` both survive a
    /// redistribution, which is the hole this closes: swapping the `nightshade`
    /// and `seaAccent` derivations leaves 10 misses on nothing but Retro while
    /// making that sentence false.
    ///
    /// Measured 2026-08-02. Every accent that lands here misses under both
    /// ``AttentionAccent`` cases and never one, which is why these are 2 and 0
    /// rather than odd numbers. `bone` is the only one whose two cases separate
    /// differently, ΔE00 4.18 against 3.11; the other four sit at 5.62 twice,
    /// Retro's two greens collapsing most derivations onto one colour.
    static let deriveMissesByAccent: [FocusAccent: Int] = [
        .accent: 0, .bone: 2, .ansi5: 2, .ansi6: 2,
        .twilight: 2, .nightshade: 0, .sea: 2,
    ]

    /// The 14 themes whose `ansi[6]` and `ansi[4]` are the same colour, where no
    /// fraction separates `sea` from `ansi6` because there is nothing to blend
    /// towards. The floor of ``seaCollidesWithAnsi6``: it can never go below this.
    static let seaCannotBeSeparated = 14
}

/// The rule `PaneTheme.attentionSeparation(of:)` holds.
///
/// Restated because that method is internal to the package and this is a
/// separate binary rather than a test target. The package tests must never do
/// this — a test that spells the rule out again asserts its own copy of it — and
/// the cost here is that a change to the measure has to be copied. The three
/// surfaces are named rather than looped so that dropping one is visible.
func separation(_ colour: RGB, in theme: PaneTheme) -> Double {
    min(
        colour.perceptualDistance(to: theme.focusedAccent),
        colour.perceptualDistance(to: theme.barBackground),
        colour.perceptualDistance(to: theme.background)
    )
}

/// The theme the app would build for this row.
///
/// `PaneTheme.init(…, focusAccent:)` resolves the accent on its last line, so
/// passing the choice in is the whole wiring rather than a reconstruction of it.
func theme(_ definition: GhosttyThemeDefinition, _ choice: FocusAccent) -> PaneTheme {
    var built = PaneTheme(
        background: definition.background,
        foreground: definition.foreground,
        selectionBackground: definition.selectionBackground,
        palette: definition.palette,
        focusAccent: choice
    )
    if mode == .breakPins { built.focusedAccent = built.barBackground }
    return built
}

/// `sea` and `nightshade` exchanged, everything else itself. Only
/// ``Mode/breakDistribution`` calls this.
func swappedForDistribution(_ choice: FocusAccent) -> FocusAccent {
    switch choice {
    case .sea: .nightshade
    case .nightshade: .sea
    default: choice
    }
}

struct Failure {
    let theme: String
    let choice: String
    let rule: String
    let detail: String
}

var failures: [Failure] = []

// `@MainActor` on the helpers rather than nowhere: top-level code in a
// single-file binary is main-actor isolated, so a plain `func` touching a global
// declared up here is a concurrency error rather than a style choice.
@MainActor
func fail(_ theme: String, _ choice: FocusAccent, _ rule: String, _ detail: String) {
    failures.append(.init(theme: theme, choice: choice.rawValue, rule: rule, detail: detail))
}

var rows = 0
var accentIsTheBar = 0
var rawClears: [FocusAccent: Int] = [:]
var deriveMisses: [Failure] = []
var deriveMissesByAccent: [FocusAccent: Int] = [:]

/// Counted once per theme rather than once per row: `sea`'s distance from raw
/// `ansi[6]` does not depend on which accent the row is for.
var seaCollisions = 0
var seaInseparable = 0

for definition in GhosttyThemeCatalog.allThemes {
    // Once per theme. `sea` is `ansi[6]` blended halfway to `ansi[4]`, and the
    // question is whether the halfway is enough to keep the menu's `sea` and
    // `ansi6` entries from resolving to one colour. `break-pins` damages
    // `focusedAccent` and not the palette, so this figure is deliberately
    // measured off the raw palette and stays honest under that control; the
    // control still fails on the four pins above it.
    let plain = theme(definition, .accent)
    // `accent(for:)` rather than this file's own copy of the blend, per the
    // header: a probe that restates a derivation passes while the shipped one
    // resolves something else. Written the restated way first, which would have
    // let a change to `seaAccent` move nothing here.
    let sea = plain.accent(for: .sea)
    if sea.perceptualDistance(to: plain.ansiColor(6)) < minimumSeparation { seaCollisions += 1 }
    if plain.ansiColor(6) == plain.ansiColor(4) { seaInseparable += 1 }

    for choice in FocusAccent.allCases {
        rows += 1
        let t = theme(definition, choice)

        // Repair. `inkFocus` is the accent as it is actually drawn on the bar,
        // and 4.5:1 there is the floor every focus colour owes whatever it
        // derives from. The control grades `focusedAccent`, which is the same
        // colour before the chain has seen it.
        let judged = mode == .breakRepair ? t.focusedAccent : t.inkFocus
        let drawn = judged.contrastRatio(against: t.barBackground)
        if drawn < minimumTextContrast {
            fail(definition.name, choice, "repair",
                 String(format: "%.2f:1 on the bar", drawn))
        }
        if t.focusedAccent.contrastRatio(against: t.barBackground) >= minimumTextContrast {
            rawClears[choice, default: 0] += 1
        }

        // The collision guard. `stock` is unguarded by design — the shipped
        // answer to the collision question is "nothing" — so it is not graded,
        // except by the control that grades nothing else.
        let guarded: AlertBehavior = mode == .breakDerive ? .stock : .derive
        for accent in AttentionAccent.allCases {
            for behavior in [AlertBehavior.noCollision, guarded] {
                // The fill comes from this row's own theme, except under the
                // distribution control, where `sea` and `nightshade` take each
                // other's. The separation is still judged `in: t`, against this
                // row's focus accent and bar, which is what makes it a wrong
                // *candidate* rather than a wrong question.
                let fillTheme = mode == .breakDistribution
                    ? theme(definition, swappedForDistribution(choice))
                    : t
                let fill = fillTheme.attentionColour(accent, behavior: behavior)
                if behavior == guarded, separation(fill, in: t) < minimumSeparation {
                    // Only the guarded behaviour is graded. `noCollision` falls
                    // back to `alert` by definition, so on a theme whose alert is
                    // itself the colliding colour it lands short, and that is the
                    // setting doing what it says rather than a defect. `derive`
                    // is the one that promises the floor.
                    deriveMisses.append(.init(
                        theme: definition.name, choice: choice.rawValue,
                        rule: "\(guarded)/\(accent)",
                        detail: String(format: "ΔE00 %.2f", separation(fill, in: t))))
                    deriveMissesByAccent[choice, default: 0] += 1
                }

                // The ink on whatever it resolved to, and the tier ordering the
                // muted candidate can invert on a mid-luminance fill.
                let ink = t.ink(on: fill)
                let muted = t.mutedInk(on: fill)
                if ink.contrastRatio(against: fill) < minimumTextContrast {
                    fail(definition.name, choice, "ink/\(accent)/\(behavior)",
                         String(format: "%.2f:1", ink.contrastRatio(against: fill)))
                }
                if muted.contrastRatio(against: fill) < minimumTextContrast {
                    fail(definition.name, choice, "mutedInk/\(accent)/\(behavior)",
                         String(format: "%.2f:1", muted.contrastRatio(against: fill)))
                }
                if muted.contrastRatio(against: fill) > ink.contrastRatio(against: fill) {
                    fail(definition.name, choice, "tierOrder/\(accent)/\(behavior)",
                         "tier 4 louder than tier 3")
                }
            }
        }

        if choice == .accent,
           t.focusedAccent.perceptualDistance(to: t.barBackground) < minimumSeparation {
            accentIsTheBar += 1
        }
    }
}

// `derive` is allowed to miss the floor on exactly one theme, and the package
// test that pins it says which and why: Retro spends all sixteen slots and its
// foreground on two greens over black, so nothing in the palette can separate
// anything. Any other theme here is a palette that had an answer and did not get
// it, which is the shape `deriveLooksPastADirectionThatIsNoUse` fixed.
for miss in deriveMisses where miss.theme != Pinned.deriveMissTheme {
    failures.append(.init(theme: miss.theme, choice: miss.choice,
                          rule: "the floor missed on a theme with somewhere to go",
                          detail: miss.detail))
}

func padded(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

/// A pinned figure, compared and reported by name.
@MainActor
func pin(_ label: String, _ measured: Int, _ expected: Int) {
    let line = "  \(padded(label, 34))\(padded(String(measured), 6))"
    guard measured != expected else { return print(line) }
    print(line + "EXPECTED \(expected)")
    failures.append(.init(theme: "-", choice: "-", rule: "pinned figure: \(label)",
                          detail: "measured \(measured), the doc comments say \(expected)"))
}

print(mode == .sweep ? "== theme catalog sweep" : "== \(mode.rawValue): a control, and it has to fail")
pin("themes", GhosttyThemeCatalog.allThemes.count, Pinned.themes)
pin("theme-by-focusAccent rows", rows, Pinned.rows)
pin("accent lands on its own bar", accentIsTheBar, Pinned.accentIsTheBar)
pin("the floor cannot be reached", deriveMisses.count, Pinned.deriveMisses)
// Named by theme as well as accent, because the raw-clears rows below are also
// one per `FocusAccent` and a bare `    bone` in a failure would not say which of
// the two sections it came from.
for choice in FocusAccent.allCases {
    pin("  of those, \(choice.rawValue) on \(Pinned.deriveMissTheme)",
        deriveMissesByAccent[choice, default: 0],
        Pinned.deriveMissesByAccent[choice] ?? -1)
}
pin("sea collides with ansi6", seaCollisions, Pinned.seaCollidesWithAnsi6)
pin("  of those, unseparable", seaInseparable, Pinned.seaCannotBeSeparated)
print("  raw value already clears \(minimumTextContrast):1, per accent")
for choice in FocusAccent.allCases {
    pin("    \(choice.rawValue)", rawClears[choice, default: 0], Pinned.rawClears[choice] ?? -1)
}

let missThemes = Set(deriveMisses.map(\.theme)).sorted()
print("  floor missed on: " + (missThemes.isEmpty ? "nothing"
    : missThemes.prefix(8).joined(separator: ", ")
    + (missThemes.count > 8 ? ", and \(missThemes.count - 8) more" : "")))

guard failures.isEmpty else {
    print("\n\(failures.count) failures:")
    for (rule, hits) in Dictionary(grouping: failures, by: \.rule).sorted(by: { $0.key < $1.key }) {
        let themes = Set(hits.map(\.theme)).sorted()
        print("  \(rule): \(hits.count) rows, \(themes.count) themes")
        print("    \(themes.prefix(10).joined(separator: ", "))"
            + (themes.count > 10 ? ", and \(themes.count - 10) more" : ""))
        print("    e.g. \(hits[0].choice) on \(hits[0].theme): \(hits[0].detail)")
    }
    exit(1)
}

print("\nevery one of \(rows) rows clears repair and carries readable ink, "
    + "and derive reaches the floor everywhere but \(Pinned.deriveMissTheme)")

// MARK: - The wells audit

/// `t` with ``PaneChrome/PaneTheme/background`` replaced by itself composited
/// over a bounding backdrop at the well's opacity, everything else untouched.
///
/// Starts from the theme `theme(_:_:)` above already built, rather than from
/// the catalog's hex strings: `background` is the one field this function
/// changes, and reaching it after `theme(_:_:)` has resolved the ansi holes
/// and the focus accent means those two are computed exactly the way the arm
/// above computes them, off the *original* opaque background, and are not
/// silently redone against a composited one that ghostty never hands them.
///
/// The well is ghostty's own compositing (`TerminalOverride.swift` maps
/// ``BaiaSettings/Settings/backgroundOpacity`` to `background-opacity`), and it
/// composites the background only: `foreground`, `focusedAccent` and `ansi` are
/// never blended with anything behind the window. A wells-audit theme built by
/// touching more than `background` would be measuring a compositor baia does
/// not have.
///
/// White and black stand in for "the extremes any wallpaper region
/// approaches", per the task, not for a claim about the owner's own desktop.
/// `RGBA.composited(over:)` is the same formula spelled the other way round
/// (`backdrop.blended(with: rgb, fraction: alpha)`); it is not reused here
/// because it lives on ``RGBA``, and building one to throw away would be a
/// second name for one blend.
func welled(_ t: PaneTheme, over backdrop: RGB, at opacity: Double) -> PaneTheme {
    var composited = t
    composited.background = backdrop.blended(with: t.background, fraction: opacity)
    return composited
}

/// The well opacity this audit exists to answer for. Not read off
/// `Settings.defaultSettings`, which is the shipped 0.85 measured alongside it
/// below: 0.42 is the value design v5 proposes and nothing in `BaiaSettings`
/// names yet, so a settings default cannot stand in for it.
let auditedWellOpacity = 0.42

/// The shipped well, so the audit reports what changes rather than only what
/// the proposal costs. Read off the settings default rather than pinned again
/// here, so a changed default moves this measurement without an edit.
let shippedWellOpacity = BaiaSettings.Settings.defaultSettings.backgroundOpacity

/// One counted failure of a rule this file already grades, against a
/// composited background rather than the opaque one.
struct WellFailure {
    let rule: String
    let theme: String
}

/// Every promise the sweep above grades, re-measured for one `choice` against
/// `row`, a theme already welled: its `background` is composited, its
/// `focusedAccent` is not yet resolved for `choice`.
///
/// `row.accent(for: choice)` is called here rather than earlier, so the one
/// derivation that reads `background` (``PaneChrome/PaneTheme/nightshadeAccent``)
/// resolves against the welled colour exactly as ``PaneChrome/PaneTheme/accent(for:)``
/// would if the app really were drawing over a 42% well; resolving it before
/// welling would grade a `nightshade` nobody sees.
///
/// Threaded through the same functions the arm calls (`accent(for:)`,
/// `attentionColour(_:behavior:)`, `ink(on:)`, `mutedInk(on:)`,
/// `attentionSeparation(of:)` via `separation(_:in:)`) rather than a second
/// copy of what they check, for the reason the header gives for driving the
/// arm through them in the first place: a copy passes while the shipped
/// derivation resolves something else.
///
/// Both `AlertBehavior` cases, the same pair and the same reason the arm's own
/// loop names: `stock` is excluded there and here, unguarded by design and
/// grading it would report on the value that promises nothing. `noCollision`
/// is graded for ink, mutedInk and tier order — a collision it falls back to
/// `alert` for is still a fill someone reads text on — but not for "the
/// floor", which is `derive`'s promise alone; the README section this mirrors
/// says why a `noCollision` miss is the setting doing what it says.
@MainActor
func gradeWell(_ row: PaneTheme, choice: FocusAccent, theme themeName: String, into hits: inout [WellFailure]) {
    var row = row
    row.focusedAccent = row.accent(for: choice)

    let drawn = row.inkFocus.contrastRatio(against: row.barBackground)
    if drawn < minimumTextContrast {
        hits.append(.init(rule: "repair", theme: themeName))
    }

    for accent in AttentionAccent.allCases {
        for behavior in [AlertBehavior.noCollision, .derive] {
            let fill = row.attentionColour(accent, behavior: behavior)
            if behavior == .derive, separation(fill, in: row) < minimumSeparation {
                hits.append(.init(rule: "the floor/\(accent)", theme: themeName))
            }
            let ink = row.ink(on: fill)
            let muted = row.mutedInk(on: fill)
            if ink.contrastRatio(against: fill) < minimumTextContrast {
                hits.append(.init(rule: "ink/\(accent)/\(behavior)", theme: themeName))
            }
            if muted.contrastRatio(against: fill) < minimumTextContrast {
                hits.append(.init(rule: "mutedInk/\(accent)/\(behavior)", theme: themeName))
            }
            if muted.contrastRatio(against: fill) > ink.contrastRatio(against: fill) {
                hits.append(.init(rule: "tierOrder/\(accent)/\(behavior)", theme: themeName))
            }
        }
    }
}

/// One backdrop, one opacity, every theme, every accent, every promise: the
/// row this report prints once per combination the task asks for (0.42 and
/// 0.85, over white and over black) plus the opaque baseline the arm above
/// already measured.
///
/// Built from ``theme(_:_:)`` the same way every row in the arm is, so
/// `break-pins` fidelity and the ansi-hole fallback are shared rather than
/// redone: the only new step is ``welled(_:over:at:)`` between that call and
/// grading.
@MainActor
func sweepWells(over backdrop: RGB, at opacity: Double) -> [WellFailure] {
    var hits: [WellFailure] = []
    for definition in GhosttyThemeCatalog.allThemes {
        for choice in FocusAccent.allCases {
            let opaque = theme(definition, .accent) // .accent: overwritten per choice inside gradeWell
            let row = opacity >= 1 ? opaque : welled(opaque, over: backdrop, at: opacity)
            gradeWell(row, choice: choice, theme: definition.name, into: &hits)
        }
    }
    return hits
}

// Runs only in `.sweep`: the four controls above exist to damage one colour
// rule each, and re-running this section under them would either re-report
// the same damage a second time under a different heading or, for
// `break-pins`, silently launder it, since `theme(_:_:)` applies `breakPins`
// globally and every well row already goes through that function. The wells
// audit's job is to measure the shipped rules against a composited
// background, not to re-derive whether the controls still damage them.
if mode == .sweep {
    print("\n== the wells audit: \(GhosttyThemeCatalog.allThemes.count) themes, "
        + "\(FocusAccent.allCases.count) accents, composited at \(auditedWellOpacity) and "
        + "\(shippedWellOpacity) over white and black, opaque as the baseline already measured above")

    let white = RGB(red: 1, green: 1, blue: 1)
    let black = RGB(red: 0, green: 0, blue: 0)

    struct WellRun {
        let label: String
        let hits: [WellFailure]
    }

    let wellRuns: [WellRun] = [
        .init(label: "opaque (baseline)", hits: sweepWells(over: white, at: 1)),
        .init(label: "0.\(Int(shippedWellOpacity * 100)) over white (shipped)",
              hits: sweepWells(over: white, at: shippedWellOpacity)),
        .init(label: "0.\(Int(shippedWellOpacity * 100)) over black (shipped)",
              hits: sweepWells(over: black, at: shippedWellOpacity)),
        .init(label: "0.\(Int(auditedWellOpacity * 100)) over white (audited)",
              hits: sweepWells(over: white, at: auditedWellOpacity)),
        .init(label: "0.\(Int(auditedWellOpacity * 100)) over black (audited)",
              hits: sweepWells(over: black, at: auditedWellOpacity)),
    ]

    for run in wellRuns {
        let byRule = Dictionary(grouping: run.hits, by: \.rule)
        print("\n  \(run.label): \(run.hits.count) failing rows")
        if run.hits.isEmpty {
            print("    clean")
            continue
        }
        for (rule, hits) in byRule.sorted(by: { $0.key < $1.key }) {
            let themes = Set(hits.map(\.theme)).sorted()
            print("    \(padded(rule, 22))\(hits.count) rows, \(themes.count) themes")
        }
        let worst = Dictionary(grouping: run.hits, by: \.theme)
            .mapValues(\.count)
            .sorted { $0.value > $1.value }
            .prefix(5)
        print("    worst offenders: "
            + worst.map { "\($0.key) (\($0.value))" }.joined(separator: ", "))
    }

    // This report is a measurement, not a rendering change: whatever the
    // numbers say, whether 0.42 is safe to ship as a default is a decision
    // for the owner with this output in hand, made in the vault hub rather
    // than in this file's exit code. The wells audit therefore never calls
    // `exit(1)` and never appends to `failures`; a promise that already fails
    // opaque is caught by the arm above, and a promise that only fails once
    // composited is exactly the finding this section exists to surface.
}
