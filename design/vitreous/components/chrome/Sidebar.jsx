import React from "react";

export function Sidebar({ groups = [], value, onSelect, header, footer, width, style, ...rest }) {
  return (
    <nav
      style={{
        display: "grid", gridTemplateRows: (header ? "auto " : "") + "minmax(0,1fr)" + (footer ? " auto" : ""),
        width, minHeight: 0,
        background: "var(--mat-fill-sidebar)",
        backdropFilter: "var(--mat-regular)", WebkitBackdropFilter: "var(--mat-regular)",
        ...style
      }}
      {...rest}
    >
      {header ? <div style={{ padding: "var(--sp-4) var(--sp-5)" }}>{header}</div> : null}
      <div style={{ overflow: "auto", padding: "var(--sp-3) var(--sp-4)", display: "grid", gap: "var(--sp-6)", alignContent: "start" }}>
        {groups.map((g, gi) => (
          <div key={g.label || gi} style={{ display: "grid", gap: "1px" }}>
            {g.label ? (
              <span style={{ padding: "0 8px 4px", font: "var(--type-caps)", letterSpacing: "var(--ls-caps)", textTransform: "uppercase", color: "var(--label-tertiary)" }}>{g.label}</span>
            ) : null}
            {(g.items || []).map((it) => {
              const on = it.id === value;
              return (
                <SidebarRow key={it.id} item={it} active={on} onSelect={onSelect} />
              );
            })}
          </div>
        ))}
      </div>
      {footer ? <div style={{ padding: "var(--sp-4) var(--sp-5)", boxShadow: "inset 0 0.5px 0 var(--separator)" }}>{footer}</div> : null}
    </nav>
  );
}

function SidebarRow({ item, active, onSelect }) {
  const [hover, setHover] = React.useState(false);
  return (
    <button
      onClick={() => onSelect && onSelect(item.id)}
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
      style={{
        all: "unset", cursor: "default",
        display: "flex", alignItems: "center", gap: "8px",
        height: "var(--h-sidebar-row)", padding: "0 8px 0 " + (8 + (item.depth || 0) * 13) + "px",
        borderRadius: "var(--r-3)",
        font: active ? "var(--type-headline)" : "var(--type-body)",
        color: active ? "var(--selection-text)" : "var(--label)",
        background: active ? "var(--selection)" : hover ? "var(--fill-tertiary)" : "transparent",
        boxShadow: active ? "var(--lens-rim)" : "none",
        transition: "background-color var(--dur-1) var(--ease-standard)"
      }}
    >
      {item.marker ? (
        <span style={{ width: 6, height: 6, borderRadius: "var(--r-capsule)", background: item.marker, flex: "none" }} />
      ) : null}
      <span style={{ flex: 1, minWidth: 0, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{item.label}</span>
      {item.trailing != null ? (
        <span style={{ flex: "none", font: "var(--type-footnote)", color: active ? "color-mix(in srgb, var(--selection-text) 78%, transparent)" : "var(--label-tertiary)" }}>{item.trailing}</span>
      ) : null}
    </button>
  );
}
