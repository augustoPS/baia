import React from "react";

export function ProgressBar({ value, indeterminate, label, valueLabel, tone = "accent", size = "regular", style, ...rest }) {
  const h = size === "small" ? 3 : 5;
  const color = tone === "accent" ? "var(--accent)" : tone === "positive" ? "var(--status-positive)" : tone === "caution" ? "var(--status-caution)" : "var(--status-negative)";
  const pct = Math.max(0, Math.min(100, value || 0));
  return (
    <div style={{ display: "grid", gap: "5px", ...style }} {...rest}>
      {(label || valueLabel) ? (
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", gap: "var(--sp-5)" }}>
          {label ? <span style={{ font: "var(--type-subheadline)", color: "var(--label-secondary)" }}>{label}</span> : null}
          {valueLabel ? <span style={{ font: "var(--type-mono)", fontSize: "var(--fs-mono-sm)", color: "var(--label-tertiary)" }}>{valueLabel}</span> : null}
        </div>
      ) : null}
      <div
        style={{
          position: "relative", height: h, borderRadius: "var(--r-capsule)", overflow: "hidden",
          background: "var(--fill)",
          boxShadow: "inset 0 0.5px 1px rgba(0,0,0,0.28), inset 0 0 0 0.5px var(--separator)"
        }}
      >
        {indeterminate ? (
          <span style={{
            position: "absolute", top: 0, bottom: 0, width: "38%", borderRadius: "var(--r-capsule)",
            background: "linear-gradient(90deg, transparent, " + color + ", transparent)",
            animation: "vg-sheen 1.4s var(--ease-standard) infinite"
          }} />
        ) : (
          <span style={{
            position: "absolute", top: 0, bottom: 0, left: 0, width: pct + "%",
            borderRadius: "var(--r-capsule)", background: color,
            boxShadow: "0 0 8px color-mix(in srgb, " + color + " 44%, transparent)",
            transition: "width var(--dur-3) var(--ease-out)"
          }} />
        )}
      </div>
    </div>
  );
}
