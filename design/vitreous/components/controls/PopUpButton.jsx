import React from "react";

export function PopUpButton({ options = [], value, onChange, size = "regular", width, pullDown, label, disabled, style, ...rest }) {
  const [hover, setHover] = React.useState(false);
  const h = size === "small" ? "var(--h-small)" : size === "large" ? "var(--h-large)" : "var(--h-regular)";
  const current = options.find((o) => (typeof o === "string" ? o : o.value) === value);
  const currentLabel = current ? (typeof current === "string" ? current : current.label) : (pullDown ? label : "");
  return (
    <span
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
      style={{
        position: "relative", display: "inline-flex", alignItems: "center",
        height: h, width, padding: "0 5px 0 9px", gap: "6px",
        borderRadius: "var(--r-3)",
        background: hover && !disabled ? "color-mix(in srgb, var(--fill) 140%, transparent)" : "var(--fill)",
        backgroundImage: "var(--lens-sheen-soft)",
        backdropFilter: "var(--mat-ultra-thin)",
        WebkitBackdropFilter: "var(--mat-ultra-thin)",
        boxShadow: "var(--lens-rim), var(--shadow-control)",
        opacity: disabled ? 0.36 : 1,
        transition: "var(--t-control)",
        ...style
      }}
      {...rest}
    >
      <span style={{ flex: 1, font: "var(--type-control)", color: "var(--label)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{currentLabel}</span>
      <span
        aria-hidden
        style={{
          display: "inline-flex", alignItems: "center", justifyContent: "center",
          width: 16, height: "calc(" + h + " - 4px)", borderRadius: "var(--r-1)",
          background: pullDown ? "transparent" : "var(--accent)",
          boxShadow: pullDown ? "none" : "var(--lens-rim)"
        }}
      >
        <svg width="7" height="10" viewBox="0 0 7 10" style={{ color: pullDown ? "var(--label-secondary)" : "var(--label-on-accent)" }}>
          {pullDown ? (
            <path d="M0.7 3.4L3.5 6.2l2.8-2.8" fill="none" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" />
          ) : (
            <g fill="none" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round">
              <path d="M0.9 4.1L3.5 1.5l2.6 2.6" />
              <path d="M0.9 5.9L3.5 8.5l2.6-2.6" />
            </g>
          )}
        </svg>
      </span>
      <select
        value={value}
        disabled={disabled}
        onChange={(e) => onChange && onChange(e.target.value)}
        style={{ position: "absolute", inset: 0, width: "100%", height: "100%", opacity: 0, cursor: "pointer" }}
      >
        {options.map((o) => {
          const v = typeof o === "string" ? o : o.value;
          const l = typeof o === "string" ? o : o.label;
          return <option key={v} value={v}>{l}</option>;
        })}
      </select>
    </span>
  );
}
