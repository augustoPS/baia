import React from "react";

export function Slider({ value = 50, min = 0, max = 100, step = 1, onChange, ticks = 0, label, valueLabel, style, ...rest }) {
  const pct = ((value - min) / (max - min)) * 100;
  return (
    <div style={{ display: "grid", gap: "6px", ...style }} {...rest}>
      {(label || valueLabel) ? (
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", gap: "var(--sp-5)" }}>
          {label ? <span style={{ font: "var(--type-body)", color: "var(--label)" }}>{label}</span> : null}
          {valueLabel ? <span style={{ font: "var(--type-mono)", color: "var(--label-secondary)" }}>{valueLabel}</span> : null}
        </div>
      ) : null}
      <div style={{ position: "relative", height: 20, display: "flex", alignItems: "center" }}>
        <div style={{
          position: "absolute", left: 0, right: 0, height: 4, borderRadius: "var(--r-capsule)",
          background: "var(--fill)",
          boxShadow: "inset 0 0.5px 1px rgba(0,0,0,0.30), inset 0 0 0 0.5px var(--separator)"
        }} />
        <div style={{
          position: "absolute", left: 0, width: pct + "%", height: 4, borderRadius: "var(--r-capsule)",
          background: "var(--accent)", boxShadow: "0 0 8px var(--accent-glow)"
        }} />
        {ticks > 0 ? (
          <div style={{ position: "absolute", left: 0, right: 0, top: 15, display: "flex", justifyContent: "space-between" }}>
            {Array.from({ length: ticks }).map((_, i) => (
              <span key={i} style={{ width: 1, height: 4, background: "var(--label-quaternary)" }} />
            ))}
          </div>
        ) : null}
        <input
          type="range" min={min} max={max} step={step} value={value}
          onChange={(e) => onChange && onChange(Number(e.target.value))}
          style={{ position: "absolute", inset: 0, width: "100%", opacity: 0, cursor: "pointer", margin: 0 }}
        />
        <span
          style={{
            position: "absolute", left: "calc(" + pct + "% - 8px)",
            width: 16, height: 16, borderRadius: "var(--r-capsule)",
            background: "var(--white)", backgroundImage: "var(--lens-sheen-soft)",
            boxShadow: "0 1px 4px rgba(0,0,0,0.34), 0 0 0 0.5px rgba(0,0,0,0.08)",
            pointerEvents: "none",
            transition: "var(--t-control)"
          }}
        />
      </div>
    </div>
  );
}
