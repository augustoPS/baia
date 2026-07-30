import React from "react";

export function Sheet({ open = true, title, message, icon, actions, width = "var(--w-sheet)", onDismiss, children, style, ...rest }) {
  if (!open) return null;
  return (
    <div
      style={{
        position: "absolute", inset: 0, zIndex: 60,
        display: "grid", justifyItems: "center", alignItems: "start",
        paddingTop: "6%",
        background: "var(--shade)",
        backdropFilter: "blur(2px)", WebkitBackdropFilter: "blur(2px)"
      }}
      onClick={onDismiss}
    >
      <div
        role="dialog"
        aria-modal="true"
        onClick={(e) => e.stopPropagation()}
        style={{
          width, maxWidth: "92%",
          padding: "var(--sp-8)",
          borderRadius: "var(--r-sheet)",
          background: "var(--mat-fill-thick)",
          backgroundImage: "var(--lens-sheen), var(--lens-refract)",
          backdropFilter: "var(--mat-thick)", WebkitBackdropFilter: "var(--mat-thick)",
          boxShadow: "var(--lens-rim-strong), var(--shadow-sheet)",
          color: "var(--label)",
          display: "grid", gap: "var(--sp-6)",
          transformOrigin: "top center",
          animation: "vg-rise var(--dur-4) var(--ease-out) both",
          ...style
        }}
        {...rest}
      >
        {(title || message || icon) ? (
          <div style={{ display: "flex", gap: "var(--sp-6)", alignItems: "flex-start" }}>
            {icon ? <span style={{ flex: "none" }}>{icon}</span> : null}
            <div style={{ display: "grid", gap: "4px" }}>
              {title ? <h2 style={{ margin: 0, font: "var(--type-title-2)" }}>{title}</h2> : null}
              {message ? <p style={{ margin: 0, font: "var(--type-body)", color: "var(--label-secondary)", textWrap: "pretty" }}>{message}</p> : null}
            </div>
          </div>
        ) : null}
        {children}
        {actions ? <div style={{ display: "flex", justifyContent: "flex-end", gap: "var(--sp-4)" }}>{actions}</div> : null}
      </div>
    </div>
  );
}
