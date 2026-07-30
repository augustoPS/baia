Text-labelled toolbar items at 28px. Group with `ToolbarSeparator`; push utilities into `trailing`.

```jsx
<Toolbar trailing={<SearchField width={180} … />}>
  <ToolbarButton label="Run" active />
  <ToolbarSeparator />
  <ToolbarButton label="Stop" disabled />
  <ToolbarButton label="Approvals" badge={2} />
</Toolbar>
```
