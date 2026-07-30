# Handoff: Vitreous — macOS glass design system

## Overview

Vitreous is a complete design system for building **Mac apps in the current macOS glass idiom**:
translucent "lensed" surfaces floating over the desktop wallpaper, platform control metrics, the
system font stack, three appearance modes (dark / light / tinted), eight runtime-switchable accents,
and two documented motion settings.

It was designed for an **agent-centric terminal app** — `ui_kits/agent_terminal/` is the reference
implementation, with a session sidebar, transcript with inline tool-call approvals, an approvals queue,
worktree diff review, a cost dashboard, a run inspector, and a ⌘K command palette. Six more kits cover
the other Mac archetypes (desktop chrome, settings, three-pane content, file browser, code editor,
chat, menu-bar utility).

This bundle contains **the system, not one feature**: tokens, 37 components, 19 foundation specimen
cards, and 8 app kits.

## About the design files

Everything in this bundle is a **design reference written in HTML/CSS + plain React** — prototypes that
show intended look, metrics and behavior. They are **not production code to copy directly.**

The task is to **recreate these designs in the target codebase's own environment**, using its
established patterns and libraries:

- **SwiftUI / AppKit (the intended target).** The token files are the spec. Map them as described in
  "Porting to SwiftUI" below — platform materials, `NSVisualEffectView`, asset-catalog colors with
  light/dark variants, `ControlSize`, `.presentationBackground`. Do **not** try to reproduce
  `backdrop-filter` math by hand; use the platform materials and use these tokens to decide *which*
  material, *which* rim, and *which* elevation.
- **A web / Electron / Tauri app.** `styles.css` + `tokens/` can be used nearly as-is (plain CSS
  custom properties, no build step). Rewrite the `.jsx` components in the codebase's component library
  and styling approach; the JSX here is inline-styled on purpose, for streaming previews, and should not
  be shipped that way.
- **No environment yet.** Pick the framework that fits the product — for a Mac app, SwiftUI — and
  implement the designs there.

The `.jsx` files are the most precise statement of every value; the `.d.ts` files define each
component's API; the `.prompt.md` files say when to use each one and when not to.

## Fidelity

**High fidelity.** Colors, type, metrics, radii, shadows, blurs, motion curves and interaction states
are final and specified numerically in `tokens/`. The kits are pixel-accurate at their stated
viewports and interactive (real state, not static mocks). Content is invented sample data ("Atlas",
sessions, threads, files) sized to exercise components at realistic density — **replace all copy with
real product copy.**

## ⚠️ Scope and legal note — read before shipping

- This is an **original interpretation** of the macOS glass idiom. It is **not Apple's Liquid Glass**,
  does not reproduce Apple's implementation or private specs, and ships **no Apple assets** — no SF Pro,
  no SF Symbols, no Apple wallpapers or icons.
- What it is grounded in: **public platform conventions** — 13px body type, 20/22/28/32px control
  heights, 24px menu bar, 28px titlebar, 52px unified toolbar, 220px sidebars, hairline separators,
  traffic-light window controls, the light/dark/reduced-transparency appearance model, and the standard
  system accent hues.
- Type resolves through `-apple-system`, so a Mac renders the real system face and other platforms get
  a metric-compatible fallback. **Verify against the current Human Interface Guidelines and the SDK you
  build against before shipping.**

---

## The core idea (implement this or nothing else matters)

**Lensed glass over the desktop.** A surface is never a flat tinted box. Every material is five layers:

1. a translucent fill,
2. a saturating backdrop blur,
3. a **bright top rim** (`inset 0 0.5px 0` at 42% white),
4. a **dark bottom rim** (`inset 0 -0.5px 0` at 38% black),
5. on larger surfaces, a 147° specular **sheen** and a corner **refraction** highlight.

Light appears to bend at the edge rather than scatter evenly. Consequences:

- **Nothing is opaque.** No window, pane, sidebar or toolbar gets a solid background. The wallpaper is
  part of the composition; remove it and the system reads as flat grey.
- **Dark glass tints toward ink, not white.** Dark fills are `rgba(20,22,26,α)` with `brightness()`
  *below* 1. White-alpha fills over a bright wallpaper turn the app milky grey — this was the single
  biggest correction made during design. The rim and sheen supply the highlight instead.
- **Light glass must actually be light**: white at 58–88% with `brightness()` ≈ 1.26, and a brighter
  window hairline ring so it separates from a dark desktop.
