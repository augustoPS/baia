import React from "react";

export function SegmentedControl({ items = [], value, onChange, size = "regular", fullWidth, style, ...rest }) {
  const h = size === "small" ? "var(--h-small)" : size === "large" ? "var(--h-large)" : "var(--h-regular)";
  return (
    <div
      role="tablist"
      style={{
        display: fullWidth ? "flex" : "inline-flex",
        width: fullWidth ? "100%" : undefined,
        alignItems: "center",
        gap: "1px",
        padding: "1.5px",
        height: "calc(" + h + " + 4px)",
        borderRadius: "var(--r-3)",
        background: "var(--fill-tertiary)",
        backdropFilter: "var(--mat-ultra-thin)",
        WebkitBackdropFilter: "var(--mat-ultra-thin)",
        boxShadow: "inset 0 0.5px 0 var(--rim-top), inset 0 0 0 0.5px var(--separator)",
        ...style
      }}
      {...rest}
    >
      {items.map((it) => {
        const id = typeof it === "string" ? it : it.id;
        const label = typeof it === "string" ? it : it.label;
        const active = id === value;
        return (
          <button
            key={id}
            role="tab"
            aria-selected={active}
            onClick={() => onChange && onChange(id)}
            style={{
              all: "unset",
              flex: fullWidth ? 1 : undefined,
              display: "inline-flex",
              alignItems: "center",
              justifyContent: "center",
              height: h,
              padding: "0 11px",
              borderRadius: "var(--r-2)",
              cursor: "pointer",
              font: active ? "var(--type-headline)" : "var(--type-control)",
              color: active ? "var(--label)" : "var(--label-secondary)",
              background: active ? "var(--mat-fill-regular)" : "transparent",
              backgroundImage: active ? "var(--lens-sheen)" : undefined,
              boxShadow: active ? "var(--lens-rim), var(--shadow-control)" : "none",
              whiteSpace: "nowrap",
              transition: "var(--t-control)"
            }}
          >
            {label}
          </button>
        );
      })}
    </div>
  );
}
