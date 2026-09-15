# Invalid settings discovery

`./run.sh` from anywhere. Two fixtures, neither launches baia or takes
focus. `bannertest.swift` compiles the shipped `SettingsRecoveryBanner` from
`Sources/SettingsWindowController.swift` and drives it offscreen.
`retypetest.swift` compiles the shipped `Sources/SettingsControls.swift`
verbatim and drives one text, number or colour field in a window that is
never ordered front, the `settings-field-history` harness.

## The question

When `config.json` carries a wrong-type field next to a valid sibling — the
S03 case, string `fontSize` plus padding 24 — does Settings actually *show*
that the decoder rejected `fontSize`, without blaming padding, without
claiming every rejected value became its default, and does writing a valid
`fontSize` clear the warning?

`SettingsStore.load()` already returns `invalidKeys`. `ConfigurationCenter`
already prints them on stderr. The Settings window's recovery banner used to
inspect only document shape and write failure, so Typography showed the
fallback 11.5 with nothing connecting that number to the file.

## What would be false if it passed and the code were wrong

- **Discovery.** A valid JSON object with `"fontSize": "big"` and
  `"windowPadding": 24` must show the banner, name `` `fontSize` ``, and not
  mention `windowPadding`. A probe that only checked `invalidKeys` would pass
  on the revision that left the banner hidden.
- **Wording.** Opacity 1.5 is clamped to 1 and still reported. The banner
  must not say that value defaulted; some rejected fields clamp, some fall
  back.
- **Correction.** Patching `fontSize` to 12 through `SettingsStore.patch` —
  the write Settings uses — must hide the banner and keep padding 24.
- **Sibling write.** Patching padding while `fontSize` is still `"big"` must
  leave the warning up. A write of a valid neighbour must not rewrite or
  excuse the invalid field.
- **Red control.** The four arms above must *fail* on
  `10dc9bafd86c6a63ff211b4b1d3fef3534b5f2dd`, whose `present` ignored
  `invalidKeys`. If they pass there, they are not grading the bug.
- **Existing recovery.** Malformed JSON still offers Repair; a write failure
  on a valid file still says the last change was not saved; a pending undo
  retry still appears; a clean file still hides the banner.

## The second question: a stale error over the file's own value

Found 2026-09-13. Font size shows 11.5. The owner types `abc`, leaves, and
"Enter a number." appears. They type `11.5` back and leave. The field shows
the file's value and the red line stays. `TextControl`, `NumberControl` and
`ColourControl` all carried it: the retyped text equals the mirror, so
`fieldHoldsTyping` is false, and a mirror proposes nothing, so nothing ever
called `show(nil)`.

The repair, in `controlTextDidEndEditing` of all three: with no typing
pending, an error showing, and the text equal to the mirror, clear the
error and propose nothing. `mirroredText` is now tracked through every
`refresh`, including the ones that leave refused or typed text in place, so
"the mirror" is what the file holds now rather than what it held when the
field was last overwritten; a ⌘Z under refused text moves it.

### What would be false if it passed and the code were wrong

- **Retype clears, and proposes nothing.** `text-retype-mirror-clears`,
  `number-retype-mirror-clears` and `colour-retype-mirror-clears` refuse
  `   `, `abc` and `zzz` in turn, type the opening value back, and assert
  the error line is hidden, the proposal list is unchanged, the field shows
  the mirror and the running value did not move. Each half has a tree that
  got it wrong: the revision before the `fieldHoldsTyping` rework cleared
  the error through a duplicate commit the transaction controller then
  dropped, and the tree after it proposed nothing and left the error up.
- **Red control.** The three arms fail on
  `10dc9bafd86c6a63ff211b4b1d3fef3534b5f2dd` on the proposal half.
- **Untouched refused text stays.** `number-leave-refused-untouched`
  focuses through `abc` without typing: error still showing, text kept,
  nothing proposed. The clear branch must not read an untouched field as a
  correction.
- **The mirror follows ⌘Z under an error.**
  `number-retype-old-value-after-undo-commits` writes 14, refuses `abc`,
  ⌘Z back to 11.5, then types 14: it is a proposal and lands. With the
  mirror frozen at 14 while the error was up, the retype read as the mirror
  and was dropped, leaving 14 on screen over 11.5 in the file.

## What it does not cover

Opening the real Settings window, VoiceOver speech, or typing a correction
into the Typography field through real key events. Those need an isolated
app and the desktop.
After a Debug build, from a terminal that is not a baia pane:

```sh
BAIA_ISOLATED_SKIP_BUILD=1 bash Diagnostics/settings-window/run.sh
```

is the existing window self-check (valid starting file). The S03 native
replay is: seed an isolated `BAIA_CONFIG_FILE` with `"fontSize": "big"` and
`"windowPadding": 24`, open Settings, read the banner, set Font size to a
value in range, confirm the banner hides and padding stays 24. This fixture
does not perform that drive.

## Run

```sh
/Users/pasqualotto/Projects/baia/Diagnostics/settings-invalid-fields/run.sh
```

It is not on `SAFE_PROBES`. The coordinator runs it; pairing it with a
focus-taking driver is still denied.
