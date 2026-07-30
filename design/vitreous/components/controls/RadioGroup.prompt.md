Use when options need descriptions; otherwise prefer `SegmentedControl` (inline) or `PopUpButton` (long lists).

```jsx
<RadioGroup value={mode} onChange={setMode} items={[
  { id: "ask", label: "Ask before every tool call" },
  { id: "safe", label: "Auto-approve safe tools", description: "Reads, searches, and git status" }
]} />
```
