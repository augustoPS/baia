Toolbar and sidebar filtering. Live-filter as the user types; never require Return.

```jsx
<SearchField value={q} onChange={(e) => setQ(e.target.value)} onClear={() => setQ("")} width={200} scope="Transcript" />
```
