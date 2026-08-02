# App-target candidates

A survey, not a plan. Nothing here has moved.

## Method

Grepped `Sources/` for `func` declarations that return a value, then read each
one's body (not the whole file) to check two things a grep for `NSWindow` and
`NSView` alone would miss: whether the function actually reaches a live window
or pane object through its parameters, and whether it merely reads `self`'s own
AppKit-backed state. A signature with no AppKit type in it can still need
AppKit; several below were dropped after reading for exactly that reason
(`ControlAdapter`'s `split`/`close`/`focus`/`zoom` all take a `Placement` that
wraps a live `WorkspaceWindowController`, and `PaneTreeController`'s
`split`/`close`/`focus` call `rebuild()` and `pushRatios()`, which walk real
`NSSplitViewController` state). Those are correctly in the app target and are
not listed.

What's listed is the opposite mistake: functions that touch no window, no
view, and no socket descriptor, sitting in `Sources/` next to code that
legitimately needs AppKit, when the type they answer about (`PaneActivity`,
`RepositoryStatus`, `ControlLayoutNode`, `PaneGraph`) already has a package.

Two tiers. Tier 1 is functions with no AppKit dependency and no coupling to
instance state beyond their own parameters, the same shape as the five found
across v1.1. Tier 2 is real candidates with a caveat: thin value, state read
from `self` rather than passed in, or no single obvious package to land in.

## Tier 1

### Control channel → `PaneControl`

| File:line | Signature | Belongs in |
|---|---|---|
| `Sources/ControlServer.swift:747` | `private func scope(of actor: ControlPaneID) -> [ControlPaneID]` | `PaneControl`, beside `PaneGraph`. Walks `children(of:)` and `peers(of:)` into one ordered, deduplicated list. A graph-traversal algorithm expressed entirely in terms of `PaneGraph` calls, with no reason to sit outside the package that owns the graph. |
| `Sources/ControlServer.swift:523` | `private func gate(_ verb: ControlVerb) -> ControlError?` | `PaneControl`, beside `ControlVerb`/`ControlError`. A pure switch over `verb.settingGate` and two `Bool`s (`isReadAllowed`, `isRunAllowed`); the two `Bool`s are the only `self` state it reads and both could be parameters. |
| `Sources/ControlServer.swift:1125` | `private func answer(for drain: Drain) -> ControlResponse` | `PaneControl`. Pure `Drain` → `ControlResponse` formatting, both package types. |
| `Sources/ControlServer.swift:1129` | `private func answer(for batch: EventBatch) -> ControlResponse` | `PaneControl`. Same shape, `EventBatch` → `ControlResponse`. |

### Control-to-workspace translation → `WorkspaceLayout` / `PaneControl`

| File:line | Signature | Belongs in |
|---|---|---|
| `Sources/ControlAdapter.swift:604` | `private static func direction(of direction: ControlDirection) -> FocusDirection` | `WorkspaceLayout`, beside `FocusDirection`. Enum-to-enum mapping between two packages' own vocabularies, no `default:` arm, which is the exact shape the `--kinds` mapping was wrong in when it first moved. |
| `Sources/ControlAdapter.swift:565` | `private static func build(_ node: ControlLayoutNode, createdBy: PaneID, into states: inout [PaneState]) -> PaneTree` | `WorkspaceLayout`, beside `PaneTree`/`PaneState`. Pure recursive tree construction from a `ControlLayoutNode` (a `PaneControl` type); nothing in the body touches a window. |
| `Sources/ControlAdapter.swift:592` | `private static func existingDirectory(_ path: String) -> String?` | `WorkspaceLayout` or `PaneControl`. Pure `FileManager` directory check, no window, no descriptor. |
| `Sources/ControlAdapter.swift:156` | `private static func name(of attention: PaneStatus.Attention) -> String?` | `PaneChrome`, beside `PaneStatus.Attention`. Pure three-case enum-to-string mapping. |

### Transport → `PaneControl` / `WorkspaceLayout`

