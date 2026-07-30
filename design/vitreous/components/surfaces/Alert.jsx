import React from "react";

export function Alert({ open = true, severity = "info", title, message, actions, onDismiss, width = 380, style, ...rest }) {
  if (!open) return null;
  const glyph = { info: "i", warning: "!", error: "×", success: "✓" }[severity] || "i";
  const tone = { info: "var(--accent)", warning: "var(--status-caution)", error: "var(--status-negative)", success: "var(--status-positive)" }[severity];
  return (
    <div
      style={{
        position: "absolute", inset: 0, zIndex: 70, display: "grid", placeItems: "center",
        background: "var(--shade)", backdropFilter: "blur(2px)", WebkitBackdropFilter: "blur(2px)"
      }}
      onClick={onDismiss}
    >
      <div
        role="alertdialog"
        onClick={(e) => e.stopPropagation()}
        style={{
          width, maxWidth: "90%", padding: "var(--sp-8) var(--sp-8) var(--sp-6)",
          borderRadius: "var(--r-6)",
          background: "var(--mat-fill-thick)",
          backgroundImage: "var(--lens-sheen)",
          backdropFilter: "var(--mat-thick)", WebkitBackdropFilter: "var(--mat-thick)",
          boxShadow: "var(--lens-rim-strong), var(--shadow-sheet)",
          color: "var(--label)", display: "grid", gap: "var(--sp-5)", justifyItems: "center", textAlign: "center",
          animation: "vg-appear var(--dur-3) var(--ease-out) both",
          ...style
        }}
        {...rest}
      >
        <span
          style={{
            width: 38, height: 38, borderRadius: "var(--r-capsule)",
            display: "grid", placeItems: "center",
            font: "var(--fw-bold) 20px/1 var(--font-system)",
            color: "var(--label-on-accent)", background: tone,
            boxShadow: "var(--lens-rim), 0 2px 10px color-mix(in srgb, " + tone + " 44%, transparent)"
          }}
        >{glyph}</span>
        {title ? <h2 style={{ margin: 0, font: "var(--type-title-3)" }}>{title}</h2> : null}
        {message ? <p style={{ margin: 0, font: "var(--type-callout)", color: "var(--label-secondary)", textWrap: "pretty" }}>{message}</p> : null}
        {actions ? <div style={{ display: "flex", gap: "var(--sp-4)", marginTop: "var(--sp-2)", width: "100%", justifyContent: "center" }}>{actions}</div> : null}
      </div>
    </div>
  );
}
