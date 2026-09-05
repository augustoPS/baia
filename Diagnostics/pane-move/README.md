# pane-move

**The question:** does a pane keep its shell when it moves?

`PaneTree.moving` is pure and twelve package suites cover it. None of them can
answer this. The whole design rests on `rebuild()` re-parenting live surfaces
rather than making them, which is true because `makeViewController` answers a
`.leaf(id)` with `panes[id]`, the controller that already exists. If that were
wrong the pane would come back as a fresh surface with a fresh shell and every
test would still pass.

## Run it from inside a pane

```
./Diagnostics/pane-move/live.sh
```

**Unlike the isolated Debug-app launchers**, this one cannot launch a copy: the
pane it needs is the pane it runs in. It opens two panes, moves one, and leaves
all three on screen for the eye. It does not pkill or `open` a bundle.

## The evidence

Each new pane prints one line before anything moves:

```
MARKER pane=<id> pid=<shell pid>
```

The shell prints it about itself, so the line carries both halves of the question.
After the move the probe reads the same pane's screen back through the control
channel and checks four things: the marker is byte-identical, the pid is
unchanged, that process is still alive, and the pane it landed beside was not
disturbed.

The aliveness check is separate on purpose. The marker is scrollback and would
survive a shell that had died, so a screen comparison alone cannot tell a live
process from its epitaph.

## What it does not cover

The `SIGWINCH`. A move rebuilds the whole tree, so every pane in the window takes
a resize signal, and a full-screen TUI redraws. That is the stated cost rather
than a defect, and it is visible to the eye in the window this leaves open.
