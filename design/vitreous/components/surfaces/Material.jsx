import React from "react";

const MATS = {
  ultraThin: { fill: "var(--mat-fill-ultra-thin)", filter: "var(--mat-ultra-thin)" },
  thin: { fill: "var(--mat-fill-thin)", filter: "var(--mat-thin)" },
  regular: { fill: "var(--mat-fill-regular)", filter: "var(--mat-regular)" },
  thick: { fill: "var(--mat-fill-thick)", filter: "var(--mat-thick)" },
  chrome: { fill: "var(--mat-fill-chrome)", filter: "var(--mat-chrome)" },
  sidebar: { fill: "var(--mat-fill-sidebar)", filter: "var(--mat-regular)" },
  menu: { fill: "var(--mat-fill-menu)", filter: "var(--mat-thick)" },
  hud: { fill: "var(--mat-fill-hud)", filter: "var(--mat-hud)" }
};

const SHADOWS = {
  none: "none", control: "var(--shadow-control)", raised: "var(--shadow-raised)",
  popover: "var(--shadow-popover)", sheet: "var(--shadow-sheet)", window: "var(--shadow-window)"
};

export function Material({
  material = "regular", radius = "var(--r-5)", pad = 0, elevation = "raised",
  sheen = true, refract = true, rim = "strong", sweep, as = "div", children, style, ...rest
}) {
  const m = MATS[material] || MATS.regular;
  const layers = [];
  if (sheen) layers.push("var(--lens-sheen)");
  if (refract) layers.push("var(--lens-refract)");
  const Tag = as;
  return (
    <Tag
      style={{
        position: "relative",
        borderRadius: radius,
        padding: pad,
        background: m.fill,
        backgroundImage: layers.length ? layers.join(", ") : undefined,
        backdropFilter: m.filter,
        WebkitBackdropFilter: m.filter,
        boxShadow: (rim === "strong" ? "var(--lens-rim-strong)" : rim === "none" ? "var(--lens-edge)" : "var(--lens-rim)") + ", " + (SHADOWS[elevation] || SHADOWS.raised),
        color: "var(--label)",
        overflow: sweep ? "hidden" : undefined,
        ...style
      }}
      {...rest}
    >
      {sweep ? (
        <span
          aria-hidden
          style={{
            position: "absolute", top: 0, bottom: 0, width: "40%",
            background: "linear-gradient(90deg, transparent, rgba(255,255,255,0.10), transparent)",
            animation: "vg-sheen var(--sheen-travel, 0s) var(--ease-standard) infinite",
            pointerEvents: "none", opacity: "var(--sheen-travel, 0s)" === "0s" ? 0 : 1
          }}
        />
      ) : null}
      {children}
    </Tag>
  );
}
