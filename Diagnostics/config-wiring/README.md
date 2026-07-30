# Config wiring probe

`./run.sh` from anywhere. Prints `PASS` or `FAIL` per step and writes its captures
to `verify-out/`, which is gitignored.

**The screen must be unlocked.** A libghostty surface only materialises in a real
window on an unlocked session, and until it does the pane spawns no pty at all, so
every check reports a false negative against a locked screen. The script refuses
up front rather than reporting a wall of failures, reading the lock state out of
`ioreg` rather than through Quartz, which needs pyobjc and is not importable from
the stock python3 here. An earlier version imported it anyway, printed `unknown`,
and the guard treated that as fine.

The question it exists to answer is whether an appearance key the config file sets
actually reaches the running app, as opposed to being parsed correctly and then
dropped on the way to a surface. Every key gets a round trip: write the file, let
the watcher pick it up, capture the window, and read the pixel back with
`../lib/pixel.py`.

Some checks cannot be pixels. Those print `LOOK` and need a human to compare two
images, because "the footers moved with the surface" is not an assertion a colour
sample can make.

It was written for Task 6 of the config-wiring plan, which has shipped. It is kept
because the round trip it checks is the one every future appearance key needs, and
because the unlocked-screen guard and the `PASS`/`FAIL`/`LOOK` harness are the
parts worth copying into the next probe.
