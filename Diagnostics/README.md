# Diagnostics

**Every test script and probe in this project goes here.** Not beside the code it
exercises, not in `design/`, not in a scratch directory. One home, so that asking
"has this been checked live?" is a directory listing.

A probe is not a unit test. The package test suites answer everything decidable
without a window; `make test` runs them and there are 1,292 of them across twelve packages. A probe
answers what those cannot: something that needs a real window, a real Metal
surface, a real spawned shell, a real socket, or a human comparing two images.
The rule that draws the line is the one the packages already follow. If a fact is
answerable without an `NSWindow` or a descriptor, it belongs in a package test. If
it is not, it belongs here.

## Layout

```
Diagnostics/
  lib/              shared harness, used by more than one probe
  <probe-name>/
    run.sh          runnable from anywhere, exits non-zero on failure
    README.md       the question this probe exists to answer
    <name>.swift    or .py, the probe itself
```

`run.sh` must work from any working directory, because every existing one does
and callers rely on it. Resolve paths from `$(dirname "$0")`, not from `$PWD`.

A probe's README says what would be false if the probe passed and the code were
wrong. "Does ⌘F open a panel" is not that; "can the find panel take first
responder inside a pane's window and silently kill every ghostty binding" is.

## The probes

| Directory | Answers |
|---|---|
| `agent-integration/` | Whether an installer that edits `~/.claude/settings.json` can be trusted with a file somebody hand-wrote. Runs against a fixture home and fingerprints the owner's real one to prove it stayed out |
| `attention-colour/` | Whether the attention treatment resolves to the colour the config asked for |
| `clip-layout/` | The bug shape that has cost four hand-found hours: something derived from a view's size, the size changing, and the derived thing never rebuilt. Drives a real rows view through a first layout, a width change and a scroll |
| `config-wiring/` | Task 6 of the config-wiring plan: every appearance key round-tripping into the running app. Colour checks are automated, the ones marked `LOOK` need a human |
| `control-channel/` | Sixty-seven checks over the real socket: scopes, statuses, event kinds, backfill, and a pane reporting on itself |
| `find-in-pane/` | Whether the find panel breaks a responder inside a pane's window, or keeps a dead pane's shell alive |
| `split-command/` | What ghostty actually does with the `command` config key, which its own documentation gets wrong, and therefore what `baia split --command` has to be given. Also the refusals, which need no app |
| `footer-corners/` | The footer's corner geometry, including full screen |
| `fullscreen-strip/` | The strip that appears along the top in full screen |
| `key-resize/` | ⌃⌘arrow divider steps under key repeat |
| `pane-resize/` | Divider drag arithmetic |
| `path-picker/` | What lands on the prompt when a sidebar row is clicked. Drives the clicks and captures five images; the verdict is human, because reading a pane's contents needs the unbuilt `read` verb |
| `theme-refresh/` | Whether a theme change reaches every surface already on screen |

## `lib/`

Shared harness. These exist because the obvious route was unavailable, and each
one's header says which route and why, so nobody re-derives it.

| File | What it is |
|---|---|
| `drive.sh` | Sourced, not run. Activation, keys, pasted text, real clicks and window captures against the running app: `act`, `key`, `type_line`, `type_raw`, `shot`, `click_pt`, `click_row`. Set `OUT` before sourcing. Shared by `capture.sh` and `path-picker/run.sh`, and the first place to look before scripting the app again |
| `click.swift` | Posts a real `CGEvent` mouse click at a screen point. `System Events click at` resolves the accessibility element under the point and presses it, which a custom-drawn view answering `mouseDown` does not implement, so the call succeeds and nothing happens. The sidebar is custom-drawn precisely so it takes no first responder, so this is not a detail a redesign removes |
| `pixel.py` | Reads pixels out of a `screencapture` PNG with no third-party dependency. `sips` reports metadata but cannot print a pixel and Pillow is not installed here. Decodes greyscale, truecolour and alpha at 8 bits |
| `demo-repo.sh` | Builds two throwaway repositories under `/tmp/baia-design-demo`: `dirty` carries every git marker state at once (`UU`, `A`, `MM`, `M`, `??`) plus a deep tree and a control-byte filename, `clean` carries none. No real repository on this machine holds all four states, and manufacturing them beats staging a conflict in something the owner is working in. Prints the two paths and nothing else |
| `capture.sh` | Drives the real app through AppleScript and captures the window rather than the screen. Feeds `design/handoffs/`, but lives here because it drives the app and because `design/` is gitignored |

Two traps in `capture.sh` that will bite anyone editing it, both documented at
length in its header: text is pasted and never typed, because `keystroke "~"`
silently arrives as `a` under the U.S. International layout; and baia must be
verified frontmost before every keystroke, or the key goes to whatever is in
front. One run typed a `cd` into the terminal running Claude Code that way.

It backs up and restores both `~/.config/baia/config.json` and the workspace
`session.json`. The session half was added 2026-07-30: `restart` deletes the
session file on every scenario, twelve times in a run, so before the fix a
finished run left the app reopening in a throwaway fixture with the real
workspace gone.

## Adding one

Copy the shape of `control-channel/`, which is the most complete. Reach for
`lib/` before writing a clicker, a pixel reader, or another AppleScript driver.
`path-picker/` is what that saves: it sat manual for weeks on the belief that a
sidebar row could not be clicked, while the clicker lived in `design-captures/`
and read as design tooling.

A probe that cannot assert is still worth writing. `config-wiring/` and
`path-picker/` both print `LOOK` where the verdict has to be human, and both are
better than the same check performed from memory.

The probe worth writing next is `clip-layout/`. Four bugs of one shape have been
found by hand, each costing a trace: something is derived from a view's size, the
size changes, and the derived thing is never rebuilt. The document view drew into
one point, the tree could not be hit at all, the hover tracking areas covered
nothing, and the rows view never repainted on a column width change.
