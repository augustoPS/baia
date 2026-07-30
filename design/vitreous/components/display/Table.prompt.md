Structured multi-column data: tool calls, files, diffs, sessions. Numbers and paths use `mono: true` columns.

```jsx
<Table
  columns={[{id:"tool",label:"Tool",width:"140px"},{id:"target",label:"Target",mono:true},{id:"ms",label:"Time",width:"70px",align:"right",mono:true}]}
  rows={calls} selected={sel} onSelect={setSel} sort={{id:"ms",dir:"desc"}} onSort={setSort} />
```
