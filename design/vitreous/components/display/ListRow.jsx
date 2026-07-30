import React from "react";

export function ListRow({ title, subtitle, trailing, leading, selected, disclosure, depth = 0, size = "regular", onClick, style, ...rest }) {
  const [hover, setHover] = React.useState(false);
  const h = subtitle ? "var(--h-list-row-large)" : size === "compact" ? "var(--h-list-row)" : "var(--h-list-row-regular)";
  return (
    <div
      onClick={onClick}
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
      style={{
        display: "flex", alignItems: "center", gap: "8px",
        minHeight: h, padding: "0 8px 0 " + (8 + depth * 14) + "px",
        borderRadius: "var(--r-2)", cursor: onClick ? "default" : undefined,
        background: selected ? "var(--selection)" : hover ? "var(--fill-tertiary)" : "transparent",
        transition: "background-color var(--dur-1) var(--ease-standard)",
        ...style
      }}
      {...rest}
    >
      {disclosure != null ? (
        <span style={{ width: 9, flex: "none", color: selected ? "var(--selection-text)" : "var(--label-tertiary)", fontSize: 8, transform: disclosure ? "rotate(90deg)" : "none", transition: "transform var(--dur-2) var(--ease-standard)" }}>▶</span>
      ) : null}
      {leading ? <span style={{ flex: "none", display: "inline-flex" }}>{leading}</span> : null}
      <span style={{ flex: 1, minWidth: 0, display: "grid", gap: "1px" }}>
        <span style={{
          font: selected ? "var(--type-headline)" : "var(--type-body)",
          color: selected ? "var(--selection-text)" : "var(--label)",
          overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap"
        }}>{title}</span>
        {subtitle ? (
          <span style={{
            font: "var(--type-subheadline)",
            color: selected ? "color-mix(in srgb, var(--selection-text) 76%, transparent)" : "var(--label-secondary)",
            overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap"
          }}>{subtitle}</span>
        ) : null}
      </span>
      {trailing ? (
        <span style={{ flex: "none", display: "inline-flex", alignItems: "center", gap: "6px", color: selected ? "var(--selection-text)" : "var(--label-tertiary)", font: "var(--type-subheadline)" }}>{trailing}</span>
      ) : null}
    </div>
  );
}
