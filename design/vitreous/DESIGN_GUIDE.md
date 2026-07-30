# Vitreous — a glass design system for macOS apps

Vitreous is an **original** design system for building Mac apps in the current macOS glass idiom:
translucent, lensed surfaces floating over the desktop, platform control metrics, the system font
stack, and a runtime-switchable accent. It was built for an **agent-centric terminal app** (the
`agent_terminal` kit is the reference implementation) and generalizes to the other Mac archetypes.

## Scope and provenance — read this first

- This system is **not Apple's** and does not reproduce Apple's Liquid Glass implementation,
  private specs, or assets. Apple's macOS 26/27 material is a proprietary, still-changing system
  design language; its exact recipes are not public.
- What Vitreous grounds itself in: **public platform conventions** — 13px body type, 20/22/28/32px
  control heights, 24px menu bar, 28px titlebar, 52px unified toolbar, 220px sidebars, hairline
  separators, traffic-light window controls, the light/dark/reduced-transparency appearance model,
  and the standard system accent hues.
- **No Apple binaries are shipped**: no SF Pro, no SF Symbols, no app icons, no wallpapers of Apple's.
  Type resolves through `-apple-system`, so a Mac renders the real system face and every other
  platform gets a metric-compatible fallback.
- Treat every value here as *this system's* opinion. If you are shipping to the App Store, verify
  against Apple's current Human Interface Guidelines and the SDK you build against.

## Sources given

- The user's brief: liquid glass for macOS apps, macOS 26/27 idiom, dark + light + tinted, full
  multi-accent set, glass intensity 95/100, documented low/high motion, ~30 components, chrome
  (menu bar, Dock, Control Center, Spotlight), and an agent-centric terminal app as the product.
- `assets/wallpapers/desk-ae86.jpg` — the user's own wallpaper, used as the desktop backdrop
  every kit and card sits on.
- Public reporting on the macOS 26 "Tahoe" appearance for terminology only (Liquid Glass as a
  translucent system material that lenses rather than merely blurs; a "clear" default with a
  higher-opacity "tinted" option; transparent menu bar; refined Dock, sidebars and toolbars).

---

## VISUAL FOUNDATIONS

### The idea

**Lensed glass over the desktop.** A surface is never a flat tinted box: it is a translucent fill,
a saturating blur, a bright top rim, a dark bottom rim, and — on larger surfaces — a specular sheen
and a corner refraction highlight. Light appears to bend at the edge instead of scattering evenly.
Nothing in the system is opaque, so the wallpaper is always part of the composition.

### Materials

Eight materials, one recipe, chosen by **role** (`tokens/materials.css`):

| Material | Fill (dark, ink-tinted) | Blur | Used for |
| --- | --- | --- | --- |
| ultraThin | ink 26% | 14px / sat 180% | inline cards, tiles, rows |
| thin | ink 34% | 24px / 180% | buttons over content, composer, message bubbles |
| regular | ink 42% | 40px / 190% | window body, content panes |
| thick | ink 52% | 60px / 165% | sheets, alerts, Dock |
| chrome | ink 44% | 48px / 200% | titlebar, toolbar, status bar, table headers |
| sidebar | ink 34% | 40px | source lists |
| menu | ink 58% | 60px | menus, popovers, palette |
| hud | ink 62% | 72px | tooltips, floating overlays |

Dark glass tints toward **ink**, never white: a white-alpha fill over a bright wallpaper turns the whole
app milky grey. The bright top rim and the sheen supply the highlight; the blur's `brightness()` sits
below 1.0 so the backdrop darkens as it thickens. Light appearance inverts this — there the fills are white at
58–88% with a `brightness()` above 1.2, because light glass over a dark desktop needs to actually be
light rather than a grey haze; its window frame also carries a brighter hairline ring so it separates
from the wallpaper. Tinted then reads as the same glass one step denser (ink 58–88%), not a different theme.

Rules: never nest `regular` inside `regular` (step to `ultraThin`); turn the sheen off above ~900px
width; blur and saturation always rise together; the window itself is `regular`, its chrome is
`chrome`, and anything floating above it is `menu` or `hud`.

### Color

- **Labels are alphas, not colors**: 96 / 60 / 38 / 22% white in dark, 90 / 55 / 32 / 18% black in
  light. Never pure white text, never a colored body paragraph.
- **Fills** (`--fill` → `--fill-quaternary`, 10 → 2.5%) are for control interiors that sit *inside*
  a material rather than being one.
- **Accent** is a single runtime variable. Eight accents ship (blue, purple, pink, red, orange,
  yellow, green, graphite) and swap by setting `[data-accent]` on the root. The accent may color:
  selection, focus rings, default buttons, switches/checkboxes, progress, and the unread dot.
  Nothing else. Yellow and green flip `--label-on-accent` to near-black for contrast.
