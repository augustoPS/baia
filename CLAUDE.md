# CLAUDE.md

> baia: a native macOS terminal workspace built on libghostty. Scaffolded 2026-07-24.
> Keep this file to durable, non-discoverable facts. Detail belongs in the vault hub.

## What baia is, and what it is not

A Swift/AppKit host app that embeds Ghostty's terminal engine and adds workspace
structure around it (project grouping, split panes, git panel). The terminal core
is not ours and never will be.

It is **not** a fork of Ghostty and **not** a fork of kero. It consumes
`Lakr233/libghostty-spm` as a package dependency. That distinction is the whole
architecture, so do not let it drift.

```
ghostty-org/ghostty          MIT   Zig terminal core + Metal renderer
  └─ Lakr233/libghostty-spm  MIT   patches Ghostty, ships a prebuilt XCFramework
       └─ baia               ours  the workspace app
```

## Licensing constraint, read before copying anything

- Ghostty is MIT. libghostty-spm is MIT (`Copyright (c) 2026 @Lakr233`).
- **kero (`egoist/kero`) is GPLv3.** Reading it for design and UX is fine. Copying
  its Swift into this repo makes baia GPLv3 and forecloses App Store distribution.
  Write our own implementations. Ideas are not copyrightable; the code is.
- egoist also maintains `egoist-labs/libghostty-spm`, a fork a few commits ahead
  of upstream. Do not switch to it. If upstream is missing something, PR upstream.

## Commands

    make doctor        verify toolchain before anything else
    make bootstrap     brew install xcodegen
    make gen           regenerate baia.xcodeproj from project.yml
    make build         build Debug, errors only on stdout, full log in .build/
    make run           build and launch detached
    make run-attached  build and run in the foreground, stdout/stderr land here
    make distclean     nuke .build and the generated xcodeproj

## Editing the build

`project.yml` is the single source of truth. `baia.xcodeproj` is generated and
gitignored, so **never edit the pbxproj** and never add files through it. New
`.swift` files under `Sources/` are picked up automatically. Build settings,
targets, entitlements, and package dependencies are YAML edits followed by
`make gen`.

`Info.plist` and `baia.entitlements` are hand-maintained committed files. They are
wired in through the `INFOPLIST_FILE` and `CODE_SIGN_ENTITLEMENTS` build settings.

**Never add `info:` or `entitlements:` keys to the target in `project.yml`.**
XcodeGen reads those as files it owns and overwrites them with generated stubs on
every `make gen`, silently discarding the microphone usage description and the
sandbox setting. This already happened once during scaffolding. If a plist
mysteriously reverts to four keys and no comments, this is why.

## The trap that will cost you an hour

`TerminalSurfaceOptions.backend` has two cases:

- `.exec` — real PTY, Ghostty spawns the process. **This is what baia uses.**
- `.inMemory(InMemoryTerminalSession)` — host-managed I/O, no PTY, sandbox-safe.

The upstream `Example/GhosttyTerminalApp` uses `.inMemory` with `ShellCraftKit`'s
`defaultSandboxShell` because that example is sandboxed. It is an *emulated*
shell. Copy the example verbatim and you get a terminal that cannot run git,
node, or a coding agent. `.exec` plus no app-sandbox entitlement is the dev
terminal configuration.

## What is missing from our Ghostty

libghostty-spm ships a trimmed build. Retained: VT core, Metal renderer, CoreText
shaping, full config system, input and IME, selection and clipboard. Removed:

- Custom GLSL shaders (`-Dcustom-shaders=false`), so no Shadertoy effects
- Terminal inspector (`-Dinspector=false`), stubbed to no-ops
- Sentry, the native app shell (`-Dapp-runtime=none`), the standalone binary

Wanting any of those back means editing the patch stack in
`Patches/ghostty/` upstream, not a config flag here.

The pinned upstream Ghostty commit lives in the package's `Ghostty.ref` and can
only change through a reviewed edit there, so a package bump cannot silently move
the terminal core.

## Security posture

The app is **not sandboxed** and hardened runtime is on. A general-purpose dev
terminal cannot be sandboxed, but it means every dependency runs with full user
privileges. Treat the dependency list as a security boundary.

`TerminalPaneController` denies OSC 52 clipboard read and write and enables paste
protection. Do not relax these for convenience. kero shipped with them set to
`allow`, and someone demonstrated within a day that a remote SSH host could read
the local clipboard through the PTY (`egoist/kero#8`). Keyboard copy and paste are
unaffected by those settings.

`NSMicrophoneUsageDescription` plus `com.apple.security.device.audio-input` exist
so voice dictation works for agents running *inside* baia. With hardened runtime
on and either piece missing, macOS denies the request silently with no prompt.

## Unverified in the scaffold

`xcodebuild` was unavailable when this was written (`xcode-select` pointed at
CommandLineTools), so **nothing here has been compiled**. Verify in this order:

1. `make doctor`, then `make build`.
2. Whether `.exec` needs an explicit start call. `ShellCraftKit` sessions need
   `shellSession.start()`; the exec path is assumed to spawn on surface creation.
3. `SWIFT_APPROACHABLE_CONCURRENCY` and `SWIFT_DEFAULT_ACTOR_ISOLATION` in
   `project.yml`. Drop these two first if the toolchain rejects them.
4. Delegate protocol names against the installed package version.

## Next feature

Project directory anchoring: resolve the closest git repository containing the
pane's current working directory, re-derived as the shell moves, with a manual
pin as override. `~/Projects` is a workspace of independent repos whose root is
not itself a repo, so anchoring on cwd alone puts the git panel in the wrong
place. kero solves this in its commit `6b8e469`; read it, then write ours.

`BAIA_PANE` is already exported into every pane's child environment for this:
processes observed from outside can be traced back to the pane that owns them.
