# Settings window self-check

`./run.sh` from anywhere, from a terminal that is **not** a baia pane: the
check launches an isolated copy of the Debug app in the foreground, opens
Settings, drives it, and quits, so it takes focus while it runs. Exits
non-zero on any failed check. Skip the build with
`BAIA_SETTINGS_WINDOW_SKIP_BUILD=1` or `BAIA_ISOLATED_SKIP_BUILD=1`.

The copy has its own bundle identifier, Application Support directory, config,
and `ZDOTDIR`. It does not copy `~/.config/baia/config.json` and does not load
the Debug session or acknowledgement. The owner's config/session/ack hashes
are compared before and after. This is the unacknowledged fixture: command
execution stays off without `command-execution.ack`.

## The question

Does the rebuilt Settings window behave as the 2026-09-04 spec says, in the
running app rather than in a package test? The package suites prove the
editing contract against a file and an `UndoManager`; they cannot see a
toolbar, a responder chain, a live pane or the preview. This does.

The check runs inside the app (`Sources/SettingsSelfCheck.swift`, Debug only)
because the window needs `ConfigurationCenter`, which needs libghostty, which
no `swiftc` probe links. It reads the same objects the window uses rather than
a screenshot of them.

## What would be false if it passed and the code were wrong

- **Window reuse.** A second `showSettings` must hand back the same controller.
  The old window was rebuilt per ⌘, and lost the draft being typed.
- **Toolbar.** Seven selectable items in the spec's order; selecting each moves
  the window title and the toolbar selection.
- **Controls.** Each page holds exactly one control per key its category owns,
  so a key without a control, or a control for a key the page does not own,
  fails by count.
- **Routing.** With Settings key, `closePane:` resolves to the Settings window
  and never to the app delegate, and pane commands validate disabled: the
  audit's S8 was ⌘W reaching a hidden workspace.
- **Every active key.** Committed through the window's own editor, each key
  moves the running settings and the file, a live pane's last applied
  appearance equals the centre's derivation, the notifier and the control
  server follow, and command execution stays off without the acknowledgement.
- **Undo.** Reverses the last edit in the running settings and the file; redo
  puts it back; a slider gesture of three frames is one undo step.
- **Invalid input.** A bad colour answers a validation error, writes nothing,
  and raises no recovery banner.
- **Numeric text.** Discovery depth is tested through its real text delegate:
  an oversized integer, a negative number, and a fractional value show errors
  without writing; valid text commits.
- **Preview.** The sample pane's resolved chrome and theme equal the centre's
  derivation for the same settings, the sample sidebar follows the setting and
  the chrome, each of the five states sets focus, activation and attention as
  named, and the sample renders non-blank pixels offscreen.
- **Malformed file.** A write is refused with the bytes untouched, the banner
  shows, repair keeps a byte-identical backup and leaves a valid file, and the
  banner hides.
- **Failure recovery.** A rejected checkbox change restores its effective value.
  A failed Undo remains visible and retryable after repair. External corruption
  and external repair update the open banner through the file watcher. These
  checks await callbacks without blocking the main queue.

## What it does not cover

Command-Comma from the keyboard, VoiceOver and Full Keyboard Access, the real
desktop behind a translucent sample, and persistence across an actual relaunch
(the file is read back through the store, which is what a relaunch reads).
Those are the owner's live pass.
