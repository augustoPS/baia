# Handoff: baia — visual design pass on the workspace sidebar

## Overview

The design v3 pass over the **workspace sidebar** of **baia** (`augustoPS/baia`, branch
`main`) — a native macOS terminal workspace built on Ghostty's engine, in AppKit, no
SwiftUI, no nibs. The sidebar shipped functionally correct and visually unstyled: two
surfaces (`changes`, `files`) that stack, resize and act, drawn in placeholder values.

This package specifies, with exact values:

1. **Material** — what the column is made of, and the rule the rest follows from
2. **The changes row** — `XY` markers coloured per column, and the five states a row
   now needs because rows became clickable
3. **The path that does not fit** — the live wrap bug, and the truncation ladder
4. **The column** — headings, the count, the anchor name, and the section split
5. **The tree** — indent guides, and where per-file git status goes
6. **Density, scroll and the empty states**
7. **Edges** — the corner, and the trailing-edge question (answered: no)
8. **Corrections** — five defects in the shipped code, two struck as already fixed

**Nothing here is a literal colour.** Every value is a derivation from `PaneTheme`
(`background`, `foreground`, `inkFocus`, `ansi[]`), passed through
`readable(_:on:minimumRatio:)`. The hex column throughout is what **Dark Pastel on
`#141414` with `focusAccent: "midnight"`** resolves to, given so you can eyeball the
result — the **formula is the spec**. A theme or accent change must move the chrome with
it; that rule is why the derivations matter more than the hexes.

This is a companion to `design_handoff_baia_chrome/`, which covers the pane chrome
(focus treatment, attention, tabs, footer tiers, divider, icon). Where the two touch —
the footer's Tier 1 treatment, the accent, the hairline vocabulary — this document
follows that one.

## About the design files

`Baia Sidebar Design Pass.dc.html` is a **design reference created in HTML**, not code
to port. It is a spec document: recreations of the seven sidebar captures at 1pt = 1px,
with each proposed treatment rendered beside its values.

The implementation target is **AppKit, in the existing repo** — `Sources/` and
`Packages/PaneChrome/`. There is no HTML, React or SwiftUI anywhere in this project and
none should be introduced. Read the document for the visual intent, implement in Swift
using the constants below.

`baia-sidebar-design-pass-standalone.html` is the same document as a single
self-contained file — no server, no sibling assets, opens by double-clicking. **Start
there.**

The `.dc.html` source is included too; to open that one, serve the folder
(`python3 -m http.server`) — it needs `support.js` and `_ds/` as siblings, both
included. `captures/` holds the seven source screenshots the recreations were built
from.

## Fidelity

**High-fidelity.** Colours, point sizes, font weights, timings and geometry are final
and were checked for WCAG contrast against the surface each one is drawn on. Mocks are
1pt = 1px, so a measurement taken off the document is a number you can type into Swift.

Every recreation was checked against captures 07–13. Four things the captures settled
that reading the source alone did not:

- **07** shows `A.` fully green and `.M` fully yellow — the `.` is coloured as though
  absence had a state. That is §2's argument rendered.
- **07** also carries the wrap bug on the row *above* one that fits, so the cause is
  width, not the path.
- **10** shows zsh's own bracketed-paste highlight around the landed path. That changed
  the landed-state decision (see §2.3).
- **12** draws `not a repository` at first-row position in `inkFaint` — character for
  character the treatment `no changes` gets.

---

## 1. Material — the decision everything follows from

### The problem

The column is currently two materials: headings fill `barBackground` (`#212121`) and
both bodies fill `panelBackground` (`#1C1C1C`). It reads as a stuck-open command palette
wearing footer-coloured caps.

### The decision

**The sidebar is another compartment, not a panel.**

| Part | Fill | Resolves | Note |
|---|---|---|---|
| body | `background` @ `settings.backgroundOpacity` | `#141414` @ 0.85 | composites exactly as a pane does |
| heading | `barBackground`, opaque | `#212121` | exactly the footer |
| hairline | on the heading's **bottom** edge | `#382D43` | faces its own rows |
| gutter | 1pt, sidebar to pane tree | `#382D43` | |

