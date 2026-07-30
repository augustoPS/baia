import React from "react";

export function KeyCap({ children, size = "regular", style, ...rest }) {
  const small = size === "small";
  return (
    <kbd
      style={{
        display: "inline-flex", alignItems: "center", justifyContent: "center",
        minWidth: small ? 15 : 18, height: small ? 15 : 18, padding: "0 4px",
        borderRadius: "var(--r-1)",
        font: "var(--fw-medium) " + (small ? "var(--fs-footnote)" : "var(--fs-subheadline)") + "/1 var(--font-system)",
        color: "var(--label-secondary)",
        background: "var(--fill)",
        backdropFilter: "var(--mat-ultra-thin)",
        WebkitBackdropFilter: "var(--mat-ultra-thin)",
        boxShadow: "var(--lens-rim), var(--shadow-control)",
        ...style
      }}
      {...rest}
    >
      {children}
    </kbd>
  );
}