- **Inputs invert the logic.** Glass is a *raised* material, so text fields are **wells**: inner shadow,
  no outer rim, `--fill-tertiary` interior.

---

## Design tokens

All tokens are plain CSS custom properties in `tokens/`, imported by `styles.css`. Those files are
the source of truth; the tables below summarize them.

### Materials — `tokens/materials.css`

Eight materials, one recipe, chosen by **role, never by look**.

| Material | Fill (dark) | Backdrop filter (dark) | Used for |
| --- | --- | --- | --- |
| `ultraThin` | `rgba(20,22,26,.26)` | `blur(14px) saturate(180%) brightness(.98)` | inline cards, tiles, quiet rows |
| `thin` | `rgba(20,22,26,.34)` | `blur(24px) saturate(180%) brightness(.96)` | buttons over content, composer, bubbles |
| `regular` | `rgba(20,22,26,.42)` | `blur(40px) saturate(190%) brightness(.94)` | window body, content panes |
| `thick` | `rgba(22,24,28,.52)` | `blur(60px) saturate(165%) brightness(.90)` | sheets, alerts, Dock |
| `chrome` | `rgba(18,20,24,.44)` | `blur(48px) saturate(200%) brightness(.96)` | titlebar, toolbar, status bar, table headers |
| `sidebar` | `rgba(18,20,24,.34)` | regular blur (40px) | source lists |
| `menu` | `rgba(30,32,37,.58)` | thick blur (60px) | menus, popovers, command palette |
| `hud` | `rgba(18,20,24,.62)` | `blur(72px) saturate(150%) brightness(.86)` | tooltips, floating overlays |

Rules: never nest `regular` inside `regular` (step down to `ultraThin`); turn the sheen off above
~900px width (it becomes a gradient, not a highlight); blur and saturation always rise together; the
window is `regular`, its chrome is `chrome`, anything floating above is `menu` or `hud`.

**Lensing layers**

```
--lens-rim:        inset 0 0.5px 0 rgba(255,255,255,.42), inset 0 -0.5px 0 rgba(0,0,0,.38)
--lens-rim-strong: inset 0 1px 0 rgba(255,255,255,.52), inset 0 -1px 0 rgba(0,0,0,.44),
                   inset 1px 0 0 rgba(255,255,255,.12), inset -1px 0 0 rgba(255,255,255,.08)
--lens-edge:       0 0 0 0.5px rgba(255,255,255,.14)
--lens-sheen:      linear-gradient(147deg, rgba(255,255,255,.26) 0%, rgba(255,255,255,.06) 22%, transparent 48%)
--lens-sheen-soft: linear-gradient(180deg, rgba(255,255,255,.14) 0%, transparent 38%)
--lens-refract:    radial-gradient(120% 90% at 12% -10%, rgba(255,255,255,.18) 0%, transparent 62%)
```

**Elevation** — shadows are always paired with a rim, never used alone.

| Token | Value | For |
| --- | --- | --- |
| `--shadow-control` | `0 1px 2px rgba(0,0,0,.34)` | buttons, switches, small controls |
| `--shadow-raised` | `0 4px 14px rgba(0,0,0,.34), 0 1px 2px rgba(0,0,0,.26)` | cards, boxes |
| `--shadow-popover` | `0 12px 38px rgba(0,0,0,.48), 0 2px 6px rgba(0,0,0,.30)` | menus, popovers, Dock |
| `--shadow-sheet` | `0 32px 80px rgba(0,0,0,.56), 0 4px 12px rgba(0,0,0,.34)` | sheets, alerts, palette |
| `--shadow-window` | `0 26px 70px rgba(0,0,0,.62), 0 0 0 0.5px rgba(255,255,255,.14)` | windows (drop + hairline ring) |
| `--shadow-accent` | `0 2px 10px var(--accent-glow)` | default buttons, engaged switches **only** |

### Color — `tokens/color.css`

**Labels are alphas, not colors.** Dark: 96 / 60 / 38 / 22% white. Light: 90 / 55 / 32 / 18% black.
Never pure-white body text, never a colored paragraph.

```
--label            rgba(255,255,255,.96)   headings, values, active rows
--label-secondary  rgba(255,255,255,.60)   body copy, subtitles
--label-tertiary   rgba(255,255,255,.38)   caps labels, metadata, units
--label-quaternary rgba(255,255,255,.22)   gutter numbers, disabled
--label-on-accent  #ffffff                 (black 88% under yellow/green accents)
```