One rule for the whole window: **every compartment is the terminal's material and wears
one chrome band.** Panes wear theirs at the bottom and report; sections wear theirs at
the top and label.

`panelBackground` is no longer used here. It keeps the command palette and the find
panel, which float; the sidebar sits beside the work and takes the work's own material.

### Why

The argument is in `panelBackground`'s own docstring — a large surface should sit
*below* the bar, because lifting it as far would make it the brightest object on screen
by area. The sidebar is the largest non-pane surface in the window, so by that reasoning
it belongs at the bottom of the ramp rather than one step up it. The panel's other
justification, separation by border and shadow, is not available: the sidebar does not
float.

Two things fall out for free:

- The sidebar and the footers become one chrome vocabulary meeting at the window's
  bottom-left corner — same fill, same hairline, same ink. That is the answer to "how
  does the sidebar relate to the pane footers": **the same anchor name, in the same
  treatment, in both places.** No connector is needed between two things that agree.
- With body and heading on different materials, the boundary between one section's rows
  and the next section's heading is already visible, so the split needs an affordance
  rather than a rule (§4.3).

### Lines take the accent; surfaces stay neutral

| Role | Derivation | Resolves | Was |
|---|---|---|---|
| `divider` | `background.blended(inkFocus, 0.14)` | `#2D2535` | `#282828` (0.12 fg) |
| `hairline` | `background.blended(inkFocus, 0.20)` | `#382D43` | `#323232` (0.18 fg) |

Both fractions are chosen so the result matches the **relative luminance** of the
neutral it replaces: the line changes hue, never weight. Nothing gets brighter.

`background`, `barBackground`, `panelBackground` and `selectedRowBackground` are
untouched. The planks are tinted; the compartments they divide are not — the metaphor
stated in colour. Under a hueless `focusAccent` the tint vanishes and both resolve back
to greys, which is the correct answer to choosing a hueless accent.

---

## 2. The changes row

### 2.1 `XY` stays, and starts telling the truth

Keep the letters. They are what `git status` prints, and a vocabulary of baia's own
would be one more thing to learn for a reader who already knows this one. **No legend** —
a legend is an admission that the thing it explains failed to.

What is wrong is that the marker is coloured **once, for the whole row**. `X` is the
index and `Y` is the working tree — two independent facts — and today a file that is
staged *and* since modified renders `MM` in one colour, throwing away the half that says
"you will lose the second M if you commit now".

**Colour the columns separately.** The marker becomes self-teaching: left is in the
commit, right is not.

| Marker | Derivation | Resolves | Meaning |
|---|---|---|---|
| `X` present | `staged` | `#45C445` | In the index. What a commit right now would contain. |
| `Y` present | `warn` | `#C4C445` | Working tree only. A commit right now would leave it behind. |
| `??` | `inkFaint` | `#898989` | Untracked. Git is not watching it; neither column applies. |
| `UU` | `alert` | `#FF5555` | Unmerged. Both columns are the conflict, so both are red. |
| empty | — | — | **A space, not `"."`.** The font is monospaced; position carries it. |

**One new derivation:**

```swift
/// A staged change. Built like `warn`, from the adjacent ANSI slot, so the pair
/// reads as a pair. Not raw `ok`: that is a signal light and never text.
public var staged: RGB { background.blended(with: ansiColor(2), fraction: 0.75) }  // #45c445
```

8.0:1 on the body. Not raw `ok`, which the row uses today — `ansi[2]` at full strength
is a signal light and its own docstring says "never used for text".

The sort order needs nothing: conflicts, staged, unstaged, untracked, by path within
each. That is what `git commit` needs answered in the order it needs it, and it is
already implemented.

### 2.2 Row anatomy

| Constant | Value | Note |
|---|---|---|
| `rowHeight` | 18 | kept — see §6 |
| `rowBaseline` | 13 | from the row top, cap-centred: (18 + 7.8) / 2 |
| `inset` | 12 | both surfaces and the heading. Files uses 10 today |
| `markerColumn` | 26 | two glyphs at 6.62 plus a 12.8 gap |

**Every string in a row draws from one origin:**

```
y = rowTop + rowBaseline - font.ascender
```

