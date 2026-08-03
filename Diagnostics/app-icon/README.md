# app-icon

**The question:** does each configuration still ship its own icon, and is the
wiring that gives it one still connected?

```
./Diagnostics/app-icon/run.sh
```

Launches nothing, opens no window, kills nothing, writes nothing. Safe from
inside a pane, unlike every other driver here.

## Why it exists

`observer/dev-icon` gave the Debug build its own icon in the fifth executor wave.
Nothing in the repository could observe it losing one again.

That is not a suspicion. The wave-five verification pass reverted
`CFBundleIconFile` from `$(PRODUCT_NAME)` back to the literal `baia`, which is
the entire substantive change of that branch, and measured what happened:
`make build` succeeded, the built `baia-dev.app` reported `CFBundleIconFile =
baia`, and `make test` reported **zero failures**. The branch had been passed by
an observer looking at a screen, and a screen stayed its only witness.

An icon is a screen judgment and this never pretends otherwise. It does not ask
whether the artwork is good, or even whether it renders. It asks whether the
chain that hands each configuration a *different* file is intact, which is a
question with an answer:

```
project.yml  configs.Debug.PRODUCT_NAME = baia-dev
     ↓
Info.plist   CFBundleIconFile = $(PRODUCT_NAME)
     ↓
built bundle CFBundleIconFile = baia-dev, == its own CFBundleExecutable
     ↓
             Contents/Resources/baia-dev.icns exists
     ↓
             and is byte-identical to tracked Icon/baia-dev.icns
```

## What it checks

**Static, needing no build.** That `Info.plist` still carries the template rather
than a literal, which is the mutation above and the cheapest thing to catch. That
`project.yml` has no `info:` key, since XcodeGen would overwrite `Info.plist` with
a stub and take the key with it. That both icons are tracked, both are listed as
resources, and the two differ in bytes: two names for one picture passes every
other check here and leaves the builds identical in the Dock.

**Per built bundle**, for each of the Debug build, a built Release build and an
installed `/Applications/baia.app` that happen to exist. That the template
resolved, that it resolved to the bundle's own `CFBundleExecutable` rather than
the other configuration's, that the named file is actually in `Contents/Resources`,
and that it matches the tracked original, which catches `make-icon.swift` being
run and its output never committed.

**Across configurations**, the claim the branch actually made: not that each build
has an icon but that the two have *different* ones. This is the only check needing
two bundles, and it skips loudly rather than passing quietly when only one exists.

## Verified

Against the verification pass's own mutation, 2026-08-02. Reverting
`CFBundleIconFile` to the literal `baia` and rebuilding fails **three** checks
independently: the template, the Debug bundle naming an icon that is not its own
`PRODUCT_NAME`, and both configurations landing on one name. Exit 1. Restored and
rebuilt, all checks pass.

Labels are bundle paths rather than basenames, because a built Release bundle and
an installed one are both `baia.app`, are routinely different builds, and a
basename makes two lines that read as a repeat.
