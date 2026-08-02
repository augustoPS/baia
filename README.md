# baia

A native macOS terminal workspace built on [Ghostty](https://ghostty.org)'s
terminal engine.

*baia* (from Kimbundu *ribaia*, "plank") is Portuguese for a stall: the
compartments planks make in a stable so each animal gets its own space. By
extension it names any divider-separated compartment, including a drive bay. It
is a false cognate of *baía*, "bay", which comes from Latin by way of French.

## Requirements

- macOS 26+
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
management, and the workspace UI.

`project.yml` is the single source of truth for the build; `baia.xcodeproj` is
generated and not checked in. Architecture notes, decisions, and gotchas live in
the vault at `vault/projects/baia/baia.md`; agent-facing conventions live in
`~/Projects/.claude/rules/baia.md`.

## Testing

`make test` runs the package suites, which cover everything decidable without a
window.

Anything that needs a real window, a Metal surface, a spawned shell, a live socket
or a human comparing two images is a probe, and every probe lives in
`Diagnostics/`. See `Diagnostics/README.md` for the layout, the shared harness in
`Diagnostics/lib/`, and what each of the ten probes answers.

## Design

`design/` is the Claude Design conversation, split by direction: `inbox/` is
design → code, `handoffs/` is code → design, both gitignored. `design/vitreous/`
beside them is tracked and maintained like source, since it is what the Liquid
Glass work is built against. See `design/README.md`.

## License

MIT. See [`LICENSE`](LICENSE).

baia embeds [Ghostty](https://github.com/ghostty-org/ghostty)'s terminal engine
through [`Lakr233/libghostty-spm`](https://github.com/Lakr233/libghostty-spm),
both MIT, whose notices are reproduced in `NOTICE`.
