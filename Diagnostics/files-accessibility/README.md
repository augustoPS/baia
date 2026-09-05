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
