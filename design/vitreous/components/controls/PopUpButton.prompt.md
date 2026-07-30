Value selection from a list (model, branch, harness) or, with `pullDown`, a menu of actions.

```jsx
<PopUpButton value={model} onChange={setModel} options={["Opus 4.6", "Sonnet 4.6", "Haiku 4.5"]} width={168} />
<PopUpButton pullDown label="Actions" options={["Duplicate session", "Export transcript…"]} />
```
