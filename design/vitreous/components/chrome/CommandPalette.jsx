import React from "react";

export function CommandPalette({ open = true, query = "", onQuery, groups = [], selected, onSelect, footer, width = "var(--w-palette)", style, ...rest }) {
  if (!open) return null;
  const flat = [];
  groups.forEach((g) => (g.items || []).forEach((it) => flat.push(it)));
  return (
    <div
      role="dialog"
      style={{
        width, maxWidth: "94%",
        borderRadius: "var(--r-7)", overflow: "hidden",
        background: "var(--mat-fill-menu)",
        backgroundImage: "var(--lens-sheen), var(--lens-refract)",
        backdropFilter: "var(--mat-hud)", WebkitBackdropFilter: "var(--mat-hud)",
        boxShadow: "var(--lens-rim-strong), var(--shadow-sheet)",
        color: "var(--label)",
        animation: "vg-rise var(--dur-3) var(--ease-out) both",
        ...style
      }}
      {...rest}
    >
      <div style={{ display: "flex", alignItems: "center", gap: "var(--sp-5)", padding: "var(--sp-5) var(--sp-6)", boxShadow: "inset 0 -0.5px 0 var(--separator)" }}>
        <span style={{ font: "var(--type-title-3)", color: "var(--label-tertiary)" }}>⌘</span>
        <input
          autoFocus
          value={query}
          placeholder="Search sessions, files, commands…"
          onChange={(e) => onQuery && onQuery(e.target.value)}
          style={{ all: "unset", flex: 1, font: "var(--fw-regular) var(--fs-title-2)/1.3 var(--font-system)", color: "var(--label)" }}
        />
        {flat.length ? <span style={{ font: "var(--type-footnote)", color: "var(--label-tertiary)" }}>{flat.length} results</span> : null}
      </div>
      <div style={{ maxHeight: 320, overflow: "auto", padding: "var(--sp-3)" }}>
        {groups.map((g, gi) => (
          <div key={g.label || gi} style={{ display: "grid", gap: "1px", marginBottom: "var(--sp-4)" }}>
            {g.label ? (
              <span style={{ padding: "4px 10px", font: "var(--type-caps)", letterSpacing: "var(--ls-caps)", textTransform: "uppercase", color: "var(--label-tertiary)" }}>{g.label}</span>
            ) : null}
            {(g.items || []).map((it) => {
              const on = it.id === selected;
              return (
                <button
                  key={it.id}
                  onClick={() => onSelect && onSelect(it.id)}
                  style={{
                    all: "unset", cursor: "default",
                    display: "flex", alignItems: "center", gap: "var(--sp-5)",
                    height: 32, padding: "0 10px", borderRadius: "var(--r-3)",
                    background: on ? "var(--selection)" : "transparent",
                    color: on ? "var(--selection-text)" : "var(--label)",
                    transition: "background-color var(--dur-1) linear"
                  }}
                >
                  <span style={{ flex: 1, minWidth: 0, font: "var(--type-body)", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{it.label}</span>
                  {it.detail ? (
                    <span style={{ font: "var(--type-subheadline)", color: on ? "color-mix(in srgb, var(--selection-text) 76%, transparent)" : "var(--label-tertiary)", whiteSpace: "nowrap" }}>{it.detail}</span>
                  ) : null}
                  {it.shortcut ? (
                    <span style={{ font: "var(--type-footnote)", color: on ? "var(--selection-text)" : "var(--label-tertiary)" }}>{it.shortcut}</span>
                  ) : null}
                </button>
              );
            })}
          </div>
        ))}
      </div>
      {footer ? (
        <div style={{ display: "flex", alignItems: "center", gap: "var(--sp-5)", padding: "var(--sp-4) var(--sp-6)", boxShadow: "inset 0 0.5px 0 var(--separator)", font: "var(--type-footnote)", color: "var(--label-tertiary)" }}>{footer}</div>
      ) : null}
    </div>
  );
}
