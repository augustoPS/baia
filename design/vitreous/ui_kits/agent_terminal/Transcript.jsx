/* eslint-disable */
const { Badge, StatusDot, Spinner, Button, Divider, Material } = window.VG;

function Bubble({ children, tone }) {
  return (
    <div style={{
      padding: "10px 12px", borderRadius: "var(--r-5)", maxWidth: "76ch",
      background: tone === "user" ? "var(--accent-quiet)" : "var(--mat-fill-ultra-thin)",
      backdropFilter: "var(--mat-ultra-thin)", WebkitBackdropFilter: "var(--mat-ultra-thin)",
      boxShadow: tone === "user"
        ? "inset 0 0 0 0.5px color-mix(in srgb, var(--accent) 42%, transparent)"
        : "var(--lens-rim)",
      font: "var(--type-body)", color: "var(--label)", textWrap: "pretty"
    }}>{children}</div>
  );
}

function ToolCall({ entry, pending, onApprove, onDeny }) {
  return (
    <div style={{
      display: "grid", gap: 6, padding: "8px 10px", borderRadius: "var(--r-4)",
      background: pending ? "color-mix(in srgb, var(--status-caution) 12%, transparent)" : "var(--term-bg)",
      backdropFilter: "var(--mat-thin)", WebkitBackdropFilter: "var(--mat-thin)",
      boxShadow: pending
        ? "inset 0 0 0 0.5px color-mix(in srgb, var(--status-caution) 48%, transparent)"
        : "inset 0 0 0 0.5px var(--separator)"
    }}>
      <div style={{ display: "flex", alignItems: "center", gap: 8, minWidth: 0 }}>
        <Badge tone={pending ? "caution" : "accent"} mono>{entry.tool}</Badge>
        <span style={{ flex: 1, minWidth: 0, font: "var(--type-mono)", color: "var(--term-fg)", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{entry.target}</span>
        {pending ? <span style={{ font: "var(--type-footnote)", color: "var(--status-caution)" }}>awaiting approval</span>
          : <span style={{ font: "var(--fw-medium) var(--fs-mono-sm)/1 var(--font-mono)", color: "var(--term-dim)" }}>{entry.ms}</span>}
      </div>
      {entry.out ? (
        <span style={{ font: "var(--fw-regular) var(--fs-mono-sm)/1.5 var(--font-mono)", color: "var(--term-dim)" }}>{entry.out}</span>
      ) : null}
      {pending ? (
        <div style={{ display: "flex", gap: 6, marginTop: 2 }}>
          <Button size="small" variant="accent" onClick={onApprove} keyEquivalent="⇧⌘A">Approve</Button>
          <Button size="small" onClick={onDeny}>Deny</Button>
        </div>
      ) : null}
    </div>
  );
}

function DiffBlock({ entry }) {
  return (
    <div style={{
      display: "flex", alignItems: "center", gap: 8, padding: "7px 10px", borderRadius: "var(--r-4)",
      background: "var(--term-bg)", backdropFilter: "var(--mat-thin)", WebkitBackdropFilter: "var(--mat-thin)",
      boxShadow: "inset 0 0 0 0.5px var(--separator)"
    }}>
      <span style={{ font: "var(--type-mono)", color: "var(--term-fg)", flex: 1, minWidth: 0, overflow: "hidden", textOverflow: "ellipsis" }}>{entry.file}</span>
      <span style={{ font: "var(--fw-medium) var(--fs-mono-sm)/1 var(--font-mono)", color: "var(--term-green)" }}>+{entry.added}</span>
      <span style={{ font: "var(--fw-medium) var(--fs-mono-sm)/1 var(--font-mono)", color: "var(--term-red)" }}>−{entry.removed}</span>
      <Button size="small" variant="borderless">Review</Button>
    </div>
  );
}

function Transcript({ entries, streaming, onApprove, onDeny }) {
  return (
    <div style={{ display: "grid", gap: 10, alignContent: "start", padding: "var(--sp-7) var(--sp-8)", overflow: "auto", minHeight: 0 }}>
      <Divider label="Today · 9:41" />
      {entries.map((e, i) => {
        if (e.kind === "user") return <div key={i} style={{ justifySelf: "end" }}><Bubble tone="user">{e.text}</Bubble></div>;
        if (e.kind === "assistant") return <Bubble key={i}>{e.text}</Bubble>;
        if (e.kind === "note") return (
          <span key={i} style={{ font: "var(--type-subheadline)", color: "var(--label-tertiary)", paddingLeft: 2 }}>{e.text}</span>
        );
        if (e.kind === "diff") return <DiffBlock key={i} entry={e} />;
        if (e.kind === "pending") return <ToolCall key={i} entry={e} pending onApprove={onApprove} onDeny={onDeny} />;
        return <ToolCall key={i} entry={e} />;
      })}
      {streaming ? (
        <div style={{ display: "flex", alignItems: "center", gap: 8, paddingLeft: 2 }}>
          <Spinner size={12} tone="accent" />
          <span style={{ font: "var(--type-subheadline)", color: "var(--label-secondary)" }}>thinking · 42 tok/s</span>
        </div>
      ) : null}
    </div>
  );
}

function Composer({ value, onChange, onSend, mode, onMode }) {
  const { SegmentedControl, KeyCap } = window.VG;
  return (
    <div style={{ padding: "var(--sp-5) var(--sp-8) var(--sp-7)", display: "grid", gap: 8 }}>
      <Material material="thin" radius="var(--r-6)" pad={0} elevation="raised"
        style={{ display: "grid", gap: 6, padding: "8px 10px" }}>
        <textarea
          value={value}
          onChange={(e) => onChange(e.target.value)}
          placeholder="Describe the next step for the agent…"
          rows={2}
          style={{ all: "unset", font: "var(--type-body)", color: "var(--label)", lineHeight: "var(--lh-body)", resize: "none" }}
        />
        <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
          <SegmentedControl size="small" value={mode} onChange={onMode} items={["Plan", "Act", "Ask"]} />
          <span style={{ marginLeft: "auto", display: "inline-flex", alignItems: "center", gap: 6, font: "var(--type-footnote)", color: "var(--label-tertiary)" }}>
            <KeyCap size="small">⌘</KeyCap><KeyCap size="small">⏎</KeyCap> send
          </span>
          <Button size="small" variant="accent" onClick={onSend}>Send</Button>
        </div>
      </Material>
    </div>
  );
}

window.Transcript = Transcript;
window.Composer = Composer;