| File:line | Signature | Belongs in |
|---|---|---|
| `Sources/ControlTransport.swift:705` | `private static func createDirectory(for socketPath: String) -> Bool` | `WorkspaceLayout`, beside `SessionStore`. Its own doc comment says it exists "the way `SessionStore` creates the one it shares with `session.json`". Two independent implementations of the same 0700-directory-walk, one of them untested in a package. |
| `Sources/ControlTransport.swift:719` | `private static func reason(_ code: Int32) -> String` | `PaneControl`. `strerror` wrapper, pure, `code` is an errno value rather than a descriptor. |

### Pane activity → `PaneActivity`

| File:line | Signature | Belongs in |
|---|---|---|
| `Sources/PaneActivityTracker.swift:188` | `private static func isIdle(_ activity: PaneActivity) -> Bool` | `PaneActivity`. One-line predicate (`activity == .idleShell`) on a type the package already owns. |
| `Sources/PaneActivityTracker.swift:297` | `private static func isWorkingAgent(_ activity: PaneActivity) -> Bool` | `PaneActivity`. Same shape, pattern-matches `.agent`. |
| `Sources/PaneActivityTracker.swift:199` | `private func shellPid(above pid: pid_t, in tree: [ProcessSnapshot]) -> pid_t?` | `PaneActivity`, beside `ProcessTree`. Pure, bounded (64-iteration) walk over `[ProcessSnapshot]`, a package type; the 64-cap and the "excludes the shell by pid" invariant are exactly the kind of thing worth a package test rather than a comment. |
| `Sources/PaneActivityTracker.swift:217` | `private static func normalized(_ name: String) -> String` | `PaneActivity`. Trivial (strips a leading `-`), but pairs with `shellPid` and has no reason to be a different distance from a test. |

### ~~Git status → `GitWorkspace` / `PaneChrome` / `ProjectAnchor`~~ MOVED 2026-08-02

The last of the seven Tier 1 groups, and the only one that did not run as a wave:
one item left, so an executor would have been orchestration with no parallelism
to buy. Done in the main session as five green commits, `113bd54..05e0d8b`.

| Was | Is now |
|---|---|
| `PaneGitStatus.repositoryRoot(for:)` | `Anchor.repositoryRoot(of:)` in `ProjectAnchor` |
| `PaneGitStatus.paneGit(_:)` | `PaneStatus.Git(_:operation:isLinkedWorktree:)` in `PaneChrome` |
| `PaneGitStatus.label(for:)` | `PaneStatus.Git.operationLabel(for:)` in `PaneChrome` |
| `ChangesSurface.sort` / `.rank` | `[RepositoryFileChange].inCommitOrder()` in `GitWorkspace` |
| `FilesSurface.guide(for:)` | `FileTree.descendants(ofRowAt:in:)` in `GitWorkspace` |

**The parameter lift was its own commit**, as planned: `paneGit` read
`self.isLinkedWorktree` for the one field a `RepositoryStatus` does not carry,
which is what kept an otherwise pure mapping in the app target.

**`paneGit` was a duplicate, which the survey did not know.**
`PaneStatusSegments.runs(for:)` already built the same eight fields from the same
type with the same dirty rule written out a second time. The two agreed, by luck:
the rule is a judgement, and a judgement in two places drifts the first time one
is corrected. Both call the one mapping now, which is why a mutation of the dirty
rule reddens a palette test that predates this work.

**`guide(for:)` could not move alone.** It reads a row array the app target built
by hand, so a package function taking a row type the app target still filled in
would have been a new copy of exactly what the first correction removed. The
flattening moved with it, and `Row` is gone from `FilesSurface`. This is the one
place the group's scope grew, and it grew for the reason the group exists.

Two corrections to trust over the table above, both found by doing it:
`FilesSurface`'s guide was at `:540` rather than the `:523` recorded, and
`label(for:)` went to `PaneChrome` rather than the `GitWorkspace` named here,
because upper-casing an operation is a decision about footer ink and the footer
is what reads it.

Every one of the twelve new tests was written against a mutation and nine
mutations were actually run, three per move. Not one was believed on a reading.
1537 tests, up from 1504 at the start of the group.

### Command palette → `PaneChrome`

