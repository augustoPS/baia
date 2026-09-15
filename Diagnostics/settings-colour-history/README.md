# settings-colour-history

Does the Appearance page's hex field overwrite the colour chosen in the native
Colors panel when focus leaves it, and does the repair keep every edit the owner
did type?

## The finding (2026-09-10, isolated app, branch `full-audit` at `10dc9ba`)

The page opens with the hex field focused and showing `#141414`. Nobody types. A
continuous gray drag in the Colors panel moves the well and the file to
`#bababa`; ⌘Z returns `#141414` and ⇧⌘Z `#bababa`. The field shows `#141414`
through all of it. Clicking the Typography toolbar item ends editing, and the
field commits `#141414` over the chosen value.

Two lines in `ColourControl` produced that:

- `refresh` skipped the field whenever `currentEditor()` was non-nil. A field
  has an editor for as long as it has focus, typed in or not, so the text froze
  at its opening value while the well beside it followed every write.
- `controlTextDidEndEditing` committed the field's text on every focus loss,
  so the frozen text became a write.

The repair replaces the editor check with a typing flag: `controlTextDidChange`
sets it, a commit clears it, and `refresh` writes the running value into any
field that does not hold typing, focused or not. Leaving a field that holds no
typing commits nothing. Invalid text still stays with its reason; typed text
still wins over a panel pick made mid-edit and is committed once when focus
leaves. The well's action path and its gesture grouping are untouched.

## What it drives

The shipped `Sources/SettingsControls.swift`, compiled verbatim beside
`historyprobe.swift`, against a recording `SettingsEditing` that applies
`backgroundHex`, refreshes the control after each write the way
`SettingsWindowController.refresh()` does, and offers `undo()`/`redo()` that
write the previous value back the way the transaction controller does. One
`ColourControl` sits in an `NSWindow` that is never ordered on screen. Its well
and field are found by walking the view tree.

The probe's entry is `@main`, as in `override-wires`. A multi-file build allows
top-level statements only in a file named `main.swift`, and the first version
had them at the top level of this file, so it did not compile.

- Focus: `window.makeFirstResponder(field)` starts the field editor's session,
  `makeFirstResponder(nil)` ends it, which is what a toolbar click does.
- Typing: the field editor's own `insertText(_:replacementRange:)`, which posts
  the change the control hears as `controlTextDidChange`.
- The panel: the well takes the colour and its action is sent. With no current
  event in the process the control takes the gesture-end path; the drag frames'
  `preview` path is the slider's arrangement and is not what this probe grades.

The field's text is read off its editor, not `stringValue`, because the getter
validates editing and would copy the editor's text into the cell, hiding
exactly the mismatch under test.

## Arms

Bug arms, which must pass on the working tree and fail on `10dc9ba`:

| arm | claim |
|---|---|
| `mirror-while-focused` | A focused field with nothing typed follows the panel pick |
| `leave-without-typing` | Leaving that field commits nothing; the chosen colour stands |
| `undo-redo-then-leave` | ⌘Z and ⇧⌘Z show in the focused field; leaving after ⇧⌘Z commits nothing |
| `leave-untouched` | Focus in and out of an untouched field proposes nothing. The buggy revision committed the opening value on every focus loss, a write the transaction controller dropped as equal to the file, so this grades the proposal rather than the file |
| `keystroke-backspace-then-panel` | A keystroke and a Backspace through the field editor leave the text as it was, then a panel pick: the pick shows in the field and leaving proposes nothing. A typing flag lowered only by a commit is still up after the Backspace and reproduces the original overwrite one keystroke later (independent review D1) |
| `invalid-then-panel-consistent` | Refused text and a later valid panel pick end consistent: the well's colour replaces the text and the reason goes with it. Before, the write's synchronous refresh skipped the text while the reason was still up, and the nil result then hid the reason (independent review D2) |

Guard arms, which must pass on both builds:

| arm | claim |
|---|---|
| `typed-commit` | Typed text commits once, when focus leaves, with no error |
| `typed-survives-panel` | A panel pick mid-edit does not replace typed text; the typed text lands |
| `invalid-kept` | Invalid text shows its reason, stays, writes nothing. What a later panel pick does to it is `invalid-then-panel-consistent`'s question |

`run.sh` builds the probe twice, once against the working tree and once against
`git show 10dc9ba:Sources/SettingsControls.swift`, and inverts the bug arms on
the second. A bug arm that passes on the buggy revision fails the run: it would
no longer be grading the bug.

## Focus

Opens no window on screen and takes no focus: no `orderFront`, `makeKey`,
`activate` or `pkill`, activation policy `.accessory`. It is not on
`guard-baia-alive.sh`'s `SAFE_PROBES`; that list is the record and adding a
member is the guard owner's call. Until then, run it from outside a baia pane.

## What it does not measure

- The drag frames' `preview` path and the window undo manager's grouping of a
  drag into one step: `SettingsTransactionControllerTests` in `BaiaSettings`.
- The field editor's typing undo, and its scrub from the window's manager on
  end editing: unchanged by the repair. In this rig typing registers nothing
  on the window's manager (see `undo-wiring` in `settings-field-history`), so
  no arm here undoes typing; `keystroke-backspace-then-panel` reaches the same
  state with a Backspace.
- The real Colors panel and toolbar: the native check is still the sequence in
  the finding above, on an isolated app.
