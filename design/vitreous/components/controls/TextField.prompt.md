Single- or multi-line entry. `mono` for paths, commands, keys.

```jsx
<TextField label="Working directory" mono defaultValue="~/src/atlas" />
<TextField multiline rows={4} placeholder="Describe the task for the agent…" />
<TextField label="Timeout" suffix="s" invalid hint="Must be 1–600" />
```
