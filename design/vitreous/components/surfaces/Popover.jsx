import React from "react";

export function Popover({ open = true, anchor = "bottom", arrow = true, width = "var(--w-popover)", pad = "var(--sp-6)", children, style, ...rest }) {
  if (!open) return null;
  const arrowPos = {
    bottom: { top: -5, left: "calc(50% - 5px)" },
    top: { bottom: -5, left: "calc(50% - 5px)" },
    left: { right: -5, top: "calc(50% - 5px)" },
    right: { left: -5, top: "calc(50% - 5px)" }
  }[anchor];
  return (
    <div
      role="dialog"
      style={{
        position: "relative", width, padding: pad,
        borderRadius: "var(--r-5)",
        background: "var(--mat-fill-menu)",
        backgroundImage: "var(--lens-sheen), var(--lens-refract)",
        backdropFilter: "var(--mat-thick)", WebkitBackdropFilter: "var(--mat-thick)",
        boxShadow: "var(--lens-rim-strong), var(--shadow-popover)",
        color: "var(--label)",
        animation: "vg-appear var(--dur-2) var(--ease-out) both",
        ...style
      }}
      {...rest}
    >
      {arrow ? (
        <span
          aria-hidden
          style={{
            position: "absolute", width: 10, height: 10, ...arrowPos,
            background: "var(--mat-fill-menu)",
            backdropFilter: "var(--mat-thick)", WebkitBackdropFilter: "var(--mat-thick)",
            transform: "rotate(45deg)",
            boxShadow: "inset 0 1px 0 var(--rim-top)"
          }}
        />
      ) : null}
      {children}
    </div>
  );
}
