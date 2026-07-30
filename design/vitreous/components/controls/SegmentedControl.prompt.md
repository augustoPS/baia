2–5 mutually exclusive view modes, usually in a toolbar or above a list.

```jsx
<SegmentedControl value={mode} onChange={setMode} items={["Transcript", "Diff", "Plan"]} />
```

More than five options, or long labels → `PopUpButton`.
