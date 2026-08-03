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

## What it grades, and why it takes two clicks

The first run, 2026-08-03, ended with `printf '%s' 'src/caf` sitting on the
prompt. The opening quote and the ASCII prefix arrived; the 0xE9 and everything
after it did not; the quote never closed and nothing executed. That is one
observation with two possible causes, and no screenshot separates them:

1. **zsh's line editor cannot hold the bytes.** ZLE decodes its input as
   characters, and 0xE9 announces a three-byte UTF-8 sequence that `.txt` does
   not complete. The bytes reached the pty and the editor is what failed.
2. **ghostty filters them.** `ghostty_surface_text` may validate UTF-8, in which
   case the tail never left the emulator and `sendBytes` is writing into a sieve.

So there are two checks, and the pair is the instrument.

**Check 1 sends into `cat`.** It reads the pty in canonical mode with no line
editor in front, so what lands in its file is exactly what the emulator
delivered. This is the one that answers whether the bytes exist at all.

**Check 2 sends onto a command line**, which is the real feature: a path a
command can use. It is expected to be the harder of the two.

`classify.py` grades each and names the layer:

| Result | Diagnosis |
|---|---|
| both match `'src/caf<E9>.txt' ` | the route is sound end to end |
| 1 passes, 2 fails | the emulator is honest; ZLE is where a non-UTF-8 path cannot go |
| both truncated at `caf` | ghostty is the filter, and `sendBytes` writes into it |
| either matches `'src/caf<EF><BF><BD>.txt' ` | a Swift `String` is still on the route |
| nothing written | the quote never closed, which is the editor refusing the bytes |

The U+FFFD row is a negative control rather than a restatement: a run matching it
has regressed to the original defect, which is a different thing from a run that
merely fails, and the output says which.

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

## Row indices, now observed

Row 2 under an expanded `src/` is `caf<E9>.txt`, confirmed against the 2026-08-03
capture. The derivation happened to be right, which it had no business being: it
came from `path-picker`'s sort order rather than from this fixture. The two
dotfiles `fixture.sh` writes are untracked, so `ls-files --others` lists them and
they take rows 4 and 5, below `src/`'s children and below nothing that is clicked.
