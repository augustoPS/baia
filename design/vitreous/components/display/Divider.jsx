import React from "react";

export function Divider({ orientation = "horizontal", inset = 0, label, style, ...rest }) {
  if (label) {
    return (
      <div style={{ display: "flex", alignItems: "center", gap: "8px", ...style }} {...rest}>
        <span style={{ flex: 1, height: "var(--hairline)", background: "var(--separator)" }} />
        <span style={{ font: "var(--type-caps)", letterSpacing: "var(--ls-caps)", textTransform: "uppercase", color: "var(--label-tertiary)" }}>{label}</span>
        <span style={{ flex: 1, height: "var(--hairline)", background: "var(--separator)" }} />
      </div>
    );
  }
  const vertical = orientation === "vertical";
  return (
    <span
      role="separator"
      style={{
        display: "block", flex: "none",
        width: vertical ? "var(--hairline)" : "auto",
        height: vertical ? "auto" : "var(--hairline)",
        alignSelf: vertical ? "stretch" : undefined,
        margin: vertical ? "0" : "0 " + inset + "px",
        background: "var(--separator)",
        ...style
      }}
      {...rest}
    />
  );
}
