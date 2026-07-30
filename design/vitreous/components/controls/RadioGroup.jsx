import React from "react";

export function RadioGroup({ items = [], value, onChange, orientation = "vertical", name, disabled, style, ...rest }) {
  return (
    <div
      role="radiogroup"
      style={{
        display: orientation === "horizontal" ? "flex" : "grid",
        gap: orientation === "horizontal" ? "var(--sp-7)" : "var(--sp-3)",
        opacity: disabled ? 0.4 : 1,
        ...style
      }}
      {...rest}
    >
      {items.map((it) => {
        const id = typeof it === "string" ? it : it.id;
        const label = typeof it === "string" ? it : it.label;
        const description = typeof it === "string" ? null : it.description;
        const on = id === value;
        return (
          <label key={id} style={{ display: "inline-flex", alignItems: "flex-start", gap: "7px", cursor: disabled ? "default" : "pointer" }}>
            <input type="radio" name={name} checked={on} onChange={() => onChange && onChange(id)} disabled={disabled} style={{ position: "absolute", opacity: 0, width: 0, height: 0 }} />
            <span
              style={{
                width: 14, height: 14, flex: "none", marginTop: 1.5, borderRadius: "var(--r-capsule)",
                display: "inline-flex", alignItems: "center", justifyContent: "center",
                background: on ? "var(--accent)" : "var(--fill)",
                backdropFilter: "var(--mat-ultra-thin)",
                WebkitBackdropFilter: "var(--mat-ultra-thin)",
                boxShadow: on ? "var(--lens-rim), var(--shadow-control)" : "inset 0 0.5px 0 var(--rim-top), inset 0 0 0 0.5px var(--separator)",
                transition: "var(--t-control)"
              }}
            >
              {on ? <span style={{ width: 5, height: 5, borderRadius: "var(--r-capsule)", background: "var(--label-on-accent)" }} /> : null}
            </span>
            <span style={{ display: "grid", gap: "1px" }}>
              <span style={{ font: "var(--type-body)", color: "var(--label)" }}>{label}</span>
              {description ? <span style={{ font: "var(--type-subheadline)", color: "var(--label-secondary)" }}>{description}</span> : null}
            </span>
          </label>
        );
      })}
    </div>
  );
}
