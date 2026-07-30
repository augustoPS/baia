Every screen starts here. Put it on a desktop backdrop so the glass has something to lens.

```jsx
<WindowFrame title="Atlas" subtitle="~/src/atlas · main"
  sidebar={<Sidebar … />} toolbar={<Toolbar … />} statusBar={<>…</>}>
  {content}
</WindowFrame>
```

Never give a window an opaque background — the whole system depends on the wallpaper showing through.
