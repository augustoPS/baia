Documents, editor buffers, terminal panes. `dirty` shows the unsaved dot.

```jsx
<Tabs tabs={[{id:"a",label:"main.rs",dirty:true},{id:"b",label:"lib.rs"}]} value={t} onChange={setT} onClose={close} onNew={add} />
```
