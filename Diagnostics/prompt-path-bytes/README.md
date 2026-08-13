# Prompt path bytes probe

**The question:** when a sidebar row names a file whose name the shell cannot
hold, is the click refused with a reason the owner can act on?

It used to ask whether the bytes reached the shell. That has an answer, below,
and the answer is why the question changed.

`./run.sh` from anywhere, and **never from inside a baia pane**: it launches and
drives `baia-dev.app` with real events. `theme-catalog` and `app-icon` are the two
probes safe in a pane; this is not one of them.

## Why it is not a check inside `path-picker`

`path-picker` addresses rows by hardcoded index, and adding a row to its fixture
silently shifts five working checks. Its own file says so, having been off by one
throughout on its first version.

The stronger reason was true while this graded bytes and is worth keeping as the
record: `path-picker` asserts by reading the pane's last line over the control
channel, and a terminal's screen buffer holds decoded text. The emulator turns
arriving bytes into cells, and a byte that is not valid UTF-8 becomes U+FFFD on
the way in, so a correct send and the defect read back identically. That is what
forced the `cat` route, and it is why the byte question could never have been
answered inside `path-picker`.

Now that the answer is a refusal, the channel read is the right instrument again,
because absence is what is being asserted and absence is ASCII.

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

The question this probe was built for has an answer, and the answer changed what
it grades.

**Measured 2026-08-03.** Clicked into `cat`, which reads the pty with no line
editor in front of it, `'src/caf<E9>.txt' ` arrived byte for byte: the emulator
delivers exactly what `sendBytes` writes, and every layer from git's index to
`ghostty_surface_text` is honest. The same click onto a command line left
`printf '%s' 'src/caf` on the prompt with the quote still open, because zsh's
line editor decodes its input as characters and drops everything from the first
byte that is not valid UTF-8.

Sending was the worse of the two failures available. A half-line reads as the app
having lost the click, and it has to be cleared by hand before anything else can
be typed. So `PromptPath` refuses such a path and the pane says why, and this
probe grades the refusal rather than the bytes.

**Where the sentence draws moved on 2026-08-13 and the check did not.** The
footer carried the refusal notice until it was deleted that day; the notice was
rehomed onto the pane cluster capsule (`Diagnostics/cluster-notice`), which is
where `2-refused.png` shows it now. The probe's subject is the sentence reaching
the screen, not the surface it lands on, so the re-home cost it nothing.

| Check | How |
|---|---|
| an ordinary name still lands | click `plain.txt`, read the prompt over the channel |
| the unholdable name appends nothing | click `caf<E9>.txt`, assert absence |
| the pane says why | by eye, in `2-refused.png` |

**The positive control is not decoration.** On its own, "nothing was appended" is
equally consistent with the refusal working, the row index being wrong, the click
missing the window, and the picker being broken outright. Check 1 is the same
picker, the same run and the neighbouring row, so check 2 means the refusal.

**The notice is by eye on purpose.** It is chrome rather than terminal text, so
the control channel's `read` cannot reach it: that verb returns what the pty
holds and the capsule is drawn by the app. `PaneClusterSegmentsTests` grades the rule
that a notice takes the bar alone, and `PromptPathTests` grades which refusal
this row produces. What no test can see is the sentence arriving on screen.

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
came from `path-picker`'s sort order rather than from this fixture.

The two byte-expectation dotfiles that sat at rows 4 and 5 went with the byte
checks. They were untracked, so `ls-files --others` listed them; without them
`README.md` moves up, and rows 1 to 3, the only ones clicked, do not move.
