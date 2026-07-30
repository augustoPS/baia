import React from "react";

const TONES = {
  running: "var(--accent)", ok: "var(--status-positive)", warn: "var(--status-caution)",
  error: "var(--status-negative)", idle: "var(--label-quaternary)"
};

export function StatusDot({ tone = "idle", pulse, label, size = 7, style, ...rest }) {
  const c = TONES[tone] || TONES.idle;
  return (
    <span style={{ display: "inline-flex", alignItems: "center", gap: "6px", minWidth: 0, ...style }} {...rest}>
      <span
        style={{
          width: size, height: size, flex: "none", borderRadius: "var(--r-capsule)", background: c,
          boxShadow: tone === "idle" ? "none" : "0 0 6px color-mix(in srgb, " + c + " 60%, transparent)",
          animation: pulse ? "vg-pulse 1.5s var(--ease-standard) infinite" : undefined
        }}
      />
      {label ? (
        <span style={{ font: "var(--type-subheadline)", color: "var(--label-secondary)", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{label}</span>
      ) : null}
    </span>
  );
}
