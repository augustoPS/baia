import React from "react";

export function Switch({ checked, onChange, label, size = "regular", disabled, style, ...rest }) {
  const w = size === "small" ? 30 : 38;
  const h = size === "small" ? 18 : 22;
  const k = h - 4;
  return (
    <label style={{ display: "inline-flex", alignItems: "center", gap: "8px", cursor: disabled ? "default" : "pointer", opacity: disabled ? 0.4 : 1, ...style }} {...rest}>
      <input type="checkbox" checked={!!checked} onChange={onChange} disabled={disabled} style={{ position: "absolute", opacity: 0, width: 0, height: 0 }} />
      <span
        style={{
          position: "relative", width: w, height: h, flex: "none",
          borderRadius: "var(--r-capsule)",
          background: checked ? "var(--accent)" : "var(--fill)",
          backdropFilter: "var(--mat-ultra-thin)",
          WebkitBackdropFilter: "var(--mat-ultra-thin)",
          boxShadow: checked
            ? "var(--lens-rim), var(--shadow-accent)"
            : "inset 0 0.5px 0 var(--rim-top), inset 0 0 0 0.5px var(--separator)",
          transition: "var(--t-control)"
        }}
      >
        <span
          style={{
            position: "absolute", top: 2, left: checked ? w - k - 2 : 2,
            width: k, height: k, borderRadius: "var(--r-capsule)",
            background: "var(--white)",
            boxShadow: "0 1px 3px rgba(0,0,0,0.32), 0 0 0 0.5px rgba(0,0,0,0.06)",
            transition: "left var(--dur-2) var(--spring-snappy)"
          }}
        />
      </span>
      {label ? <span style={{ font: "var(--type-body)", color: "var(--label)" }}>{label}</span> : null}
    </label>
  );
}
