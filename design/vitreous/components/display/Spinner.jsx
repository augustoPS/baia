import React from "react";

export function Spinner({ size = 14, tone = "secondary", style, ...rest }) {
  const color = tone === "accent" ? "var(--accent)" : "var(--label-tertiary)";
  return (
    <span
      role="progressbar"
      style={{
        display: "inline-block", width: size, height: size, flex: "none",
        borderRadius: "var(--r-capsule)",
        border: Math.max(1.5, size / 9) + "px solid var(--fill)",
        borderTopColor: color,
        animation: "vg-spin 0.7s linear infinite",
        ...style
      }}
      {...rest}
    />
  );
}
