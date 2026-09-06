# Capsule and cards accessibility fixture

Run `./run.sh` from any directory. It compiles the production capsule, shared
card rows, three card views, and embedded approval view with Swift 6 and
`-default-isolation MainActor`, then queries and presses their AppKit
accessibility elements without creating an `NSWindow`, launching baia, or
changing focus.

The fixture verifies meaningful roles and labels, selected and enabled state,
the standard card cancel action, callback arguments, stable child identity,
disabled actions, model/result generation fences, reentrant changes-card
replacement, retained-card dismissal, late-result refusal, and the approval
one-answer fence. It exercises the production views and closures directly; it
does not reconstruct a semantic transcript.

`./run-controller-lifetime.sh --compile-only` compiles the additional
real-window fixture without launching it. The coordinator can run
`./run-controller-lifetime.sh` from a second terminal to exercise the actual
`ClusterCardController` show, replacement, close, and dismiss boundaries. That
run creates a temporary host window and takes key, so it is deliberately not a
safe in-pane probe; the compile-only mode creates no window and changes no
focus. The fixture compiles the controller and cards from production source;
its two-line `PalettePanel` stand-in is checked against the shipped definition
before compilation.

Each runner puts compiler products under one uniquely named `mktemp`
directory. Its EXIT trap removes that exact directory and nothing else.