The same rule the footer uses with `baselineFromTop` 15 in a 22pt bar. Today the marker
draws at `y + 3` and the path at `y + 1`, both top-origin in a flipped view, so the
marker sits 2pt below the path it labels — in the one row this whole pass is about.

Path colouring is unchanged and correct: directory `inkFaint` `#898989`, basename
`foreground` `#BBBBBB`.

### 2.3 The row is a target now — five states

Clicking writes the path onto the focused pane's prompt, unrun. That is a real action
with a real refusal, so the row owes four answers it does not currently give: that it
can be clicked, that it is being clicked, that the click landed, and that it did not.

| State | Fill | Resolves | Ink | Timing |
|---|---|---|---|---|
| rest | none | — | unchanged | cursor `.pointingHand` over the body |
| hover | `selectedRowBackground` | `#282828` | unchanged | 150ms |
| pressed | `background.blended(inkFocus, 0.16)` | `#31313B` | unchanged | none, while held |
| landed | the pressed fill, released | `#31313B` | unchanged | 90ms in / 220ms out |
| refused | `background.blended(alert, 0.24)` | `#3D1E1E` | path → `alert` | 90ms in / 220ms out |

**Landed and refused are deliberately not symmetric, and capture 10 is why.** A landed
click already has a loud confirmation: zsh brackets the inserted path and draws it
highlighted on the prompt line, which is the largest thing on screen and exactly where
the next keystroke goes. A second announcement in the sidebar would be the app saying the
same thing twice. So landing is just the pressed fill fading out — enough to mark *which
row* was hit, which is the only part the pane cannot answer.

`alert` carries the refusal alone, because nothing else happens at all: the prompt does
not move, and today the only signal is a beep, which is inaudible on a muted machine and
indistinguishable from every other beep on an audible one. Same 90 / 220 shape as the
release, so the two read as one gesture with two outcomes.

A refusal is rare and unrepeatable — the path will not become sendable — so it needs to
be legible once rather than persistent. It beats an inline error line, which would need a
row's worth of height the layout cannot give.

**One API change.** `onSelect` hands over a `String` and hears nothing back, so the row
cannot know which flash to draw:

```swift
var onSelect: ((String) -> Bool)?   // true = landed, false = refused
```

`PromptPath.Resolution` already carries exactly that distinction, so the surface stays as
ignorant of quoting as it is now while gaining the one bit it needs.

---

## 3. The path that does not fit

### The bug

`ChangesRowsView` draws the path with `line.draw(in:)` into a rect `Self.rowHeight` tall.
`draw(in:)` **wraps**, and `/` is a break opportunity — so a path too wide breaks after a
directory, the second line falls outside an 18pt rect, and **what gets clipped is the
file name the row exists to show**. Rows render as `Sources/Workspace/` with no file.
This is captures 07 and 09.

### The budget

```
column       260
- inset       12 leading + 12 trailing
- marker      26
= path       210pt ÷ 6.62 advance = 31 characters

at the 120pt minimum   70pt = 10 characters
```

### The decision: a path loses its **directory**, never its **name**

Draw one line with `draw(at:)`, and elide the directory ourselves before drawing,
measuring as we go.

| Width | Renders | Rule |
|---|---|---|
| fits | `Packages/PaneChrome/Sources/PaneChrome/PaneTheme.swift` | — |
| 260pt · 31ch | `Packages/…/PaneTheme.swift` | elide middle directories; keep the last while it fits |
| 200pt · 22ch | `…/PaneTheme.swift` | all directories collapse to one `…/` |
| 160pt · 14ch | `PaneTheme.swift` | directory goes entirely; the name is whole |
| 120pt · 10ch | `PaneT….swift` | floor only: middle-truncate the **stem**, always keep the extension |

The file name is the answer to "which file"; the directory is context for it. Any scheme
that shortens them together — a trailing ellipsis, a middle ellipsis over the whole
string, an `NSLineBreakMode` on the attributed string — spends the width on the half that
matters less.

Keep the extension: a `.swift` and a `.md` with the same stem are different files, and
tail-truncation would make them one row twice.