**Fills** — control interiors that sit *inside* a material rather than being one: `--fill` .10,
`--fill-secondary` .07, `--fill-tertiary` .045, `--fill-quaternary` .025 (white in dark; black at
.06 / .04 / .028 / .018 in light).

**Separators** are hairlines: `--separator` 10%, `--separator-opaque` 16%, drawn at 0.5px
(`--hairline`). Never a 1px solid line, never a colored left border.

**System hues** — status only, never decoration.

| Token | Dark | Light |
| --- | --- | --- |
| `--system-blue` | `#0a84ff` | `#007aff` |
| `--system-purple` | `#bf5af2` | `#af52de` |
| `--system-pink` | `#ff375f` | `#ff2d55` |
| `--system-red` | `#ff453a` | `#ff3b30` |
| `--system-orange` | `#ff9f0a` | `#ff9500` |
| `--system-yellow` | `#ffd60a` | `#ffcc00` |
| `--system-green` | `#32d74b` | `#34c759` |
| `--system-teal` | `#64d2ff` | `#5ac8fa` |
| `--system-graphite` | `#98989d` | `#8e8e93` |

Semantic: `--status-positive` green, `--status-caution` orange, `--status-negative` red,
`--status-info` blue.

**Accent** is one runtime variable. Set `[data-accent="blue|purple|pink|red|orange|yellow|green|graphite"]`
on the root element. Derived: `--accent-hover` (+14% white), `--accent-press` (+18% black),
`--accent-quiet` (22%), `--accent-glow` (44%), `--focus-ring` (58%), `--selection` (82%).
Yellow and green flip `--label-on-accent` to `rgba(0,0,0,.88)`.

**The accent may color only**: selection, focus rings, default buttons, switches / checkboxes / radios,
progress fills, the unread dot, and links. Nothing else.

**Terminal palette** (agent apps show transcripts): `--term-bg` (42% ink well), `--term-fg` 94%,
`--term-dim` 46%, and six hues — dark `#7ee787 #79d4ff #d2a8ff #ffd479 #ff7b72`, re-darkened for
light glass to `#1a7f37 #0969da #8250df #9a6700 #cf222e` (the dark pastels sit at ~1.3:1 on a white
material).

**Menu bar** has its own tokens because it rides on the wallpaper, not on app glass: `--menubar-label`
94% white, `--menubar-label-shadow`, `--menubar-scrim` (top-down black gradient). These stay light
in **both** appearances — a light wallpaper needs a per-desktop override, not a per-appearance one.

### Typography — `tokens/typography.css`

```
--font-system: -apple-system, BlinkMacSystemFont, "SF Pro Text", "SF Pro Display",
               "Helvetica Neue", "Segoe UI", system-ui, sans-serif
--font-mono:   ui-monospace, "SF Mono", "JetBrains Mono", Menlo, Consolas, monospace
```

| Role | Size / line | Weight |
| --- | --- | --- |
| large title | 26 / 32 | 700 |
| title 1 | 22 / 26 | 700 |
| title 2 | 17 / 22 | 590 |
| title 3 | 15 / 20 | 590 |
| headline | 13 / 17 | 590 |
| body | 13 / 17 | 400 |
| callout | 12 / 16 | 400 |
| subheadline | 11 / 14 | 400 |
| footnote / caption | 10 / 13 | 400 |
| mono | 12 / 16 | 400 |
| mono small | 11 | 500 |

**590 is the platform semibold.** Tracking: `--ls-large-title` .008em, `--ls-title` .004em,
`--ls-body` −.003em, `--ls-caps` .06em. Semantic shorthands exist as `--type-*` (e.g.
`--type-body`, `--type-headline`, `--type-mono`, `--type-caps`).

**Mono carries machine truth.** Every path, sha, branch, count, cost, duration, command and transcript
line is mono; sans carries prose. Never set reading copy below 13px. Never set a metric in sans.

### Metrics — `tokens/metrics.css`

Platform values, **not** an 8px grid.

- **Control heights**: mini 16, small 20, **regular 22**, large 28, prominent 32. Fields 22 / 28.
- **Rows**: list 24, regular 28, large 36, sidebar 28, menu item 22.
- **Chrome**: titlebar 28, unified toolbar 52, menu bar 24, tab 28, status bar 24, Dock 64.
- **Radii**: 3 / 5 / 6 / 8 / 10 / 12 / 16 / 20, window **11**, sheet 16, `--r-capsule` 999 for fields
  and pills.