| File:line | Signature | Belongs in |
|---|---|---|
| `Sources/CommandPaletteController.swift:372` | `private static func runs(for status: RepositoryStatus) -> [PaneStatusRun]` | `PaneChrome`. Pure `RepositoryStatus` → `[PaneStatusRun]`, built entirely through `PaneStatusSegments.build`, a package function; nothing here needs the controller. |
| `Sources/CommandPaletteController.swift:268` | `private static func kind(of kind: Project.Kind) -> PaletteRowKind` | `PaneChrome` or `GitWorkspace`. Three-case enum mapping from `GitWorkspace.Project.Kind` to `PaneChrome.PaletteRowKind`, no `default:`, the same risk shape as `direction(of:)` above and as the historical `--kinds` bug. |

### The repeated `colour`/`leading` cluster → `PaneChrome`

Four separate, near-identical "map a semantic role to an `RGB` through a
`PaneTheme`" functions, each written fresh rather than shared:

| File:line | Signature |
|---|---|
| `Sources/ChangesSurface.swift:508` | `static func colour(_ role: Role, in theme: PaneTheme) -> RGB` |
| `Sources/CommandPaletteView.swift:312` | `private func colour(for emphasis: PaneStatusEmphasis) -> RGB` |
| `Sources/PaneStatusBarView.swift:589` | `private func colour(for emphasis: PaneStatusEmphasis) -> RGB` |
| `Sources/FilesSurface.swift:372` | `private func colour(of mark: FileChangeMark) -> RGB` |

