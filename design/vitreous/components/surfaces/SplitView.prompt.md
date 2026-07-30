Compose window bodies: sidebar + list + detail, or content + inspector.

```jsx
<SplitView panes={[
  { width: "var(--w-sidebar)", content: <Sidebar … /> },
  { width: "var(--w-list-pane)", content: <List … /> },
  { content: <Detail … /> }
]} />
```