- **Panes**: sidebar 220 (min 180, wide 260), list 300, inspector 280, popover 300, sheet 480,
  palette 640.
- **Insets**: pane 10, row 8, content 20, `--gap-row` 2, `--hairline` 0.5.
- **Spacing scale** `--sp-1…12`: 2, 4, 6, 8, 10, 12, 16, 20, 24, 32, 40, 56.

### Motion — `tokens/motion.css`

Two documented settings on the root element:

- `[data-motion="low"]` (**default**) — `--ease-standard: cubic-bezier(.32,.72,0,1)`, durations
  90 / 140 / 220 / 340 / 520ms, press scale **0.98**, no sheen travel.
- `[data-motion="high"]` — `--spring-bouncy: cubic-bezier(.34,1.42,.64,1)` for surfaces, elastic
  sheets, animated specular sweeps, press scale **0.955**.

Semantic transitions: `--t-control` (background / shadow / border / color), `--t-press` (transform),
`--t-surface`, `--t-sheet`. Keyframes: `vg-appear` (scale .97 → 1), `vg-rise` (12px + fade),
`vg-sheen`, `vg-pulse`, `vg-spin`, `vg-caret`. `prefers-reduced-motion` is already wired to
flatten everything to a linear fade with press scale 1.

**Interaction states** — apply consistently:

| State | Change |
| --- | --- |
| hover | fill brightens (~×1.4), edge strengthens; **nothing moves** |
| press | `scale(var(--press-scale))` over 90ms |
| focus | `inset 0 0 0 1px var(--accent)` + `0 0 0 3px var(--focus-ring)` — never an outline-offset |
| selected | `--selection` fill (accent 82%), label → `--selection-text`, weight → 590 |
| disabled | `opacity: .36`, no pointer feedback |

### Appearance modes — `tokens/appearance.css`

Three scopes, set **on the root element only**:

- `[data-appearance="dark"]` — the base (declared in `color.css`).
- `[data-appearance="light"]` — inverts labels / fills; materials become white 58–88% with
  `brightness()` 1.24–1.30; shadows soften to 13–42% black; the window ring brightens to
  `rgba(255,255,255,.30)`; terminal hues re-darken.
- `[data-glass="tinted"]` — the **readability / accessibility mode**. Opacity rises to .58–.88 (dark) /
  .86–.96 (light), blur drops to 20–38px, the sheen falls back to `--lens-sheen-soft`, refraction goes
  to `none`, secondary / tertiary labels brighten. **It is still glass** — the wallpaper stays faintly
  visible and saturation stays up so accents keep chroma. It must never become a flat dark theme, and it
  never changes layout, metrics or color roles.

All three must be supported by any implementation; the settings kit shows the control surface for them.

---

## Components

37 exports in four groups. Every component has three files: `.jsx` (exact values), `.d.ts` (typed
API), `.prompt.md` (when to use / when not to).

**`components/controls/`** — Button (push / accent / glass / borderless / destructive × 4 sizes),
SegmentedControl, Switch, Checkbox (with mixed state), RadioGroup, Slider (ticks + value label), Stepper,
PopUpButton (value + pull-down forms), TextField (single / multi-line, mono, prefix / suffix, invalid),
SearchField (scope chip + clear), TokenField, ProgressBar (determinate / indeterminate).

**`components/display/`** — Badge (5 tones, mono, filled, count), StatusDot
(running / ok / warn / error / idle + pulse), KeyCap, Spinner, Divider (optional caps label), Tooltip,
Table (sortable, selectable, mono / secondary columns, zebra), ListRow
(title / subtitle / leading / trailing / disclosure / depth).

**`components/surfaces/`** — **Material** (the primitive: 8 materials × 6 elevations × rim / sheen /
refract flags), Box, GroupedSection (settings rows), SplitView, Inspector, Popover, Menu, Sheet, Alert.

**`components/chrome/`** — WindowFrame (traffic lights, unified titlebar / toolbar, sidebar whose
titlebar segment is transparent to the sidebar, inspector, tabs, status bar, inactive state), Toolbar +
ToolbarButton + ToolbarSeparator, Sidebar, Tabs, MenuBar, Dock, ControlCenter, CommandPalette.

### Component API contract

Read the `.d.ts` files for exact props. Patterns worth preserving when porting:

- **Role-based variants, not style props.** `variant="accent"`, `material="chrome"`,
  `elevation="sheet"` — callers name intent, the system owns the values.
