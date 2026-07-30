Only for conditions the user must acknowledge — destructive confirmation, failed run, revoked credentials. Everything else is a `Sheet` or an inline banner.

```jsx
<Alert open={o} severity="warning" title="Discard 3 uncommitted changes?"
  message="The agent will reset the worktree before retrying."
  actions={<><Button onClick={no}>Cancel</Button><Button variant="destructive">Discard</Button></>} />
```
