import React from "react";

export function Inspector({ tabs = [], tab, onTab, sections = [], width = "var(--w-inspector)", children, style, ...rest }) {
  return (
    <aside
      style={{
        width, display: "grid", gridTemplateRows: tabs.length ? "auto minmax(0,1fr)" : "minmax(0,1fr)",
        minHeight: 0,
        background: "var(--mat-fill-sidebar)",
        backdropFilter: "var(--mat-regular)", WebkitBackdropFilter: "var(--mat-regular)",
        boxShadow: "inset 0.5px 0 0 var(--separator)",
        ...style
      }}
      {...rest}
    >
      {tabs.length ? (
        <div style={{ display: "flex", padding: "6px var(--sp-4)", gap: "1px", boxShadow: "inset 0 -0.5px 0 var(--separator)" }}>
          {tabs.map((t) => {
            const id = typeof t === "string" ? t : t.id;
            const label = typeof t === "string" ? t : t.label;
            const on = id === tab;
            return (
              <button
                key={id}
                onClick={() => onTab && onTab(id)}
                style={{
                  all: "unset", flex: 1, textAlign: "center", cursor: "pointer",
                  height: 22, borderRadius: "var(--r-2)", lineHeight: "22px",
                  font: on ? "var(--type-headline)" : "var(--type-body)",
                  color: on ? "var(--label)" : "var(--label-secondary)",
                  background: on ? "var(--fill)" : "transparent",
                  boxShadow: on ? "var(--lens-rim)" : "none",
                  transition: "var(--t-control)"
                }}
              >{label}</button>
            );
          })}
        </div>
      ) : null}
      <div style={{ overflow: "auto", padding: "var(--sp-6)", display: "grid", gap: "var(--sp-7)", alignContent: "start" }}>
        {sections.map((s, i) => (
          <div key={s.title || i} style={{ display: "grid", gap: "var(--sp-4)" }}>
            {s.title ? (
              <span style={{ font: "var(--type-caps)", letterSpacing: "var(--ls-caps)", textTransform: "uppercase", color: "var(--label-tertiary)" }}>{s.title}</span>
            ) : null}
            {s.content}
          </div>
        ))}
        {children}
      </div>
    </aside>
  );
}