- **Controlled state.** Every interactive component takes `value` / `checked` + `onChange`; none
  holds app state.
- **Composition over configuration.** `WindowFrame` takes `sidebar`, `toolbar`, `inspector`,
  `tabs`, `statusBar` as slots; `SplitView` takes a `panes` array; `GroupedSection` takes
  `rows` with a trailing `control`.
- **Text labels only** (see Iconography).

---

## Screens / views

Each kit is a standalone interactive HTML file at a stated viewport, with its own README describing
structure and live interactions.

| Kit | Viewport | Purpose | Layout |
| --- | --- | --- | --- |
| **`agent_terminal/`** (reference) | 1280×800 | Run and supervise coding agents | Menu bar → WindowFrame (sidebar 220 + content + inspector 280) with tab strip and status bar; the toolbar's leading SegmentedControl switches the content pane between **Transcript / Approvals / Diff / Cost** |
| `desktop/` | 1280×800 | System chrome | Transparent menu bar, two layered windows (one inactive), Control Center panel, Spotlight palette, magnifying Dock |
| `settings/` | 1000×720 | App settings | WindowFrame (sidebar 200) + centered 620px column of GroupedSections; its Appearance pane drives the system's own modes live |
| `three_pane/` | 1280×800 | Mail / notes / feeds | SplitView: sidebar 220 + list 300 + reading pane (72ch max) |
| `file_browser/` | 1280×800 | Files | Three view modes over one tree: columns (push / pop panes), grid (lettered tiles), sortable Table list; Quick Look as a Sheet |
| `editor/` | 1280×800 | Code | Changed-files sidebar, document tabs with dirty dot, 56px gutter + diff-tinted source, inspector (Diff / Problems / Test) |
| `chat/` | 1180×760 | Messaging | Conversation list 260 + thread + glass composer; own messages take the accent fill, received are thin glass |
| `menu_bar_utility/` | 1100×620 | App with no window | Status item opens a 320px Popover that *is* the app; Control Center panel beside it |

### Agent terminal detail (the primary screen)

- **Sidebar (220)** — sessions with `marker` status dots and relative-time trailing text, worktrees
  group, search header, appearance / tinted footer controls.
- **Toolbar (52)** — leading view switcher; Run / Stop / Approvals (badge) / New session; trailing ⌘K
  search button and model PopUpButton.
- **Transcript** — user bubbles (accent-quiet, right-aligned), assistant bubbles (ultraThin), tool calls
  in a `--term-bg` well with tool Badge + mono target + duration, **pending approval** rows tinted
  caution with inline Approve / Deny, diff blocks with +/− counts, streaming indicator.
- **Composer** — thin-material rounded well, Plan / Act / Ask SegmentedControl, ⌘⏎ hint, accent Send.
- **Approvals** — multi-select queue with low / medium / high risk tiers, per-row Explain / Deny /
  Approve, bulk actions, and an empty state.
- **Diff** — file list with +/− counts and staged / unstaged badges, unified hunk with gutter and
  add / remove tints at 13% over glass, Stage / Revert hunk.
- **Cost** — four metric tiles, 7-day bar chart (today in accent), per-session Table, budget
  GroupedSection.
- **Inspector (280)** — Run / Tools / Cost tabs.
- **Status bar (24)** — StatusDot + current tool, mono metrics, state Badge.

### Interactions & behavior

- ⌘K / ⌘Space toggles the command palette; ⎋ dismisses palette, sheets and menus.
- Approving a pending tool call rewrites the transcript entry, clears the status-bar warning, and updates
  the toolbar badge and menu-bar status.
- Sheets rise 12px with a fade (`vg-rise`, 340ms); menus and popovers scale from 0.97 (`vg-appear`,
  140ms); alerts use the same rise.
- Sidebar filters live as you type — never require Return.
- Only the middle pane scrolls; chrome stays fixed. **Every grid / flex child that can hold
  `white-space: pre` content needs `min-width: 0`** or it overflows its pane (a real bug found
  during review).
- Scrollbars are 9px, `--fill` thumb, transparent track, inset by a 2px transparent border.

### State management

Per-window state used by the reference kit: current session id, content view, active tab, inspector tab,
sidebar query, palette open + query, sheet open, open menu id, composer draft, agent mode
(Plan / Act / Ask), model, auto-approve flag, temperature, appearance, glass mode, transcript entries
(with a derived `pending` flag).

