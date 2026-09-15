# settings-field-history

Does a focused, untouched number or text field overwrite an undone value when
focus leaves it, and does the repair keep every edit the owner did type, every
refusal the owner has to correct, and the locale the owner types in?

## The finding (2026-09-10, isolated app, branch `full-audit` at `10dc9ba`)

Native proof: `.superpowers/sdd/roadmap/acceptance/run_c40d7fcb9df8/settings-final/…/s02-number-undo-leave.json`.

The Typography page has its Font size field focused, showing 14. Nobody types.
⌘Z writes 11.5 to the file; the stepper beside the field shows 11.5 and the
field keeps 14. Clicking the Window toolbar item ends editing, and the field
commits 14 over the undone value.

Two lines in `NumberControl` produced that, the same two `ColourControl`
carried (see `settings-colour-history`):

- `refresh` skipped the field whenever `currentEditor()` was non-nil. A field
  has an editor for as long as it has focus, typed in or not, so the text froze
  while the stepper beside it followed every write.
- `controlTextDidEndEditing` parsed and committed the field's text on every
  focus loss, so the frozen text became a write.

`TextControl` carried the same two lines. No page builds one today, so there is
no native proof for it; the `text-*` arms below drive the shipped class the way
a page would and fail on `10dc9ba` for the same reason.

The repair is the one `ColourControl` took: a typing flag set by
`controlTextDidChange`, cleared by a commit, and `refresh` writes the running
value into any field that does not hold typing, focused or not. Leaving a field
that holds no typing commits nothing. In `NumberControl` a stepper click also
clears the flag, since its text replaces whatever was typed. Invalid text still
stays with its reason; typed text still wins over ⌘Z made mid-edit and is
committed once when focus leaves; the range, whole-number and locale parsing
are untouched.

## What it drives

The shipped `Sources/SettingsControls.swift`, compiled verbatim beside
`fieldprobe.swift`, against a recording `SettingsEditing` that applies
`fontSize`, `discoveryMaxDepth` and `themeName`, refreshes the control after
each write the way `SettingsWindowController.refresh()` does, drops a write
equal to the file the way the transaction controller does, and offers
`undo()`/`redo()` that write the previous value back. One control at a time
sits in an `NSWindow` that is never ordered on screen. Its field and stepper
are found by walking the view tree. The number controls are built with the
arguments `SettingsPages` gives the Font size and Discovery depth rows.

- Focus: `window.makeFirstResponder(field)` starts the field editor's session,
  `makeFirstResponder(nil)` ends it, which is what a toolbar click does.
- Typing: the field editor's own `insertText(_:replacementRange:)`, which posts
  the change the control hears as `controlTextDidChange`.
- The stepper: it takes the value and its action is sent.
- Locale: every typed number is spelled by a `NumberFormatter` on
  `Locale.current`, the locale the control's own formatter parses in. `run.sh`
  runs the locale arm a second time under `-AppleLocale de_DE` and checks the
  separator the arm prints, so a comma is exercised rather than assumed.

The field's text is read off its editor, not `stringValue`, because the getter
validates editing and would copy the editor's text into the cell, hiding
exactly the mismatch under test.

## Arms

Bug arms, which must pass on the working tree and fail on `10dc9ba`:

| arm | claim |
|---|---|
| `number-mirror-while-focused` | A focused number field with nothing typed follows ⌘Z like its stepper |
| `number-undo-then-leave` | Leaving that field after ⌘Z proposes nothing; the undone value stands |
| `number-leave-untouched` | Focus in and out of an untouched field proposes nothing. The buggy revision committed the opening value on every focus loss, a write the transaction controller dropped as equal to the file, so this grades the proposal |
| `number-stepper-replaces-typing` | A stepper click mid-edit replaces the typed text and writes once; leaving afterwards proposes nothing more |
| `number-keystroke-backspace-then-history-undo` | A keystroke and a Backspace through the field editor leave the text as it was; ⌘Z on the app's own stack (a real `SettingsTransactionController` on a scratch file, one `UndoManager` the window hands to its field editor) undoes the last write. The field shows the undone value and leaving proposes nothing. A typing flag lowered only by a commit is still up after the Backspace and freezes the text (independent review D1) |

Report arm, always green, not in `run.sh`: `undo-wiring` prints the field
editor's `allowsUndo`, the cell's, which manager the editor answers, and what
the shared manager holds after typing and after the event closes. It exists
because the first run showed typing registering nothing on the window's
manager in this rig, so no arm here undoes typing itself; the finding it
graded is reached with a Backspace instead.
| `text-mirror-while-focused` | The same for a focused text field |
| `text-undo-then-leave` | The same for leaving a text field after ⌘Z |
| `text-leave-untouched` | The same for an untouched text field |

Guard arms, which must pass on both builds:

| arm | claim |
|---|---|
| `number-typed-commit` | Typed text commits once, when focus leaves, with no error |
| `number-locale-typed` | A fraction typed with the locale's separator commits and mirrors back in the same spelling; run twice, the second time under `de_DE` |
| `number-typed-survives-undo` | ⌘Z mid-edit moves the stepper and not the typed text; the typed text lands |
| `number-invalid-kept` | Text that is not a number shows its reason, writes nothing, stays through ⌘Z, clears when corrected |
| `number-out-of-range` | A number outside the range is refused with the range, not clamped |
| `number-whole-levels` | The integer-backed control refuses a fraction before `edit` rounds it, and takes a whole number |
| `text-typed-commit` | Typed text commits once, when focus leaves |
| `text-typed-survives-undo` | ⌘Z mid-edit does not replace typed text; the typed text lands |
| `text-invalid-kept` | Text the file refuses shows its reason, stays, writes nothing |

`run.sh` builds the probe twice, once against the working tree and once against
`git show 10dc9ba:Sources/SettingsControls.swift`, and inverts the bug arms on
the second. A bug arm that passes on the buggy revision fails the run: it would
no longer be grading the bug.

## Focus

Opens no window on screen and takes no focus: no `orderFront`, `makeKey`,
`activate` or `pkill`, activation policy `.accessory`. It is not on
`guard-baia-alive.sh`'s `SAFE_PROBES`; that list is the record and adding a
member is the guard owner's call. Until then, run it from outside a baia pane
and from a session the guard does not cover.

## What it does not measure

- The window undo manager's grouping and the inverse registration:
  `SettingsTransactionControllerTests` in `BaiaSettings`.
- The real toolbar and the real ⌘Z through the responder chain: the native
  check is still the sequence in the finding above, on an isolated app. The
  `number-keystroke-backspace-then-history-undo` arm calls the shared
  manager's `undo()` directly, which is what the Edit menu reaches; the menu
  and the responder chain themselves are not driven.
- The field editor's own typing undo: in this rig it registers nothing on the
  window's manager (`undo-wiring` says what it is wired to), so whether ⌘Z in
  the app first undoes typing is a native question.
- A number typed with the wrong locale's separator (`11.5` under `de_DE`):
  whatever `NumberFormatter` makes of it is the shipped behaviour and not
  graded here.
