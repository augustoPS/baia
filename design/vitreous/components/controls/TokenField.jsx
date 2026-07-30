import React from "react";

export function TokenField({ tokens = [], onRemove, onAdd, placeholder = "Add filter…", label, style, wrapStyle, ...rest }) {
  const [draft, setDraft] = React.useState("");
  const [focus, setFocus] = React.useState(false);
  return (
    <label style={{ display: "grid", gap: "5px", ...wrapStyle }}>
      {label ? <span style={{ font: "var(--type-body)", color: "var(--label-secondary)" }}>{label}</span> : null}
      <span
        style={{
          display: "flex", alignItems: "center", flexWrap: "wrap", gap: "4px",
          minHeight: "var(--h-field-large)", padding: "3px 6px",
          borderRadius: "var(--r-2)",
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
        {tokens.map((t, i) => (
          <span
            key={typeof t === "string" ? t : t.id || i}
            style={{
              display: "inline-flex", alignItems: "center", gap: "4px",
              height: 18, padding: "0 5px 0 7px", borderRadius: "var(--r-capsule)",
              font: "var(--type-subheadline)", color: "var(--label)",
              background: "var(--accent-quiet)",
              boxShadow: "inset 0 0 0 0.5px color-mix(in srgb, var(--accent) 48%, transparent)"
            }}
          >
            {typeof t === "string" ? t : t.label}
            <button
              onClick={() => onRemove && onRemove(t, i)}
              aria-label="Remove"
              style={{ all: "unset", cursor: "pointer", color: "var(--label-secondary)", font: "var(--fw-bold) 9px/1 var(--font-system)" }}
            >×</button>
          </span>
        ))}
        <input
          value={draft}
          placeholder={tokens.length ? "" : placeholder}
          onChange={(e) => setDraft(e.target.value)}
          onFocus={() => setFocus(true)}
          onBlur={() => setFocus(false)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && draft.trim() && onAdd) { onAdd(draft.trim()); setDraft(""); }
            if (e.key === "Backspace" && !draft && tokens.length && onRemove) onRemove(tokens[tokens.length - 1], tokens.length - 1);
          }}
          style={{ all: "unset", flex: 1, minWidth: 60, font: "var(--type-body)", color: "var(--label)" }}
        />
      </span>
    </label>
  );
}