**The marker never truncates and never moves.** It is 26pt of fixed column, two glyphs,
and the only thing on the row that cannot be recovered by widening the sidebar.

Name-first ordering was the alternative and it loses: it breaks the column's alignment,
so the eye can no longer run down a fixed left edge of names — which is the whole reason
the directory is faint and the name is not.

**Why this matters beyond the bug.** The ladder degrades over 140pt of width without ever
losing the identifying fact, so the column stays useful at every width the drag allows
and the owner is never pushed toward widening it to read a row. The fix has to make the
*current* width sufficient, because the alternative costs every pane a `SIGWINCH`. The
tree gets the same ladder for its names, which is what makes §5's depth budget work.

---

## 4. The column

### 4.1 The heading

28pt currently spends itself on a static word the config already chose. It can carry
three things without growing, and it must not grow.

| Part | Spec |
|---|---|
| label | mono 11 **regular**, ALL CAPS, +0.08em tracking, `inkContext` `#9D9D9D` |
| count | mono 11, `inkFaint` `#898989`, 6pt after the label. **Changes only.** |
| anchor | system 11 semibold, `inkFocus` when key else `foreground`, trailing |
| baseline | 18 from the heading's top, cap-centred in 28 |
| height | 28, unconditional |

Caps and tracking make the label a label rather than a title, so it stops competing with
the row text below it at the same size. **Regular, not the `.medium` it uses today** —
weight is the row's tier signal, not the heading's.

The count is Changes only: a repository's total file count is not a fact anyone needs.
It also earns the heading its keep at the 48pt minimum — two rows under `CHANGES 41` is
still a useful section; two rows under `CHANGES` is a broken one.

`headingBaseline` 18 replaces `(bounds.height - size.height) / 2 + 1`, whose `+ 1` exists
because the view is not flipped.

### 4.2 The anchor name is the footer answer

The same string, in the same treatment, appears in the focused pane's footer and at the
top of the column, and **that repetition is the connection**. Anything else would be a
connector drawn between two things that could simply agree.

The footer stands nothing down: it reports `*3 ?2 !1` on one line and the column names
which. Drawn on bar material, so the anchor takes the same repaired `#C890FF` the footer
does.

**Only the first heading carries it.** In `both` the two sections are the same
repository, and printing it twice would say there were two.

### 4.3 The split between two stacked sections

| State | Treatment |
|---|---|
| rest | **nothing** — body `#141414` meeting heading `#212121` is the boundary |
| hover | 2pt along the lower heading's top edge, `bg.blended(fg, 0.30)` `#464646`, 150ms |
| drag | 2pt, `inkFocus` `#C890FF` |
| grab | 7pt tall, centred on the boundary, unchanged |

§1 put body and heading on different materials, so the boundary already exists. What is
missing is not a mark but a **reply**. The same three-state vocabulary the split divider
between panes uses: undiscoverable becomes discoverable on approach, and the column gains
no permanent chrome for a control used once a session.

**Drawn by the heading, not by the grab view.** `DividerGrabView` stays transparent and
hit-only; it just tells the heading below it which of the three states to draw. That keeps
the 2pt inside the heading's fixed 28 and out of the layout.

---

## 5. The tree

### 5.1 Indent guides

Depth is the tree's whole problem in a 260pt column: four levels in and you are counting
spaces to work out where you are. Draw a 1pt vertical guide at every ancestor level, in
`divider` — the same colour and weight as the line between two panes. Each nesting level
is literally a plank, which is the app's own name for itself.

| Constant | Value | Note |
|---|---|---|
| `inset` | 12 | was 10; now agrees with Changes and the heading |
| `indent` | 12 | per level |
| `chevronColumn` | 12 | was 14 — one indent step, so a child's name lands under its parent's chevron |
| guide | 1pt at `inset + d * indent + 5`, for every `d < depth` | `divider` `#2D2535`, full row height so guides join into columns |
| directory | `inkContext`, trailing `/` | |
| file | `foreground` | |

The trailing slash is doing real work: a collapsed directory and a file with no extension
are otherwise the same row with a chevron that may or may not be there. It is also what
every shell prints — the same argument that keeps `XY`.

