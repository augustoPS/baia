# settings-colour-interruption

Does a mid-drag close of the Appearance page's native Colors panel leave an
unpublished preview, and does the repair commit that last accepted colour
once so the UI, the file, and Undo agree?

## The finding (2026-09-10, isolated app, branch `full-audit` at `10dc9ba`)

Native proof: `.superpowers/sdd/roadmap/acceptance/run_c40d7fcb9df8/settings-final/40FACBB6-2865-4589-BC8A-0D80F432A33C/colour-close-history.json`.

PID 72470, grayscale panel drag starting at `#141414`, visible `#aaaaaa`
while the mouse was held, AXPress on the Colors close button at
`1789090402.453`, panel gone. After release the hex field was `#aaaaaa`
and the scratch file was `#141414`. One Undo then cleared the preview by
rolling back an earlier opacity write; the colour never entered history.

`ColourControl.picked` previews while `NSApp.currentEvent` is a mouse-down
or drag, and only calls `endGesture` on a later callback. Closing the
native panel omits that callback, so the last preview stays in the running
value and never reaches the file.

S02 allows either committing the last accepted gesture once or cancelling
to the origin, provided UI and file agree and no unpublished preview
remains. The slider's native Escape-during-drag already commits the last
value (0.81, one Undo back to 0.42). Colour takes the same policy: panel
close, well deactivation (the well losing the panel, including a focus
transfer that dismisses it), and Escape-as-close commit the last previewed
hex once.

## What it drives

The shipped `Sources/SettingsControls.swift`, compiled verbatim beside
`interruptprobe.swift`, against a real `SettingsTransactionController`
writing a scratch `config.json`. Preview must not write; `endGesture` must.
A recording editor that applied both to one in-memory value would hide the
bug. One `ColourControl` sits in an `NSWindow` that is never ordered on
screen. Its well and field are found by walking the view tree.

- Drag frames: an `NSEvent.leftMouseDragged` is posted and dequeued so it
  is `NSApp.currentEvent`, then the well takes the colour and fires its
  action. That is the preview path `picked()` takes inside the panel.
- Mouse-up: the same with `leftMouseUp`.
- Panel close: `willCloseNotification` posted at `NSColorPanel.shared`,
  which is never ordered front. The well is never `activate()`'d.
- Well deactivation: `NSColorWell.deactivate()`, the other arrival of
  "the well lost the panel".

## Arms

Bug arms, which must pass on the working tree and fail on `10dc9ba`:

| arm | claim |
|---|---|
| `panel-close-while-held` | Two drag frames then panel close write the last hex once; one Undo returns the origin; a second close adds nothing |
| `well-deactivate-while-held` | The same commit, arriving as the well deactivating |
| `panel-close-write-failure` | Close against a broken file takes the preview down, records the failure, writes nothing |

Guard arms, which must pass on both builds:

| arm | claim |
|---|---|
| `release-one-undo` | A completed drag still writes on mouse-up as one undo; idle close afterwards adds nothing |
| `idle-panel-close` | Close with no drag writes nothing and registers nothing |
| `write-failure-on-release` | A refused write on mouse-up still reverts, the existing `endGesture` contract |

`run.sh` builds the probe twice, once against the working tree and once
against `git show 10dc9ba:Sources/SettingsControls.swift`, and inverts the
bug arms on the second. A bug arm that passes on the buggy revision fails
the run: it would no longer be grading the bug.

## Focus

Opens no window on screen and takes no focus: no `orderFront`, `makeKey`,
`activate` or `pkill`, activation policy `.accessory`. The well is never
`activate()`'d, so the Colors panel is not shown. It is not on
`guard-baia-alive.sh`'s `SAFE_PROBES`; that list is the record and adding a
member is the guard owner's call. Until then, run it from outside a baia
pane.

## What it does not measure

- The focused hex field's typing flag: `settings-colour-history`.
- The slider's own mouse-up delivery, including Escape-during-drag: native
  checks already commit the last value.
- A live ordered Colors panel or a second disposable window. The hooks
  those use (willClose, deactivate) are driven here without showing them.
