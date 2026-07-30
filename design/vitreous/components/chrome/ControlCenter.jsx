import React from "react";

export function ControlCenter({ tiles = [], width = 300, style, ...rest }) {
  return (
    <div
      style={{
        width, padding: "var(--sp-5)",
        display: "grid", gridTemplateColumns: "repeat(4, 1fr)", gap: "var(--sp-4)",
        borderRadius: "var(--r-7)",
        background: "var(--mat-fill-thin)",
        backgroundImage: "var(--lens-sheen), var(--lens-refract)",
        backdropFilter: "var(--mat-thick)", WebkitBackdropFilter: "var(--mat-thick)",
        boxShadow: "var(--lens-rim-strong), var(--shadow-popover)",
        color: "var(--label)",
        ...style
      }}
      {...rest}
    >
      {tiles.map((t, i) => (
        <Tile key={t.id || i} tile={t} />
      ))}
    </div>
  );
}

function Tile({ tile }) {
  const [hover, setHover] = React.useState(false);
  const span = tile.span || 2;
  const on = tile.on;
  const isSlider = tile.value != null;
  return (
    <div
      onClick={tile.onToggle}
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
      style={{
        gridColumn: "span " + span,
        display: "grid", gap: "6px", alignContent: isSlider ? "space-between" : "center",
        minHeight: isSlider ? 76 : 56, padding: "var(--sp-4)",
        borderRadius: "var(--r-5)",
        cursor: "default",
        background: on ? "var(--accent)" : hover ? "var(--fill)" : "var(--fill-secondary)",
        backgroundImage: on ? "var(--lens-sheen-soft)" : undefined,
        boxShadow: on ? "var(--lens-rim), var(--shadow-accent)" : "var(--lens-rim)",
        transition: "var(--t-control)"
      }}
    >
      <span style={{ display: "grid", gap: "1px" }}>
        <span style={{ font: "var(--type-headline)", color: on ? "var(--label-on-accent)" : "var(--label)" }}>{tile.label}</span>
        {tile.detail ? (
          <span style={{ font: "var(--type-footnote)", color: on ? "color-mix(in srgb, var(--label-on-accent) 78%, transparent)" : "var(--label-secondary)" }}>{tile.detail}</span>
        ) : null}
      </span>
      {isSlider ? (
        <span style={{ position: "relative", height: 6, borderRadius: "var(--r-capsule)", background: "var(--fill)", boxShadow: "inset 0 0.5px 1px rgba(0,0,0,0.3)" }}>
          <span style={{ position: "absolute", inset: "0 auto 0 0", width: tile.value + "%", borderRadius: "var(--r-capsule)", background: "var(--white)" }} />
        </span>
      ) : null}
    </div>
  );
}
