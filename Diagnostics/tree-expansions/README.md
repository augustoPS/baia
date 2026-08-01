# tree-expansions

**The question:** does the file tree come back open after a quit, and is it keyed
under the anchor the sidebar actually uses?

`make test` cannot answer either half. The open set lives on a sidebar surface,
the key it is stored under is resolved by walking the filesystem for a repository
root, and the round trip is a real quit and a real launch.

## The defect it exists to catch

The pane opens in `<fixture>/src`, a subdirectory. Its tree anchors at
`<fixture>`, because `AnchorResolver.automatic` walks up to the repository root,
so the expansions are keyed under a path **no pane records as its working
directory**.

`SessionStore.reconciled` prunes the map to the anchors surviving panes resolve
to. Prune against the raw working directory instead and nothing claims
`<fixture>`, so the map is written correctly at quit and thrown away at the next
launch. Check 3 still passes; check 4 fails. Every unit test passes either way,
because a fixture whose working directory equals its anchor cannot tell the two
apart.

## The checks

| # | what it asserts |
|---|---|
| 1 | row 10 sends nothing while `src/` is closed. The negative control: without it, checks 2 and 4 would pass against a tree that is always open |
| 2 | row 10 sends `src/plain.txt` once `src/` is opened |
| 3 | ⌘Q leaves `fileTreeExpansions` in the session file, keyed under the resolved anchor and not under the raw working directory |
| 4 | after a relaunch, row 10 sends `src/plain.txt` with nothing clicked open |

Check 3 is asserted against the session file rather than against the screen,
because a map written under the wrong key looks identical in a capture.

**⌘Q, not `pkill`.** The session is flushed as the app terminates and a killed
process writes nothing, which is the difference between measuring the feature and
measuring an empty file.

## What it borrows

`Diagnostics/lib/drive.sh` for activation, clicks and captures.
`Diagnostics/lib/read-prompt.py` for the pane's own last line, moved there from
`path-picker/` when this became its second caller.

The fixture is `path-picker/fixture.sh`, and it is borrowed rather than rewritten
for one reason: its row indices were measured against a capture rather than
guessed, and a probe about which row is open cannot afford to be off by one.
path-picker's own README records that its first version was off by one throughout
and every check failed against the same wrong file.

## Running it

```
make build
./Diagnostics/tree-expansions/run.sh
```

The screen must be unlocked and the machine left alone: the clicks are real
events at real screen points and anything in front will take them. The config's
`sidebar` key and the session file are both backed up and restored on exit,
including on a kill.
