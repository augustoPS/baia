import React from "react";

export function Checkbox({ checked, indeterminate, onChange, label, description, disabled, style, ...rest }) {
  const on = !!checked || indeterminate;
  return (
    <label
      style={{
        display: "inline-flex", alignItems: "flex-start", gap: "7px",
        cursor: disabled ? "default" : "pointer", opacity: disabled ? 0.4 : 1, ...style
      }}
      {...rest}
    >
      <input type="checkbox" checked={!!checked} onChange={onChange} disabled={disabled} style={{ position: "absolute", opacity: 0, width: 0, height: 0 }} />
      <span
        style={{
          width: 14, height: 14, flex: "none", marginTop: 1.5,
          borderRadius: "var(--r-1)",
          display: "inline-flex", alignItems: "center", justifyContent: "center",
          background: on ? "var(--accent)" : "var(--fill)",
          backdropFilter: "var(--mat-ultra-thin)",
          WebkitBackdropFilter: "var(--mat-ultra-thin)",
          boxShadow: on ? "var(--lens-rim), var(--shadow-control)" : "inset 0 0.5px 0 var(--rim-top), inset 0 0 0 0.5px var(--separator)",
          transition: "var(--t-control)"
        }}
      >
        {indeterminate ? (
          <span style={{ width: 8, height: 1.5, background: "var(--label-on-accent)", borderRadius: 1 }} />
        ) : checked ? (
          <svg width="10" height="10" viewBox="0 0 10 10" aria-hidden>
            <path d="M1.8 5.2l2 2 4.4-4.6" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" style={{ color: "var(--label-on-accent)" }} />
          </svg>
        ) : null}
      </span>
      {(label || description) ? (
        <span style={{ display: "grid", gap: "1px" }}>
          {label ? <span style={{ font: "var(--type-body)", color: "var(--label)" }}>{label}</span> : null}
          {description ? <span style={{ font: "var(--type-subheadline)", color: "var(--label-secondary)" }}>{description}</span> : null}
        </span>
      ) : null}
    </label>
  );
}
