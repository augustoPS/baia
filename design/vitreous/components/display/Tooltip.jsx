import React from "react";

export function Tooltip({ content, shortcut, placement = "bottom", children, style, ...rest }) {
  const [open, setOpen] = React.useState(false);
  const pos = {
    bottom: { top: "calc(100% + 6px)", left: "50%", transform: "translateX(-50%)" },
    top: { bottom: "calc(100% + 6px)", left: "50%", transform: "translateX(-50%)" },
    left: { right: "calc(100% + 6px)", top: "50%", transform: "translateY(-50%)" },
    right: { left: "calc(100% + 6px)", top: "50%", transform: "translateY(-50%)" }
  }[placement];
  return (
    <span
      onMouseEnter={() => setOpen(true)}
      onMouseLeave={() => setOpen(false)}
      style={{ position: "relative", display: "inline-flex", ...style }}
      {...rest}
    >
      {children}
      {open ? (
        <span
          role="tooltip"
          style={{
            position: "absolute", zIndex: 90, ...pos,
            display: "inline-flex", alignItems: "center", gap: "6px",
            padding: "3px 7px", borderRadius: "var(--r-2)",
            font: "var(--type-subheadline)", color: "var(--label)",
            background: "var(--mat-fill-hud)",
            backdropFilter: "var(--mat-hud)", WebkitBackdropFilter: "var(--mat-hud)",
            boxShadow: "var(--lens-rim), var(--shadow-popover)",
            whiteSpace: "nowrap", pointerEvents: "none",
            animation: "vg-appear var(--dur-2) var(--ease-out) both"
          }}
        >
          {content}
          {shortcut ? <span style={{ color: "var(--label-tertiary)" }}>{shortcut}</span> : null}
        </span>
      ) : null}
    </span>
  );
}
