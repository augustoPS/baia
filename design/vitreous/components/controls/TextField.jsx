import React from "react";

export function TextField({ label, hint, invalid, mono, multiline, rows = 3, size = "regular", prefix, suffix, style, wrapStyle, ...rest }) {
  const [focus, setFocus] = React.useState(false);
  const h = size === "large" ? "var(--h-field-large)" : "var(--h-field)";
  const Tag = multiline ? "textarea" : "input";
  return (
    <label style={{ display: "grid", gap: "5px", ...wrapStyle }}>
      {label ? <span style={{ font: "var(--type-body)", color: "var(--label-secondary)" }}>{label}</span> : null}
      <span
        style={{
          display: "flex", alignItems: multiline ? "flex-start" : "center", gap: "6px",
          minHeight: multiline ? undefined : h,
          padding: multiline ? "6px 8px" : "0 8px",
          borderRadius: "var(--r-2)",
          background: "var(--fill-tertiary)",
          backdropFilter: "var(--mat-ultra-thin)",
          WebkitBackdropFilter: "var(--mat-ultra-thin)",
          boxShadow: invalid
            ? "inset 0 0 0 1px var(--system-red), inset 0 0.5px 1.5px rgba(0,0,0,0.24)"
            : focus
              ? "inset 0 0 0 1px var(--accent), 0 0 0 3px var(--focus-ring)"
              : "inset 0 0.5px 1.5px rgba(0,0,0,0.24), inset 0 0 0 0.5px var(--separator)",
          transition: "var(--t-control)"
        }}
      >
        {prefix ? <span style={{ font: "var(--type-body)", color: "var(--label-tertiary)" }}>{prefix}</span> : null}
        <Tag
          rows={multiline ? rows : undefined}
          onFocus={() => setFocus(true)}
          onBlur={() => setFocus(false)}
          style={{
            all: "unset", flex: 1, minWidth: 0, resize: multiline ? "vertical" : undefined,
            font: mono ? "var(--type-mono)" : "var(--type-body)",
            lineHeight: multiline ? "var(--lh-body)" : undefined,
            color: "var(--label)",
            ...style
          }}
          {...rest}
        />
        {suffix ? <span style={{ font: "var(--type-footnote)", color: "var(--label-tertiary)" }}>{suffix}</span> : null}
      </span>
      {hint ? <span style={{ font: "var(--type-subheadline)", color: invalid ? "var(--system-red)" : "var(--label-tertiary)" }}>{hint}</span> : null}
    </label>
  );
}