**Depth budget.** 236pt at 6.62/char. At depth 4 the name starts at 72 and has 164pt = 24
characters, dropping to 22 once the status column is reserved. Deeper than that and §3's
ladder truncates the stem — the tree gets the same rule as the changes list, which is why
it needs no rule of its own.

### 5.2 Per-file status — wanted and unbuilt

**Trailing, one glyph, 12 from the right edge. `statusColumn` 14.**

Leading is where indentation lives; a status column on the left would either push every
name right by 26pt — a quarter of the depth budget — or collide with the guides. Trailing
costs the name 14pt at any depth and never moves as the tree expands.

One glyph rather than `XY`, because the changes list is where the index-versus-worktree
distinction is worth two columns. In the tree the question is "has this changed at all,
and how much should I care", so collapse to the **most urgent of the two**:

| Glyph | Colour | Meaning |
|---|---|---|
| `!` | `alert` `#FF5555` | conflict |
| `*` | `warn` `#C4C445` | unstaged |
| `M` | `staged` `#45C445` | staged |
| `?` | `inkFaint` `#898989` | untracked |
| — | — | nothing when clean |

`*` and `?` are the footer's own glyphs; `M` and `!` are git's. Nothing new is learned.

**A collapsed directory carries the strongest status beneath it.** That is what makes the
tree navigable rather than decorative: a closed `Sources/` showing `M` tells you the
change is in there, which is the one thing a collapsed row can say that its rows cannot.

### 5.3 Hover

| State | Treatment |
|---|---|
| rest | guides at `divider`, every level |
| hovered | row fill `selectedRowBackground` `#282828`; **the guide at index `d`** of a directory at depth `d`, in `inkFocus`, spanning its descendant rows only |
| fade | 150ms, with the row fill |

You see the extent of what you are about to collapse before you collapse it, which is the
question a chevron never answers. One guide, never the ancestors — the row fill already
says which row.

---

## 6. Density, scroll and states

### Density — 18pt stays, and the reason it was chosen was wrong

The source says `rowHeight` 18 matches the terminal. It does not: ghostty at font size
11.5 draws a line about 15pt tall, so an 18pt row is already 20% looser than the grid
beside it. The rows never lined up and cannot, because the fonts and sizes differ.

Keep it anyway, for a reason that only became true when rows became clickable: **18pt is
the target.** Tightening to 16 buys two more rows in a 220pt section and costs 11% of
every hit area in a list where a misclick puts the wrong path on a live prompt. That is
the wrong trade — the one `FileTreeRowsView` already learned when it split the row on x
and gave the chevron a 7pt target.

If more rows are ever wanted, the honest lever is the split, not the row: dragging the
Changes section shorter shows more of the tree and costs no accuracy.

### Scroll

**Overlay scrollers, autohiding** — which is what both surfaces already do. Nothing
further: a legacy scroller takes 15pt of width permanently, and width is the one dimension
that costs a `SIGWINCH`. The count in the heading is what tells you there is more below —
a list of nine showing four is legible as partial precisely because the heading says nine.

### Empty, and absent

| State | Treatment |
|---|---|
| `no changes` / `no files` | first row position, inset 12, `inkFaint`, lowercase |
| `not a repository` | **centred**, `inkContext`, with the anchor path beneath it in `inkFaint`, tilde-abbreviated |

A clean tree is not an error and should not be centred and announced — it reads as the
list's own first line, which is what it is. `not a repository` is a different kind of
answer: position and ink both say "this is not the empty version of the other thing", and
the path answers the question the message provokes.

Today (capture 12) both sit at first-row position in `inkFaint` — character for character
the treatment `no changes` gets. The two states the brief calls a real distinction are
drawn identically.

**Both sections say it, and that survives.** Two sections each answer for themselves;
suppressing the second would leave a heading with a blank body, which reads as broken
rather than as answered.

---

## 7. Edges

**Square, flush, no inset.** The sidebar owns the window's bottom-left corner and rounds
with it. The leftmost pane's footer goes square, which is what
`edgesCoveredByHost = [.left]` already tells it. Capture 13 confirms both.