All four return `RGB`, never `NSColor`, and none take a view. They belong in
`PaneChrome` beside `PaneTheme`, consolidated rather than copied; `PaneTheme`
already has one tested resolver of this shape (`PaneTheme.accent(for:)`,
referenced from `ConfigurationCenter`'s doc comments) and these are four more
of the same kind sitting outside it.

| File:line | Signature | Belongs in |
|---|---|---|
| `Sources/PaneStatusBarView.swift:574` | `private func leading(for role: PaneStatusSegmentRole, busy: Bool) -> Double` | `PaneChrome`. Pure layout-constant lookup (`chipPadding`, `dotDiameter + dotGap`, or `0`), no view. |

## Tier 2 (real, but weaker)

| File:line | Signature | Why it's weaker |
|---|---|---|
| `Sources/ControlServer.swift:41` | `static func defaultSocketPath() -> String` | Pure path construction off `SessionStore.defaultFileURL()`, itself already in `WorkspaceLayout`. Small; moving it mostly relocates one string concatenation. |
| `Sources/ControlServer.swift:871` | `private func wait(from request: ControlRequest) -> Int?` | Already a one-line delegate to `ControlWire.cappedWait` (the actual cap logic is already in `PaneControl`). Moving the wrapper itself buys little. |
| `Sources/RowFeedback.swift:124` / `:143` | `func fill(_ row: Int, in theme: PaneTheme) -> (colour: RGB, alpha: Double)?` / `func ink(_ row: Int, in theme: PaneTheme) -> (colour: RGB, alpha: Double)?` | Pure given their parameters, but read `pressed`/`levels`/`answers` off `self`; extracting them means passing that state in explicitly, which is a small refactor and not just a move. |
| `Sources/CommandPaletteController.swift:411`, `Sources/CommandPaletteView.swift:349`, `Sources/FindPanelController.swift:378` | `static func height(forRowCount count: Int) -> Double` (× 3, near-identical) | Trivial arithmetic, but written three times rather than once. Worth collapsing into `PaneChrome` more for the duplication than for any risk in the logic itself. |
| `Sources/SettingsPreviewColumn.swift:30` | `private static func status(asking: Bool) -> PaneStatus` | Pure `PaneStatus` fixture builder, but it's sample data for a settings preview, not logic anything depends on being right. |
| `Sources/ConfigurationCenter.swift:61-150` | `themeDefinition(from:)`, `terminalTheme(from:)`, `terminalConfiguration(from:)`, `paneTheme(from:)`, `derivations(for:)`, `chrome(for:)` | Pure `Settings` → theme/config derivations, no AppKit. Not flagged as Tier 1 because the doc comments show this was a deliberate choice, not an oversight: each one explicitly delegates real logic to already-tested package functions (`PaneTheme.accent(for:)`) and exists only to compose three packages' types (`BaiaSettings`, `PaneChrome`, and the external `GhosttyTheme`/`GhosttyTerminal` bindings) that have no fourth package in common today. Moving it means picking or creating that fourth package, not just relocating a function. |

## Two corrections, from the 2026-08-01 review

This survey was reviewed before being used to plan anything, and two rows overstate
how easy a move would be. Both are the same shape the document already knows how to
flag, and did not.

- **`Sources/PaneGitStatus.swift:208` `paneGit(_:)` is not pure in its own
  parameter.** Its body reads `isLinkedWorktree`, a stored property set from `root`
  elsewhere in the class. Moving it means making that an explicit parameter, exactly
  the caveat given to `gate(_:)` two rows above. **The correction held.** It was
  lifted in `113bd54` as its own commit before anything moved, and the group cost
  five commits rather than four because of it. What neither the row nor this
  correction caught is that the function was already duplicated inside `PaneChrome`;
  see the group's own entry above.
- **The four-function colour cluster is not uniform.** Only
  `ChangesSurface.swift:508` is a pure static taking `role` and `theme`. The other
  three are instance methods on `NSView` subclasses reading `self.theme`, and
  `PaneStatusBarView.swift:589` reads `isFocused`, `fillsBarForAttention` and
  `inkBackground` as well, with the second branching to a different code path. That
  is a state extraction, not a move.

## What was excluded, and why

- Every `ControlAdapter` method that takes or builds a `Placement`
  (`placements`, `placement(of:)`, `record(for:)`, `readLines(from:)`,
  `applyLayout`, `report`, `accept`, `split`, `close`, `focus`, `zoom`,
  `resize`, `equalize`, `group(around:)`, `layout(of:...)`,
  `applyLayout(_:createdBy:)`, `describe(...)`): `Placement` wraps a live
  `WorkspaceWindowController` and `TerminalPaneController`. None of it is
  answerable without a window.
- `PaneTreeController`'s `split`/`close`/`focus`/`resize`/`equalize`: each
  calls `rebuild()`, `pushRatios()`, or `focusPane()`, which mutate real
  `NSSplitViewController` state. `canClose`/`isFocused`/`snapshot`/`tabTitle`
  are thin one-line wrappers over `Workspace` (already pure, already a
  package) or over live pane state; there's no logic left in them to move.
- `ControlSecrets.mint()`: deliberately in the app target per its own doc
  comment, so `PaneControl` (compiled into the CLI shipped in every pane's
  `PATH`) never links `Security`.
- `ControlTransport`'s `peerIsThisUser(_:)`, `bind`/`bindOnQueue`,
  `somethingIsListening(at:)`, `fill(_:with:)`: all need a live socket
  descriptor or `sockaddr_un`.
- `ControlServer.admit(_:as:)`: the connection id it takes is a live
  connection-table key, same shape as a descriptor.
- `ControlServer.permitted(_:token:)`, `registerPane`, `start()`: call
  `graph.authorize`/`graph.open` against the server's own live `PaneGraph`
  instance rather than a passed-in one; refactoring them to be pure would
  mean threading the graph through as a parameter, which is a design change,
  not a move.
- `MenuCommandSelectors.selector(for:)`: every arm is `#selector(...)`
  against `NSApplication`/`NSWindow`/`AppDelegate`; AppKit through and
  through despite the plain-looking signature.
- `PaneStatusBarView.render(_:)`, `CommandPaletteView.drawChip`/`draw`: build
  `NSAttributedString`/`NSFont` directly.
- `SettingsView.heading(_:)`: returns `some View` (SwiftUI).
- `AppDelegate.panesToSearch(_:)`, `AppDelegate.snapshot()`,
  `PaneTreeController.snapshot(windowFrame:)`: all walk live windows or read
  live pane state (`pane.readScreenLines()`, `controller.snapshot`) even
  though their own signatures show no AppKit type.
