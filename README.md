# baia

A native macOS terminal workspace built on [Ghostty](https://ghostty.org)'s
terminal engine.

*baia* (from Kimbundu *ribaia*, "plank") is Portuguese for a stall: the
compartments planks make in a stable so each animal gets its own space. By
extension it names any divider-separated compartment, including a drive bay. It
is a false cognate of *baía*, "bay", which comes from Latin by way of French.

## Requirements

- macOS 15+
- Xcode 26+ with `xcode-select` pointed at it, not CommandLineTools
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`make bootstrap`)

## Build

```sh
make doctor    # verify the toolchain
make build     # generate the project and build Debug
make run       # launch
```

`baia.xcodeproj` is generated from `project.yml` and is not checked in.

## Architecture

The terminal engine is [`Lakr233/libghostty-spm`](https://github.com/Lakr233/libghostty-spm),
consumed as a package dependency. baia supplies the app shell, window and pane
management, and the workspace UI. See `CLAUDE.md` for the constraints that keep
that boundary intact.

## License

Not yet chosen. The dependency chain is MIT throughout, so anything is still open.