Do not inset and do not round the column. An inset sidebar would put the window's own
background in a margin nothing else in this app has, and would hand the corner back to a
pane that would then have to round again — one more state for the corner logic to be
wrong about. Flush is also what makes §1 legible: the body running edge to edge is what
reads as another compartment rather than as a floating panel.

The `isHidden` on the gutter and the grab strip at zero width is already right, and it is
the one place a design could break the corner.

### Trailing edge: no

The icon is one plank with the occupied bay on its **leading** side, and the sidebar
reading as that shape is what decided the housing. Mirroring the column mirrors the app's
own picture of itself for a preference nobody has asked for.

The arithmetic being mirror-symmetric is what makes it cheap to add later, not a reason to
add it now. Two things would change, both one line: `edgesCoveredByHost` becomes
`[.right]`, and the status column in §5 would want to move leading so it does not sit
against the panes.

---

## 8. Corrections — read against the source, 2026-07-29

| # | Where | What |
|---|---|---|
| 01 | `ChangesRowsView` | **The path wraps and the file name is what gets clipped.** `line.draw(in:)` into a rect `rowHeight` tall; `draw(in:)` wraps at break opportunities, of which `/` is one. Captures 07 and 09. §3 replaces it with a measured elision and `draw(at:)`. |
| 02 | `ChangesRowsView` | Marker at `y + baseline` where `baseline = 3`, path at `y + 1`. Both top-origin in a flipped view, so **the marker sits 2pt below the path it labels**. One `rowBaseline` for both. |
| 03 | both surfaces | Insets disagree: `ChangesRowsView.inset` 12, `FileTreeRowsView.inset` 10, `SurfaceTitleView` draws its title at 12. Stacked, the tree is 2pt out from everything above it. One constant, 12. |
| 04 | `ChangesRowsView` | `Marker.colour(in:)` returns one colour for the whole row, so `MM` renders both letters as staged. Per-column colour, per §2. Also `theme.ok` is used as text, which its own docstring forbids — `staged` replaces it. |
| 05 | `SurfaceTitleView` | The hairline exists and is not where the brief says. The view is **not flipped**, so `NSRect(x: 0, y: 0, …)` draws along its own **bottom** edge — correct, and worth a comment saying so, since the `+ 1` in the title's centring is there for the same unflipped reason. **The split between two sections still has nothing on it**: `DividerGrabView` is transparent. §4.3 answers with a hover state rather than a line. |
| ~~06~~ | ~~`FileTreeRowsView`~~ | ~~No `resizeSubviews` override, so the document view only ever grows.~~ **Fixed 2026-07-29** — both views override `layout()` and clamp to the clip view, with a guard against the re-layout loop. |
| ~~07~~ | ~~`ChangesRowsView`~~ | ~~Changes rows are inert.~~ **Implemented** — both surfaces carry `onSelect` and the path picker landed. That is what makes §2.3's five states necessary rather than speculative. |

### Still unverified

The brief says `View → Switch Sidebar` "cycles all four live". `SidebarHost.show(_:)`
takes a whole stack and an empty list closes the column, so the mechanism is there — but
whether `off` is in the cycle, and whether the command can reopen from `off`, is worth
confirming against `AppDelegate` before it is written down as behaviour. Same shape as the
`focusAccent` no-op: a key decoded and stored while nothing read it.

---

## 9. Design tokens — the constants, ready to type

