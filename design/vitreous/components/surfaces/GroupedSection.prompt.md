The settings-window building block. One concern per section; explain consequences in `footnote`, not in a tooltip.

```jsx
<GroupedSection title="Permissions" footnote="Applies to new sessions only."
  rows={[{ label: "Auto-approve reads", control: <Switch checked={a} onChange={t} /> },
         { label: "Shell access", description: "bash, zsh", control: <PopUpButton options={["Ask", "Allow"]} value={v} onChange={s} /> }]} />
```
