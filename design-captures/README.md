# Design captures

Screenshots of the running app for the Claude Design handover. **Gitignored on
purpose**: they are large, they go stale the moment the UI changes, and
`capture.sh` regenerates the whole set from the real app in about four minutes.

Regenerate after `make build`:

```bash
./design-captures/capture.sh
```

Claude Design is connected to the repository but **cannot see these**, since the
directory is ignored. Attach them to the conversation by hand.

## The set

Captures 01 to 06 are the pane, footer and tab references the v1 and v2 documents
were built from, and they run with the sidebar off so they still show what they
were built to show. 07 to 13 are the sidebar, for v3.

| File | Shows |
|---|---|
| `01-four-pane-window.png` | Four panes in one tab. The focused-pane problem: with four footers the 2pt stripe is hard to find |
| `02-three-repos-git-states.png` | Three panes in three repositories: `baia main *`, `vault main *`, `admin main ?3`. Dirty, dirty, and untracked-only |
| `03-pinned-pane.png` | A pane pinned to `~/Projects`, which is not a repository, so the footer shows `PIN` and the working directory and no git segments |
| `04-attention-marker.png` | The richest one. Title reads `● 1 waiting`, the left pane is pinned **and** asking (`PIN` plus a red `!` plus its working directory), the middle pane is focused, and the right shows a third git state |
| `05-four-tab-bar.png` | Four tabs. Every tab reads `baia — <project>`, so the repeated prefix eats the width |
| `06-activity-labels.png` | A pane running `sleep 400` labelled `sleep`, trailing-aligned, beside an idle pane |
| `07-changes-surface.png` | Changes alone, with every marker state at once: `UU` conflict, `A` staged, `MM` staged and since modified, `M` unstaged, `??` untracked, and two paths too long for the column |
| `08-files-tree.png` | The tree in this repository, `Packages/BaiaSettings` expanded, so indentation runs three levels deep in a 260 pt column |
| `09-both-sections.png` | Both sections stacked. Two headings, two scroll regions, the invisible split between them, and a short list above a long one |
| `10-path-picker.png` | What a click does: `Sources/Workspace/Pane.swift` sitting on the focused pane's prompt, unrun |
| `11-no-changes.png` | The empty state of a clean repository, above a tree that is not empty |
| `12-not-a-repository.png` | Both sections reading `not a repository` for a pane anchored to a plain directory. A different fact from "nothing changed", and currently the same sentence twice |
| `13-sidebar-and-panes.png` | The sidebar beside three panes. The footer and the sidebar describing one repository with nothing connecting them, and the window's leading corners belonging to the column |

**The elided rows in 07 and 09 are new, and they replace a bug.** Until 2026-07-29
`ChangesSurface.draw(_:atIndex:)` drew the path with `NSAttributedString.draw(in:)`
into a one-row rect, so a path wider than the column wrapped at its last `/` onto a
second line the rect clipped away, and what disappeared was the file name the row
exists to show. Thirty characters was enough at 260 pt, which is
`Sources/Workspace/Divider.swift`. The rows now run design v3 §3's ladder: the
directory gives way and the name never does, so that row draws as
`Sources/…/Divider.swift` and `Sources/Workspace/Pane.swift` beside it is untouched.
`PaneChrome.RowPath` is the rule and it is unit tested.

## Reading the footer

Left to right: anchor name, `PIN` when pinned, branch, git markers, then the agent
or command label and the working directory pushed to the right.

The marker vocabulary is the owner's own shell prompt and does not change:
`↑` ahead, `↓` behind, `*` dirty, `?` untracked.

Segments disappear rather than render empty, which is why no two captures show the
same set:

- A plain-directory anchor emits no git segments at all, even when git data exists
- A branch with no upstream drops ahead and behind rather than showing stale zeroes
- The working directory appears only when it differs from the anchor
- An idle shell contributes no agent segment

## What the script needs, and why

- **`demo-repo.sh`** builds two throwaway repositories under `/tmp/baia-design-demo`.
  The Changes surface groups conflicts, staged, unstaged and untracked, and no
  repository on this machine holds all four at once. Manufacturing them beats
  staging and conflicting something the owner is working in.
- **`click.swift`** posts a real mouse event, compiled to `.build/click` on first
  run. The sidebar takes no first responder, so its rows cannot be reached by
  keyboard, and they cannot be reached by AppleScript either: `System Events click
  at` resolves the accessibility element under the point and presses it, which a
  custom-drawn view answering `mouseDown` does not implement. The call reports the
  element it found and nothing happens.
- **The config**, `~/.config/baia/config.json`, is where each capture's sidebar
  state is written before launch. Cycling with `View → Switch Sidebar` counts from
  whatever the file already says, so a capture pressing ⌘⌥S a fixed number of times
  lands somewhere different on every machine. The file is backed up and put back on
  exit, including when the run is killed.
- **`caffeinate`** holds the display awake for the run. Four minutes with no human
  input is long enough for the display to sleep, and a slept display has no windows
  to ask about: `window 1` becomes an invalid index and `screencapture -R` refuses
  the rect, which reads as an app bug rather than as a screensaver.

## What is deliberately absent

Nothing now. The icon shipped, and 01 to 06 were regenerated on 2026-07-29 against
the current build, so they carry the v2 footer frame and the whole-pane attention
frame rather than the scrim they were first taken with.