```swift
// PaneTheme — one addition
/// A staged change. Built like `warn`, from the adjacent ANSI slot, so the pair
/// reads as a pair. Not raw `ok`: that is a signal light and never text.
public var staged: RGB { background.blended(with: ansiColor(2), fraction: 0.75) }  // #45c445

// Lines carry the accent; surfaces do not
/// Both fractions match the relative luminance of the neutral they replace, so the
/// line changes hue and never weight. Under a hueless focusAccent these resolve back
/// to greys, which is the correct answer to choosing a hueless accent.
public var divider: RGB  { background.blended(with: inkFocus, fraction: 0.14) }  // #2d2535
public var hairline: RGB { background.blended(with: inkFocus, fraction: 0.20) }  // #382d43
// Unchanged and deliberately neutral: background, barBackground, panelBackground,
// selectedRowBackground. A surface is a compartment; only the planks are tinted.

// Material
body      background @ settings.backgroundOpacity   #141414 @ 0.85
heading   barBackground, opaque                     #212121
hairline  on the heading's BOTTOM edge              #382d43
gutter    1pt, sidebar to tree                      #382d43

// Metrics — one set for both surfaces
rowHeight        18      // kept because it is a target, not because it matches the
                         // terminal — ghostty at 11.5 draws a ~15pt line
rowBaseline      13      // from the row top, cap-centred: (18 + 7.8) / 2
inset            12      // Changes 12 already; Files was 10; heading 12 already
markerColumn     26      // two glyphs at 6.62 plus a 12.8 gap
indent           12      // per tree level
chevronColumn    12      // was 14 — one indent step
guideInset        5      // 1pt guide at inset + d * indent + 5, for every d < depth
statusColumn     14      // trailing, one glyph, 12 from the right edge
headingHeight    28      // unconditional
headingBaseline  18      // from the heading top; replaces the unflipped + 1
grabHeight        7      // unchanged

// Every string in a row draws from one origin:
//     y = rowTop + rowBaseline - font.ascender

// The changes row
marker   mono 11, X coloured by the index and Y by the working tree, independently
         X present   staged      #45c445      ??   inkFaint  #898989
         Y present   warn        #c4c445      UU   alert     #ff5555
         empty column  a space, not "."
path     directory inkFaint #898989 · basename foreground #bbbbbb
         ONE line, draw(at:), never draw(in:)

// The path ladder. Elide the DIRECTORY; the name is the invariant.
fits            Packages/PaneChrome/Sources/PaneChrome/PaneTheme.swift
elide middle    Packages/…/PaneTheme.swift          keep the last dir while it fits
drop all dirs   …/PaneTheme.swift                   still says "not at the root"
no dirs         PaneTheme.swift
floor only      PaneT….swift                        middle-truncate the STEM,
                                                    always keep the extension

// Row states — a fill and an ink, never a geometry
rest      no fill, cursor .pointingHand over the body
hover     selectedRowBackground              #282828   150ms
pressed   background.blended(inkFocus, 0.16) #31313b   while held, no transition
landed    the pressed fill, released         #31313b   ink unchanged, 90ms / 220ms
          // quiet on purpose: zsh already highlights the inserted path on the
          // prompt line (capture 10). The row only marks WHICH row was hit.
refused   background.blended(alert, 0.24)    #3d1e1e   path → alert, 90ms / 220ms
          // loud on purpose: nothing else happens. The prompt does not move and
          // the beep is inaudible muted and ambiguous audible.
// onSelect becomes ((String) -> Bool)? so the row knows which flash to draw.

// The heading
label    mono 11 REGULAR, ALL CAPS, tracking +0.08em, inkContext
count    mono 11, inkFaint, 6pt after the label. Changes only.
anchor   system 11 semibold, inkFocus when key else foreground, trailing.
         First section only — in `both` the two are one repository.

// The tree
directory  inkContext, trailing "/"        file  foreground
guide      divider #2d2535, 1pt, full row height, at every ancestor level
hover      row fill selectedRowBackground; the guide at index d in inkFocus,
           spanning that directory's descendant rows only
status     trailing, one glyph, most urgent of X and Y:
           !  conflict   *  unstaged   M  staged   ?  untracked   (nothing when clean)
           a collapsed directory carries the strongest status beneath it

// The split between two stacked sections
rest     nothing — body #141414 meeting heading #212121 is the boundary
hover    2pt along the lower heading's top edge, bg.blended(fg, 0.30) #464646, 150ms
drag     2pt, inkFocus #c890ff
// Drawn by the heading, inside its fixed 28. DividerGrabView stays transparent and
// hit-only, and just reports which state to draw.

// States
no changes / no files   first row, inset 12, inkFaint, lowercase
not a repository        centred, inkContext, with the anchor path beneath it in
                        inkFaint, tilde-abbreviated. Both sections say it.
scroll                  overlay scrollers, autohiding. No legacy scroller: 15pt of
                        permanent width is the one dimension that costs a SIGWINCH.

// Edges
sidebar owns the window's bottom-left corner and rounds with it
leftmost pane footer goes square — edgesCoveredByHost = [.left], already correct
no inset, no rounding on the column itself
trailing edge: no. The icon puts the occupied bay leading.
```

