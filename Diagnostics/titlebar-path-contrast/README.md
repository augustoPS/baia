# titlebar-path-contrast

**Question.** Does the production titlebar path keep its theme ink while adding
an opposite-luminance edge under glass, and remove that edge under flat chrome?

The probe compiles `TitlebarPathAccessory.swift` with its production colour
bridge and package dependencies. It inspects the real `NSTextField` and
`NSImageView` state. It checks Dark Pastel and a light Dawnfox fixture, then
switches one accessory from glass to flat and back without recreating it.

Run from anywhere:

```sh
./run.sh
```

This probe opens no window, takes no focus, launches nothing, and changes no
application state. `./run.sh --expect-missing` is the one-use RED baseline: it
passes only while the production accessory has no glass edge treatment.
