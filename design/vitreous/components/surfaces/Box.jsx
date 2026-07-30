import React from "react";

export function Box({ title, subtitle, header, footer, actions, material = "ultraThin", pad = "var(--sp-6)", radius = "var(--r-5)", children, style, ...rest }) {
  const fills = {
    ultraThin: ["var(--mat-fill-ultra-thin)", "var(--mat-ultra-thin)"],
    thin: ["var(--mat-fill-thin)", "var(--mat-thin)"],
    regular: ["var(--mat-fill-regular)", "var(--mat-regular)"]
  };
  const [fill, filter] = fills[material] || fills.ultraThin;
  return (
    <section
      style={{
        display: "grid", gap: "var(--sp-5)", padding: pad, borderRadius: radius,
        background: fill, backgroundImage: "var(--lens-sheen-soft)",
        backdropFilter: filter, WebkitBackdropFilter: filter,
        boxShadow: "var(--lens-rim), var(--shadow-raised)",
        color: "var(--label)", minWidth: 0,
        ...style
      }}
      {...rest}
    >
      {(title || subtitle || actions || header) ? (
        <header style={{ display: "flex", alignItems: "flex-start", justifyContent: "space-between", gap: "var(--sp-5)" }}>
          <div style={{ display: "grid", gap: "2px", minWidth: 0 }}>
            {title ? <h3 style={{ margin: 0, font: "var(--type-title-3)", color: "var(--label)" }}>{title}</h3> : null}
            {subtitle ? <span style={{ font: "var(--type-subheadline)", color: "var(--label-secondary)" }}>{subtitle}</span> : null}
            {header}
          </div>
          {actions ? <div style={{ display: "flex", alignItems: "center", gap: "var(--sp-3)", flex: "none" }}>{actions}</div> : null}
        </header>
      ) : null}
      {children}
      {footer ? (
        <footer style={{ paddingTop: "var(--sp-5)", boxShadow: "inset 0 0.5px 0 var(--separator)", font: "var(--type-subheadline)", color: "var(--label-tertiary)" }}>{footer}</footer>
      ) : null}
    </section>
  );
}
