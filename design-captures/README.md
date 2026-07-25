# Design captures

Screenshots of the running app for the Claude Design handover. **Gitignored on
purpose**: they are large, they go stale the moment the UI changes, and
`capture.sh` regenerates the whole set from the real app in about three minutes.

Regenerate after `make build`:

```bash
./design-captures/capture.sh
```

Claude Design is connected to the repository but **cannot see these**, since the
directory is ignored. Attach them to the conversation by hand.

## The set

| File | Shows |
|---|---|
| `01-four-pane-window.png` | Four panes in one tab. The focused-pane problem: with four footers the 2pt stripe is hard to find |
| `02-three-repos-git-states.png` | Three panes in three repositories: `baia main *`, `vault main *`, `admin main ?3`. Dirty, dirty, and untracked-only |
| `03-pinned-pane.png` | A pane pinned to `~/Projects`, which is not a repository, so the footer shows `PIN` and the working directory and no git segments |
| `04-attention-marker.png` | The richest one. Title reads `● 1 waiting`, the left pane is pinned **and** asking (`PIN` plus a red `!` plus its working directory), the middle pane is focused, and the right shows a third git state |
| `05-four-tab-bar.png` | Four tabs. Every tab reads `baia — <project>`, so the repeated prefix eats the width |
| `06-activity-labels.png` | A pane running `sleep 400` labelled `sleep`, trailing-aligned, beside an idle pane |

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

## What is deliberately absent

No app icon, so the window and the Dock show the placeholder grid. That is also
the leading suspect for `NSApp.dockTile.badgeLabel` doing nothing, which is why
the waiting count lives in the window title instead.
