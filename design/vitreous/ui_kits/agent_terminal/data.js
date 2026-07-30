window.ATLAS = {
  sessions: [
    { id: "s1", label: "Refactor auth guard", state: "done", when: "4m", tools: 12, cost: 0.41 },
    { id: "s2", label: "Fix flaky e2e", state: "running", when: "now", tools: 6, cost: 0.19 },
    { id: "s3", label: "Bump deps to 1.82", state: "review", when: "26m", tools: 21, cost: 0.88 },
    { id: "s4", label: "Write release notes", state: "done", when: "1h", tools: 4, cost: 0.12 },
    { id: "s5", label: "Audit tool permissions", state: "idle", when: "3h", tools: 0, cost: 0 }
  ],
  worktrees: [
    { id: "w1", label: "agent/refactor-auth", state: "done" },
    { id: "w2", label: "agent/flaky-e2e", state: "running" },
    { id: "w3", label: "agent/deps-1.82", state: "review" }
  ],
  transcript: [
    { kind: "user", text: "The e2e session spec is flaky in CI. Find the race and fix it." },
    { kind: "note", text: "plan · 4 steps · read tests, reproduce with repeat-each, patch wait, verify" },
    { kind: "tool", tool: "read", target: "tests/e2e/session.spec.ts", ms: "12ms", out: "142 lines" },
    { kind: "tool", tool: "bash", target: "npx playwright test session --repeat-each 5", ms: "41.2s", out: "2 of 5 failed · timeout waiting for [data-session-ready]" },
    { kind: "assistant", text: "The spec waits on a selector the renderer only sets after the first frame. I'll await the state event instead of the attribute." },
    { kind: "diff", file: "tests/e2e/session.spec.ts", added: 6, removed: 3 },
    { kind: "tool", tool: "bash", target: "npx playwright test session --repeat-each 5", ms: "38.7s", out: "5 of 5 passed" },
    { kind: "pending", tool: "bash", target: "git commit -am 'fix(e2e): await session-ready event'" }
  ],
  calls: [
    { id: 1, tool: "read", target: "tests/e2e/session.spec.ts", ms: "12ms", state: "ok" },
    { id: 2, tool: "bash", target: "playwright --repeat-each 5", ms: "41.2s", state: "warn" },
    { id: 3, tool: "edit", target: "tests/e2e/session.spec.ts", ms: "28ms", state: "ok" },
    { id: 4, tool: "bash", target: "playwright --repeat-each 5", ms: "38.7s", state: "ok" },
    { id: 5, tool: "bash", target: "git commit -am …", ms: "—", state: "pending" }
  ],
  palette: [
    { label: "Fix flaky e2e", detail: "session · running", shortcut: "⏎" },
    { label: "tests/e2e/session.spec.ts", detail: "~/src/atlas" },
    { label: "Run plan…", detail: "command", shortcut: "⌘R" },
    { label: "Approve pending tool", detail: "1 waiting", shortcut: "⇧⌘A" },
    { label: "Open worktree diff", detail: "agent/flaky-e2e" }
  ]
};
