# Palette accessibility

This fixture proves that the production `PaletteListView` exposes the drawn
palette and find results as an accessibility list with row children. It checks
the list's required label and rows attributes, generation-fenced row indices,
selected and enabled state, visible-row updates, press routing through the
list's existing activation closure, and refusal by disabled or obsolete rows.
It also checks the notifications a result replacement delivers:
`layoutChanged` always, `rowCountChanged` when the count moves, and
`selectedRowsChanged` when the current selection remains valid. It does not
post a speech announcement.

`run.sh` compiles `Sources/CommandPaletteView.swift` verbatim with the real
`PaneChrome` sources. The fixture creates no window, starts no application event
loop, changes no focus, and writes only to one `mktemp` directory that its exit
trap removes exactly.

Run from any directory:

```bash
/Users/pasqualotto/Projects/baia/Diagnostics/palette-accessibility/run.sh
```

The existing Debug libghostty build products are link inputs because
`PaneChrome` imports `GhosttyTheme` and `GhosttyTerminal`. If those products are
absent, the fixture refuses with a command to create them. It does not build or
launch baia.
