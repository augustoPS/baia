# Quick terminal lifecycle probe

Run `./Diagnostics/quick-terminal/run.sh` from a terminal outside baia. This
probe opens a panel and takes keyboard focus. It refuses to run inside a baia
pane. `./Diagnostics/quick-terminal/run.sh --build-only` compiles without
opening a window or registering a shortcut.

The executable compiles the shipped `QuickTerminalController.swift` and
`GlobalTerminalShortcut.swift`. A small terminal fixture replaces the Ghostty
surface, so no shell starts and no settings, session state, or installed app
changes. The fixture checks controller and view identity across hide and close,
shell-exit callbacks, and interrupted show/hide transitions.

This does not prove real PTY survival, appearance, Space/full-screen behavior,
or actual global key delivery. Verify those with the isolated Debug app: start
`caffeinate` in the quick terminal, toggle from another app, close its panel,
and confirm the same process and terminal remain. Quit that Debug instance and
confirm its shell exits.

The live shortcut check temporarily registers Command + backtick. If Ghostty
or another app owns it, the probe checks the error path and reports the live
shortcut check as skipped. It does not change the other app's shortcut.