- **System hues are status only** — positive/caution/negative/info. They never decorate.
- **Terminal palette** (`--term-*`) exists because agent apps show transcripts: dimmed foreground on
  a 42%-black well, six syntax hues that survive translucency. The five hues are re-declared darker in
  the light and light+tinted scopes — pastel syntax colors fall to ~1.3:1 on a white material, so any
  new hue you add must ship a light value too.
- Separators are hairlines at 10–16% — never a 1px solid line, never a colored left border.

### Appearance modes

Three scopes, set on the root element and nothing else:

- `[data-appearance="dark"]` — the base.
- `[data-appearance="light"]` — inverts labels and fills; materials become white at 44–78% with
  higher brightness, and shadows soften to 13–30% black.
- `[data-glass="tinted"]` — the readability/accessibility mode. **Still glass, not a second theme**:
  fills rise to 0.58–0.88 (dark) / 0.86–0.96 (light) so the wallpaper stays faintly present, blur stays
  high (20–38px), saturation stays up so accents keep their chroma, the rim and a reduced sheen survive,
  and only the corner refraction is dropped. Secondary/tertiary labels brighten. Metrics, layout and
  color roles are untouched, so any screen can be reviewed in all three modes.

One exception to the appearance model: the **desktop menu bar sits on the wallpaper, not on an app
material**, so it does not follow `--label`. It uses `--menubar-label` (light in every appearance) over
`--menubar-scrim`, exactly as the platform keeps menu-bar text light over dark desktops. On a light
wallpaper, override `--menubar-label` / `--menubar-scrim` per desktop — never per appearance.

Also honour `prefers-reduced-motion` (already wired in `tokens/motion.css`).

### Typography

System stack only (`--font-system`, `--font-mono`). 13px body / 17px line is the baseline; 26/22/17/15
titles; 11px subheadline; 10px footnote for status bars and caps labels. 590 is the platform semibold.
**Mono carries machine truth** — every path, sha, branch, count, cost, duration, command and transcript
line is mono; sans carries prose. Never set reading copy below 13px, and never set a metric in sans.

### Metrics

Platform values, not an 8px grid: controls 16/20/22/28/32; rows 24/28/36; titlebar 28; unified toolbar 52;
menu bar 24; menu item 22; status bar 24; tab 28. Radii 3/5/6/8/10/12/16/20, window 11, sheet 16, capsule
for fields and pills. Panes: sidebar 220 (min 180, wide 260), list 300, inspector 280, popover 300,
palette 640. Insets: pane 10, row 8, content 20.

### Elevation and depth

Shadows are paired with rims, never used alone: `control` (0 1 2 /.34) → `raised` (0 4 14) →
`popover` (0 12 38) → `sheet` (0 32 80) → `window` (0 26 70 + a 0.5px hairline ring). The accent glow
(`--shadow-accent`) is reserved for default buttons and engaged switches. Inputs invert the logic:
they are **wells** — inner shadow, no outer rim — because glass is a raised material.

### Motion

Two documented settings on the root: `[data-motion="low"]` (default) uses `cubic-bezier(.32,.72,0,1)`
with 90/140/220/340ms steps and a 0.98 press scale; `[data-motion="high"]` swaps in a springy
`cubic-bezier(.34,1.42,.64,1)`, elastic sheets, specular sweeps and a 0.955 press. Hover brightens the
fill and never moves the control. Focus is a 1px accent stroke plus a 3px ring. Sheets rise 12px and
settle; menus and popovers scale from 0.97. No bounce in low, no travel in either.

### Layout

Windows are the unit: rounded 11px, traffic lights at 12px with 8px gaps, unified titlebar+toolbar on
chrome material, optional sidebar whose titlebar segment is transparent to the sidebar, optional
inspector on the trailing edge, status bar at the bottom. Content columns cap at ~72ch with
`text-wrap: pretty`. Only the middle pane scrolls; chrome stays put.

### Imagery

The system ships no illustration style. Imagery = the user's desktop wallpaper (dark, cool, high
contrast works best) and content the app itself renders. If a screenshot or thumbnail is needed and
absent, show a labelled empty glass surface rather than inventing artwork.

---

## CONTENT FUNDAMENTALS

macOS app voice: terse, concrete, in the user's vocabulary, never chatty.

- **Sentence case everywhere** — window titles, buttons, menu items, section headers. Menu items and
  toolbar labels are Title Case only when they name a command in the menu bar itself
  ("New Session", "Export Transcript…").
- **Buttons are verbs**: Run, Stop, Approve, Deny, Create, Commit…, Reset…. A trailing ellipsis means
  "this opens something else". Never "OK" where a verb fits.
- **Destructive language is explicit**: "Discard 3 uncommitted changes?" not "Are you sure?".
- **Numbers are facts, set in mono**: `$1.23`, `62% context`, `5 of 5 passed`, `38.7s`, `+6 −3`,
  `4f2c9ab`. Round money to cents, durations to one decimal, percentages to integers.
- **Status words come from the machine**: running, queued, done, review, pending, blocked, passed,
  failed, clean, awaiting approval.
