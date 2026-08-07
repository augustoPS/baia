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

There is one more way to be unanswerable in a package test, and `theme-catalog/`
is it: a fact that needs no window and no descriptor but does need a dependency no
package may take. The ghostty theme catalog lives inside libghostty, and
`PaneChrome` deliberately imports neither AppKit nor libghostty, so nothing in the
one-second loop can count the themes it is measured against. The cost of having no
home for that was paid in prose: every present-tense catalog figure in `PaneChrome`
said 463 themes while the shipped catalog held 485, and nothing could notice.
A probe of this kind still owns no rule. Every threshold it grades against is read
off the package rather than restated.

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
| `app-icon/` | Whether each configuration still ships its own icon, from `project.yml`'s `PRODUCT_NAME` through `Info.plist`'s template to the file in the built bundle. Added after the wave-five pass proved that reverting the whole `dev-icon` change built clean and tested green. Launches nothing, so it is the second probe here that is safe from inside a pane |
| `attention-colour/` | Whether the attention treatment resolves to the colour the config asked for |
| `clip-layout/` | The bug shape that has cost four hand-found hours: something derived from a view's size, the size changing, and the derived thing never rebuilt. Drives a real rows view through a first layout, a width change and a scroll |
| `config-wiring/` | Task 6 of the config-wiring plan: every appearance key round-tripping into the running app. Colour checks are automated, the ones marked `LOOK` need a human |
| `control-channel/` | Sixty-seven checks over the real socket: scopes, statuses, event kinds, backfill, and a pane reporting on itself |
| `find-in-pane/` | Whether the find panel breaks a responder inside a pane's window, or keeps a dead pane's shell alive |
| `split-command/` | What ghostty actually does with the `command` config key, which its own documentation gets wrong, and therefore what `baia split --command` has to be given. Also the refusals, which need no app |
| `footer-corners/` | The footer's corner geometry, including full screen |
| `glass-backdrop/` | What a 22 pt `NSGlassEffectView` over a pane actually samples, and whether extending the surface under it costs the grid a row. Four render arms over a controlled white/black backdrop, plus a real-PTY grid measurement. Found that the shipped bar adapts strongly and falls to 1.5:1 text contrast over a bright desktop, which is the opposite of the flat-slab failure it was built to look for |
| `fullscreen-strip/` | The strip that appears along the top in full screen |
| `key-resize/` | ⌃⌘arrow divider steps under key repeat |
| `pane-resize/` | Divider drag arithmetic |
| `path-picker/` | What lands on the prompt when a sidebar row is clicked. Drives the clicks and captures five images; the verdict is human, because reading a pane's contents needs the unbuilt `read` verb |
| `theme-catalog/` | Whether a contrast promise measured on one theme holds on the other 484, and whether the figures the doc comments quote are still true. All 485 shipped themes by all seven `FocusAccent` cases. The only probe here that needs no window, no shell and no socket, and it is the exception that proves the rule below. Its build is `build.sh`, callable on its own for a reader who wants the binary without the verdict |
| `theme-refresh/` | Whether a theme change reaches every surface already on screen |
| `titlebar-toolbar/` | What actually puts material in the titlebar of a non-opaque window. Found that an empty `NSToolbar` is necessary and not sufficient: the material also needs a non-clear window `backgroundColor`, and `.clear` kills it outright at every opacity. Grades ten arms on luminance spread rather than mean, because a bare titlebar over a dark wallpaper and the real material have the same mean — which is how the defect shipped once already. **Activates and takes the keyboard, so it must run from outside a pane** |

## `lib/`

Shared harness. These exist because the obvious route was unavailable, and each
one's header says which route and why, so nobody re-derives it.

| File | What it is |
|---|---|
| `app-identity.sh` | Sourced, not run. Answers *which* baia a probe is talking to, from the bundle it launched rather than from a spelling: `APP_NAME`, `APP_ID`, `APP_EXEC`, `APP_SUPPORT`, `APP_SESSION`, `APP_SOCKET`, plus `quit_app`, `activate_app` and `app_is_running`. Set `APP` before sourcing. Read its header before adding a fifth driver |
| `app-identity-test.sh` | 13 checks over the kill pattern, run against command-line strings rather than processes, so it launches nothing and kills nothing. Includes the pre-2026-08-02 pattern as a worked example of the bug and an over-broad pattern as a negative control |
| `drive.sh` | Sourced, not run. Activation, keys, pasted text, real clicks and window captures against the running app: `act`, `key`, `type_line`, `type_raw`, `shot`, `click_pt`, `click_row`. Set `APP` and `OUT` before sourcing; it sources `app-identity.sh` itself. Shared by `capture.sh` and `path-picker/run.sh`, and the first place to look before scripting the app again |
| `click.swift` | Posts a real `CGEvent` mouse click at a screen point. `System Events click at` resolves the accessibility element under the point and presses it, which a custom-drawn view answering `mouseDown` does not implement, so the call succeeds and nothing happens. The sidebar is custom-drawn precisely so it takes no first responder, so this is not a detail a redesign removes |
| `pixel.py` | Reads pixels out of a `screencapture` PNG with no third-party dependency. `sips` reports metadata but cannot print a pixel and Pillow is not installed here. Decodes greyscale, truecolour and alpha at 8 bits |
| `demo-repo.sh` | Builds two throwaway repositories under `/tmp/baia-design-demo`: `dirty` carries every git marker state at once (`UU`, `A`, `MM`, `M`, `??`) plus a deep tree and a control-byte filename, `clean` carries none. No real repository on this machine holds all four states, and manufacturing them beats staging a conflict in something the owner is working in. Prints the two paths and nothing else |
| `capture.sh` | Drives the real app through AppleScript and captures the window rather than the screen. Feeds `design/handoffs/`, but lives here because it drives the app and because `design/` is gitignored |

Two traps in `capture.sh` that will bite anyone editing it, both documented at
length in its header: text is pasted and never typed, because `keystroke "~"`
silently arrives as `a` under the U.S. International layout; and baia must be
verified frontmost before every keystroke, or the key goes to whatever is in
front. One run typed a `cd` into the terminal running Claude Code that way.

**Never name the app.** Every probe here launches `baia-dev.app` and the owner
runs `baia.app` all day, so a literal `baia` in a `pkill` pattern, an AppleScript
`tell application`, or an `Application Support/` path reaches the wrong one. The
2026-08-02 split updated `APP` in all four drivers and none of those, and the
harness spent the interval launching one build and then killing, driving and
reading the state of the other: eighteen references across six files, found by
the wave-five verification pass. `app-identity.sh` is the single answer and
`app-identity-test.sh` is what keeps it honest.

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

## Every script here runs on the bash macOS ships

`/bin/bash` is 3.2.57, from 2007, on every Mac: Apple stopped at the last version
before bash went GPLv3 and will not move. Homebrew's bash 5 installs beside it and
takes over `#!/usr/bin/env bash` for whoever has it on their PATH, which is the
trap rather than the fix. A script written against 5 works here and dies on a
stock Mac at its first bash-4 builtin.

It dies badly. On 2026-08-02 `pane-move/live.sh` reached `readarray` after it had
already opened two panes, so the failure left a half-built workspace and named a
builtin rather than a cause.

```
./Diagnostics/lib/shell-compat.sh
```

Two arms and a negative control: every script must parse under `/bin/bash`
specifically, none may name a construct 3.2 lacks, and the pattern is fed one line
per banned construct so a typo in the alternation cannot report a clean sweep.

Rewrite rather than reach for a newer bash. A `while read` loop replaces
`readarray` everywhere, and 3.2 is what the next person will have.
