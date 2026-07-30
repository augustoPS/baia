# Agent integration probe

`./run.sh` from anywhere. Fourteen checks, each printing `ok` or `FAIL`, ending
in `PASS` or `FAILED n of m`. Needs `make build` and nothing else: it launches no
app and opens no socket.

The question it exists to answer is not "does `install-hooks` work". It is
**whether an installer that edits a file baia does not own can be trusted with
one that somebody hand-wrote**, which is a different question and a much harder
one to be confident of from unit tests alone.

## The sandbox is the point, and it is the thing that failed first

`HookInstaller` resolves paths from a home directory, and the first version took
that home from `NSHomeDirectory()`. That function reads `getpwuid` and **ignores
the environment**, so a run with `HOME` pointed at a scratch directory was
silently ignored and installed into the owner's real `~/.claude` instead. That is
how it was found, on 2026-07-30, by a run that believed itself sandboxed.

`Layout.home()` now takes `$HOME` first. The last check here is what keeps that
true: the owner's own `settings.json` is fingerprinted with `shasum` before
anything runs and compared after everything has, so a regression fails this probe
loudly rather than quietly editing a config.

## The fixture

A settings document holding hooks baia knows nothing about, arranged so the merge
has something real to preserve:

- a foreign hook in `PreToolUse`, which is an event baia also wants
- a foreign hook in `PostToolUse`, under a matcher baia does not want
- an `async` key inside a foreign hook object, which is a field baia has never
  heard of sitting inside a structure baia has to walk past
- keys on either side of `hooks`, in a deliberate order, so a rebuilt document
  shows up

## What it checks

**Install.** The script lands inside the fixture, the settings gain baia's hook,
both foreign hooks survive, the top-level key order holds, everything outside
`hooks` is untouched, and the unknown `async` key is still there.

**Install again.** Reports nothing to do. A second run must not append a second
hook or rewrite the file.

**Uninstall.** Exits 0, the settings come back **byte-identical** to what they
were, the script is gone, and the backup from before the first install is still
on disk holding the pre-install state rather than a later one. That last check
exists because the first version's backup overwrote itself, so an uninstall
destroyed the one file worth having if the uninstall were wrong.

**A malformed document.** Left exactly as it was, with a refusal that says why.
The owner's hand edit is worth more than the install, and repairing JSON is not
baia's to attempt.

## What it does not check

The hook's own behaviour. Deciding a state from a payload means running the
script against Claude Code's event shapes, and that belongs with a real session
rather than here. The decision table is exercised by hand with a stub `baia` on
`PATH`; see the script's header for the seven guards it has to fail silently on.
