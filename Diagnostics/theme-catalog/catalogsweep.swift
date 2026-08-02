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
                let fill = t.attentionColour(accent, behavior: behavior)
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
