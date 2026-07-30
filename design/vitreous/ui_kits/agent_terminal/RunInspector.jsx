/* eslint-disable */
const { Inspector, Table, ProgressBar, Badge, StatusDot, PopUpButton, Switch, Divider, Slider } = window.VG;

function RunInspector({ tab, onTab, calls, model, onModel, autoApprove, onAutoApprove, temp, onTemp }) {
  const stateTone = { ok: "positive", warn: "caution", pending: "neutral" };
  return (
    <Inspector tabs={["Run", "Tools", "Cost"]} tab={tab} onTab={onTab} sections={
      tab === "Run" ? [
        { title: "Model", content: <PopUpButton value={model} onChange={onModel} options={["Opus 4.6", "Sonnet 4.6", "Haiku 4.5"]} width="100%" /> },
        { title: "Temperature", content: <Slider value={temp * 100} valueLabel={temp.toFixed(2)} min={0} max={200} onChange={(v) => onTemp(v / 100)} /> },
        { title: "Permissions", content: <Switch checked={autoApprove} onChange={() => onAutoApprove(!autoApprove)} label="Auto-approve safe tools" /> },
        { title: "Worktree", content: (
          <div style={{ display: "grid", gap: 5 }}>
            <span style={{ font: "var(--type-mono)", color: "var(--label-secondary)" }}>agent/flaky-e2e</span>
            <StatusDot tone="warn" label="1 uncommitted change" />
          </div>
        ) },
        { title: "Context", content: <ProgressBar value={62} label="Window" valueLabel="62%" /> }
      ] : tab === "Tools" ? [
        { title: "Calls", content: (
          <Table
            rowHeight="var(--h-list-row)"
            columns={[{ id: "tool", label: "Tool", width: "62px" }, { id: "target", label: "Target", mono: true }, { id: "ms", label: "ms", width: "54px", align: "right", mono: true }]}
            rows={calls} selected={4} onSelect={() => {}} />
        ) },
        { title: "Availability", content: (
          <div style={{ display: "flex", flexWrap: "wrap", gap: 5 }}>
            <Badge tone="positive">read</Badge><Badge tone="positive">edit</Badge>
            <Badge tone="caution">bash</Badge><Badge tone="negative">network</Badge>
          </div>
        ) }
      ] : [
        { title: "This session", content: (
          <div style={{ display: "grid", gap: 6 }}>
            <Row k="Input" v="128,402 tok" />
            <Row k="Output" v="18,914 tok" />
            <Divider />
            <Row k="Cost" v="$1.23" strong />
            <Row k="Budget" v="$10.00" />
          </div>
        ) },
        { title: "Budget", content: <ProgressBar value={12} tone="positive" label="Spent" valueLabel="12%" /> },
        { title: "Today", content: (
          <Table rowHeight="var(--h-list-row)"
            columns={[{ id: "s", label: "Session" }, { id: "c", label: "Cost", width: "58px", align: "right", mono: true }]}
            rows={[{ id: 1, s: "Refactor auth", c: "$0.41" }, { id: 2, s: "Flaky e2e", c: "$0.19" }, { id: 3, s: "Bump deps", c: "$0.88" }]} />
        ) }
      ]
    } />
  );
}

function Row({ k, v, strong }) {
  return (
    <div style={{ display: "flex", alignItems: "baseline", gap: 8 }}>
      <span style={{ font: "var(--type-body)", color: "var(--label-secondary)" }}>{k}</span>
      <span style={{ marginLeft: "auto", font: strong ? "var(--fw-semibold) var(--fs-mono)/1 var(--font-mono)" : "var(--type-mono)", color: "var(--label)" }}>{v}</span>
    </div>
  );
}

window.RunInspector = RunInspector;
