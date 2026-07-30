# Vitreous — rules for implementing this design system

Read `README.md` first (handoff spec, token tables, porting map), then `DESIGN_GUIDE.md`
(foundations and content voice). The files in `tokens/` are the contract — the numbers in them win
over any prose, including this file.

## Non-negotiables

1. **Nothing is opaque.** Every surface is a material over the desktop. No solid window, pane, sidebar or
   toolbar background. If the wallpaper cannot show through, the design is broken.
2. **Every material is five layers**: fill + backdrop blur/saturate + bright top rim + dark bottom rim +
   (large surfaces) sheen and refraction. A blurred box with no rim is not this system.
3. **Dark glass tints toward ink** (`rgba(20,22,26,α)`, `brightness()` < 1), never white-alpha.
   **Light glass is genuinely light** (white 58–88%, `brightness()` ≈ 1.26).
4. **Pick materials by role**, not by look: chrome for titlebars/toolbars/status bars, sidebar for source
   lists, menu for menus/popovers/palette, hud for tooltips/overlays, ultraThin→thick for content by how
   much backdrop should show through.
5. **Never nest `regular` in `regular`** — step down a depth. Sheen off above ~900px wide.
6. **Inputs are wells**: inner shadow, no outer rim, `--fill-tertiary` interior.
7. **Labels are alphas** (96/60/38/22% dark, 90/55/32/18% light). No pure-white text, no colored prose.
8. **One accent per window**, read from `--accent` / the system accent. It may color only: selection,
   focus rings, default buttons, switches/checkboxes/radios, progress, unread dots, links.
9. **System hues are status only.** Never decorative.
10. **Platform metrics, not an 8px grid**: controls 20/22/28/32, rows 24/28/36, titlebar 28, toolbar 52,
    menu bar 24, menu item 22, status bar 24, window radius 11, hairlines 0.5px.
11. **Mono for machine truth** — every path, sha, branch, count, cost, duration, command, transcript line.
    Sans for prose. Body never below 13px.
12. **Text labels only** — this system ships no icon set. Use StatusDot / marker dots for state and the
    platform's own Unicode glyphs for keys, disclosure, sort and checks.
13. **Support all three appearances**: `[data-appearance="dark"|"light"]` and `[data-glass="tinted"]`.
    Tinted is still glass (wallpaper faintly visible, saturation up), never a flat dark theme, and it
    changes no layout, metric or color role.
14. **Two motion settings**: `[data-motion="low"]` default (ease `cubic-bezier(.32,.72,0,1)`, press
    .98), `"high"` springy (press .955). Hover brightens and never moves. Focus is a 1px accent stroke
    plus a 3px ring. Honour reduce-motion.
15. **`min-width: 0` on every grid/flex child that can hold long mono content**, or panes overflow.

## Voice

Sentence case. Buttons are verbs (Run, Approve, Commit…). A trailing ellipsis means "opens something
else". Destructive copy is explicit ("Discard 3 uncommitted changes?"). Numbers are facts, set in mono.
Status words come from the machine (running, queued, pending, passed, failed, clean). Secondary copy
explains consequences in one line at secondary alpha. **No emoji, no exclamation marks, no marketing
adjectives.** Empty states say what would be here and what to do.

## Do not

- Ship the bundled `.jsx` or `ds-runtime.js` — they are inline-styled previews and a dev loader.
- Reproduce `backdrop-filter` math by hand on Apple platforms; use the platform materials.
- Reimplement the menu bar or Dock in a real app — those kits are context only.
- Add colors, radii, type sizes or spacing values that are not in `tokens/`.
- Claim or imply this is Apple's Liquid Glass. It is an original interpretation, ships no Apple assets,
  and must be checked against the current Human Interface Guidelines before shipping.
