import React from "react";

export function GroupedSection({ title, footnote, rows = [], children, style, ...rest }) {
  return (
    <section style={{ display: "grid", gap: "6px", ...style }} {...rest}>
      {title ? (
        <h4 style={{ margin: "0 0 0 2px", font: "var(--type-headline)", color: "var(--label)" }}>{title}</h4>
      ) : null}
      <div
        style={{
          borderRadius: "var(--r-4)", overflow: "hidden",
          background: "var(--mat-fill-ultra-thin)",
          backdropFilter: "var(--mat-thin)", WebkitBackdropFilter: "var(--mat-thin)",
          boxShadow: "var(--lens-rim), var(--shadow-control)"
        }}
      >
        {rows.map((r, i) => (
          <div
            key={r.id || i}
            style={{
              display: "flex", alignItems: "center", gap: "var(--sp-5)",
              minHeight: 34, padding: "6px var(--sp-6)",
              boxShadow: i < rows.length - 1 ? "inset 0 -0.5px 0 var(--separator)" : "none"
            }}
          >
            <div style={{ display: "grid", gap: "1px", minWidth: 0, flex: 1 }}>
              <span style={{ font: "var(--type-body)", color: "var(--label)" }}>{r.label}</span>
              {r.description ? <span style={{ font: "var(--type-subheadline)", color: "var(--label-secondary)" }}>{r.description}</span> : null}
            </div>
            {r.control ? <div style={{ flex: "none", display: "flex", alignItems: "center", gap: "var(--sp-4)" }}>{r.control}</div> : null}
          </div>
        ))}
        {children}
      </div>
      {footnote ? (
        <span style={{ font: "var(--type-subheadline)", color: "var(--label-tertiary)", margin: "0 2px" }}>{footnote}</span>
      ) : null}
    </section>
  );
}
