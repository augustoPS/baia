import React from "react";

export function SplitView({ panes = [], gap = 0, dividers = true, style, ...rest }) {
  return (
    <div
      style={{
        display: "grid",
        gridTemplateColumns: panes.map((p) => p.width || "minmax(0,1fr)").join(" "),
        gap, minHeight: 0, minWidth: 0, height: "100%",
        ...style
      }}
      {...rest}
    >
      {panes.map((p, i) => (
        <div
          key={p.id || i}
          style={{
            minWidth: 0, minHeight: 0, position: "relative", display: "grid",
            boxShadow: dividers && i < panes.length - 1 ? "inset -0.5px 0 0 var(--separator)" : undefined,
            overflow: p.scroll === false ? "hidden" : "auto"
          }}
        >
          {p.content}
        </div>
      ))}
    </div>
  );
}
