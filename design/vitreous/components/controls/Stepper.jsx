import React from "react";

function Arrow({ dir, onClick }) {
  const [hover, setHover] = React.useState(false);
  return (
    <button
      onClick={onClick}
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
      style={{
        all: "unset", cursor: "pointer", display: "flex", alignItems: "center", justifyContent: "center",
        height: 10, width: 15,
        background: hover ? "var(--fill)" : "transparent",
        transition: "var(--t-control)"
      }}
    >
      <svg width="7" height="4" viewBox="0 0 7 4" aria-hidden style={{ transform: dir === "down" ? "rotate(180deg)" : "none" }}>
        <path d="M0.6 3.4L3.5 0.6l2.9 2.8" fill="none" stroke="currentColor" strokeWidth="1.1" strokeLinecap="round" style={{ color: "var(--label-secondary)" }} />
      </svg>
    </button>
  );
}

export function Stepper({ value = 0, min = -Infinity, max = Infinity, step = 1, onChange, unit, width = 68, style, ...rest }) {
  const set = (v) => onChange && onChange(Math.min(max, Math.max(min, v)));
  return (
    <span style={{ display: "inline-flex", alignItems: "stretch", gap: "3px", ...style }} {...rest}>
      <span
        style={{
          display: "inline-flex", alignItems: "center", gap: "3px",
          height: "var(--h-field)", width, padding: "0 7px",
          borderRadius: "var(--r-2)",
          background: "var(--fill-tertiary)",
          backdropFilter: "var(--mat-ultra-thin)",
          WebkitBackdropFilter: "var(--mat-ultra-thin)",
          boxShadow: "inset 0 0.5px 1.5px rgba(0,0,0,0.26), inset 0 0 0 0.5px var(--separator)"
        }}
      >
        <input
          value={value}
          onChange={(e) => set(Number(e.target.value) || 0)}
          style={{ all: "unset", flex: 1, minWidth: 0, textAlign: "right", font: "var(--type-mono)", color: "var(--label)" }}
        />
        {unit ? <span style={{ font: "var(--type-footnote)", color: "var(--label-tertiary)" }}>{unit}</span> : null}
      </span>
      <span
        style={{
          display: "inline-grid", borderRadius: "var(--r-1)", overflow: "hidden",
          background: "var(--fill)",
          backdropFilter: "var(--mat-ultra-thin)",
          WebkitBackdropFilter: "var(--mat-ultra-thin)",
          boxShadow: "var(--lens-rim), var(--shadow-control)"
        }}
      >
        <Arrow dir="up" onClick={() => set(value + step)} />
        <span style={{ height: 0.5, background: "var(--separator)" }} />
        <Arrow dir="down" onClick={() => set(value - step)} />
      </span>
    </span>
  );
}
