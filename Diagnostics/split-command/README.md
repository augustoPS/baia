# Split-command probe

`./run.sh` from anywhere. Seven automated checks plus one capture a human looks
at. `./run.sh --refusals` runs only the checks that need no app. The driving
half launches an isolated copy rather than typing into a baia that is already
running.

The question it exists to answer is **what ghostty actually does with the
`command` config key**, and therefore what a caller of `baia split --command`
has to write. Its own documentation gets this wrong, and the wrong reading
produces a pane that fails on a red screen.

## What ghostty really does

The documentation embedded in the library says a value with arguments "will be
executed using `/bin/sh -c`". It is not. Measured 2026-08-01 by reading
ghostty's own failure screen, the value is run as:

```
/usr/bin/login -q -flp <user> /bin/bash --noprofile --norc -c exec -l <value>
```

Two consequences, and both are load-bearing:

**The `exec -l` is already supplied.** A value that begins with its own `exec`
becomes `exec -l exec '/bin/zsh' …`, which asks bash for a program called
`exec`. Ghostty answers that with a red "failed to launch the requested command"
screen and the pane sits there dead.

**A login PATH exists.** `/usr/bin/login` builds one, so a tool found by name in
a spawned pane is found because of this wrapper and not because of anything baia
does. That contradicts what an earlier probe concluded from a bare `/bin/sh`
script value, where `path_helper` never ran; the wrapper is the difference.

So the shape that works, and the one the capture checks, is:

```
'/bin/zsh' -lc '<what you want>; exec "$SHELL" -l'
```

The trailing `exec "$SHELL" -l` is what keeps the pane once the command is done,
so it becomes an ordinary terminal instead of closing. Ghostty closes a pane
whose command exits, which is ghostty's behaviour and not baia's.

## Why this cannot be a package test

Nothing about a shell ghostty spawns is decidable without spawning one. The
config value reaches a real surface through a real config file parsed by a
library baia links but does not control, and the failure mode this probe exists
for is a red screen inside a pane. A test process has no business opening a
window, so the shape checks live here and the parse checks live in
`ControlWireTests` and `ArgumentsTests`.

## The refusal half, which needs no app

Parsing happens before the environment check, so `baia split --command` can be
exercised with no socket at all.

The newline refusal is the one that matters and it is a security boundary, not
tidiness. The value is rendered into a ghostty config file as `command = <value>`
and that file is parsed line by line, so a value carrying a newline writes a
second config key of the caller's choosing. `clipboard-read = allow` is one line
long and undoes the OSC 52 denial every pane is built with, which is the one
setting this project has a standing rule never to relax. `ControlWire.refusalForCommand`
owns the rule and both the CLI and the server call it, because a hand-written
frame never passes through the CLI.

## Driving it

The app half types into the **focused** pane, so focus a plain shell first;
`⌥⌘←` and `⌥⌘→` move focus. The run refuses to type if baia is not frontmost,
which is `lib/drive.sh`'s own rule and the reason it exists.

The command value travels through a file rather than through the typed line, so
the shell being typed into never re-quotes it. Everything here is full of single
quotes and the point is to deliver them unchanged.

## What it does not answer

Whether anything *uses* `--command` for its intended purpose. The flag was built
so a `/fork` hook could open a pane holding the parent session, and that hook
does not exist: `/fork` runs its `SessionStart` hook inside a Claude Code daemon
worker rather than in the pane, so the hook cannot authenticate as the pane it
would need to split. See the vault note. `--command` stands on its own and
closes half of the `run` gap baia's help lists under `NOT YET`.
