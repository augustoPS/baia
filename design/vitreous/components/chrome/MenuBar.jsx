import React from "react";

export function MenuBar({ appName = "App", menus = [], statusItems = [], clock, open, onOpen, style, ...rest }) {
  return (
    <div
      style={{
        display: "flex", alignItems: "center", gap: "var(--sp-3)",
        height: "var(--menubar-h)", padding: "0 var(--sp-5)",
        background: "var(--menubar-scrim)",
        backdropFilter: "var(--mat-ultra-thin)", WebkitBackdropFilter: "var(--mat-ultra-thin)",
        color: "var(--menubar-label)", font: "var(--type-body)",
        textShadow: "var(--menubar-label-shadow)",
        ...style
      }}
      {...rest}
    >
      <span style={{ font: "var(--type-headline)", padding: "0 6px" }}>{appName}</span>
      {menus.map((m) => {
        const id = typeof m === "string" ? m : m.id || m.label;
        const label = typeof m === "string" ? m : m.label;
        const on = open === id;
        return (
          <button
            key={id}
            onClick={() => onOpen && onOpen(on ? null : id)}
            style={{
              all: "unset", cursor: "default", padding: "1px 7px", borderRadius: "var(--r-2)",
              color: on ? "var(--selection-text)" : "inherit",
              background: on ? "var(--selection)" : "transparent",
              transition: "background-color var(--dur-1) linear"
            }}
          >{label}</button>
        );
      })}
      <span style={{ marginLeft: "auto", display: "flex", alignItems: "center", gap: "var(--sp-6)" }}>
        {statusItems.map((s, i) => (
          <span key={i} style={{ font: "var(--type-subheadline)", opacity: 0.9 }}>{s}</span>
        ))}
        {clock ? <span style={{ font: "var(--type-body)" }}>{clock}</span> : null}
      </span>
    </div>
  );
}
