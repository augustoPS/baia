import React from "react";

export function Dock({ items = [], style, ...rest }) {
  const [hoverIdx, setHoverIdx] = React.useState(-1);
  return (
    <div
      style={{
        display: "inline-flex", alignItems: "flex-end", gap: "var(--sp-4)",
        padding: "6px 8px",
        borderRadius: "var(--r-7)",
        background: "var(--mat-fill-thin)",
        backgroundImage: "var(--lens-sheen), var(--lens-refract)",
        backdropFilter: "var(--mat-thick)", WebkitBackdropFilter: "var(--mat-thick)",
        boxShadow: "var(--lens-rim-strong), var(--shadow-popover)",
        ...style
      }}
      {...rest}
    >
      {items.map((it, i) => {
        const hovered = hoverIdx === i;
        const near = Math.abs(hoverIdx - i) === 1 && hoverIdx > -1;
        const size = hovered ? 54 : near ? 46 : 40;
        return (
          <span
            key={it.id || i}
            onMouseEnter={() => setHoverIdx(i)}
            onMouseLeave={() => setHoverIdx(-1)}
            style={{ display: "grid", justifyItems: "center", gap: "3px", cursor: "default" }}
          >
            <span
              style={{
                width: size, height: size, borderRadius: "var(--r-5)",
                display: "grid", placeItems: "center",
                font: "var(--fw-semibold) " + Math.round(size / 2.6) + "px/1 var(--font-system)",
                color: "var(--label-on-accent)",
                background: it.tint || "linear-gradient(180deg, var(--grey-6), var(--grey-4))",
                backgroundImage: "var(--lens-sheen-soft)",
                boxShadow: "var(--lens-rim), var(--shadow-raised)",
                transition: "width var(--dur-2) var(--spring-snappy), height var(--dur-2) var(--spring-snappy)"
              }}
            >{it.initials || String(it.label || "").slice(0, 1)}</span>
            <span style={{ width: 4, height: 4, borderRadius: "var(--r-capsule)", background: it.running ? "var(--label-secondary)" : "transparent" }} />
          </span>
        );
      })}
    </div>
  );
}
