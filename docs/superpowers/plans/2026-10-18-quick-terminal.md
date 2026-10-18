# Quick Terminal Implementation Plan

**Goal:** Toggle one persistent terminal from any app with Command + backtick while Baia runs.

**Approved behavior:** A top-edge overlay hides without closing its shell. Closing regular windows leaves Baia running. Quit ends the overlay session and includes its busy job in confirmation. No command replay after restart.

**Architecture:** A nonactivating AppKit panel owns one lazily created TerminalPaneController. Carbon owns the global shortcut. AppDelegate owns both for the application lifetime. The panel is excluded from workspace session persistence.

**Constraints:** Use the existing MIT terminal engine and exec backend. Preserve clipboard restrictions and live configuration updates. Never quit or install over the Baia hosting this session. Preserve unrelated worktree changes.

1. [x] Add the persistent panel in `Sources/QuickTerminalController.swift`. Hide and close preserve pane identity; shell exit clears it. Use fixed terminal geometry during slide animation and honor Reduce Motion.
2. [x] Add `Sources/GlobalTerminalShortcut.swift` and connect application lifetime, quit confirmation, Settings updates, close shortcuts and menu fallback. Add the command to WorkspaceMenu's existing exhaustive tables. Register conflicts must be visible and retryable.
3. [x] Verify menu and dispatch rules with focused package tests. Build Debug and Release through make. Add a native lifecycle probe and run only checks safe inside a Baia pane. Review the final diff and refresh Graphify when available.

**Verification:** Repeated show/hide must retain the exact pane and shell; explicit shell exit permits a new session. Native tests must check rapid toggles, focus, top-edge geometry and close behavior. Live global-shortcut checks require a disposable instance and must not disrupt the host. Record any unverified live behavior explicitly.

## Evidence

WorkspaceMenu: 70 tests pass. Moving Quick Terminal into the workspace-required validation group makes the new availability test fail; restoring application scope passes. Debug and Release builds pass.

Native probe compiles against shipped panel and shortcut source. Its focus-taking executable was not run from the host pane. Through Computer Use, a uniquely identified disposable app opened the real overlay, started shell PID 42369 and caffeinate PID 42577, hid with Command-W, and restored the same PIDs through File > Quick Terminal. Command-Q presented a caffeinate-specific confirmation; confirming ended app PID 42246, shell and caffeinate. The isolated helper verified normal-state fingerprints and cleaned up its own copy.

An earlier fixture was relaunched by the UI tool after its launch runner exited. It lost its disposable environment and produced an inconsistent close-menu observation. The controlled run kept its launch runner alive and verified Command-W with the panel as key window. No production workaround was introduced for that observation.

Global key delivery from another application, full-screen Spaces, both Reduce Motion settings, and the standalone rapid-toggle probe still need live acceptance. The Debug app is open separately; the installed app hosting this session was not replaced or quit. Graph JSON and report refreshed; Graphify's HTML viewer exceeds its node ceiling.
