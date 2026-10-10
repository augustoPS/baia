# Native tab layout

Run `bash Diagnostics/tab-close-layout/run.sh` from any directory.

Measures actual AppKit native-tab opening, returning to the original tab, and
closing the sibling tab in non-key accessory windows. It compiles the production
content-layout observer and resize delegate from
`WorkspaceWindowController.swift`. No layout is forced after opening or closing.

Checks that both the newly opened tab and the original tab when selected lay out
against the expanded 68 pt band, then that the original tab lays out against the
collapsed 32 pt band after its sibling closes. The window frame must stay fixed.

Run `bash Diagnostics/tab-close-layout/run.sh --without-observer` as a negative
control. This omits the extracted production observer assignment. It must fail
with the new tab's stale 32 pt band instead of 68 pt after opening a sibling. Before the opening assertion was added, the pre-fix source failed
on closure with a stale 68 pt band instead of 32 pt.

The hosts are small measuring content controllers, not Ghostty terminals or the
full sidebar. The test covers the production layout invalidation boundary and
real native tab transitions. It does not measure terminal grid resizing,
terminal rendering, full sidebar geometry, glass pixels, or the installed app.

No Baia app is launched or activated. No shell, settings, session, or support files
are read or changed. Windows cannot become key or main and close on exit.
