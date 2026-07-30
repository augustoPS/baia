Primary navigation. Text labels only; use `marker` dots for status and `trailing` for counts.

```jsx
<Sidebar value={v} onSelect={setV} header={<SearchField placeholder="Filter" />}
  groups={[{ label: "Sessions", items: [{ id: "s1", label: "Refactor auth", trailing: "4m", marker: "var(--status-positive)" }] }]} />
```