Appearance / accent / motion belong on the root element as `data-appearance`, `data-accent`,
`data-glass`, `data-motion` — in a Mac app these map to `NSApp.effectiveAppearance`, the user's
accent color, and the reduce-transparency / reduce-motion accessibility flags.

---

## Porting to SwiftUI / AppKit

| Vitreous | Platform equivalent |
| --- | --- |
| `Material material="regular"` | `.background(.regularMaterial)` / `NSVisualEffectView` content background |
| `material="chrome"` | `.background(.bar)` / header-view blending mode |
| `material="sidebar"` | `NSVisualEffectView` `.sidebar` |
| `material="menu"` / `"hud"` | `.menu` / `.hudWindow` |
| `--lens-rim` | a 0.5pt top / bottom `LinearGradient` overlay stroke (SwiftUI has no rim primitive) |
| `--shadow-window` | window shadow + `.stroke(.white.opacity(0.14), lineWidth: 0.5)` |
| `WindowFrame` | `NSWindow` with `titlebarAppearsTransparent`, unified toolbar, `NSSplitViewController` |
| `Sidebar` | `List` with `.listStyle(.sidebar)` |
| `Inspector` | `.inspector(isPresented:)` (macOS 14+) |
| `Sheet` / `Alert` | `.sheet` / `.alert` with `.presentationBackground(.thickMaterial)` |
| `Popover` | `.popover` |
| `CommandPalette` | a borderless floating `NSPanel` |
| `MenuBar` / `Dock` | system-owned — do not reimplement; those kits are context only |
| `--accent` | `Color.accentColor` (respect the user's system accent instead of hardcoding) |
| control heights | `.controlSize(.small / .regular / .large)` |
| `[data-glass="tinted"]` | reduce-transparency accessibility flag |
| `[data-motion]` | reduce-motion accessibility flag |

Bring the token values across as a `Color` / `Metric` / `Material` namespace with light + dark
variants in an asset catalog — do not scatter literals.

## Assets

- `assets/wallpapers/desk-ae86.jpg` — **the user's own wallpaper**, the desktop backdrop behind every
  kit and specimen card. Referenced by the single token `--desktop-image`; swap it to re-shoot
  everything. Not for redistribution — replace with the user's real asset or the system desktop.
- **No icons, no logos, no fonts are bundled.** See below.

## Iconography

**This system ships no icon set — by design.** Every label is typographic (the brief called for
text-only labels). In place of icons:

- text labels at 13px / 500 for controls, 11px for metadata;
- `StatusDot` and sidebar `marker` dots for state;
- Unicode only where it is the platform's own vocabulary — ⌘ ⌥ ⇧ ⌃ ⏎ ⎋ ↑ ↓, ▶ disclosure, ▲▼ sort, ✓ check;
- tiny inline SVG shapes drawn *as part of* a control (search loupe, stepper chevrons, checkmark);
- lettered tiles standing in for app icons (Dock) and file kinds (browser grid).

If the target app adopts SF Symbols, add a single `Icon` wrapper and document the set — do not scatter
inline SVG through screens. Expect density to change noticeably once icons are added.

## Files in this bundle

```
README.md                  ← this document
CLAUDE.md                  ← condensed non-negotiable rules for the implementing agent
DESIGN_GUIDE.md            ← full design-system guide (foundations, content voice, index, caveats)
styles.css                 ← single entry point; imports all tokens
tokens/
  typography.css  color.css  materials.css  metrics.css  motion.css  appearance.css
components/
  controls/   12 components × (.jsx / .d.ts / .prompt.md) + 2 specimen cards
  display/     8 components × 3 + 1 specimen card
  surfaces/    9 components × 3 + 2 specimen cards
  chrome/      8 components × 3 + 2 specimen cards
guidelines/                ← 19 foundation specimen cards (materials, appearance, color, type, metrics, motion)
ui_kits/
  agent_terminal/  index.html + Transcript.jsx + RunInspector.jsx + Screens.jsx + data.js + README.md
  desktop/  settings/  three_pane/  file_browser/  editor/  chat/  menu_bar_utility/
ds-runtime.js              ← dev-only loader that resolves components as window.VG for the HTML previews
assets/wallpapers/desk-ae86.jpg
```

Open any `ui_kits/*/index.html` or `guidelines/*.html` directly in a browser (no build step) to see
the intended result. `ds-runtime.js` exists only to make those previews run standalone — **do not port
it.**
