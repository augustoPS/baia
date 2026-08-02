# The dev build wears the release icon, and the Dock cannot tell them apart

You are working in a git worktree of baia on branch `observer/dev-icon`.

## The item

Release and Debug are two installable copies meant to run at the same time:
`baia.app` / `pasqualotto.baia` in `/Applications`, and `baia-dev.app` /
`pasqualotto.baia.dev` built by `make run`. They own separate support
directories and separate bundle ids on purpose.

They wear the same icon. `project.yml` ships `Icon/baia.icns` to the target with
no per-configuration condition, and `Icon/make-icon.swift` hardcodes its three
colours (`:34`, `:38`, `:42`). So the one place the two builds are hardest to
tell apart is the one place the owner looks most: the Dock and the app switcher.

## The goal, and it is the same size as the scope

`make-icon.swift` takes the accented colour as a parameter, produces
`Icon/baia.icns` unchanged and `Icon/baia-dev.icns` in a midnight purple, and
`project.yml` ships each to its own configuration, so a Release build and a Debug
build carry different icon bytes.

Not "the icon looks good". The purple is the owner's eye to judge and it is one
constant; you are building the mechanism that lets him change it in one line.

## The colour

Only the accented colour moves. `make-icon.swift:42` calls it `occupied` and its
comment names its job: "the only thing here with a hue, which is the same rule
the footer follows". `field` and `plank` stay as they are in both icons.

Release keeps `#B5D5FF`. Debug takes a midnight purple, starting at `#6B3FA0`.
That value is a starting point, not a finding. If it reads badly at 32 pt in the
Dock, say so with what you saw and leave the constant where a one-line edit
changes it.

## The first step

**`make-icon.swift` gets its parameter before a second icon exists**, and that
commit regenerates `Icon/baia.icns` byte-for-byte identically to what is checked
in today.

That is the check worth having: if parameterising the generator changes the
release icon at all, the parameter is wrong and every later comparison is against
a moved baseline. Prove it with `git status` showing `Icon/baia.icns` unmodified
after a regeneration, and say so in the commit message.

## project.yml, and the two things you must not do

The wiring is a per-configuration resource, which is the same shape the support
directory already uses (`BAIA_SUPPORT_DIRECTORY`, set per configuration and read
back through `Info.plist`). Follow that pattern rather than inventing one.

**Never add `info:` or `entitlements:` keys to the target.** XcodeGen treats
those as files it owns and silently overwrites the hand-maintained `Info.plist`
and `baia.entitlements` with stubs on every `make gen`. They are wired through
`INFOPLIST_FILE` and `CODE_SIGN_ENTITLEMENTS` instead.

`project.yml` is the only build source of truth. Never edit a pbxproj and never
add files through Xcode.

## Scope

`Icon/make-icon.swift`, `Icon/baia-dev.icns` (new, generated), and `project.yml`.

Nothing in `Sources/` and nothing in `Packages/`. If it seems to need either,
stop and say so.

## Verify

`make build`, from the worktree root, **and** an explicit comparison of the two
bundles' icons.

`make build` runs `make gen`, so it is what proves the `project.yml` change is
well-formed and that Debug still builds. It does not prove the two icons differ,
so assert that separately: build both configurations and compare the icon bytes
in each bundle, or compare `Icon/baia.icns` against `Icon/baia-dev.icns` and show
that `project.yml` names a different one per configuration. State in your final
message which of those you did.

`swift Icon/make-icon.swift` is how the generator runs. It passes through rtk
unfiltered, so only its bare spelling exists.

Measured in a fresh worktree: `make build` about 25 seconds cold.

## Rules

Commit each green step separately. Never run a `Diagnostics/*/run.sh`, `make run`,
or anything that quits baia: you are running inside it. `make run` is denied to
you by settings as well, and that is not the way to see your icon.
