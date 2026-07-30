# UI kit — Agent terminal

The flagship kit: an agent-centric terminal app for macOS ("Atlas") — the archetype this system
was commissioned for. Built entirely from Vitreous primitives, no bespoke styling.

## Surfaces

| File | What |
| --- | --- |
| `index.html` | Whole window: transparent menu bar, window frame, sessions sidebar, tab strip, transcript, composer, run inspector, status bar, ⌘K palette, new-session sheet |
| `Transcript.jsx` | Transcript entries — user bubble, assistant bubble, tool call, pending approval, diff block, streaming indicator — plus the composer |
| `RunInspector.jsx` | Inspector tabs: Run (model, temperature, permissions, worktree, context), Tools (call table, availability), Cost (tokens, budget, today) |
| `Screens.jsx` | The other three views: approvals queue (multi-select, risk tiers), worktree diff (file list, hunk, stage/revert), cost dashboard (spend chart, per-session table, budget controls) |
| `data.js` | Sample sessions, worktrees, transcript, tool calls, palette hits |

## Interactions

- The toolbar's leading segmented control switches the main pane between Transcript, Approvals, Diff and Cost.
- ⌘K or the toolbar Search button opens the command palette; ⎋ dismisses.
- The pending `git commit` call can be approved or denied — approving rewrites the entry and
  clears the status-bar warning; toolbar badge and menu-bar status follow.
- Sidebar filter, session switching, tabs, inspector tabs, model pop-up, temperature slider and
  the permission switch are all live.
- The sidebar footer switches appearance (dark/light) and toggles tinted glass, so the window can
  be reviewed in all three modes.
- Menu-bar File/Session titles open real `Menu` surfaces.

## Notes

"Atlas" and all content are invented sample data, sized to exercise every component at realistic
density. Nothing is copied from a real product.
