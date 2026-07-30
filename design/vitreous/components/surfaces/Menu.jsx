import React from "react";

function Item({ item, onPick }) {
  const [hover, setHover] = React.useState(false);
  if (item === "-" || item.separator) {
    return <span style={{ display: "block", height: "var(--hairline)", background: "var(--separator)", margin: "4px 0" }} />;
  }
  if (item.header) {
    return <span style={{ display: "block", padding: "4px 10px 2px", font: "var(--type-caps)", letterSpacing: "var(--ls-caps)", textTransform: "uppercase", color: "var(--label-tertiary)" }}>{item.header}</span>;
  }
  const disabled = item.disabled;
  return (
    <button
      onClick={() => !disabled && onPick && onPick(item)}
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
      style={{
        all: "unset", display: "flex", alignItems: "center", gap: "8px",
        width: "100%", boxSizing: "border-box",
        height: "var(--h-menu-item)", padding: "0 8px", borderRadius: "var(--r-2)",
        cursor: disabled ? "default" : "default",
        font: "var(--type-body)",
        color: disabled ? "var(--label-tertiary)" : hover ? "var(--selection-text)" : "var(--label)",
        background: hover && !disabled ? "var(--selection)" : "transparent",
        transition: "background-color var(--dur-1) linear"
      }}
    >
      <span style={{ width: 10, flex: "none", opacity: item.checked ? 1 : 0, fontSize: 10 }}>✓</span>
      <span style={{ flex: 1, whiteSpace: "nowrap" }}>{item.label}</span>
      {item.shortcut ? <span style={{ color: hover && !disabled ? "color-mix(in srgb, var(--selection-text) 80%, transparent)" : "var(--label-tertiary)", font: "var(--type-body)" }}>{item.shortcut}</span> : null}
      {item.submenu ? <span style={{ fontSize: 8, color: "var(--label-tertiary)" }}>▶</span> : null}
    </button>
  );
}

export function Menu({ items = [], onPick, width = 220, style, ...rest }) {
  return (
    <div
      role="menu"
      style={{
        width, padding: "4px", borderRadius: "var(--r-4)",
        background: "var(--mat-fill-menu)",
        backgroundImage: "var(--lens-sheen)",
        backdropFilter: "var(--mat-thick)", WebkitBackdropFilter: "var(--mat-thick)",
        boxShadow: "var(--lens-rim-strong), var(--shadow-popover)",
        animation: "vg-appear var(--dur-1) var(--ease-out) both",
        ...style
      }}
      {...rest}
    >
      {items.map((it, i) => <Item key={i} item={typeof it === "string" ? { label: it, separator: it === "-" } : it} onPick={onPick} />)}
    </div>
  );
}
