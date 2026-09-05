# baia instructions

Apply `~/Projects/AGENTS.md`, including when this checkout is a worktree outside
that directory's instruction ancestry. This file adds baia-specific rules. Read
`CLAUDE.md` for the detailed project constraints and diagnostic history; apply
its project rules in Codex too. Claude hooks and permission configuration do
not run in Codex, so enforce their safety intent through the checks below.

## Context and scope

baia is a macOS terminal workspace in Swift and AppKit, with the Ghostty engine
from `Lakr233/libghostty-spm`. Read `~/Projects/vault/projects/baia/baia.md` before
substantial work. Open work is in `~/Projects/vault/projects/baia/baia-todo.md`; follow
its linked plans and update the relevant item when its status changes.

Check the current branch, revision, and dirty paths before editing. Preserve
existing changes and keep unrelated fixes separately reviewable. Use subagents
for coding tasks with bounded ownership. Serialize edits to shared integration
files, especially `AppDelegate.swift` and `TerminalPaneController.swift`.

## Build and verification

| Command | Purpose |
| --- | --- |
| `make build` | Debug app build; full log at `.build/xcodebuild.log` |
| `make test` | Tests for every local package |
| `swift test --package-path Packages/<name>` | Focused package tests |
| `make CONFIG=Release build` | Release build without installation |
| `make run` | Build and launch the separate Debug app |

Never run bare `xcodebuild`. `project.yml` is the build source of truth;
`baia.xcodeproj` is generated. Do not edit generated project files. Do not add
`info:` or `entitlements:` keys to `project.yml`; keep the existing
`INFOPLIST_FILE` and `CODE_SIGN_ENTITLEMENTS` settings.

Package tests do not compile `Sources/`, and an app build does not run package
tests. A change to a package imported by the app needs both. Commit each
verified, coherent step separately when committing work.

## Code boundaries

Put behavior that needs neither an `NSWindow` nor a descriptor in a local
package under `Packages/`. Keep AppKit and descriptor integration in `Sources/`.
Move callers with their implementation so each step builds.

Use the MIT upstream Ghostty dependency and the tracked patch workflow. Do not
copy GPLv3 code from kero or switch to its fork. Terminal surfaces must use
`backend: .exec`. Preserve the OSC 52 clipboard denials in
`TerminalPaneController`.

Each pane owns its terminal controller. Live configuration changes use the
controller's update methods; assigning the view's configuration or controller
can destroy the PTY. Pane chrome must preserve terminal first responder and
must not change terminal geometry when focus changes.

## State and live diagnostics

Release is `/Applications/baia.app` with bundle ID `pasqualotto.baia`; Debug is
`baia-dev.app` with bundle ID `pasqualotto.baia.dev`. They have separate support
directories, selected by `BAIASupportDirectory` in the bundle. Never collapse
their session, socket, or recent-project state into one location. Settings are
shared at `~/.config/baia/config.json`; diagnostics must use a disposable config
through `BAIA_CONFIG_FILE` when changing settings.

Put probes in `Diagnostics/<name>/` with a `run.sh` that works from any working
directory and a README stating the measured property. Reuse `Diagnostics/lib/`.
Use package tests for logic and real-app probes for window, shell, socket, and
focus behavior.

Before running a probe, read `Diagnostics/observer-pane/guard-baia-alive.sh`.
Its `SAFE_PROBES` list is authoritative for probes allowed inside a baia pane.
Do not run other `Diagnostics/*/run.sh` scripts or `make run-attached` from
inside a baia pane. `make run` is allowed because it launches the separate Debug
app without quitting the host.

For state-mutating app tests, use a disposable instance with a unique bundle ID,
support directory, config, and shell fixture. Clean up only the exact processes
the test created. Verify normal app state is unchanged. Never use a broad
process-name kill to clean up a probe or install over the daily driver as part
of routine verification.
