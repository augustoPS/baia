Window-scoped modal work: open/save, new session setup, permission prompts. Default action rightmost.

```jsx
<Sheet open={o} title="New session" onDismiss={close}
  actions={<><Button onClick={close}>Cancel</Button><Button variant="accent">Create</Button></>}>
  <TextField label="Working directory" mono defaultValue="~/src/atlas" />
</Sheet>
```