- **Secondary copy explains consequences**, one line, at secondary alpha: "Applies to new sessions
  only.", "Reads, searches, git status."
- **No emoji.** No exclamation marks. No "Oops". No marketing adjectives.
- Empty states say what would be here and what to do: "No pending approvals. Tools run
  automatically while auto-approve is on."

---

## ICONOGRAPHY

**This system deliberately ships no icons.** The brief specified text-only labels, and every kit
honours that: toolbar items, sidebar rows, menu items and tiles are typographic. In their place:

- **Text labels** at 13px/500 for controls, 11px for metadata.
- **Status dots** (`StatusDot`, sidebar `marker`) carry state instead of glyphs.
- **Unicode symbols only where they are the platform's own vocabulary**: keyboard glyphs
  (⌘ ⌥ ⇧ ⌃ ⏎ ⎋ ↑ ↓), disclosure triangles (▶), sort arrows (▲▼), checkmarks (✓), the search
  loupe and stepper chevrons (tiny inline SVG shapes drawn as part of the control, not an icon set).
- **Lettered tiles** stand in for app icons in the Dock and for file kinds in the browser grid.

If you later adopt an icon set, add an `Icon` wrapper component and document the set here — do not
sprinkle inline SVG through screens.

### Assets

- `assets/wallpapers/desk-ae86.jpg` — the user's wallpaper; `--desktop-image` points at it. Swap that
  one token to re-shoot every kit and card on a different desktop.
- No logo exists for the sample app ("Atlas"); its name is set in plain type wherever a mark would go.

---

## INDEX

| Path | What |
| --- | --- |
| `styles.css` | Entry point — imports every token file |
| `tokens/typography.css` | System + mono stacks, sizes, weights, semantic type roles |
| `tokens/color.css` | Greys, label alphas, fills, separators, system hues, 8 accents, terminal palette |
| `tokens/materials.css` | The glass recipe: fills, blurs, rims, sheen, refraction, elevation, desktop backdrop |
| `tokens/metrics.css` | Control heights, chrome heights, radii, pane widths, insets |
| `tokens/motion.css` | Easings, durations, low/high motion, keyframes, reduced-motion |
| `tokens/appearance.css` | `[data-appearance="light"]` and `[data-glass="tinted"]` scopes |
| `ds-runtime.js` | Resolves the compiled component bundle as `window.VG` (falls back to transpiling sources) so cards and kits run standalone |
| `guidelines/` | 19 specimen cards — Materials, Appearance, Colors, Type, Metrics, Motion |
| `components/controls/` | Button, SegmentedControl, Switch, Checkbox, RadioGroup, Slider, Stepper, PopUpButton, TextField, SearchField, TokenField, ProgressBar |
| `components/display/` | Badge, StatusDot, KeyCap, Spinner, Divider, Tooltip, Table, ListRow |
| `components/surfaces/` | Material, Box, GroupedSection, SplitView, Inspector, Popover, Menu, Sheet, Alert |
| `components/chrome/` | WindowFrame, Toolbar (+ToolbarButton/Separator), Sidebar, Tabs, MenuBar, Dock, ControlCenter, CommandPalette |
| `ui_kits/agent_terminal/` | **Reference app** — sessions, transcript, approvals queue, worktree diff, cost dashboard, run inspector, ⌘K palette |
| `ui_kits/desktop/` | Menu bar, layered windows, Control Center, Spotlight palette, Dock |
| `ui_kits/settings/` | Settings window; its Appearance pane drives the system's own modes |
| `ui_kits/three_pane/` | Sidebar + list + reading pane (mail/notes/feeds) |
| `ui_kits/file_browser/` | Columns / grid / sortable list, path bar, Quick Look sheet |
| `ui_kits/editor/` | Tabs, diff gutter, problems + test inspector |
| `ui_kits/chat/` | Conversation list, thread, glass composer |
| `ui_kits/menu_bar_utility/` | Status-item popover and Control Center panel — an app with no window |
| `assets/wallpapers/` | Desktop backdrop |
| `SKILL.md` | Agent-Skills entry point |

### Intentional additions

Beyond the standard Mac control set, three components exist because the target product is an agent
terminal: **KeyCap** (shortcut hints), **StatusDot** (agent/check/queue state), and the
`--term-*` palette used by the transcript surfaces. Deliberately absent: Avatar, Accordion,
Breadcrumbs, Carousel, and anything icon-dependent.

## Caveats

1. **Not Apple's system.** Independent interpretation; verify against the current HIG before shipping.
2. **No SF Pro / SF Symbols** — system stack + text labels. Real SF appears only when viewed on a Mac.
3. **Icon-free by request.** Screens read as typographic; adding an icon set later will change density.
4. `backdrop-filter` is the whole system. In print, screenshots, or renderers without it (some
   screenshot pipelines), glass falls back to flat translucent fills — use `[data-glass="tinted"]` for
   those contexts.
5. Sample content ("Atlas", sessions, threads, files) is invented to exercise components at realistic
   density; replace it with real product copy before using a kit as a spec.
