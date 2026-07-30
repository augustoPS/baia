import React from "react";

export function Table({ columns = [], rows = [], selected, onSelect, sort, onSort, rowHeight = "var(--h-list-row-regular)", zebra, style, ...rest }) {
  return (
    <div
      style={{
        display: "grid", gridTemplateRows: "auto 1fr", minHeight: 0,
        borderRadius: "var(--r-4)", overflow: "hidden",
        background: "var(--fill-quaternary)",
        boxShadow: "inset 0 0 0 0.5px var(--separator)",
        ...style
      }}
      {...rest}
    >
      <div
        style={{
          display: "grid",
          gridTemplateColumns: columns.map((c) => c.width || "1fr").join(" "),
          height: "var(--h-list-row)", alignItems: "center",
          padding: "0 var(--inset-row)",
          background: "var(--mat-fill-chrome)",
          backdropFilter: "var(--mat-chrome)", WebkitBackdropFilter: "var(--mat-chrome)",
          boxShadow: "inset 0 -0.5px 0 var(--separator), inset 0 0.5px 0 var(--rim-top)"
        }}
      >
        {columns.map((c) => (
          <button
            key={c.id}
            onClick={() => onSort && onSort(c.id)}
            style={{
              all: "unset", cursor: onSort ? "pointer" : "default",
              display: "flex", alignItems: "center", gap: "4px",
              justifyContent: c.align === "right" ? "flex-end" : "flex-start",
              font: "var(--fw-semibold) var(--fs-footnote)/1 var(--font-system)",
              color: "var(--label-secondary)", padding: "0 4px", minWidth: 0
            }}
          >
            <span style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{c.label}</span>
            {sort && sort.id === c.id ? (
              <span style={{ color: "var(--label-tertiary)", fontSize: 8 }}>{sort.dir === "desc" ? "▼" : "▲"}</span>
            ) : null}
          </button>
        ))}
      </div>
      <div style={{ overflow: "auto", minHeight: 0 }}>
        {rows.map((r, i) => {
          const on = selected === (r.id != null ? r.id : i);
          return (
            <div
              key={r.id != null ? r.id : i}
              onClick={() => onSelect && onSelect(r.id != null ? r.id : i)}
              style={{
                display: "grid",
                gridTemplateColumns: columns.map((c) => c.width || "1fr").join(" "),
                height: rowHeight, alignItems: "center",
                padding: "0 var(--inset-row)", cursor: onSelect ? "default" : undefined,
                background: on ? "var(--selection)" : zebra && i % 2 ? "var(--fill-quaternary)" : "transparent",
                boxShadow: "inset 0 -0.5px 0 var(--separator)",
                transition: "background-color var(--dur-1) var(--ease-standard)"
              }}
            >
              {columns.map((c) => (
                <span
                  key={c.id}
                  style={{
                    padding: "0 4px", minWidth: 0,
                    textAlign: c.align === "right" ? "right" : "left",
                    font: c.mono ? "var(--type-mono)" : "var(--type-body)",
                    color: on ? "var(--selection-text)" : c.secondary ? "var(--label-secondary)" : "var(--label)",
                    overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap"
                  }}
                >
                  {r[c.id]}
                </span>
              ))}
            </div>
          );
        })}
      </div>
    </div>
  );
}