### Accent — `focusAccent: "midnight"`

```
inkFocus  ansi[4].blended(ansi[5], 0.5) = #aa55ff
          4.18:1 on barBackground, so readable() repairs it one step to #c890ff at 6.8:1
```

Used in three places in the sidebar: the heading's anchor name, the split while dragged,
and the hovered tree guide. Nothing in the row marker vocabulary takes it — `#C890FF`
accent, `#45C445` staged, `#C4C445` unstaged, `#FF5555` conflict are all well separated,
so focus never reads as a git state.

---

## 10. Typography

| Role | Font | Size | Weight |
|---|---|---|---|
| heading label | SF Mono | 11 | regular |
| heading count | SF Mono | 11 | regular |
| heading anchor | SF Pro Text | 11 | semibold |
| row marker | SF Mono | 11 | regular |
| row path | SF Mono | 11 | regular |
| tree name | SF Mono | 11 | regular |
| tree status | SF Mono | 11 | regular |

`NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)` advances 6.62pt per
character — every width budget in this document is derived from that number.

---

## 11. Constraint compliance

Each of the four hard constraints, and how every proposal here meets it:

- **No first responder.** Every new state is a tracking area and a redraw. No control, no
  table view, no selection. Every view in the column still returns false from
  `acceptsFirstResponder`, including the ones that now flash.
- **No width change.** Every value is a colour, a height, or an x-offset inside 260pt. The
  path ladder exists precisely so the current width is sufficient — the alternative to
  eliding is widening, and widening costs every pane a `SIGWINCH`.
- **No conditional heading height.** 28pt regardless of content, focus, count or hover.
  The split's 2pt hover edge is drawn *inside* the heading rather than above it, for
  exactly this reason.
- **No literal colour.** One new derivation (`staged`), two retuned (`divider`,
  `hairline`), four row fills all `background.blended(…)`. Nothing reads `NSAppearance`.

---

## 12. Files

| File | What |
|---|---|
| `baia-sidebar-design-pass-standalone.html` | The spec document, self-contained. **Open this.** |
| `Baia Sidebar Design Pass.dc.html` | Same document, as source. Needs a server. |
| `support.js`, `_ds/` | Required siblings of the `.dc.html`. |
| `captures/07…13` | The seven source screenshots the recreations were built from. |
| `2026-07-27-design-v3-sidebar-handoff.md` | The brief this answers. |
| `github.md` | Repo/branch/commit record and the screen → source map. |

### Source files this touches

| Area | File |
|---|---|
| §1 material, §9 tokens | `Packages/PaneChrome/Sources/PaneChrome/PaneTheme.swift` |
| §2 the row, §3 the path | `Sources/ChangesSurface.swift` |
| §3 refusal semantics | `Packages/PanePrompt/Sources/PanePrompt/PromptPath.swift` |
| §4 the column | `Sources/WorkspaceSurface.swift` (`SurfaceTitleView`), `Sources/SurfaceHosts.swift` |
| §5 the tree | `Sources/FilesSurface.swift` |
| §7 edges | `Sources/SurfaceHosts.swift` (`edgesCoveredByHost`, `DividerGrabView`) |
| §8 unverified | `Sources/AppDelegate.swift` (`toggleSurfacePanels`) |

---

## Suggested order

1. **§3 the path ladder** and **§8/01–02** — the wrap bug is a correctness failure and
   fixing it retires the `draw(in:)` that causes the baseline disagreement.
2. **§9 tokens** — `staged`, `divider`, `hairline`. Everything else reads them.
3. **§1 material** and **§8/03** — one line each, and they make the rest legible.
4. **§2.1 per-column markers** and **§2.2 one baseline**.
5. **§4 the heading** — label weight, count, anchor name.
6. **§2.3 the five row states**, with the `onSelect` signature change.
7. **§5 the tree** — inset, chevron column, guides, then status.
8. **§4.3 and §6** — the split hover, and the two empty states.
