import React from "react";

export function Tabs({ tabs = [], value, onChange, onClose, onNew, style, ...rest }) {
  return (
    <div style={{ display: "flex", alignItems: "stretch", gap: "2px", padding: "4px var(--sp-4)", minWidth: 0, ...style }} {...rest}>
      <div style={{ display: "flex", gap: "2px", overflow: "auto", minWidth: 0, flex: 1 }}>
        {tabs.map((t) => {
          const on = t.id === value;
          return (
            <button
              key={t.id}
              onClick={() => onChange && onChange(t.id)}
              style={{
                all: "unset", cursor: "default",
                display: "inline-flex", alignItems: "center", gap: "6px",
                height: "var(--tab-h)", padding: "0 10px", borderRadius: "var(--r-3)",
                font: on ? "var(--type-headline)" : "var(--type-body)",
                color: on ? "var(--label)" : "var(--label-secondary)",
                background: on ? "var(--mat-fill-regular)" : "transparent",
                backgroundImage: on ? "var(--lens-sheen)" : undefined,
                boxShadow: on ? "var(--lens-rim), var(--shadow-control)" : "none",
                maxWidth: 220, minWidth: 0, whiteSpace: "nowrap",
                transition: "var(--t-control)"
              }}
            >
              {t.dirty ? <span style={{ width: 5, height: 5, borderRadius: "var(--r-capsule)", background: "var(--accent)", flex: "none" }} /> : null}
              <span style={{ overflow: "hidden", textOverflow: "ellipsis" }}>{t.label}</span>
              {onClose ? (
                <span
                  onClick={(e) => { e.stopPropagation(); onClose(t.id); }}
                  style={{ flex: "none", width: 13, height: 13, borderRadius: "var(--r-1)", display: "grid", placeItems: "center", color: "var(--label-tertiary)", font: "var(--fw-medium) 10px/1 var(--font-system)" }}
                >×</span>
              ) : null}
            </button>
          );
        })}
      </div>
      {onNew ? (
        <button
          onClick={onNew}
          aria-label="New tab"
          style={{
            all: "unset", cursor: "default", flex: "none",
            width: "var(--tab-h)", height: "var(--tab-h)", borderRadius: "var(--r-3)",
            display: "grid", placeItems: "center",
            color: "var(--label-secondary)", font: "var(--fw-regular) 15px/1 var(--font-system)",
            background: "transparent", transition: "var(--t-control)"
          }}
        >+</button>
      ) : null}
    </div>
  );
}
