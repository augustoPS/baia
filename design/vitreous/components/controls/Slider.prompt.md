Continuous settings — temperature, transparency, font size. Pair with `valueLabel` in mono so the number is readable.

```jsx
<Slider label="Temperature" value={t} valueLabel={t.toFixed(2)} min={0} max={2} step={0.05} onChange={setT} />
```
