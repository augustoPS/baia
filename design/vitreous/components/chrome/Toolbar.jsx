import React from "react";

export function Toolbar({ leading, children, trailing, style, ...rest }) {
  return (
    <div
      style={{
        display: "flex", alignItems: "center", gap: "var(--sp-4)", flex: 1, minWidth: 0,
        height: "var(--toolbar-h)", ...style
      }}
      {...rest}
    >
      {leading}
      {children ? <div style={{ display: "flex", alignItems: "center", gap: "var(--sp-4)", minWidth: 0 }}>{children}</div> : null}
      {trailing ? <div style={{ display: "flex", alignItems: "center", gap: "var(--sp-4)", marginLeft: "auto", flex: "none" }}>{trailing}</div> : null}
    </div>
  );
}

export function ToolbarButton({ label, active, disabled, badge, onClick, style, ...rest }) {
  const [hover, setHover] = React.useState(false);
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
      style={{
        all: "unset", cursor: disabled ? "default" : "pointer",
        display: "inline-flex", alignItems: "center", gap: "5px",
        height: "var(--h-toolbar-item)", padding: "0 10px",
        borderRadius: "var(--r-3)",
        font: active ? "var(--type-headline)" : "var(--type-control)",
        color: disabled ? "var(--label-tertiary)" : active ? "var(--label)" : hover ? "var(--label)" : "var(--label-secondary)",
        background: active ? "var(--fill)" : hover && !disabled ? "var(--fill-secondary)" : "transparent",
        boxShadow: active ? "var(--lens-rim)" : "none",
        whiteSpace: "nowrap",
        transition: "var(--t-control)",
        ...style
      }}
      {...rest}
    >
      {label}
      {badge != null ? (
        <span style={{ font: "var(--fw-semibold) var(--fs-footnote)/1 var(--font-mono)", color: "var(--accent)" }}>{badge}</span>
      ) : null}
    </button>
  );
}

export function ToolbarSeparator() {
  return <span style={{ width: "var(--hairline)", alignSelf: "center", height: 16, background: "var(--separator)", flex: "none" }} />;
}
