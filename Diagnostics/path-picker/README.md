# Path picker probe

`./run.sh` from anywhere, outside a baia pane. Builds the fixture, drives an
isolated copy of the Debug app, writes five images to `verify-out/path-picker/`,
and prints `ok` or `FAIL` per check. It does not rewrite `~/.config/baia` or
the Debug session.

**It needs the machine to itself.** The clicks are real events at real screen
points, so anything that comes to the front during a run takes them. `act` refuses
to continue unless baia is genuinely frontmost, which stops a keystroke leaking
into another app, but a stray click still lands where it lands.

**It passes or fails, and it did not until 2026-07-30.** The question this probe
exists to answer is what lands on the focused pane's prompt line when a sidebar
row is clicked, and until the control channel's `read` verb existed, nothing
outside the app could see that. The probe posted the clicks and left a human five
images to compare.

`read` closed it. Each click is now followed by a read of the pane's own last
line, compared against what the picker was supposed to send, and the script exits
non-zero when one disagrees. The images are still captured, because a failure
reads far better beside a picture of the pane than as a diff of two strings.

The capability comes from the pane itself: `launch` has the shell write
`$BAIA_TOKEN` and `$BAIA_PANE` to the output directory, which is a readout rather
than a forgery, since a token is minted per pane per run and written nowhere
else. `read` is `.descendant` and resolves `subject == actor`, which is what lets
a pane read itself.

## Why this was believed unassertable

`fixture.sh` still carries the sentence it was written with: *"nothing here can
drive a mouse or read `NSApp.keyWindow`"*. Half of that was never true. The
clicker existed the whole time, in `design-captures/`, where it read as design
tooling rather than probe tooling, and `capture.sh` had been using it to click
sidebar rows by index for weeks. Consolidating everything into `Diagnostics/` on
2026-07-30 is what surfaced it. The other half stood until `read` shipped on the same
day, and now neither does.

The clicker has to post a real `CGEvent`, and this is not a detail a redesign
removes. `System Events click at` resolves the accessibility element under the
point and presses it; a custom-drawn view answering `mouseDown` implements no
press, so the call reports the element it found and nothing happens. The sidebar
is custom-drawn precisely so it takes no first responder, which is what keeps
every ghostty binding alive in the pane beside it.

## The fixture

`fixture.sh` builds a repository under `$TMPDIR/baia-path-picker-fixture` holding
every name the picker has to survive, and prints its path. It is kept separate
from the runner because it is worth running alone when checking something by
hand.

Names that must send correctly: a plain one, one with a space, one with a double
quote, one with an apostrophe, an accented one, `~notes.txt`, `=lookup.txt`,
`-rf.txt`, and a leaf three directories deep. Names that must **refuse**:
`ctrl<TAB>name.txt` and `esc<ESC>[Dname.txt`. Both are legal on macOS and both
would drive zsh's line editor rather than land on the prompt, so the row has to
decline and flash rather than send.

It also leaves a staged change and a rename, so the Changes list holds more than
untracked rows and the rename's original path is on the wire as an entry of its
own.

`../lib/demo-repo.sh` is a different fixture and they are not merged on purpose:
that one manufactures git marker states for the Changes surface, this one
manufactures pathological filenames for the picker.

## The brittle part

The row indices in `run.sh` are the fixture's tree in fixture order under a
`files` sidebar. They are the one thing in the script that can silently click the
wrong row. If a capture shows the wrong file, read the tree in the image and
correct the index rather than guessing; `click_row` takes the section's first row
centre and a 1-based row number, and the 17.5 pt spacing was measured against a
capture rather than read off the geometry constants.

## Two checks stay by hand

Neither is a click. Clicking while an agent is mid-run has to insert into the
agent's prompt rather than the shell's, and that needs an agent genuinely
running. And `~notes.txt`, `=lookup.txt` and `-rf.txt` must not expand or read as
options, which the unit tests already pin but which is worth seeing once in a
real shell.
