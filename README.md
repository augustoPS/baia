# baia

A native macOS terminal workspace built on [Ghostty](https://ghostty.org)'s
terminal engine. Baia keeps terminals, projects, files, and agent activity in
one AppKit workspace.

[Website](https://baia.sh) · [Source](https://github.com/augustoPS/baia)

*baia* (from Kimbundu *ribaia*, "plank") is Portuguese for a stall: the
compartments planks make in a stable so each animal gets its own space. By
extension it names any divider-separated compartment, including a drive bay. It
is a false cognate of *baía*, "bay", which comes from Latin by way of French.

## Download and install

Baia is currently distributed from source. It does not yet have a notarized
binary release.

### Requirements

- macOS 26+
- Xcode 26+ with `xcode-select` pointed at it, not CommandLineTools
- Homebrew, used to install [XcodeGen](https://github.com/yonaskolb/XcodeGen)

### Install

```sh
git clone https://github.com/augustoPS/baia.git
cd baia
make bootstrap
make doctor
make install
open -a baia
```

`make install` builds the Release app and copies it to `/Applications/baia.app`.
Run `make install` again after pulling a newer version. Use `make uninstall` to
remove the app; its Application Support data is left in place.

For development, `make build` creates the separate Debug app and `make run`
launches it as `baia-dev.app`, without replacing the installed copy.

## Use baia

1. Launch Baia and press **Command-K** to open the project palette.
2. Choose a project to attach its directory, files, and Git context to the pane.
3. Use **Command-D** to split right or **Shift-Command-D** to split down.
4. Use **Option-Command-arrow** to move focus between panes.
5. Open **Settings** with **Command-,** to change the terminal theme, font,
   sidebar, and workspace appearance.

Useful commands are also available from the **Pane**, **Project**, **View**, and
**Window** menus. Native macOS tabs can be reordered, dragged into another tabbed
window, detached, and restored with the workspace session.

## Architecture

The terminal engine is [`Lakr233/libghostty-spm`](https://github.com/Lakr233/libghostty-spm),
consumed as a package dependency. Baia supplies the app shell, window and pane
management, and the workspace UI.

`project.yml` is the single source of truth for the build; `baia.xcodeproj` is
generated and not checked in. Contributor and automation constraints live in
`AGENTS.md` and `CLAUDE.md`.

## Testing

`make test` runs the package suites, which cover everything decidable without a
window. `make build` compiles the app target.

Anything that needs a real window, a Metal surface, a spawned shell, a live socket,
or a human comparing two images is a probe in `Diagnostics/`. See
`Diagnostics/README.md` for the layout and safety rules.

## Design

`design/vitreous/` contains the tracked design source for Baia's Liquid Glass
interface. See `design/README.md`.

## License

MIT. See [`LICENSE`](LICENSE).

Baia embeds [Ghostty](https://github.com/ghostty-org/ghostty)'s terminal engine
through [`Lakr233/libghostty-spm`](https://github.com/Lakr233/libghostty-spm),
both MIT, whose notices are reproduced in `NOTICE`.
