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

The build and executable live in one uniquely named `mktemp` directory. The EXIT
trap removes that exact directory and nothing else.
