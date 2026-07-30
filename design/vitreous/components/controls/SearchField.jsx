import React from "react";

export function SearchField({ value, onChange, onClear, placeholder = "Search", width, size = "regular", scope, style, ...rest }) {
  const [focus, setFocus] = React.useState(false);
  const h = size === "large" ? "var(--h-field-large)" : "var(--h-field)";
  return (
    <span
      style={{
        display: "inline-flex", alignItems: "center", gap: "6px",
        height: h, width, padding: "0 7px",
        borderRadius: "var(--r-capsule)",
        background: "var(--fill-tertiary)",
        backdropFilter: "var(--mat-ultra-thin)",
        WebkitBackdropFilter: "var(--mat-ultra-thin)",
        boxShadow: focus
          ? "inset 0 0 0 1px var(--accent), 0 0 0 3px var(--focus-ring)"
          : "inset 0 0.5px 1.5px rgba(0,0,0,0.24), inset 0 0 0 0.5px var(--separator)",
        transition: "var(--t-control)",
        ...style
      }}
      {...rest}
    >
      <svg width="11" height="11" viewBox="0 0 12 12" aria-hidden style={{ flex: "none", color: "var(--label-tertiary)" }}>
        <circle cx="5" cy="5" r="3.6" fill="none" stroke="currentColor" strokeWidth="1.3" />
        <path d="M7.9 7.9l3 3" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" />
      </svg>
      {scope ? (
        <span style={{ font: "var(--type-footnote)", color: "var(--label-secondary)", padding: "1px 5px", borderRadius: "var(--r-capsule)", background: "var(--fill)", whiteSpace: "nowrap" }}>{scope}</span>
      ) : null}
      <input
        value={value}
        placeholder={placeholder}
        onChange={onChange}
        onFocus={() => setFocus(true)}
        onBlur={() => setFocus(false)}
        style={{ all: "unset", flex: 1, minWidth: 0, font: "var(--type-body)", color: "var(--label)" }}
      />
      {value ? (
        <button
          onClick={onClear}
          aria-label="Clear search"
          style={{
            all: "unset", cursor: "pointer", width: 13, height: 13, borderRadius: "var(--r-capsule)",
            display: "inline-flex", alignItems: "center", justifyContent: "center",
            background: "var(--label-quaternary)", color: "var(--label)", font: "var(--fw-bold) 9px/1 var(--font-system)"
          }}
        >×</button>
      ) : null}
    </span>
  );
}
