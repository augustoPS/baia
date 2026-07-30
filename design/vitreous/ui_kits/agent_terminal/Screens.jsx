/* eslint-disable */
const { Box, Table, Badge, StatusDot, Button, Divider, Material, ProgressBar, SegmentedControl, ListRow, Checkbox, Tooltip, KeyCap, GroupedSection, PopUpButton } = window.VG;

const QUEUE = [
  { id: "q1", tool: "bash", target: "git commit -am 'fix(e2e): await session-ready event'", risk: "low", session: "Fix flaky e2e", when: "9:41" },
  { id: "q2", tool: "bash", target: "gh pr create --fill --base main", risk: "medium", session: "Fix flaky e2e", when: "9:41" },
  { id: "q3", tool: "network", target: "npm publish --tag next", risk: "high", session: "Bump deps to 1.82", when: "9:38" },
  { id: "q4", tool: "edit", target: "crates/agent/src/plan.rs", risk: "low", session: "Refactor auth guard", when: "9:20" }
];

const RISK = { low: "positive", medium: "caution", high: "negative" };

function ApprovalsScreen() {
  const [queue, setQueue] = React.useState(QUEUE);
  const [picked, setPicked] = React.useState(["q1"]);
  const [filter, setFilter] = React.useState("All");
  const shown = queue.filter((q) => filter === "All" || RISK[q.risk] === (filter === "Safe" ? "positive" : filter === "Review" ? "caution" : "negative"));
  const toggle = (id) => setPicked((p) => p.includes(id) ? p.filter((x) => x !== id) : p.concat(id));
  const resolve = () => { setQueue((q) => q.filter((x) => !picked.includes(x.id))); setPicked([]); };

  return (
    <div style={{ overflow: "auto", padding: "var(--sp-8)", display: "grid", gap: "var(--sp-7)", alignContent: "start" }}>
      <div style={{ display: "flex", alignItems: "center", gap: "var(--sp-5)" }}>
        <span style={{ font: "var(--type-title-2)" }}>Approvals</span>
        <Badge tone={queue.length ? "caution" : "positive"}>{queue.length ? queue.length + " waiting" : "all clear"}</Badge>
        <SegmentedControl size="small" value={filter} onChange={setFilter} items={["All", "Safe", "Review", "Blocked"]} style={{ marginLeft: "auto" }} />
      </div>

      {shown.length ? (
        <div style={{ display: "grid", gap: "var(--sp-4)" }}>
          {shown.map((q) => (
            <Material key={q.id} material="ultraThin" radius="var(--r-5)" pad={12} elevation="control"
              style={{ display: "grid", gap: 8 }}>
              <div style={{ display: "flex", alignItems: "center", gap: 10, minWidth: 0 }}>
                <Checkbox checked={picked.includes(q.id)} onChange={() => toggle(q.id)} />
                <Badge tone={RISK[q.risk]} mono>{q.tool}</Badge>
                <span style={{ flex: 1, minWidth: 0, font: "var(--type-mono)", color: "var(--term-fg)", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{q.target}</span>
                <span style={{ font: "var(--type-footnote)", color: "var(--label-tertiary)" }}>{q.when}</span>
              </div>
              <div style={{ display: "flex", alignItems: "center", gap: 8, paddingLeft: 26 }}>
                <span style={{ font: "var(--type-subheadline)", color: "var(--label-secondary)" }}>{q.session}</span>
                <Badge tone={RISK[q.risk]}>{q.risk} risk</Badge>
                <div style={{ marginLeft: "auto", display: "flex", gap: 6 }}>
                  <Button size="small" variant="borderless">Explain</Button>
                  <Button size="small">Deny</Button>
                  <Button size="small" variant="accent">Approve</Button>
                </div>
              </div>
            </Material>
          ))}
        </div>
      ) : (
        <Material material="ultraThin" radius="var(--r-5)" pad={24} elevation="control" style={{ display: "grid", gap: 6, justifyItems: "center", textAlign: "center" }}>
          <span style={{ font: "var(--type-title-3)", color: "var(--label-secondary)" }}>No pending approvals</span>
          <span style={{ font: "var(--type-body)", color: "var(--label-tertiary)", maxWidth: "44ch" }}>
            Tools run automatically while auto-approve is on. Anything touching the network or publishing always stops here.
          </span>
        </Material>
      )}

      <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
        <span style={{ font: "var(--type-subheadline)", color: "var(--label-secondary)" }}>{picked.length} selected</span>
        <span style={{ marginLeft: "auto", display: "inline-flex", alignItems: "center", gap: 5, font: "var(--type-footnote)", color: "var(--label-tertiary)" }}>
          <KeyCap size="small">⇧</KeyCap><KeyCap size="small">⌘</KeyCap><KeyCap size="small">A</KeyCap> approve selected
        </span>
        <Button size="small" onClick={resolve} disabled={!picked.length}>Deny selected</Button>
        <Button size="small" variant="accent" onClick={resolve} disabled={!picked.length}>Approve selected</Button>
      </div>
    </div>
  );
}

const FILES = [
  { id: "f1", path: "tests/e2e/session.spec.ts", add: 6, del: 3, state: "staged" },
  { id: "f2", path: "tests/e2e/helpers.ts", add: 2, del: 0, state: "staged" },
  { id: "f3", path: "crates/agent/src/plan.rs", add: 11, del: 4, state: "unstaged" }
];

const HUNK = [
  { n: 118, t: "test('session becomes ready', async ({ page }) => {", k: "plain" },
  { n: 119, t: "  await page.goto('/session/new');", k: "plain" },
  { n: 120, t: "-  await page.waitForSelector('[data-session-ready]');", k: "del" },
  { n: 121, t: "+  await page.waitForEvent('session-ready');", k: "add" },
  { n: 122, t: "+  // the attribute lands a frame after the event", k: "add" },
  { n: 123, t: "  await expect(page.getByRole('log')).toBeVisible();", k: "plain" },
  { n: 124, t: "});", k: "plain" }
];

function DiffScreen() {
  const [file, setFile] = React.useState("f1");
  const [mode, setMode] = React.useState("Unified");
  const current = FILES.find((x) => x.id === file) || FILES[0];
  return (
    <div style={{ display: "grid", gridTemplateColumns: "260px minmax(0,1fr)", minHeight: 0 }}>
      <div style={{ display: "grid", gap: 1, alignContent: "start", minWidth: 0, padding: "var(--sp-5)", boxShadow: "inset -0.5px 0 0 var(--separator)", overflow: "auto" }}>
        <span style={{ font: "var(--type-caps)", letterSpacing: "var(--ls-caps)", textTransform: "uppercase", color: "var(--label-tertiary)", padding: "0 8px 6px" }}>Worktree · agent/flaky-e2e</span>
        {FILES.map((x) => (
          <ListRow key={x.id} size="compact" selected={x.id === file} onClick={() => setFile(x.id)}
            title={x.path.split("/").pop()}
            subtitle={x.path.split("/").slice(0, -1).join("/")}
            trailing={<><span style={{ color: "var(--term-green)" }}>+{x.add}</span><span style={{ color: "var(--term-red)" }}>−{x.del}</span></>} />
        ))}
        <Divider inset={8} style={{ margin: "8px 0" }} />
        <div style={{ padding: "0 8px", display: "grid", gap: 6 }}>
          <Button size="small" fullWidth variant="accent">Commit staged…</Button>
          <Button size="small" fullWidth>Stash worktree</Button>
        </div>
      </div>

      <div style={{ display: "grid", gridTemplateRows: "auto minmax(0,1fr) auto", minHeight: 0, minWidth: 0, overflow: "hidden" }}>
        <div style={{ display: "flex", alignItems: "center", gap: 10, minWidth: 0, padding: "8px var(--sp-7)", boxShadow: "inset 0 -0.5px 0 var(--separator)" }}>
          <span style={{ font: "var(--type-mono)", color: "var(--label-secondary)", minWidth: 0, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{current.path}</span>
          <Badge tone={current.state === "staged" ? "positive" : "caution"}>{current.state}</Badge>
          <SegmentedControl size="small" value={mode} onChange={setMode} items={["Unified", "Split"]} style={{ marginLeft: "auto" }} />
        </div>
        <div style={{ overflow: "auto", minWidth: 0, padding: "var(--sp-6) 0" }}>
          <div style={{ padding: "0 var(--sp-7) 6px", font: "var(--type-mono)", color: "var(--label-tertiary)" }}>@@ -118,7 +118,9 @@</div>
          {HUNK.map((l) => (
            <div key={l.n} style={{
              display: "grid", gridTemplateColumns: "56px 1fr", alignItems: "center", minHeight: 20,
              background: l.k === "add" ? "color-mix(in srgb, var(--status-positive) 13%, transparent)"
                : l.k === "del" ? "color-mix(in srgb, var(--status-negative) 13%, transparent)" : "transparent"
            }}>
              <span style={{ textAlign: "right", paddingRight: 12, font: "var(--fw-regular) var(--fs-mono-sm)/1.5 var(--font-mono)", color: "var(--label-quaternary)" }}>{l.n}</span>
              <span style={{ font: "var(--type-mono)", whiteSpace: "pre", color: l.k === "add" ? "var(--term-green)" : l.k === "del" ? "var(--term-red)" : "var(--term-fg)" }}>{l.t}</span>
            </div>
          ))}
        </div>
        <div style={{ display: "flex", alignItems: "center", gap: 8, padding: "8px var(--sp-7)", boxShadow: "inset 0 0.5px 0 var(--separator)" }}>
          <StatusDot tone="ok" label="playwright 5/5 after this hunk" />
          <div style={{ marginLeft: "auto", display: "flex", gap: 6 }}>
            <Button size="small" variant="borderless">Revert hunk</Button>
            <Button size="small">Stage hunk</Button>
          </div>
        </div>
      </div>
    </div>
  );
}

function CostScreen() {
  const [range, setRange] = React.useState("7 days");
  const bars = [0.42, 0.81, 0.36, 1.24, 0.68, 1.02, 1.23];
  const max = Math.max.apply(null, bars);
  return (
    <div style={{ overflow: "auto", padding: "var(--sp-8)", display: "grid", gap: "var(--sp-7)", alignContent: "start" }}>
      <div style={{ display: "flex", alignItems: "center", gap: "var(--sp-5)" }}>
        <span style={{ font: "var(--type-title-2)" }}>Cost</span>
        <SegmentedControl size="small" value={range} onChange={setRange} items={["24 hours", "7 days", "Month"]} style={{ marginLeft: "auto" }} />
      </div>

      <div style={{ display: "grid", gridTemplateColumns: "repeat(4, 1fr)", gap: "var(--sp-4)" }}>
        {[["Today", "$1.23"], ["This week", "$5.76"], ["This month", "$38.14"], ["Per session", "$0.62"]].map(([k, v]) => (
          <Material key={k} material="ultraThin" radius="var(--r-5)" pad={12} elevation="control" style={{ display: "grid", gap: 4 }}>
            <span style={{ font: "var(--type-caps)", letterSpacing: "var(--ls-caps)", textTransform: "uppercase", color: "var(--label-tertiary)" }}>{k}</span>
            <span style={{ font: "var(--fw-semibold) 22px/1 var(--font-mono)", color: "var(--label)" }}>{v}</span>
          </Material>
        ))}
      </div>

      <Box title="Spend" subtitle="Last 7 days · budget $250/month">
        <div style={{ display: "grid", gap: 10 }}>
          <div style={{ display: "flex", alignItems: "flex-end", gap: 10, height: 110 }}>
            {bars.map((b, i) => (
              <div key={i} style={{ flex: 1, display: "grid", gap: 6, justifyItems: "center", alignContent: "end" }}>
                <span style={{ font: "var(--fw-medium) var(--fs-mono-sm)/1 var(--font-mono)", color: "var(--label-secondary)" }}>{"$" + b.toFixed(2)}</span>
                <span style={{
                  width: "100%", height: Math.round((b / max) * 76) + "px", borderRadius: "var(--r-2)",
                  background: i === bars.length - 1 ? "var(--accent)" : "var(--fill)",
                  boxShadow: i === bars.length - 1 ? "var(--lens-rim), var(--shadow-accent)" : "var(--lens-rim)"
                }} />
                <span style={{ font: "var(--type-footnote)", color: "var(--label-tertiary)" }}>{["M", "T", "W", "T", "F", "S", "S"][i]}</span>
              </div>
            ))}
          </div>
          <ProgressBar value={15} tone="positive" label="Month against budget" valueLabel="$38.14 / $250" />
        </div>
      </Box>

      <div style={{ display: "grid", gridTemplateColumns: "minmax(0,1.2fr) minmax(0,1fr)", gap: "var(--sp-6)" }}>
        <Box title="By session">
          <Table rowHeight="var(--h-list-row-regular)"
            columns={[{ id: "s", label: "Session" }, { id: "t", label: "Tools", width: "62px", align: "right", mono: true }, { id: "c", label: "Cost", width: "72px", align: "right", mono: true }]}
            rows={[
              { id: 1, s: "Bump deps to 1.82", t: "21", c: "$0.88" },
              { id: 2, s: "Refactor auth guard", t: "12", c: "$0.41" },
              { id: 3, s: "Fix flaky e2e", t: "6", c: "$0.19" },
              { id: 4, s: "Write release notes", t: "4", c: "$0.12" }
            ]}
            sort={{ id: "c", dir: "desc" }} onSort={() => {}} selected={1} onSelect={() => {}} />
        </Box>
        <GroupedSection title="Controls" footnote="Hard stop pauses every running agent when the cap is reached."
          rows={[
            { label: "Monthly cap", control: <Badge mono>$250.00</Badge> },
            { label: "Warn at", control: <PopUpButton size="small" value="80%" onChange={() => {}} options={["50%", "80%", "90%"]} width={80} /> },
            { label: "Hard stop", control: <Badge tone="positive">on</Badge> }
          ]} />
      </div>
    </div>
  );
}

window.ApprovalsScreen = ApprovalsScreen;
window.DiffScreen = DiffScreen;
window.CostScreen = CostScreen;
