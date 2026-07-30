System-wide or app-wide search and command running (⌘K / ⌘Space). Center it over a dimmed desktop.

```jsx
<CommandPalette open={o} query={q} onQuery={setQ} selected={sel} onSelect={setSel}
  groups={[{ label: "Sessions", items: [{ id: "s1", label: "Refactor auth guard", detail: "4m ago", shortcut: "⏎" }] }]}
  footer={<><KeyCap size="small">↑</KeyCap><KeyCap size="small">↓</KeyCap> to navigate</>} />
```
