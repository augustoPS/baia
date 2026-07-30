import React from "react";

const SIZES = {
  small: { h: "var(--h-small)", px: "9px", font: "var(--type-control-sm)", r: "var(--r-2)" },
  regular: { h: "var(--h-regular)", px: "12px", font: "var(--type-control)", r: "var(--r-3)" },
  large: { h: "var(--h-large)", px: "16px", font: "var(--type-control)", r: "var(--r-4)" },
  prominent: { h: "var(--h-prominent)", px: "20px", font: "var(--type-title-3)", r: "var(--r-5)" }
};

function skin(variant, hover, on) {
  if (variant === "accent") {
    return {
      color: "var(--label-on-accent)",
      background: on ? "var(--accent-press)" : hover ? "var(--accent-hover)" : "var(--accent)",
      backgroundImage: "var(--lens-sheen-soft)",
      boxShadow: "var(--lens-rim), var(--shadow-control), var(--shadow-accent)",
      border: "none"
    };
  }
  if (variant === "glass") {
    return {
      color: "var(--label)",
      background: on ? "var(--mat-fill-thin)" : hover ? "var(--mat-fill-regular)" : "var(--mat-fill-thin)",
      backgroundImage: "var(--lens-sheen)",
      backdropFilter: "var(--mat-thin)",
      WebkitBackdropFilter: "var(--mat-thin)",
      boxShadow: "var(--lens-rim-strong), var(--shadow-control)",
      border: "none"
    };
  }
  if (variant === "borderless") {
    return {
      color: hover ? "var(--label)" : "var(--label-secondary)",
      background: hover ? "var(--fill-secondary)" : "transparent",
      boxShadow: "none",
      border: "none"
    };
  }
  if (variant === "destructive") {
    return {
      color: "var(--system-red)",
      background: on ? "color-mix(in srgb, var(--system-red) 26%, transparent)" : hover ? "color-mix(in srgb, var(--system-red) 18%, transparent)" : "var(--fill)",
      backdropFilter: "var(--mat-ultra-thin)",
      WebkitBackdropFilter: "var(--mat-ultra-thin)",
      boxShadow: "var(--lens-rim), var(--shadow-control)",
      border: "none"
    };
  }
  return {
    color: "var(--label)",
    background: on ? "var(--fill-secondary)" : hover ? "color-mix(in srgb, var(--fill) 130%, transparent)" : "var(--fill)",
    backgroundImage: "var(--lens-sheen-soft)",
    backdropFilter: "var(--mat-ultra-thin)",
    WebkitBackdropFilter: "var(--mat-ultra-thin)",
    boxShadow: "var(--lens-rim), var(--shadow-control)",
    border: "none"
  };
}

export function Button({ variant = "push", size = "regular", shape = "rounded", disabled, fullWidth, keyEquivalent, children, style, ...rest }) {
  const [hover, setHover] = React.useState(false);
  const [down, setDown] = React.useState(false);
  const s = SIZES[size] || SIZES.regular;
  return (
    <button
      type="button"
      disabled={disabled}
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => { setHover(false); setDown(false); }}
      onMouseDown={() => setDown(true)}
      onMouseUp={() => setDown(false)}
      style={{
        display: fullWidth ? "flex" : "inline-flex",
        width: fullWidth ? "100%" : undefined,
        alignItems: "center",
        justifyContent: "center",
        gap: "6px",
        height: s.h,
        padding: "0 " + s.px,
        borderRadius: shape === "capsule" ? "var(--r-capsule)" : s.r,
        font: s.font,
        letterSpacing: "var(--ls-body)",
        whiteSpace: "nowrap",
        cursor: disabled ? "default" : "pointer",
        opacity: disabled ? 0.36 : 1,
        transform: down && !disabled ? "scale(var(--press-scale))" : "none",
        transition: "var(--t-control), var(--t-press)",
        WebkitTapHighlightColor: "transparent",
        ...skin(variant, hover && !disabled, down && !disabled),
        ...style
      }}
      {...rest}
    >
      {children}
      {keyEquivalent ? (
        <span style={{ font: "var(--type-footnote)", color: "currentColor", opacity: 0.5, marginLeft: "2px" }}>{keyEquivalent}</span>
      ) : null}
    </button>
  );
}
