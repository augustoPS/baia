import React from "react";

const TONES = {
  neutral: { fg: "var(--label-secondary)", bg: "var(--fill)", rim: "var(--separator)" },
  accent: { fg: "var(--accent)", bg: "var(--accent-quiet)", rim: "color-mix(in srgb, var(--accent) 44%, transparent)" },
  positive: { fg: "var(--status-positive)", bg: "color-mix(in srgb, var(--status-positive) 16%, transparent)", rim: "color-mix(in srgb, var(--status-positive) 40%, transparent)" },
  caution: { fg: "var(--status-caution)", bg: "color-mix(in srgb, var(--status-caution) 16%, transparent)", rim: "color-mix(in srgb, var(--status-caution) 40%, transparent)" },
  negative: { fg: "var(--status-negative)", bg: "color-mix(in srgb, var(--status-negative) 16%, transparent)", rim: "color-mix(in srgb, var(--status-negative) 40%, transparent)" }
};

export function Badge({ tone = "neutral", mono, filled, count, children, style, ...rest }) {
  const t = TONES[tone] || TONES.neutral;
  const solid = filled || count != null;
  return (
    <span
      style={{
        display: "inline-flex", alignItems: "center", justifyContent: "center", gap: "4px",
        height: 16, minWidth: count != null ? 16 : undefined, padding: "0 6px",
        borderRadius: "var(--r-capsule)",
        font: mono ? "var(--fw-medium) var(--fs-footnote)/1 var(--font-mono)" : "var(--fw-semibold) var(--fs-footnote)/1 var(--font-system)",
        letterSpacing: mono ? 0 : "0.01em",
        color: solid ? (tone === "neutral" ? "var(--label)" : "var(--label-on-accent)") : t.fg,
        background: solid ? (tone === "neutral" ? "var(--fill)" : "var(--" + (tone === "accent" ? "accent" : "status-" + tone) + ")") : t.bg,
        backdropFilter: "var(--mat-ultra-thin)",
        WebkitBackdropFilter: "var(--mat-ultra-thin)",
        boxShadow: solid ? "var(--lens-rim)" : "inset 0 0 0 0.5px " + t.rim,
        whiteSpace: "nowrap",
        ...style
      }}
      {...rest}
    >
      {count != null ? count : children}
    </span>
  );
}
