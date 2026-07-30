# design

The Claude Design side of the repository. Everything here is about the
conversation with Claude Design: what it is asked for, what comes back, and the
system those answers are folded into.

**The two traffic folders are split by direction, not by topic.** A design pass
lands in both, and that is correct: the brief and captures that went out are
`handoffs/`, the document that came back is `inbox/`.

| Folder | Direction | Tracked |
|---|---|---|
| `inbox/` | design → code | no |
| `handoffs/` | code → design | no |
| `vitreous/` | neither, it is the system itself | **yes** |

**No tooling lives here.** Test scripts and probes go in `Diagnostics/`, including
`capture.sh`, which feeds `handoffs/` but is not part of it. The two traffic
folders are gitignored, so anything left in them that mattered would be lost.

## `inbox/` — design to code

What Claude Design sends back: a finished pass, a critique, a change of
direction, a design-system bundle. This is the side that carries instructions
into the repository.

Items are consumed rather than kept. Once a pass has been acted on, its durable
form is the vault note and the code, not the inbox copy.

Holds the three passes so far: `pass-v1/`, `pass-v2/`, and `sidebar/`, the last
carrying the v3 sidebar document, its standalone render, the `_ds/` token bundle
and Claude Design's own `github.md` sync record.

## `handoffs/` — code to design

What is sent out: the brief describing what a pass should answer, and the
captures it has to argue from. One directory per pass.

Claude Design is connected to the repository but **cannot see this directory**,
because it is ignored. Attach the files to the conversation by hand.

Regenerate the captures from the real app after `make build`:

```sh
./Diagnostics/lib/capture.sh                             # design/handoffs/captures
./Diagnostics/lib/capture.sh design/handoffs/sidebar/captures
```

The run takes about four minutes, needs the screen unlocked, and drives the app
through AppleScript, so leave the machine alone while it goes. It restores both
`~/.config/baia/config.json` and the workspace `session.json` on exit, including
after a kill.

The durable copy of a brief belongs in the vault at `vault/projects/baia/`, which
is where `2026-07-27-design-v3-sidebar-handoff.md` already sits alongside its
copy here.

## `vitreous/` — the design system

**Tracked, and maintained like source.** The design system baia's Liquid Glass
work is built against: tokens, components, guidelines, and per-surface UI kits,
with its own `CLAUDE.md` and `DESIGN_GUIDE.md`.

This is not traffic in either direction and does not go stale with the UI; it is
the thing the UI is brought into line with. Update it as glass treatments are
chosen, in the same commit as the code that adopts them, so the system and the
app never describe different rules.

The candidates it has to answer for are unchanged: the palette scrim, the
whole-pane attention frame, the divider, and the alert-on-alert composite. Two
constraints are already known and neither is a bug. `backgroundOpacity` and
`backgroundBlur` cannot be judged inside the settings window's samples, because
both act on the window against the desktop and an embedded surface has the
settings window behind it; the same limit applies to any glass that samples what
is behind it. And the AppKit surface is thin next to SwiftUI's: `NSGlassEffectView`
and `NSGlassEffectContainerView` are reachable unguarded since the floor moved to
macOS 26, but there is no morphing, no interactive glass, and no tint API.
