# padding-respawn

Measures part of Q02: what a live padding or material edit does to a pane
that already exists. The observable is the pane's shell and everything under
it: their pids are recorded before each edit and compared after. A respawned
pane would show a new shell pid; a pane reconfigured in place keeps it.

`run.sh` builds Debug, launches a disposable copy through
`Diagnostics/lib/isolated-app.sh` with one pane and the control channel on,
then `probe.py` rewrites the copy's config four times (padding 8 to 24,
material liquidGlass to solid, solid to liquidGlass, padding back to 8), waits three
seconds after each for the watcher to apply it, and compares descendant
pids. Finally it splits a new pane over the socket to show the app still
spawns after the edits, and that the original pane's processes survive.

## Pass criterion

Every edit leaves the descendant pid set unchanged and the app answering,
the new pane opens with its own shell, and normal state fingerprints are
unchanged afterwards.

## What it does not prove

Whether the existing pane's grid, insets or scrollback changed on screen,
which is what the Q02 caption question is about; that needs the desktop
check in the owner live-check queue. It puts a window on screen but never
takes the keyboard.
