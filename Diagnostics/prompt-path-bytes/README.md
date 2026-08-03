# Prompt path bytes probe

**The question:** when a sidebar row names a file whose name is not valid UTF-8,
do those exact bytes reach the shell?

`./run.sh` from anywhere, and **never from inside a baia pane**: it launches and
drives `baia-dev.app` with real events. `theme-catalog` and `app-icon` are the two
probes safe in a pane; this is not one of them.

## Why it is not a check inside `path-picker`

Two reasons, and the second is the interesting one.

`path-picker` grades by reading the focused pane's last line over the control
channel. That cannot work here. A terminal's screen buffer holds decoded text: the
emulator turns arriving bytes into cells, and a byte that is not valid UTF-8
becomes U+FFFD on the way in. A correct send and the exact defect this exists to
catch therefore read back identically. The assertion has to come from the shell,
which receives bytes, rather than from the screen, which receives characters.

So the command line is assembled as `printf '%s' <clicked path> > sent.bin`: the
click supplies the middle, zsh writes the argument out untouched, and `cmp` grades
the file against bytes the fixture recorded. Nothing in that route decodes.

The other reason is mundane. `path-picker` addresses rows by hardcoded index, and
adding one row to its fixture silently shifts five working checks.

## The fixture holds a file this machine cannot create

APFS refuses a filename that is not valid UTF-8 at creation, so the name cannot be
written to disk on macOS and never will be. Git has no such rule: a Unix filename
is a byte string with two rules, no NUL and no slash, and git records what the
index holds. A clone from an ext4, NFS or ExFAT checkout carries such names into
the index on a Mac that could not have made them.

`fixture.sh` therefore writes the entry straight into a tree object with `mktree`,
which takes the name as bytes, and reads it into the index. `git status` reports
it `AD`, in the index and absent from the worktree, which is what the
cloned-from-elsewhere case actually looks like here after checkout declines the
name. Confirmed 2026-08-02 that `git ls-files -z` and `git status --porcelain=v2
-z` both emit the 0xE9 unchanged, and those are the two commands `GitCommand` runs
behind the Files tree and the Changes list.

## What it grades

One click, two assertions:

- the bytes the shell received equal the bytes git holds, `'src/caf<E9>.txt' `
- and they are not `'src/caf<EF><BF><BD>.txt' `, which is what the same click
  produced while the path went through a Swift `String`

The second is a negative control rather than a restatement. A run that matches it
has regressed to the original defect, which is a different thing from a run that
merely fails, and the output says so.

The route under test is the whole of it: git's index, `GitStatusParser`,
`RepositoryPath`, the surface's `onSelect`, `PromptPath`,
`TerminalPaneController.send`, the patched `sendBytes`, and
`ghostty_surface_text`.

## It needs a human once, and it blocks silently without one

Attempted unattended 2026-08-03 and it hung. It got as far as launching
`baia-dev` and stopped there: nothing was written to `verify-out/`, no click was
posted, and the script sat indefinitely rather than failing.

The cause is macOS TCC. Every event helper in `Diagnostics/lib/drive.sh` goes
through `act`, whose first action is `osascript -e 'tell application id ... to
activate'`, and the first time the calling process drives System Events macOS
puts up an Automation consent dialog and **blocks the `osascript` call until
somebody answers it**. Overnight nobody did. `UserNotificationCenter` was up the
whole time, which is the tell.

This is not the locked-screen case and does not look like it. `activate_app`
gives up after eight tries with `ABORT: <app> never came to the front`, so a
screen that cannot bring a window forward fails in about eight seconds and says
so. A hang with no output is the dialog.

So the first run of this probe on a machine, or after a Automation permission is
reset, has to be watched by a person who can click Allow. Runs after that are
unattended-safe. Grant it in System Settings > Privacy & Security > Automation
for whichever app hosts the shell.

What the attempt did prove, which was the open question about running it from
inside a baia pane: the identity guards hold. `quit_app` pkills a pattern
anchored at the absolute path of the worktree's `baia-dev`, and the Release
`baia` this pane runs in was still alive afterwards. `act` refuses to type unless
the frontmost process is named `baia-dev`, and nothing was typed into the pane.
The shared `~/.config/baia/config.json` was rewritten to `sidebar: files` for the
run and restored by the `EXIT` trap, confirmed after the kill.

## Row indices are derived, not observed

The click targets row 2 under an expanded `src/`. This probe was written from
inside a baia pane, where it could not be run, so that number comes from the sort
order `path-picker` recorded rather than from a capture of this fixture. **Confirm
it against `1-clicked.png` on the first run and correct `run.sh` rather than
guessing.** path-picker's first version was off by one throughout and every check
failed against the wrong row.
