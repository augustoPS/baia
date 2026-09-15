# Files accessibility fixture

Run `./run.sh` from any directory. The fixture compiles the production
`FileTreeRowsView` and its shipped source dependencies with Swift 6 and
`-default-isolation MainActor`, then exercises its virtual accessibility outline
without creating an `NSWindow`, launching baia, or moving focus.

It verifies that every visible tree node, including nodes outside the clip, is a
stable semantic row with the drawn filename, repository-relative path, hierarchy,
selection, disclosure and enabled state. It also presses the production AX rows
to prove files reach the existing `onSelect` closure, directories use the existing
expand path, disabled and obsolete rows refuse, and a callback that replaces the
tree cannot retarget selection to a replacement row.

It also asserts the shape VoiceOver's table mode needs. VoiceOver walks an
`AXList` through its children, so the palette's leaf rows speak; it walks an
`AXOutline` in table mode, where the cursor lands on cells and never on a bare
row. The 2026-09-10 native capture read "Files, table, No selection." and no
cursor move entered a row, while the same rows were reachable over the AX API.
The fixture therefore requires that a table-family container gives every row one
`AXCell` child (a list may keep leaf rows), and that each cell names its row as
parent, speaks the row's filename and full path, covers the row's frame, reports
the row's enabled and selected state and row index, exposes `AXPress` that
selects through the row's path, keeps its identity across expansion, and goes
stale with its row after a root or tree replacement. The outline's
`AXVisibleCells` and `AXSelectedCells` follow the rows. Whether VoiceOver also
needs `AXColumns` on the container is not decidable here; only a native run
answers it.

The final arm measures a direct AX walk over 251 and 1001 flattened rows. Each
sample makes three passes that ask every production row for index, label, value,
frame, disclosure level, enabled state, selected state, and disclosed parent,
then asks the directory for its disclosed children. The fixture takes the
median of three samples at each size. Four times as many rows must take less
than ten times as long. The ratio leaves headroom above linear growth while
rejecting the measured quadratic path search; the fixture prints both median
nanosecond samples and their ratio. This is an in-process work-bound check, not
a VoiceOver speech or latency measurement.

The build and executable live in one uniquely named `mktemp` directory. The EXIT
trap removes that exact directory and nothing else.
