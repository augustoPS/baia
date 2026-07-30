import React from "react";

function TrafficLights({ inactive }) {
  const [hover, setHover] = React.useState(false);
  const dots = [
    { c: "#ff5f57", g: "×" },
    { c: "#febc2e", g: "–" },
    { c: "#28c840", g: "+" }
  ];
  return (
    <span
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
      style={{ display: "inline-flex", gap: "8px", alignItems: "center", flex: "none" }}
    >
      {dots.map((d) => (
        <span
          key={d.c}
          style={{
            width: 12, height: 12, borderRadius: "var(--r-capsule)",
            background: inactive ? "var(--label-quaternary)" : d.c,
            boxShadow: "inset 0 0.5px 0 rgba(255,255,255,0.34), 0 0.5px 1px rgba(0,0,0,0.24)",
            display: "grid", placeItems: "center",
            font: "var(--fw-bold) 8px/1 var(--font-system)",
            color: hover && !inactive ? "rgba(0,0,0,0.46)" : "transparent",
            transition: "color var(--dur-1) linear"
          }}
        >{d.g}</span>
      ))}
    </span>
  );
}

export function WindowFrame({
  title, subtitle, toolbar, sidebar, sidebarWidth = "var(--w-sidebar)", inspector,
  statusBar, tabs, inactive, radius = "var(--r-window)", children, style, ...rest
}) {
  return (
    <div
      style={{
        position: "relative",
        display: "grid",
        gridTemplateRows: "auto" + (tabs ? " auto" : "") + " minmax(0,1fr)" + (statusBar ? " auto" : ""),
        borderRadius: radius,
        overflow: "hidden",
        background: "var(--mat-fill-regular)",
        backdropFilter: "var(--mat-regular)", WebkitBackdropFilter: "var(--mat-regular)",
        boxShadow: "var(--shadow-window)",
        color: "var(--label)",
        minHeight: 0,
        ...style
      }}
      {...rest}
    >
      <header
        style={{
          display: "grid",
          gridTemplateColumns: sidebar ? sidebarWidth + " minmax(0,1fr)" : "minmax(0,1fr)",
          minHeight: toolbar ? "var(--toolbar-h)" : "var(--titlebar-h)",
          background: "var(--mat-fill-chrome)",
          backgroundImage: "var(--lens-sheen-soft)",
          backdropFilter: "var(--mat-chrome)", WebkitBackdropFilter: "var(--mat-chrome)",
          boxShadow: "inset 0 0.5px 0 var(--rim-top), inset 0 -0.5px 0 var(--separator)"
        }}
      >
        <div style={{ display: "flex", alignItems: "center", gap: "var(--sp-6)", padding: "0 var(--sp-6)", minWidth: 0 }}>
          <TrafficLights inactive={inactive} />
          {sidebar ? null : (
            <span style={{ display: "grid", gap: "1px", minWidth: 0 }}>
              {title ? <span style={{ font: "var(--type-headline)", color: inactive ? "var(--label-tertiary)" : "var(--label)", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{title}</span> : null}
              {subtitle ? <span style={{ font: "var(--type-footnote)", color: "var(--label-tertiary)" }}>{subtitle}</span> : null}
            </span>
          )}
        </div>
        {sidebar ? (
          <div style={{ display: "flex", alignItems: "center", gap: "var(--sp-5)", padding: "0 var(--sp-6)", minWidth: 0, boxShadow: "inset 0.5px 0 0 var(--separator)" }}>
            {title ? (
              <span style={{ display: "grid", gap: "1px", minWidth: 0, marginRight: "auto" }}>
                <span style={{ font: "var(--type-headline)", color: inactive ? "var(--label-tertiary)" : "var(--label)", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{title}</span>
                {subtitle ? <span style={{ font: "var(--type-footnote)", color: "var(--label-tertiary)" }}>{subtitle}</span> : null}
              </span>
            ) : null}
            {toolbar}
          </div>
        ) : toolbar ? (
          <div style={{ display: "flex", alignItems: "center", gap: "var(--sp-5)", padding: "0 var(--sp-6)", minWidth: 0 }}>{toolbar}</div>
        ) : null}
      </header>

      {tabs ? (
        <div style={{ boxShadow: "inset 0 -0.5px 0 var(--separator)", background: "var(--fill-quaternary)" }}>{tabs}</div>
      ) : null}

      <div style={{ display: "grid", gridTemplateColumns: (sidebar ? sidebarWidth + " " : "") + "minmax(0,1fr)" + (inspector ? " auto" : ""), minHeight: 0 }}>
        {sidebar ? (
          <div style={{ minWidth: 0, minHeight: 0, display: "grid", boxShadow: "inset -0.5px 0 0 var(--separator)" }}>{sidebar}</div>
        ) : null}
        <div style={{ minWidth: 0, minHeight: 0, display: "grid" }}>{children}</div>
        {inspector ? <div style={{ minHeight: 0, display: "grid" }}>{inspector}</div> : null}
      </div>

      {statusBar ? (
        <footer
          style={{
            display: "flex", alignItems: "center", gap: "var(--sp-5)",
            height: "var(--statusbar-h)", padding: "0 var(--sp-6)",
            font: "var(--type-footnote)", color: "var(--label-secondary)",
            background: "var(--mat-fill-chrome)",
            backdropFilter: "var(--mat-chrome)", WebkitBackdropFilter: "var(--mat-chrome)",
            boxShadow: "inset 0 0.5px 0 var(--separator)"
          }}
        >{statusBar}</footer>
      ) : null}
    </div>
  );
}
