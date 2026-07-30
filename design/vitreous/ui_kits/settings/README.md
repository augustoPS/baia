# UI kit — Settings

Settings window: 200px category sidebar, centered 620px content column of `GroupedSection` rows.

- Three panes are built (Agents & tools, Providers & keys, Appearance); the remaining sidebar items
  deliberately show an empty state rather than invented content.
- The Appearance pane is the system's own control surface: theme, clear/tinted glass, accent color and
  motion setting all write `data-*` attributes on the root, so the whole window re-renders live.
- "Reset all settings" opens a destructive `Alert`.
