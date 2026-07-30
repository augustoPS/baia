Use for any custom glass surface not already covered by `Box`, `Popover`, `Sheet`, `Toolbar`, `Sidebar`.

```jsx
<Material material="hud" radius="var(--r-6)" pad={12} elevation="popover">…</Material>
```

Material roles: `chrome` toolbars/titlebars, `sidebar` source lists, `menu` menus, `hud` floating overlays and tooltips, `ultraThin→thick` general content by how much backdrop should show through. Turn `sheen` off on surfaces wider than ~900px.
